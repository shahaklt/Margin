import SwiftUI
import AppKit

struct MarginApp: App {
    @State private var model: AppModel
    private let services: MacServices
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let model = AppModel(brain: ClaudeBrain(), compiler: TeXCompiler())
        _model = State(initialValue: model)
        services = MacServices(model: model)
    }

    var body: some Scene {
        Window("Margin", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "New Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarMenu().environment(model)
        } label: {
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Mac-only extras: the floating recording indicator and the global ⌥⌘R shortcut.
@MainActor
final class MacServices {
    let indicator: IndicatorController
    let hotKey: HotKey

    init(model: AppModel) {
        let indicator = IndicatorController(model: model)
        self.indicator = indicator
        hotKey = HotKey(keyCode: 15 /* R */, modifiers: [.command, .option]) { [weak model] in model?.toggleRecording() }
        model.onActivityChange = { [weak indicator] in indicator?.update() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
            .keyboardShortcut("r", modifiers: [.command, .option])
        if !model.modelReady {
            Text(model.modelError.map { "Model error: \($0)" } ?? (model.modelProgress < 0 ? model.modelStatus : "\(model.modelStatus) \(Int(model.modelProgress * 100))%"))
        }
        Divider()
        Button("Open Margin") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Margin") {
            if model.isRecording { model.stopRecording() }
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
