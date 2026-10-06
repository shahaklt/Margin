import SwiftUI

enum SidebarItem: Hashable {
    case all, unsorted, folder(UUID)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem? = .all
    @State private var search = ""
    @State private var editingClass: ClassFolder?
    @State private var addingClass = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $sidebar, editingClass: $editingClass, addingClass: $addingClass)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            NoteList(items: filteredNotes, title: listTitle, selection: $model.selectedNoteID)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            if let id = model.selectedNoteID, model.store.note(id) != nil {
                NoteDetail(noteID: id)
                    .id(id)
            } else {
                EmptyDetail()
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .sheet(isPresented: $addingClass) { ClassEditor(folder: nil) }
        .sheet(item: $editingClass) { ClassEditor(folder: $0) }
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
    var body: some View {
        ContentUnavailableView {
            Label("No Note Selected", systemImage: "waveform")
        } description: {
            Text("Press ⌥⌘R anywhere to start recording. Margin transcribes on your Mac, tells speakers apart, writes notes, and files them into the right class.")
        } actions: {
            Button("Start Recording") { model.toggleRecording() }
                .buttonStyle(.glassProminent)
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
                            Button("Show in Finder") {
                                let url = NoteStore.exportRoot.appendingPathComponent(c.name)
                                NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : NoteStore.exportRoot)
                            }
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
            if !model.modelReady { ModelStatusCard().padding(10) }
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
                ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Recordings you make will appear here."))
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
                } else if note.isBusy {
                    ProgressView().controlSize(.mini)
                } else if note.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                Text(note.title).font(.headline).lineLimit(1)
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
        Button("Copy as Markdown") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.store.markdown(note), forType: .string)
        }
        .disabled(note.isBusy)
        Button("Rewrite Notes") { model.regenerate(note.id) }
            .disabled(note.isBusy || note.lines.isEmpty)
        if note.status == .failed {
            Button("Retry Transcription") { model.retry(note.id) }
        }
        Divider()
        Button("Delete Note", role: .destructive) {
            if model.selectedNoteID == note.id { model.selectedNoteID = nil }
            model.store.delete(note.id)
        }
        .disabled(note.status == .recording)
    }
}
