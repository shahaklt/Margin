import Foundation

struct BrainNotes {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var className: String?
    var latexBody: String
}

/// Something that can write full notes and answer questions — on the Mac, Claude via the
/// signed-in `claude` CLI (the user's plan usage). The iPhone has none and defers to the Mac.
protocol NotesBrain: Sendable {
    var name: String { get }
    func isAvailable() async -> Bool
    func writeNotes(transcript: String, title: String, className: String?, date: Date, classes: [String]) async throws -> BrainNotes
    func fixLaTeX(body: String, error: String) async throws -> String
    func ask(question: String, transcript: String, title: String, history: [ChatMessage], sessionID: String?) async throws -> (answer: String, sessionID: String?)
}

/// Turns a .tex document into PDF data (tectonic on the Mac).
protocol SheetCompiler: Sendable {
    func isAvailable() async -> Bool
    func compile(_ tex: String) async throws -> Data
}

enum BrainError: LocalizedError {
    case unavailable(String)
    case badOutput(String)
    case compileFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let s): s
        case .badOutput(let s): "Unexpected response: \(s)"
        case .compileFailed(let s): "LaTeX didn't compile: \(s)"
        }
    }
}

/// Prompt + parser shared by any brain.
enum BrainPrompt {
    static func notesPrompt(transcript: String, title: String, className: String?, date: Date, classes: [String]) -> String {
        let classList = classes.isEmpty ? "(none defined)" : classes.map { "- \($0)" }.joined(separator: "\n")
        return """
        Recording: "\(title)" on \(date.formatted(date: .complete, time: .shortened))\(className.map { ", currently filed under \($0)" } ?? "").
        The student's classes:
        \(classList)

        Reply with exactly two blocks and nothing else:

        <meta>
        {"title": "specific 3-8 word title for this lesson", "summary": "2-4 sentence summary", \
        "keyPoints": ["5-10 most important takeaways"], "actionItems": ["every homework/test/deadline/reminder, with dates"], \
        "className": "exact name from the class list above, or null if none clearly fits"}
        </meta>
        <latex>
        (the LaTeX body, starting with \\section{Overview})
        </latex>

        Transcript:
        \(transcript)
        """
    }

    static func parse(_ text: String) throws -> BrainNotes {
        guard let latex = block("latex", in: text), latex.contains("\\section") else {
            throw BrainError.badOutput(String(text.prefix(200)))
        }
        struct Meta: Decodable {
            var title: String?
            var summary: String?
            var keyPoints: [String]?
            var actionItems: [String]?
            var className: String?
        }
        var meta = Meta()
        if let raw = block("meta", in: text), let data = raw.data(using: .utf8) {
            meta = (try? JSONDecoder().decode(Meta.self, from: data)) ?? meta
        }
        return BrainNotes(
            title: meta.title ?? "Class Notes",
            summary: meta.summary ?? "",
            keyPoints: meta.keyPoints ?? [],
            actionItems: meta.actionItems ?? [],
            className: meta.className,
            latexBody: stripFences(latex)
        )
    }

    static func block(_ tag: String, in text: String) -> String? {
        guard let a = text.range(of: "<\(tag)>"), let b = text.range(of: "</\(tag)>", range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let askSystem = """
    You are a study assistant. The user is a student asking about one of their recorded classes. \
    Answer from the transcript; say so when something wasn't covered. You may add brief general knowledge \
    if clearly labeled. Be concise. Use Markdown; write math in plain text or simple notation.
    """
}
