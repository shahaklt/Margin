import SwiftUI

@main
struct MarginPhoneApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(model)
                // Voice Memos → Share → Margin (or "Open in Margin" from Files) lands here.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    model.importAudio([url])
                }
                .onChange(of: phase) {
                    if phase == .active {
                        model.store.syncFromDisk()
                        model.processBackgroundWork()
                    }
                }
                .task {
                    if DemoMode.isOn { DemoMode.seed(model) }
                    // CI: import Documents/lecture.m4a through the normal pipeline.
                    if ProcessInfo.processInfo.arguments.contains("-MarginImportTest") {
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        model.importAudio([docs.appendingPathComponent("lecture.m4a")])
                    }
                    if PendingIntent.startRecording {
                        PendingIntent.startRecording = false
                        await model.startRecording()
                    }
                }
        }
    }
}
