import SwiftUI

struct ClassesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ClassFolder?
    @State private var adding = false

    var body: some View {
        List {
            ForEach(model.store.classes) { c in
                Button { editing = c } label: {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(c.color)
                        VStack(alignment: .leading) {
                            Text(c.name).foregroundStyle(.primary)
                            if !c.keywords.isEmpty {
                                Text(c.keywords.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Add Class", systemImage: "plus") { adding = true }
        }
        .overlay {
            if model.store.classes.isEmpty {
                ContentUnavailableView("No Classes", systemImage: "folder.badge.plus", description: Text("Add each class you take. Margin files every recording into the matching one."))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $adding) { ClassEditor(folder: nil) }
        .sheet(item: $editing) { ClassEditor(folder: $0) }
    }
}

struct SpeechModelSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("whisperModel") private var whisperModel = WhisperModelChoice.defaultChoice.rawValue
    @AppStorage("language") private var language = "en"

    var body: some View {
        Section {
            Picker("Speech model", selection: $whisperModel) {
                ForEach(WhisperModelChoice.allCases) { choice in
                    #if os(iOS)
                    Text(choice.shortLabel).tag(choice.rawValue)
                    #else
                    Text(choice.label).tag(choice.rawValue)
                    #endif
                }
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
                else { Text(model.modelProgress < 0 ? model.modelStatus : "\(model.modelStatus) \(Int(model.modelProgress * 100))%").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Whisper (WhisperKit) transcribes and Pyannote (SpeakerKit) tells speakers apart, both on-device and offline.")
                .foregroundStyle(.secondary)
        }
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
                                .frame(width: 18, height: 18)
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
                if folder != nil {
                    Button("Delete", role: .destructive) {
                        if let f = folder { model.store.deleteClass(f.id) }
                        dismiss()
                    }
                }
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
        #if os(macOS)
        .frame(width: 460)
        #endif
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
            _ = model.store.addClass(trimmed, keywords: words, colorIndex: colorIndex)
        }
        dismiss()
    }
}

#if os(iOS)
/// iPhone settings: pick the shared iCloud Drive folder, where transcription happens, classes and model.
struct PhoneSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("phoneTranscription") private var where_ = "phone"
    @AppStorage("keepAudio") private var keepAudio = true
    @State private var pickingFolder = false
    @State private var folderName = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Library", value: folderName)
                Button(SyncBookmark.isSet ? "Change Folder…" : "Choose iCloud Drive Folder…") { pickingFolder = true }
                if SyncBookmark.isSet {
                    Button("Stop Syncing", role: .destructive) {
                        SyncBookmark.clear()
                        model.store.reopen()
                        folderName = model.store.root.lastPathComponent
                    }
                }
            } header: {
                Text("Sync with Mac")
            } footer: {
                Text("In the picker, open iCloud Drive and select the “Margin” folder your Mac created. Notes, audio and note sheets sync both ways.")
            }

            Section {
                Picker("Transcribe on", selection: $where_) {
                    Text("This iPhone").tag("phone")
                    Text("My Mac").tag("mac")
                }
                Toggle("Keep audio recordings", isOn: $keepAudio)
            } footer: {
                Text("“My Mac” saves battery: the phone only records and uploads; your Mac transcribes when it's on. Full LaTeX sheets and Claude answers always come from the Mac.")
            }

            if where_ == "phone" { SpeechModelSection() }

            Section("Classes") {
                NavigationLink("Edit Classes") { ClassesSettings().navigationTitle("Classes") }
            }

            Section("On-device notes") {
                Text(NoteGenerator.aiStatusText).font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { folderName = model.store.root.lastPathComponent }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try SyncBookmark.save(url)
                model.store.reopen()
                folderName = model.store.root.lastPathComponent
            } catch {
                model.alert = "Couldn't use that folder: \(error.localizedDescription)"
            }
        }
        .onChange(of: where_) { if where_ == "phone" { model.prepareModels() } }
    }
}
#endif
