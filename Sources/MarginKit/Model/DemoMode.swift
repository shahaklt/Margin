import Foundation

/// `-MarginDemo` launch argument: a throwaway library with sample notes, used by CI to screenshot
/// the iPhone app in the simulator. `-MarginScreen <name>` opens a specific screen.
enum DemoMode {
    nonisolated static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-MarginDemo") }

    nonisolated static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-MarginScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func seed(_ model: AppModel) {
        let store = model.store
        guard store.notes.isEmpty else { return }
        let gov = store.addClass("AP Gov", colorIndex: 0)
        let physics = store.addClass("AP Physics 1", colorIndex: 4)
        _ = store.addClass("AP Stats", colorIndex: 6)

        var n = Note(title: "Newton's Second Law & Free-Body Diagrams", createdAt: Date().addingTimeInterval(-3600))
        n.duration = 2820
        n.classID = physics.id
        n.status = .ready
        n.notesEngine = "Claude"
        n.summary = "Introduced Newton's second law (F = ma) and how to draw free-body diagrams before solving force problems, including friction and the normal force on inclines."
        n.keyPoints = ["Net force equals mass times acceleration; forces are vectors, so add them by component.",
                       "Always draw a free-body diagram before writing equations.",
                       "Friction opposes motion; the normal force is perpendicular to the surface.",
                       "On an incline, split gravity into mg sin θ (along) and mg cos θ (into) the surface."]
        n.actionItems = ["Lab report on the inclined plane due Wednesday", "Unit test on forces next Friday"]
        n.lines = [
            TranscriptLine(speaker: 0, start: 0, end: 12, text: "Okay, so today is Newton's second law. Net force equals mass times acceleration."),
            TranscriptLine(speaker: 1, start: 13, end: 17, text: "Does that work when there's friction too?"),
            TranscriptLine(speaker: 0, start: 18, end: 40, text: "Great question. Yes — friction is just another force on your free-body diagram. It opposes the motion, and its size is mu times the normal force."),
        ]
        n.speakerNames = [0: "Mr. Alvarez"]
        n.chat = [ChatMessage(role: .user, text: "What's on the test?"),
                  ChatMessage(role: .assistant, text: "The **unit test on forces** is next Friday. Expect free-body diagrams, F = ma problems, and friction on inclines.")]
        store.upsert(n)
        let tex = LaTeXSheet.document(title: n.title, className: physics.name, date: n.createdAt, duration: n.duration, body: LaTeXSheet.localBody(n))
        #if os(iOS)
        store.saveSheet(n.id, tex: tex, pdf: SheetPDFRenderer.pdf(for: n, className: physics.name))
        #endif
        store.update(n.id) { $0.sheetStatus = .ready }

        var g = Note(title: "Federalism & Separation of Powers", createdAt: Date().addingTimeInterval(-90_000))
        g.duration = 3010; g.status = .ready; g.classID = gov.id; g.origin = .mac
        g.summary = "How the Constitution splits power between national and state governments, and among the three branches."
        store.upsert(g)

        var q = Note(title: "Recording — Oct 6, 9:14 AM", createdAt: Date().addingTimeInterval(-600))
        q.status = .transcribing; q.statusDetail = "Identifying speakers…"; q.duration = 1500
        store.upsert(q)
    }
}
