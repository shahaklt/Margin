import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Claude", systemImage: "sparkle") { ClaudeSettings() }
            Tab("Sync", systemImage: "icloud") { SyncSettings() }
            Tab("Classes", systemImage: "folder") { ClassesSettings() }
            Tab("Models", systemImage: "cpu") {
                Form {
                    SpeechModelSection()
                    Section("On-device notes") { Text(NoteGenerator.aiStatusText).foregroundStyle(.secondary) }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 560, height: 460)
    }
}

struct GeneralSettings: View {
    @AppStorage("keepAudio") private var keepAudio = true
    @AppStorage("mirrorToFinder") private var mirror = true
    @AppStorage("indicatorPosition") private var position = "top"
    @Environment(AppModel.self) private var model

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
                Toggle("Keep a folder per class (Markdown + PDF sheet)", isOn: $mirror)
                Button("Show Library in Finder") { NSWorkspace.shared.open(model.store.root) }
            } footer: {
                Text("Class folders live in \(model.store.classesRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useClaude") private var useClaude = true
    @AppStorage("claudeModel") private var claudeModel = ""
    @State private var status: ClaudeCLI.Status?
    @State private var checking = false
    @State private var hasTeX = TeXCompiler.engine() != nil

    var body: some View {
        Form {
            Section {
                LabeledContent("Account") {
                    if checking { ProgressView().controlSize(.small) }
                    else if let status {
                        if !status.installed { Text("Claude Code not found").foregroundStyle(.orange) }
                        else if status.loggedIn && status.usesSubscription {
                            Label(status.email ?? "Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if status.loggedIn {
                            Text("Signed in with an API key — sign in with your Claude plan instead").foregroundStyle(.orange)
                        } else { Text("Not signed in").foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    Button(status?.loggedIn == true ? "Switch Account…" : "Sign In with Claude…") { ClaudeCLI.openLogin() }
                        .disabled(status?.installed == false)
                    Button("Refresh") { Task { await check() } }
                }
                Toggle("Use Claude for notes, LaTeX sheets and questions", isOn: $useClaude)
                    .onChange(of: useClaude) { Task { await check() } }
                Picker("Model", selection: $claudeModel) {
                    Text("Claude Code default").tag("")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                    Text("Haiku (lightest on usage)").tag("haiku")
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Runs your installed Claude Code (`claude auth login`) in the background, so it uses your normal Pro/Max plan usage — no API key or API billing. Tools are disabled; Claude only sees the transcript you send.")
                    .foregroundStyle(.secondary)
            }
            if status?.installed == false {
                Section {
                    Text("Install Claude Code, then sign in:")
                    Text("curl -fsSL https://claude.ai/install.sh | bash").font(.body.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                LabeledContent("LaTeX engine") {
                    Text(TeXCompiler.engine()?.0.lastPathComponent ?? "Not installed").foregroundStyle(hasTeX ? .primary : .secondary)
                }
                if !hasTeX {
                    Text("brew install tectonic").font(.body.monospaced()).textSelection(.enabled)
                }
            } header: {
                Text("Note sheets")
            } footer: {
                Text("After every lesson Margin writes a LaTeX sheet — Overview, Reminders & Announcements, Key Equations, Core Concepts, Definitions, Worked Examples, Review Questions — and compiles it to PDF.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        checking = true
        ClaudeBrain.invalidate()
        status = await ClaudeCLI.status()
        hasTeX = TeXCompiler.engine() != nil
        checking = false
        await model.refreshBrain()
    }
}

struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("syncICloud") private var sync = true

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iPhone through iCloud Drive", isOn: $sync)
                    .disabled(!Library.iCloudAvailable)
                    .onChange(of: sync) { model.store.reopen() }
                LabeledContent("Library") {
                    Text(model.store.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Show in Finder") { NSWorkspace.shared.open(model.store.root) }
            } footer: {
                if Library.iCloudAvailable {
                    Text("Notes, audio and note sheets live in iCloud Drive → Margin. On the iPhone app, open Settings → Choose iCloud Drive Folder and pick that “Margin” folder. Your Mac transcribes phone recordings, writes their LaTeX sheets with Claude, and answers questions asked on the phone.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Turn on iCloud Drive in System Settings → Apple Account → iCloud to sync with your iPhone.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
