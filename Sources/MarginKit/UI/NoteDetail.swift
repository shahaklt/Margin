import SwiftUI
import AVFoundation
import PDFKit

@MainActor @Observable
final class AudioPlayer {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0

    func load(_ url: URL?) {
        stop()
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { player = nil; duration = 0; return }
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    var available: Bool { player != nil }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func seek(_ t: Double) {
        player?.currentTime = max(0, t - 0.3)
        currentTime = t
        if !isPlaying { play() }
    }

    func stop() {
        pause()
        player?.stop()
        currentTime = 0
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case notes = "Notes", sheet = "Sheet", transcript = "Transcript", ask = "Ask"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .notes: "sparkles"
        case .sheet: "doc.richtext"
        case .transcript: "quote.bubble"
        case .ask: "bubble.left.and.text.bubble.right"
        }
    }
}

enum Layout {
    #if os(iOS)
    static let hPad: CGFloat = 16
    static let titleSize: CGFloat = 24
    #else
    static let hPad: CGFloat = 28
    static let titleSize: CGFloat = 26
    #endif
}

struct NoteDetail: View {
    @Environment(AppModel.self) private var model
    let noteID: UUID
    var initialTab: DetailTab = .notes
    @State private var player = AudioPlayer()
    @State private var tab: DetailTab = .notes
    @State private var renamingSpeaker: Int?
    @State private var speakerDraft = ""

    private var note: Note? { model.store.note(noteID) }

