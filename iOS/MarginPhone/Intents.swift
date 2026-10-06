import AppIntents

/// The phone's version of the Mac's ⌥⌘R: assign it to the Action button, Control Center, or say
/// "Record a class in Margin" to Siri.
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop Recording"
    static let description = IntentDescription("Starts recording a class in Margin, or stops the current recording.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let model = AppModel.shared {
            model.toggleRecording()
        } else {
            PendingIntent.startRecording = true
        }
        return .result()
    }
}

/// Set when the intent launches the app before the model exists; the app starts recording once ready.
@MainActor
enum PendingIntent {
    static var startRecording = false
}

struct MarginShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Record a class in \(.applicationName)", "Start recording in \(.applicationName)", "Stop recording in \(.applicationName)"],
            shortTitle: "Record Class",
            systemImageName: "waveform"
        )
    }
}
