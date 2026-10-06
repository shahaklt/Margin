import SwiftUI
import AppKit

struct MarginApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

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