    var body: some View {
        if let note {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    header(note)
                    if note.isBusy || note.status == .failed || note.status == .queued { StatusBanner(note: note) }
                    if player.available && !note.isBusy { PlayerBar(player: player) }
                    Picker("View", selection: $tab) {
                        ForEach(DetailTab.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, Layout.hPad)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 820)

                Divider().opacity(0.4)

                Group {
                    switch tab {
                    case .notes: NotesTab(note: note)
                    case .sheet: SheetTab(note: note)
                    case .transcript: transcript(note)
                    case .ask: AskTab(note: note)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem { ExportMenu(note: note) }
                ToolbarItem {
                    Menu {
                        NoteActions(note: note)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                }
            }
            .onAppear {
                player.load(model.store.audioURL(note))
                tab = note.status == .recording ? .transcript : initialTab
            }
            .onChange(of: note.status) { if note.status == .ready { player.load(model.store.audioURL(note)) } }
            .onChange(of: note.audioFileName) { player.load(model.store.audioURL(note)) }
            .onDisappear { player.stop() }
            .alert("Rename Speaker", isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
                TextField("Name", text: $speakerDraft)
                Button("Save") {
                    if let s = renamingSpeaker {
                        let name = speakerDraft.trimmingCharacters(in: .whitespaces)
                        model.store.update(noteID) { $0.speakerNames[s] = name.isEmpty ? nil : name }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func header(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: Binding(
                get: { note.title },
                set: { new in model.store.update(noteID) { $0.title = new } }
            ), axis: .vertical)
            .font(.system(size: Layout.titleSize, weight: .bold))
            .textFieldStyle(.plain)
            .disabled(note.isBusy)

            #if os(iOS)
            // Phone: class chip + one compact line of facts.
            HStack(spacing: 10) {
                ClassPicker(note: note)
                Text(compactFacts(note)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            #else
            HStack(spacing: 10) { meta(note) }
            #endif
        }
    }

    private func compactFacts(_ note: Note) -> String {
        var parts = [note.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())]
        if note.duration > 0 { parts.append(note.duration.friendlyDuration) }
        if note.speakerCount > 0 { parts.append("\(note.speakerCount) speaker\(note.speakerCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func meta(_ note: Note) -> some View {
        ClassPicker(note: note)
        Group {
            Label(note.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            if note.duration > 0 { Label(note.duration.friendlyDuration, systemImage: "clock") }
            if note.speakerCount > 0 {
                Label("\(note.speakerCount) speaker\(note.speakerCount == 1 ? "" : "s")", systemImage: "person.2")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func transcript(_ note: Note) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if note.lines.isEmpty {
                        Text(note.status == .recording ? "Listening… text appears every ~30 seconds." : "No transcript yet.")
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(note.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Button {
                                player.seek(line.start)
                            } label: {
                                Text(line.start.clock)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .disabled(!player.available)

                            VStack(alignment: .leading, spacing: 3) {
                                if line.speaker >= 0 {
                                    Button {
                                        speakerDraft = note.speakerNames[line.speaker] ?? ""
                                        renamingSpeaker = line.speaker
                                    } label: {
                                        Text(note.speakerName(line.speaker))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Palette.color(line.speaker * 3 + 1))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Rename speaker")
                                }
                                Text(line.text)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                                    .foregroundStyle(note.status == .recording ? .secondary : .primary)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Layout.hPad)
                .padding(.vertical, 18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: note.lines.count) {
                if note.status == .recording { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }
}

// MARK: Notes tab

struct NotesTab: View {
    let note: Note

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !note.summary.isEmpty {
                    Card(title: "Summary", icon: "text.alignleft") {
                        Text(note.summary).textSelection(.enabled).lineSpacing(3)
                    }
                }
                if !note.actionItems.isEmpty {
                    Card(title: "Reminders & To Do", icon: "bell.badge", tint: .red) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(note.actionItems.enumerated()), id: \.offset) { _, item in
                                Label(item, systemImage: "circle").textSelection(.enabled)
                            }
                        }
                    }
                }
                if !note.keyPoints.isEmpty {
                    Card(title: "Key Points", icon: "sparkles") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(note.keyPoints.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -3)
                                    Text(point).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                if note.summary.isEmpty && note.keyPoints.isEmpty {
                    ContentUnavailableView("No Notes Yet", systemImage: "sparkles", description: Text(note.isBusy ? "Notes appear when transcription finishes." : "Nothing to summarize."))
                }
                if let engine = note.notesEngine {
                    Text("Written by \(engine)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Layout.hPad)
            .padding(.vertical, 18)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Sheet tab (LaTeX → PDF)

struct SheetTab: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        let _ = model.store.sheetRevision
        VStack(spacing: 0) {
            if let pdf = model.store.sheetPDF(note.id), note.sheetStatus != .generating {
                PDFViewer(url: pdf, revision: model.store.sheetRevision)
                HStack(spacing: 12) {
                    if let err = note.sheetError {
                        Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                    Spacer()
                    #if os(macOS)
                    Button("Open in Preview") { NSWorkspace.shared.open(pdf) }
                    #endif
                    rewriteButton
                }
                .padding(10)
                .background(.bar)
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch note.sheetStatus {
        case .generating:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(model.brainAvailable ? "Claude is writing your note sheet…" : "Building your note sheet…")
            }
        case .pending where model.brain == nil:
            ContentUnavailableView("Waiting for Your Mac", systemImage: "laptopcomputer.and.iphone",
                                   description: Text("Your Mac writes the LaTeX sheet with Claude and syncs it here through iCloud Drive."))
        default:
            ContentUnavailableView {
                Label("No Note Sheet Yet", systemImage: "doc.richtext")
            } description: {
                if let err = note.sheetError { Text(err) }
                else if note.isBusy { Text("The sheet is written after transcription finishes.") }
                else { Text("Generate a LaTeX study sheet with equations, reminders and key concepts.") }
            } actions: {
                if model.brain != nil, !note.isBusy, !note.lines.isEmpty { rewriteButton }
            }
        }
    }

    @ViewBuilder
    private var rewriteButton: some View {
        if model.brain != nil {
            Button(model.brainAvailable ? "Rewrite with Claude" : "Rebuild Sheet") { model.regenerate(note.id) }
                .buttonStyle(.glass)
                .disabled(note.isBusy || note.sheetStatus == .generating)
        }
    }
}

#if os(macOS)
struct PDFViewer: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if context.coordinator.loaded != "\(url.path)#\(revision)" {
            context.coordinator.loaded = "\(url.path)#\(revision)"
            v.document = PDFDocument(url: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = "" }
}
#else
struct PDFViewer: UIViewRepresentable {
    let url: URL
    let revision: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if context.coordinator.loaded != "\(url.path)#\(revision)" {
            context.coordinator.loaded = "\(url.path)#\(revision)"
            v.document = PDFDocument(url: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = "" }
}
#endif

// MARK: Ask tab

struct AskTab: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let suggestions = ["What will be on the test?", "Explain the hardest concept simply", "Quiz me on this lesson", "List every equation and when to use it"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if note.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(intro).foregroundStyle(.secondary)
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { send(s) }
                                        .buttonStyle(.glass)
                                        .disabled(note.lines.isEmpty)
                                }
                            }
                        }
                        ForEach(note.chat) { msg in
                            ChatBubble(message: msg, waitingForMac: model.brain == nil)
                        }
                        if note.chat.last?.pending == true, model.brain != nil {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Claude is thinking…").foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Layout.hPad)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: note.chat.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            HStack(spacing: 8) {
                TextField("Ask about this class…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { send(draft) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || note.lines.isEmpty)
                if !note.chat.isEmpty {
                    Menu {
                        Button("Clear Conversation", role: .destructive) { model.clearChat(note.id) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: 820)
        }
    }

    private var intro: String {
        if model.brain == nil { return "Ask anything about this class. Your Mac answers with Claude next time it's on, and the reply syncs here." }
        if !model.brainAvailable { return "Sign in to Claude in Settings to ask questions about this class." }
        return "Ask Claude anything about this class. Uses your Claude plan through Claude Code."
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.ask(note.id, t)
        draft = ""
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let waitingForMac: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(LocalizedStringKey(message.text))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: .rect(cornerRadius: 16))
                if message.pending && waitingForMac {
                    Label("Waiting for your Mac", systemImage: "laptopcomputer").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

// MARK: Export

struct ExportMenu: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @State private var exportDoc: ExportDocument?
    @State private var exportAll: [ExportDocument] = []
    @State private var showingSingle = false
    @State private var showingAll = false
    @State private var shareURLs: [URL] = []

    var body: some View {
        let kinds = Exporter.available(note, store: model.store)
        Menu {
            Section("Save As…") {
                ForEach(kinds) { kind in
                    Button { save(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                }
            }
            Button {
                exportAll = Exporter.all(note: note, store: model.store).map(ExportDocument.init(url:))
                showingAll = !exportAll.isEmpty
            } label: { Label("Save Everything to Folder…", systemImage: "folder.badge.plus") }
            .disabled(kinds.isEmpty)
            Divider()
            #if os(macOS)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Exporter.markdown(note, className: model.store.folder(note.classID)?.name), forType: .string)
            } label: { Label("Copy Notes as Markdown", systemImage: "doc.on.doc") }
            if let tex = model.store.sheetTeX(note.id) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tex, forType: .string)
                } label: { Label("Copy LaTeX Source", systemImage: "function") }
            }
            #else
            Button {
                UIPasteboard.general.string = Exporter.markdown(note, className: model.store.folder(note.classID)?.name)
            } label: { Label("Copy Notes as Markdown", systemImage: "doc.on.doc") }
            #endif
            ShareLink(items: Exporter.all(note: note, store: model.store)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .disabled(kinds.isEmpty)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(note.isBusy)
        .help("Save or share the transcript, notes, LaTeX sheet, or audio")
        .fileExporter(isPresented: $showingSingle, document: exportDoc, contentType: exportDoc?.contentType ?? .data,
                      defaultFilename: exportDoc?.url.lastPathComponent) { _ in }
        .fileExporter(isPresented: $showingAll, documents: exportAll, contentType: .data) { _ in }
    }

    private func save(_ kind: Exporter.Kind) {
        guard let url = try? Exporter.file(kind, note: note, store: model.store) else {
            model.alert = "That file isn't available on this device yet."
            return
        }
        exportDoc = ExportDocument(url: url)
        showingSingle = true
    }
}

// MARK: Pieces

struct ClassPicker: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        let folder = model.store.folder(note.classID)
        Menu {
            Button("Unsorted") { model.store.file(note.id, into: nil) }
            Divider()
            ForEach(model.store.classes) { c in
                Button(c.name) { model.store.file(note.id, into: c.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(folder?.color ?? .secondary)
                Text(folder?.name ?? "Unsorted")
            }
            .font(.callout.weight(.medium))
        }
        .buttonStyle(.glass)
        .fixedSize()
    }
}

struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        HStack(spacing: 10) {
            switch note.status {
            case .recording:
                RecordingDot()
                Text(model.transcribeOnThisDevice ? "Recording — transcribing live on this device" : "Recording — your Mac will transcribe it")
            case .queued:
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                Text(note.statusDetail ?? "Waiting to be transcribed").lineLimit(2)
                Spacer()
                if model.transcribeOnThisDevice { Button("Transcribe Now") { model.retry(note.id) } }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(note.statusDetail ?? "Something went wrong.").lineLimit(2)
                Spacer()
                Button("Retry") { model.retry(note.id) }
            default:
                ProgressView().controlSize(.small)
                Text(note.statusDetail ?? (note.status == .transcribing ? "Transcribing…" : "Writing notes…"))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct PlayerBar: View {
    let player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                .controlSize(.small)
            Text("\(player.currentTime.clock) / \(player.duration.clock)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }
}
