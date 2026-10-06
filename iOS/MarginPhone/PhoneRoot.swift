import SwiftUI
import UniformTypeIdentifiers

enum PhoneRoute: Hashable {
    case folder(UUID?)   // nil = Unsorted
    case all
    case note(UUID, DetailTab)
}

/// iPhone: a navigation stack (classes → notes → note) with a floating record dock.
/// iPad / wide windows use the same three-column layout as the Mac.
struct PhoneRoot: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            ContentView()
                .safeAreaInset(edge: .bottom) { RecordDock(onFinished: { _ in }).padding(.bottom, 8) }
        } else {
            PhoneHome()
        }
    }
}

struct PhoneHome: View {
    @Environment(AppModel.self) private var model
    @State private var path: [PhoneRoute] = []
    @State private var search = ""
    @State private var importing = false
    @State private var showSettings = false
    @State private var addingClass = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.transcribeOnThisDevice && !model.modelReady && !DemoMode.isOn {
                    ModelStatusCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if search.isEmpty {
                    Section("Classes") {
                        ForEach(model.store.classes) { c in
                            NavigationLink(value: PhoneRoute.folder(c.id)) {
                                folderRow(c.name, icon: "folder.fill", tint: c.color, count: model.store.notes(in: c.id).count)
                            }
                        }
                        NavigationLink(value: PhoneRoute.folder(nil)) {
                            folderRow("Unsorted", icon: "questionmark.folder", tint: .secondary, count: model.store.notes(in: nil).count)
                        }
                        Button { addingClass = true } label: {
                            Label(model.store.classes.isEmpty ? "Add your classes" : "Add Class", systemImage: "plus")
                        }
                    }
                }
                Section {
                    let notes = recent
                    if notes.isEmpty {
                        Text(search.isEmpty ? "Tap Record to capture a class, or import a voice memo." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(notes) { note in
                        NavigationLink(value: PhoneRoute.note(note.id, .notes)) { NoteRow(note: note) }
                            .swipeActions { deleteButton(note) }
                            .contextMenu { NoteActions(note: note) }
                    }
                } header: {
                    HStack {
                        Text(search.isEmpty ? "Recent" : "Results")
                        Spacer()
                        if search.isEmpty && model.store.notes.count > recent.count {
                            NavigationLink("See All", value: PhoneRoute.all).font(.caption).textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Margin")
            .searchable(text: $search, prompt: "Search notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Import voice memo")
                }
            }
            .navigationDestination(for: PhoneRoute.self) { route in
                switch route {
                case .folder(let id): PhoneNoteList(classID: id, showsAll: false)
                case .all: PhoneNoteList(classID: nil, showsAll: true)
                case .note(let id, let tab):
                    NoteDetail(noteID: id, initialTab: tab)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordDock { id in path = [.note(id, .transcript)] }
                    .padding(.bottom, 4)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AudioFiles.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.importAudio(urls)
                if let id = model.selectedNoteID { path = [.note(id, .notes)] }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { PhoneSettings() } }
        .sheet(isPresented: $addingClass) { ClassEditor(folder: nil).presentationDetents([.large]) }
        .alert("Margin", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.alert ?? "") }
        .onChange(of: model.selectedNoteID) { _, id in
            // Opening a shared voice memo jumps straight to it.
            if let id, model.store.note(id)?.status == .transcribing, path.isEmpty { path = [.note(id, .notes)] }
        }
        .onAppear(perform: openDemoScreen)
    }

    private var recent: [Note] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(model.store.notes.prefix(8)) }
        return model.store.notes.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
                || $0.plainTranscript.localizedCaseInsensitiveContains(q)
        }
    }

    private func folderRow(_ title: String, icon: String, tint: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: { Image(systemName: icon).foregroundStyle(tint) }
    }

    private func deleteButton(_ note: Note) -> some View {
        Button(role: .destructive) { model.store.delete(note.id) } label: { Label("Delete", systemImage: "trash") }
            .disabled(note.status == .recording)
    }

    private func openDemoScreen() {
        guard DemoMode.isOn, path.isEmpty, let screen = DemoMode.screen else { return }
        let note = model.store.notes.first { $0.status == .ready && !$0.lines.isEmpty }
        switch screen {
        case "folder": if let c = model.store.classes.dropFirst().first { path = [.folder(c.id)] }
        case "notes": if let note { path = [.note(note.id, .notes)] }
        case "sheet": if let note { path = [.note(note.id, .sheet)] }
        case "transcript": if let note { path = [.note(note.id, .transcript)] }
        case "ask": if let note { path = [.note(note.id, .ask)] }
        case "settings": showSettings = true
        default: break
        }
    }
}

struct PhoneNoteList: View {
    @Environment(AppModel.self) private var model
    let classID: UUID?
    let showsAll: Bool
    @State private var editing: ClassFolder?

    var body: some View {
        let notes = showsAll ? model.store.notes : model.store.notes(in: classID)
        List {
            if notes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Recordings filed here show up in this list."))
            }
            ForEach(notes) { note in
                NavigationLink(value: PhoneRoute.note(note.id, .notes)) { NoteRow(note: note) }
                    .swipeActions {
                        Button(role: .destructive) { model.store.delete(note.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu { NoteActions(note: note) }
            }
        }
        .navigationTitle(showsAll ? "All Notes" : model.store.folder(classID)?.name ?? "Unsorted")
        .toolbar {
            if let c = model.store.folder(classID) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { editing = c }
                }
            }
        }
        .sheet(item: $editing) { ClassEditor(folder: $0) }
    }
}

/// Bottom glass dock: a Record button when idle; a live panel (waveform, timer, latest words, Stop)
/// while recording; a small progress pill while notes are being written.
struct RecordDock: View {
    @Environment(AppModel.self) private var model
    var onFinished: (UUID) -> Void
    @Namespace private var glass

    private var liveText: String? {
        guard let id = model.recordingNoteID, let last = model.store.note(id)?.lines.last?.text else { return nil }
        return String(last.suffix(110))
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if model.isRecording || DemoMode.screen == "recording" {
                recordingPanel
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .glassEffectID("dock", in: glass)
            } else {
                HStack(spacing: 12) {
                    if model.processingCount > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Writing notes").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).frame(height: 48)
                        .glassEffect(.regular, in: .capsule)
                    }
                    Button {
                        Task { await model.startRecording() }
                    } label: {
                        Label("Record", systemImage: "record.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 22).frame(height: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .glassEffectID("dock", in: glass)
                }
            }
        }
        .padding(.horizontal, 16)
        .animation(.smooth(duration: 0.35), value: model.isRecording)
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RecordingDot()
                Text("Recording").font(.subheadline.weight(.semibold))
                Spacer()
                if let start = model.recorder.startedAt {
                    Text(start, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("12:34").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Waveform(levels: DemoMode.screen == "recording" ? (0..<48).map { Float(0.3 + 0.6 * abs(sin(Double($0) * 0.6))) } : model.recorder.levels,
                     barCount: 40, color: .red)
                .frame(height: 34)
            Text(liveText ?? (model.transcribeOnThisDevice ? "Listening… text appears every ~30 seconds." : "Your Mac will transcribe this recording."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let id = model.recordingNoteID
                model.stopRecording()
                if let id { onFinished(id) }
            } label: {
                Label("Stop", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        }
        .padding(16)
    }
}
