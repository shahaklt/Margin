import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all, unsorted, folder(UUID)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem? = .all
    @State private var search = ""
    @State private var editingClass: ClassFolder?
    @State private var addingClass = false
    @State private var importing = false
    @State private var showSettings = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $sidebar, editingClass: $editingClass, addingClass: $addingClass)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
                #if os(iOS)
                .navigationTitle("Margin")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                #endif
        } content: {
            NoteList(items: filteredNotes, title: listTitle, selection: $model.selectedNoteID)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            if let id = model.selectedNoteID, model.store.note(id) != nil {
                NoteDetail(noteID: id)
                    .id(id)
            } else {
                EmptyDetail(importing: $importing)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Import Audio", systemImage: "square.and.arrow.down") }
                    .help("Import a voice memo or audio file")
            }
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AudioFiles.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importAudio(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { url in
                AudioFiles.importTypes.contains { UTType(filenameExtension: url.pathExtension)?.conforms(to: $0) ?? false }
            }
            model.importAudio(audio)
            return !audio.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .overlay { Label("Drop audio to transcribe", systemImage: "waveform.badge.plus").font(.title3.bold()) }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $addingClass) { ClassEditor(folder: nil) }
        .sheet(item: $editingClass) { ClassEditor(folder: $0) }
        #if os(iOS)
        .sheet(isPresented: $showSettings) { NavigationStack { PhoneSettings() } }
        #endif
        .alert("Margin", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var listTitle: String {
        switch sidebar {
        case .all, nil: "All Notes"
        case .unsorted: "Unsorted"
        case .folder(let id): model.store.folder(id)?.name ?? "Class"
        }
    }

    private var filteredNotes: [Note] {
        var notes = model.store.notes
        switch sidebar {
        case .all, nil: break
        case .unsorted: notes = notes.filter { $0.classID == nil }
        case .folder(let id): notes = notes.filter { $0.classID == id }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
                || $0.plainTranscript.localizedCaseInsensitiveContains(q)
        }
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                if model.isRecording {
                    Waveform(levels: model.recorder.levels, barCount: 10, color: .white)
                        .frame(width: 26, height: 12)
                    Text("Stop")
                } else {
                    Image(systemName: "record.circle")
                    Text("Record")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .help("Start or stop recording (⌥⌘R)")
        .animation(.smooth(duration: 0.25), value: model.isRecording)
    }
}

struct EmptyDetail: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No Note Selected", systemImage: "waveform")
        } description: {
            #if os(macOS)
            Text("Press ⌥⌘R anywhere to start recording, or drop in a voice memo. Margin transcribes on your Mac, tells speakers apart, writes a LaTeX note sheet, and files it into the right class.")
            #else
            Text("Record a class or import a voice memo. Margin transcribes it, tells speakers apart, and files it into the right class.")
            #endif
        } actions: {
            Button("Start Recording") { model.toggleRecording() }
                .buttonStyle(.glassProminent)
            Button("Import Voice Memo…") { importing = true }
                .buttonStyle(.glass)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @Binding var editingClass: ClassFolder?
    @Binding var addingClass: Bool
    @State private var pendingDelete: ClassFolder?

    var body: some View {
        List(selection: $selection) {
            Section {
                row(.all, "All Notes", "tray.full", .secondary, model.store.notes.count)
                row(.unsorted, "Unsorted", "questionmark.folder", .secondary, model.store.notes(in: nil).count)
                    .dropDestination(for: String.self) { ids, _ in file(ids, into: nil) }
            }
            Section("Classes") {
                ForEach(model.store.classes) { c in
                    row(.folder(c.id), c.name, "folder.fill", c.color, model.store.notes(in: c.id).count)
                        .dropDestination(for: String.self) { ids, _ in file(ids, into: c.id) }
                        .contextMenu {
                            Button("Edit Class…") { editingClass = c }
                            #if os(macOS)
                            Button("Show in Finder") {
                                let url = model.store.classesRoot.appendingPathComponent(NoteStore.sanitize(c.name))
                                NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : model.store.root)
                            }
                            #endif
                            Divider()
                            Button("Delete Class", role: .destructive) { pendingDelete = c }
                        }
                }
                Button {
                    addingClass = true
                } label: {
                    Label(model.store.classes.isEmpty ? "Add your classes" : "Add Class", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.transcribeOnThisDevice && !model.modelReady { ModelStatusCard().padding(10) }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Class", role: .destructive) {
                if let c = pendingDelete {
                    if selection == .folder(c.id) { selection = .all }
                    model.store.deleteClass(c.id)
                }
            }
        } message: {
            Text("Its notes move to Unsorted. No notes are deleted.")
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String, _ tint: Color, _ count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").foregroundStyle(.tertiary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .tag(item)
    }

    @discardableResult
    private func file(_ ids: [String], into classID: UUID?) -> Bool {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        uuids.forEach { model.store.file($0, into: classID) }
        return !uuids.isEmpty
    }
}

struct ModelStatusCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.modelError {
                Label("Model failed to load", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                Button("Try Again") { model.prepareModels() }.controlSize(.small)
            } else {
                Text(model.modelStatus).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if model.modelProgress < 0 {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                } else {
                    ProgressView(value: model.modelProgress).controlSize(.small)
                }
                Text("You can record now — transcription catches up when this finishes.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: Note list

struct NoteList: View {
    @Environment(AppModel.self) private var model
    var items: [Note]
    var title: String
    @Binding var selection: UUID?

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Recordings and imported voice memos appear here."))
            } else {
                List(selection: $selection) {
                    ForEach(groupedByDay, id: \.0) { day, notes in
                        Section(day) {
                            ForEach(notes) { note in
                                NoteRow(note: note)
                                    .tag(note.id)
                                    .draggable(note.id.uuidString)
                                    .contextMenu { NoteActions(note: note) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private var groupedByDay: [(String, [Note])] {
        let cal = Calendar.current
        var groups: [(String, [Note])] = []
        for note in items {
            let label: String
            if cal.isDateInToday(note.createdAt) { label = "Today" }
            else if cal.isDateInYesterday(note.createdAt) { label = "Yesterday" }
            else { label = note.createdAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            if groups.last?.0 == label { groups[groups.count - 1].1.append(note) } else { groups.append((label, [note])) }
        }
        return groups
    }
}

struct NoteRow: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.status == .recording {
                    RecordingDot()
                } else if note.isBusy || note.sheetStatus == .generating {
                    ProgressView().controlSize(.mini)
                } else if note.status == .queued {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary).font(.caption)
                } else if note.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                Text(note.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if note.origin == .iphone { Image(systemName: "iphone").font(.caption2).foregroundStyle(.tertiary) }
            }
            HStack(spacing: 6) {
                Text(note.createdAt.formatted(date: .omitted, time: .shortened))
                if note.duration > 0 { Text("·"); Text(note.duration.friendlyDuration) }
                if let c = model.store.folder(note.classID) {
                    Text("·")
                    Circle().fill(c.color).frame(width: 6, height: 6)
                    Text(c.name).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !note.snippet.isEmpty {
                Text(note.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NoteActions: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        Menu("Move to Class") {
            Button("Unsorted") { model.store.file(note.id, into: nil) }
            Divider()
            ForEach(model.store.classes) { c in
                Button(c.name) { model.store.file(note.id, into: c.id) }
            }
        }
        Button(model.brainAvailable ? "Rewrite Notes & Sheet with Claude" : "Rewrite Notes") { model.regenerate(note.id) }
            .disabled(note.isBusy || note.lines.isEmpty)
        if note.status == .failed || note.status == .queued {
            Button("Transcribe Now") { model.retry(note.id) }
        }
        Divider()
        Button("Delete Note", role: .destructive) {
            if model.selectedNoteID == note.id { model.selectedNoteID = nil }
            model.store.delete(note.id)
        }
        .disabled(note.status == .recording)
    }
}
