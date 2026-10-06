import SwiftUI
import AVFoundation

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

struct NoteDetail: View {
    @Environment(AppModel.self) private var model
    let noteID: UUID
    @State private var player = AudioPlayer()
    @State private var renamingSpeaker: Int?
    @State private var speakerDraft = ""

    private var note: Note? { model.store.note(noteID) }

    var body: some View {
        if let note {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(note)
                        if note.isBusy || note.status == .failed { StatusBanner(note: note) }
                        if player.available && !note.isBusy { PlayerBar(player: player) }
                        if !note.summary.isEmpty {
                            Card(title: "Summary", icon: "text.alignleft") {
                                Text(note.summary).font(.body).textSelection(.enabled).lineSpacing(3)
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
                        if !note.actionItems.isEmpty {
                            Card(title: "To Do", icon: "checklist") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(note.actionItems.enumerated()), id: \.offset) { _, item in
                                        Label(item, systemImage: "circle").textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        transcript(note)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: note.lines.count) {
                    if note.status == .recording { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        NoteActions(note: note)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                }
            }
            .onAppear { player.load(model.audioURL(for: note)) }
            .onChange(of: note.status) { if note.status == .ready { player.load(model.audioURL(for: note)) } }
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
            .font(.system(size: 26, weight: .bold))
            .textFieldStyle(.plain)
            .disabled(note.isBusy)

            HStack(spacing: 10) {
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
            }
        }
    }

    @ViewBuilder
    private func transcript(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Transcript", systemImage: "quote.bubble")
                .font(.headline)
                .foregroundStyle(.secondary)
            if note.lines.isEmpty {
                Text(note.status == .recording ? "Listening… text appears every ~30 seconds." : "No transcript.")
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
                    .help(player.available ? "Play from here" : "")

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
        }
    }
}

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
        .menuStyle(.button)
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
                Text("Recording — transcribing live on this Mac")
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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }
}
