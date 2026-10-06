import Foundation
import Observation

/// Where the library lives. With sync on, that's a "Margin" folder in iCloud Drive that both
/// the Mac and iPhone apps read and write — no iCloud entitlement or paid developer account needed.
enum Library {
    nonisolated static let localSupport: URL = {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        #endif
        let url = base.appendingPathComponent("Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Device-local, never synced.
    nonisolated static var modelsDir: URL { ensure(localSupport.appendingPathComponent("Models", isDirectory: true)) }
    nonisolated static var recordingDir: URL { ensure(localSupport.appendingPathComponent("Recording", isDirectory: true)) }

    #if os(macOS)
    nonisolated static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    nonisolated static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }
    #endif

    /// The synced (or local fallback) library root.
    @MainActor static func resolveRoot() -> URL {
        #if os(macOS)
        let syncOn = UserDefaults.standard.object(forKey: "syncICloud") as? Bool ?? true
        if syncOn, iCloudAvailable {
            return ensure(iCloudDrive.appendingPathComponent("Margin", isDirectory: true))
        }
        return ensure(localSupport.appendingPathComponent("Library", isDirectory: true))
        #else
        if let url = SyncBookmark.resolve() { return url }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ensure(docs.appendingPathComponent("Margin", isDirectory: true))
        #endif
    }

    @discardableResult
    nonisolated static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

#if os(iOS)
/// The iCloud Drive folder the user picked on the phone, kept as a security-scoped bookmark.
enum SyncBookmark {
    private static var active: URL?

    @MainActor static func save(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: "syncBookmark")
        active?.stopAccessingSecurityScopedResource()
        active = url
    }

    @MainActor static func resolve() -> URL? {
        if let active { return active }
        guard let data = UserDefaults.standard.data(forKey: "syncBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "syncBookmark")
        }
        active = url
        return url
    }

    @MainActor static var isSet: Bool { UserDefaults.standard.data(forKey: "syncBookmark") != nil }

    @MainActor static func clear() {
        active?.stopAccessingSecurityScopedResource()
        active = nil
        UserDefaults.standard.removeObject(forKey: "syncBookmark")
    }
}
#endif

/// Persists notes and classes as JSON files in the library root and picks up changes
/// made by the other device. Layout:
///   classes.json · Notes/<id>.json · Audio/<id>.m4a · Sheets/<id>.tex|pdf · Classes/<Class>/…
@MainActor @Observable
final class NoteStore {
    private(set) var notes: [Note] = []
    private(set) var classes: [ClassFolder] = []
    private(set) var root: URL
    /// Bumped whenever a sheet PDF changes so views reload it.
    private(set) var sheetRevision = 0

    /// Notes this device is actively writing; remote copies never clobber them.
    var locallyBusy: Set<UUID> = []

    private var knownDates: [String: Date] = [:]
    private var classesDate: Date?
    private var watcher: Timer?
    var onRemoteChange: (() -> Void)?

    var notesDir: URL { Library.ensure(root.appendingPathComponent("Notes", isDirectory: true)) }
    var audioDir: URL { Library.ensure(root.appendingPathComponent("Audio", isDirectory: true)) }
    var sheetsDir: URL { Library.ensure(root.appendingPathComponent("Sheets", isDirectory: true)) }
    var classesRoot: URL { root.appendingPathComponent("Classes", isDirectory: true) }
    private var classesURL: URL { root.appendingPathComponent("classes.json") }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        root = Library.resolveRoot()
        #if os(macOS)
        migrateLegacyLibrary()
        #endif
        load()
        startWatching()
    }

    func reopen() {
        root = Library.resolveRoot()
        knownDates = [:]
        classesDate = nil
        load()
    }

    // MARK: Loading & sync

