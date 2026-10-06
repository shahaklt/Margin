import Foundation
import Observation

/// Persists notes and classes as JSON in Application Support, and mirrors every
/// note as Markdown into ~/Documents/Margin/<Class>/ so the folders exist in Finder too.
@MainActor @Observable
final class NoteStore {
    private(set) var notes: [Note] = []
    private(set) var classes: [ClassFolder] = []

    nonisolated static let supportDir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static var notesDir: URL { dir("Notes") }
    nonisolated static var audioDir: URL { dir("Audio") }
    nonisolated static var modelsDir: URL { dir("Models") }

    nonisolated static var exportRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
    }

    nonisolated private static func dir(_ name: String) -> URL {
        let url = supportDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var classesURL: URL { Self.supportDir.appendingPathComponent("classes.json") }
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

    init() { load() }

    // MARK: Loading

    private func load() {
        if let data = try? Data(contentsOf: classesURL),
           let decoded = try? decoder.decode([ClassFolder].self, from: data) {
            classes = decoded
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.notesDir, includingPropertiesForKeys: nil)) ?? []
        notes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Note.self, from: Data(contentsOf: $0)) }
            .map { note in
                // A note left busy means the app quit mid-flight.
                var n = note
                if n.isBusy {
                    n.status = .failed
                    n.statusDetail = "Interrupted — use Retry to transcribe the saved audio."
                }
                return n
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Notes

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    func upsert(_ note: Note, persist: Bool = true) {
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
        try? FileManager.default.removeItem(at: Self.notesDir.appendingPathComponent("\(id).json"))
        if let audio = n.audioFileName {
            try? FileManager.default.removeItem(at: Self.audioDir.appendingPathComponent(audio))
        }
        removeExport(n)
    }

    func file(_ id: UUID, into classID: UUID?) {
        update(id) {
            $0.classID = classID
            $0.manuallyFiled = true
        }
    }

    func notes(in classID: UUID?) -> [Note] { notes.filter { $0.classID == classID } }

    private func save(_ note: Note, previous: Note?) {
        if let data = try? encoder.encode(note) {
            try? data.write(to: Self.notesDir.appendingPathComponent("\(note.id).json"), options: .atomic)
        }
        if let previous, exportURL(previous) != exportURL(note) { removeExport(previous) }
        export(note)
    }

    // MARK: Classes

    func addClass(_ name: String, keywords: [String] = []) -> ClassFolder {
        let c = ClassFolder(name: name, keywords: keywords, colorIndex: classes.count)
        classes.append(c)
        saveClasses()
        return c
    }

    func updateClass(_ c: ClassFolder) {
        guard let i = classes.firstIndex(where: { $0.id == c.id }) else { return }
        let renamed = classes[i].name != c.name
        let affected = notes(in: c.id)
        if renamed { affected.forEach(removeExport) }
        classes[i] = c
        saveClasses()
        if renamed { affected.forEach(export) }
    }

    func deleteClass(_ id: UUID) {
        for n in notes(in: id) {
            removeExport(n)
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
        if let data = try? encoder.encode(classes) { try? data.write(to: classesURL, options: .atomic) }
    }

    // MARK: Finder mirror

    private var mirrorEnabled: Bool { UserDefaults.standard.object(forKey: "mirrorToFinder") as? Bool ?? true }

    private func exportURL(_ note: Note) -> URL {
        let folderName = sanitize(folder(note.classID)?.name ?? "Unsorted")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        let file = "\(df.string(from: note.createdAt)) \(sanitize(note.title)).md"
        return Self.exportRoot.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(file)
    }

    private func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return String(s.components(separatedBy: bad).joined(separator: "-").prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    private func export(_ note: Note) {
        guard mirrorEnabled, note.status == .ready else { return }
        let url = exportURL(note)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? markdown(note).write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeExport(_ note: Note) {
        try? FileManager.default.removeItem(at: exportURL(note))
    }

    func markdown(_ note: Note) -> String {
        var md = "# \(note.title)\n\n"
        md += "*\(note.createdAt.formatted(date: .complete, time: .shortened)) · \(note.duration.friendlyDuration)"
        if let c = folder(note.classID) { md += " · \(c.name)" }
        md += "*\n\n"
        if !note.summary.isEmpty { md += "## Summary\n\n\(note.summary)\n\n" }
        if !note.keyPoints.isEmpty { md += "## Key Points\n\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !note.actionItems.isEmpty { md += "## Action Items\n\n" + note.actionItems.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n" }
        md += "## Transcript\n\n"
        for line in note.lines {
            md += "**\(note.speakerName(line.speaker))** `\(line.start.clock)`  \n\(line.text)\n\n"
        }
        return md
    }
}
