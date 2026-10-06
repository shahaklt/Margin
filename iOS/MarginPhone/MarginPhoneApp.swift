import SwiftUI

@main
struct MarginPhoneApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        }
    }
}