    private func load() {
        classes = readClasses() ?? []
        classesDate = modDate(classesURL)
        var loaded: [Note] = []
        for (url, date) in listNoteFiles() {
            knownDates[url.lastPathComponent] = date
            if var n = readNote(url) {
                // A note this device left busy means the app quit mid-flight.
                if n.isBusy && n.origin == .current {
                    n.status = .failed
                    n.statusDetail = "Interrupted — use Retry to transcribe the saved audio."
                }
                loaded.append(n)
            }
        }
        notes = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func startWatching() {
        watcher = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromDisk() }
        }
    }

    /// Pulls in notes/classes changed by the other device.
    func syncFromDisk() {
        var changed = false
        if let d = modDate(classesURL), d != classesDate {
            classesDate = d
            if let c = readClasses(), c != classes { classes = c; changed = true }
        }
        let files = listNoteFiles()
        var seen = Set<UUID>()
        for (url, date) in files {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            seen.insert(id)
            guard knownDates[url.lastPathComponent] != date else { continue }
            knownDates[url.lastPathComponent] = date
            guard !locallyBusy.contains(id), let remote = readNote(url) else { continue }
            if let i = notes.firstIndex(where: { $0.id == id }) {
                if remote.updatedAt > notes[i].updatedAt {
                    if remote.sheetStatus == .ready { sheetRevision += 1 }
                    notes[i] = remote
                    changed = true
                }
            } else {
                notes.append(remote)
                notes.sort { $0.createdAt > $1.createdAt }
                changed = true
            }
        }
        // Deleted on the other device (and not just evicted to a placeholder).
        let gone = notes.filter { !seen.contains($0.id) && !locallyBusy.contains($0.id) && $0.status != .recording }
        if !gone.isEmpty {
            let placeholders = placeholderIDs()
            let removed = gone.filter { !placeholders.contains($0.id) }.map(\.id)
            if !removed.isEmpty { notes.removeAll { removed.contains($0.id) }; changed = true }
        }
        if changed { onRemoteChange?() }
    }

    private func listNoteFiles() -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: keys)) ?? []
        var out: [(URL, Date)] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                // Evicted by iCloud — ask for it; it'll show up on a later pass.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard url.pathExtension == "json" else { continue }
            out.append((url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast))
        }
        return out
    }

    private func placeholderIDs() -> Set<UUID> {
        let urls = (try? FileManager.default.contentsOfDirectory(atPath: notesDir.path)) ?? []
        return Set(urls.compactMap { name in
            guard name.hasPrefix("."), name.hasSuffix(".json.icloud") else { return nil }
            return UUID(uuidString: String(name.dropFirst().dropLast(".json.icloud".count)))
        })
    }

    private func modDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func readNote(_ url: URL) -> Note? {
        guard let data = coordinatedRead(url) else { return nil }
        return try? decoder.decode(Note.self, from: data)
    }

    private func readClasses() -> [ClassFolder]? {
        guard let data = coordinatedRead(classesURL) else { return nil }
        return try? decoder.decode([ClassFolder].self, from: data)
    }

    // MARK: Coordinated file access (keeps iCloud Drive happy)

    func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    func coordinatedWrite(_ data: Data, to url: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            try? data.write(to: u, options: .atomic)
        }
    }

    func coordinatedDelete(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// Copies a file into the library (e.g. audio), coordinated.
    func coordinatedCopy(_ src: URL, to dst: URL) throws {
        var err: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { u in
            do {
                if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
                try FileManager.default.copyItem(at: src, to: u)
            } catch { thrown = error }
        }
        if let e = thrown ?? err { throw e }
    }

    // MARK: Notes

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    func upsert(_ note: Note, persist: Bool = true) {
        var note = note
        if persist { note.updatedAt = Date() }
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            let old = notes[i]
            notes[i] = note
            if persist { save(note, previous: old) }
        } else {
            notes.insert(note, at: 0)
            if persist { save(note, previous: nil) }
        }
    }

    func update(_ id: UUID, persist: Bool = true, _ change: (inout Note) -> Void) {
        guard var n = note(id) else { return }
        change(&n)
        upsert(n, persist: persist)
    }

    func delete(_ id: UUID) {
        guard let n = note(id) else { return }
        notes.removeAll { $0.id == id }
        coordinatedDelete(notesDir.appendingPathComponent("\(id).json"))
        if let audio = n.audioFileName { coordinatedDelete(audioDir.appendingPathComponent(audio)) }
        coordinatedDelete(sheetURL(id, "tex"))
        coordinatedDelete(sheetURL(id, "pdf"))
        removeMirror(n)
    }

    func file(_ id: UUID, into classID: UUID?) {
        update(id) {
            $0.classID = classID
            $0.manuallyFiled = true
        }
    }

    func notes(in classID: UUID?) -> [Note] { notes.filter { $0.classID == classID } }

    private func save(_ note: Note, previous: Note?) {
        guard let data = try? encoder.encode(note) else { return }
        let url = notesDir.appendingPathComponent("\(note.id).json")
        coordinatedWrite(data, to: url)
        knownDates[url.lastPathComponent] = modDate(url)
        if let previous, mirrorURL(previous, "md") != mirrorURL(note, "md") { removeMirror(previous) }
        writeMirror(note)
    }

    // MARK: Audio & sheets

    func audioURL(_ note: Note) -> URL? {
        guard let name = note.audioFileName else { return nil }
        let url = audioDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let placeholder = audioDir.appendingPathComponent(".\(name).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
        }
        return nil
    }

    func sheetURL(_ id: UUID, _ ext: String) -> URL { sheetsDir.appendingPathComponent("\(id).\(ext)") }

    func sheetTeX(_ id: UUID) -> String? {
        coordinatedRead(sheetURL(id, "tex")).flatMap { String(data: $0, encoding: .utf8) }
    }

    func sheetPDF(_ id: UUID) -> URL? {
        let url = sheetURL(id, "pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let placeholder = sheetsDir.appendingPathComponent(".\(id).pdf.icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
        }
        return nil
    }

    func saveSheet(_ id: UUID, tex: String, pdf: Data?) {
        coordinatedWrite(Data(tex.utf8), to: sheetURL(id, "tex"))
        if let pdf { coordinatedWrite(pdf, to: sheetURL(id, "pdf")) } else { coordinatedDelete(sheetURL(id, "pdf")) }
        sheetRevision += 1
        if let n = note(id) { writeMirror(n) }
    }

    // MARK: Classes

    func addClass(_ name: String, keywords: [String] = [], colorIndex: Int? = nil) -> ClassFolder {
        let c = ClassFolder(name: name, keywords: keywords, colorIndex: colorIndex ?? classes.count)
        classes.append(c)
        saveClasses()
        return c
    }

    func updateClass(_ c: ClassFolder) {
        guard let i = classes.firstIndex(where: { $0.id == c.id }) else { return }
        let renamed = classes[i].name != c.name
        let affected = notes(in: c.id)
        if renamed { affected.forEach(removeMirror) }
        classes[i] = c
        saveClasses()
        if renamed { affected.forEach(writeMirror) }
    }

    func deleteClass(_ id: UUID) {
        for n in notes(in: id) {
            removeMirror(n)
            update(n.id) { $0.classID = nil; $0.manuallyFiled = false }
        }
        classes.removeAll { $0.id == id }
        saveClasses()
    }

    func folder(_ id: UUID?) -> ClassFolder? {
        guard let id else { return nil }
        return classes.first { $0.id == id }
    }

    private func saveClasses() {
        guard let data = try? encoder.encode(classes) else { return }
        coordinatedWrite(data, to: classesURL)
        classesDate = modDate(classesURL)
    }

    // MARK: Per-class folders (Markdown + PDF sheet), written by the Mac only to avoid duplicate writers

    private var mirrorEnabled: Bool {
        #if os(macOS)
        UserDefaults.standard.object(forKey: "mirrorToFinder") as? Bool ?? true
        #else
        false
        #endif
    }

    func mirrorURL(_ note: Note, _ ext: String) -> URL {
        let folderName = Self.sanitize(folder(note.classID)?.name ?? "Unsorted")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        let file = "\(df.string(from: note.createdAt)) \(Self.sanitize(note.title)).\(ext)"
        return classesRoot.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(file)
    }

    nonisolated static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return String(s.components(separatedBy: bad).joined(separator: "-").prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    private func writeMirror(_ note: Note) {
        guard mirrorEnabled, note.status == .ready else { return }
        let md = mirrorURL(note, "md")
        Library.ensure(md.deletingLastPathComponent())
        coordinatedWrite(Data(Exporter.markdown(note, className: folder(note.classID)?.name).utf8), to: md)
        if let pdf = sheetPDF(note.id) {
            try? coordinatedCopy(pdf, to: mirrorURL(note, "pdf"))
        }
    }

    private func removeMirror(_ note: Note) {
        guard mirrorEnabled else { return }
        coordinatedDelete(mirrorURL(note, "md"))
        coordinatedDelete(mirrorURL(note, "pdf"))
    }

    // MARK: Migration from v1 (Application Support) into the synced library

    #if os(macOS)
    private func migrateLegacyLibrary() {
        let legacy = Library.localSupport
        let legacyNotes = legacy.appendingPathComponent("Notes")
        guard root.path != legacy.path,
              !UserDefaults.standard.bool(forKey: "migratedV1"),
              FileManager.default.fileExists(atPath: legacyNotes.path) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: classesURL.path), fm.fileExists(atPath: legacy.appendingPathComponent("classes.json").path) {
            try? coordinatedCopy(legacy.appendingPathComponent("classes.json"), to: classesURL)
        }
        for url in (try? fm.contentsOfDirectory(at: legacyNotes, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            let dst = notesDir.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: dst.path) { try? coordinatedCopy(url, to: dst) }
        }
        let legacyAudio = legacy.appendingPathComponent("Audio")
        for url in (try? fm.contentsOfDirectory(at: legacyAudio, includingPropertiesForKeys: nil)) ?? [] {
            let dst = audioDir.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: dst.path) { try? coordinatedCopy(url, to: dst) }
        }
        UserDefaults.standard.set(true, forKey: "migratedV1")
    }
    #endif
}
