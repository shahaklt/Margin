import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Classes", systemImage: "folder") { ClassesSettings() }
            Tab("Models", systemImage: "cpu") { ModelSettings() }
        }
        .frame(width: 520, height: 400)
    }
}

struct GeneralSettings: View {
    @AppStorage("keepAudio") private var keepAudio = true
    @AppStorage("mirrorToFinder") private var mirror = true
    @AppStorage("indicatorPosition") private var position = "top"

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") { Text("⌥⌘R").monospaced() }
                Picker("Indicator", selection: $position) {
                    Text("Top of screen").tag("top")
                    Text("Bottom of screen").tag("bottom")
                }
            }
            Section {
                Toggle("Keep audio recordings", isOn: $keepAudio)
                Toggle("Save notes as Markdown in Documents/Margin", isOn: $mirror)
                Button("Show Notes Folder in Finder") {
                    try? FileManager.default.createDirectory(at: NoteStore.exportRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(NoteStore.exportRoot)
                }
            } footer: {
                Text("Everything stays on this Mac. Each class gets its own folder.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClassesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ClassFolder?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.store.classes) { c in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(c.color)
                        VStack(alignment: .leading) {
                            Text(c.name)
                            if !c.keywords.isEmpty {
                                Text(c.keywords.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = c }.buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if model.store.classes.isEmpty {
                    ContentUnavailableView("No Classes", systemImage: "folder.badge.plus", description: Text("Add each class you take. Margin files every recording into the matching one."))
                }
            }
            HStack {
                Button("Add Class", systemImage: "plus") { adding = true }
                Spacer()
            }
            .padding(10)
        }
        .sheet(isPresented: $adding) { ClassEditor(folder: nil) }
        .sheet(item: $editing) { ClassEditor(folder: $0) }
    }
}

struct ModelSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("whisperModel") private var whisperModel = WhisperModelChoice.accurate.rawValue
    @AppStorage("language") private var language = "en"

    var body: some View {
        Form {
            Section {
                Picker("Speech model", selection: $whisperModel) {
                    ForEach(WhisperModelChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: whisperModel) { model.prepareModels() }
                Picker("Language", selection: $language) {
                    Text("English").tag("en")
                    Text("Auto-detect").tag("auto")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Chinese").tag("zh")
                    Text("Hebrew").tag("he")
                    Text("Japanese").tag("ja")
                }
                .disabled(whisperModel.hasSuffix(".en"))
                LabeledContent("Status") {
                    if model.modelReady { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if let e = model.modelError { Text(e).foregroundStyle(.orange).lineLimit(2) }
                    else { Text("\(model.modelStatus) \(Int(model.modelProgress * 100))%").foregroundStyle(.secondary) }
                }
            } footer: {
                Text("Whisper (WhisperKit) for transcription and Pyannote (SpeakerKit) for telling speakers apart. Both run on the Neural Engine, fully offline.")
                    .foregroundStyle(.secondary)
            }
            Section("Notes") {
                Text(NoteGenerator.aiStatusText).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClassEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: ClassFolder?
    @State private var name = ""
    @State private var keywords = ""
    @State private var colorIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(folder == nil ? "New Class" : "Edit Class").font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("AP Biology"))
                TextField("Topics (optional)", text: $keywords, prompt: Text("cells, mitosis, enzymes, DNA"), axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        ForEach(Palette.colors.indices, id: \.self) { i in
                            Circle()
                                .fill(Palette.colors[i])
                                .frame(width: 16, height: 16)
                                .overlay { if i == colorIndex { Circle().stroke(.primary, lineWidth: 2).padding(-3) } }
                                .onTapGesture { colorIndex = i }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Topics help Margin recognize the class from what's said. The class name alone often works.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(folder == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = folder?.name ?? ""
            keywords = folder?.keywords.joined(separator: ", ") ?? ""
            colorIndex = folder?.colorIndex ?? model.store.classes.count
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let words = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if var f = folder {
            f.name = trimmed
            f.keywords = words
            f.colorIndex = colorIndex
            model.store.updateClass(f)
        } else {
            var f = model.store.addClass(trimmed, keywords: words)
            f.colorIndex = colorIndex
            model.store.updateClass(f)
        }
        dismiss()
    }
}
