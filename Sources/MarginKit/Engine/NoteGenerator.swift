import Foundation
import FoundationModels
import NaturalLanguage

struct GeneratedNotes {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var classID: UUID?
}

/// Schemas are built at runtime with DynamicGenerationSchema (no @Generable macros needed),
/// which also lets the class field be constrained to the user's actual class names.
private enum Schemas {
    static let text = DynamicGenerationSchema(type: String.self)
    static let list = DynamicGenerationSchema(arrayOf: text)

    static func section() throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "SectionNotes", properties: [
            .init(name: "keyPoints", description: "3 to 6 concise bullet points capturing the most important ideas, definitions, facts or examples in this part of the class", schema: list),
            .init(name: "actionItems", description: "Homework, assignments, readings, deadlines, exams or tasks mentioned. Empty if none.", schema: list),
        ]), dependencies: [])
    }

    static func lecture(classNames: [String]) throws -> GenerationSchema {
        let choice = DynamicGenerationSchema(name: "ClassChoice", anyOf: classNames + ["None"])
        return try GenerationSchema(root: DynamicGenerationSchema(name: "LectureNotes", properties: [
            .init(name: "title", description: "A short, specific title for this class session, 3 to 8 words, no quotes", schema: text),
            .init(name: "summary", description: "A 2 to 4 sentence summary of what was covered", schema: text),
            .init(name: "keyPoints", description: "5 to 10 of the most important takeaways, deduplicated, each one sentence", schema: list),
            .init(name: "actionItems", description: "All homework, assignments, readings, deadlines and exam dates mentioned, deduplicated. Empty if none.", schema: list),
            .init(name: "className", description: "Which of the student's classes this session belongs to, judged by subject matter. None if it does not clearly match any.", schema: choice),
        ]), dependencies: [])
    }
}

private struct LectureNotes {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var className: String
}

/// Turns a transcript into structured notes and picks a class folder.
/// Uses Apple's on-device Foundation Model when Apple Intelligence is on; otherwise falls
/// back to an extractive summary and keyword matching. Nothing leaves the Mac either way.
enum NoteGenerator {
    static var aiAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var aiStatusText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple Intelligence is on — notes are written by the on-device model."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings for AI-written notes. Using basic summaries for now."
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence. Using basic summaries."
        case .unavailable(.modelNotReady): return "Apple Intelligence model is still downloading. Using basic summaries for now."
        default: return "On-device language model unavailable. Using basic summaries."
        }
    }

    static func generate(transcript: String, date: Date, classes: [ClassFolder]) async -> GeneratedNotes {
        let shortDate = date.formatted(.dateTime.month(.abbreviated).day())
        let fallbackTitle = "Class — " + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        // Drop "Speaker 1:" style prefixes for the statistical fallbacks.
        let spoken = transcript.replacingOccurrences(of: #"(?m)^[^:\n]{1,40}:\s"#, with: "", options: .regularExpression)
        let localPick = ClassMatcher.best(transcript: spoken, classes: classes)

        if aiAvailable, transcript.split(separator: " ").count > 25,
           let ai = try? await generateWithModel(transcript: transcript, classes: classes) {
            let title = ai.title.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return GeneratedNotes(
                title: title.isEmpty ? fallbackTitle : title,
                summary: ai.summary,
                keyPoints: ai.keyPoints,
                actionItems: ai.actionItems,
                classID: match(ai.className, in: classes)?.id ?? localPick?.id
            )
        }

        let extracted = extractiveKeyPoints(spoken, count: 6)
        let topics = topNouns(spoken, count: 2)
        let topicTitle = topics.isEmpty ? nil : topics.joined(separator: " & ")
        let title: String = switch (localPick, topicTitle) {
        case let (c?, t?): "\(c.name): \(t)"
        case let (c?, nil): "\(c.name) — \(shortDate)"
        case let (nil, t?): "\(t) — \(shortDate)"
        default: fallbackTitle
        }
        return GeneratedNotes(
            title: title,
            summary: extracted.prefix(2).joined(separator: " "),
            keyPoints: extracted,
            actionItems: actionSentences(spoken),
            classID: localPick?.id
        )
    }

    /// Answers a question about a note with the on-device model. Its context is small, so only the
    /// transcript lines most related to the question (plus the summary) are included.
    static func answer(question: String, note: Note) async throws -> String {
        let qWords = Set(question.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        let ranked = note.lines.enumerated().map { i, line -> (Int, Int) in
            let words = Set(line.text.lowercased().split { !$0.isLetter }.map(String.init))
            return (i, words.intersection(qWords).count)
        }.sorted { $0.1 > $1.1 }
        var picked: [Int] = []
        var budget = 1100
        for (i, _) in ranked {
            let n = note.lines[i].text.split(separator: " ").count
            if n > budget { continue }
            picked.append(i)
            budget -= n
            if budget < 40 { break }
        }
        let excerpt = picked.sorted().map { "[\(note.lines[$0].start.clock)] \(note.speakerName(note.lines[$0].speaker)): \(note.lines[$0].text)" }.joined(separator: "\n")
        let history = note.chat.filter { !$0.pending }.suffix(4).map { "\($0.role == .user ? "Student" : "You"): \($0.text.prefix(400))" }.joined(separator: "\n")
        let prompt = """
        Class: \(note.title)
        Summary: \(note.summary)
        Key points: \(note.keyPoints.joined(separator: "; "))
        Reminders: \(note.actionItems.joined(separator: "; "))

        Relevant transcript excerpts:
        \(excerpt)
        \(history.isEmpty ? "" : "\nEarlier conversation:\n\(history)\n")
        Question: \(question)
        """
        let session = LanguageModelSession(instructions: BrainPrompt.askSystem)
        return try await session.respond(to: prompt).content
    }

    // MARK: On-device model (map → reduce, the model has a small context window)

    private static func generateWithModel(transcript: String, classes: [ClassFolder]) async throws -> LectureNotes {
        let instructions = """
        You are a precise note-taker for a student. You turn raw lecture transcripts into clear study notes. \
        Transcripts come from speech recognition and may contain errors; infer intended terms. Never invent facts.
        """
        let chunks = chunk(transcript, words: 1100)
        var sectionPoints: [String] = []
        var sectionTasks: [String] = []

        if chunks.count > 1 {
            for part in chunks {
                let session = LanguageModelSession(instructions: instructions)
                let section = try await session.respond(
                    to: "Take notes on this part of a class transcript:\n\n\(part)",
                    schema: try Schemas.section()
                ).content
                sectionPoints += (try? section.value([String].self, forProperty: "keyPoints")) ?? []
                sectionTasks += (try? section.value([String].self, forProperty: "actionItems")) ?? []
            }
        }

        let classList = classes.isEmpty ? "(no classes defined)" : classes.map { c in
            c.keywords.isEmpty ? "- \(c.name)" : "- \(c.name) (topics: \(c.keywords.joined(separator: ", ")))"
        }.joined(separator: "\n")

        let material: String
        if chunks.count > 1 {
            var notes = sectionPoints.map { "- \($0)" }.joined(separator: "\n")
            if !sectionTasks.isEmpty { notes += "\n\nTasks mentioned:\n" + sectionTasks.map { "- \($0)" }.joined(separator: "\n") }
            material = "Notes from each part of the class, in order:\n\(String(notes.prefix(6000)))"
        } else {
            material = "Class transcript:\n\(transcript)"
        }

        let session = LanguageModelSession(instructions: instructions)
        let content = try await session.respond(
            to: "\(material)\n\nThe student's classes are:\n\(classList)\n\nWrite the final study notes.",
            schema: try Schemas.lecture(classNames: classes.map(\.name))
        ).content
        return LectureNotes(
            title: try content.value(String.self, forProperty: "title"),
            summary: (try? content.value(String.self, forProperty: "summary")) ?? "",
            keyPoints: (try? content.value([String].self, forProperty: "keyPoints")) ?? [],
            actionItems: (try? content.value([String].self, forProperty: "actionItems")) ?? [],
            className: (try? content.value(String.self, forProperty: "className")) ?? "None"
        )
    }

    private static func chunk(_ text: String, words: Int) -> [String] {
        let all = text.split(separator: " ")
        return stride(from: 0, to: all.count, by: words).map { all[$0..<min(all.count, $0 + words)].joined(separator: " ") }
    }

    private static func match(_ name: String, in classes: [ClassFolder]) -> ClassFolder? {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !n.isEmpty, n != "none" else { return nil }
        return classes.first { $0.name.lowercased() == n }
            ?? classes.first { n.contains($0.name.lowercased()) || $0.name.lowercased().contains(n) }
    }

    // MARK: Fallbacks

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(text[range].trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        return out
    }

    /// Sentences that mention homework, readings, due dates or assessments.
    static func actionSentences(_ text: String) -> [String] {
        let cues = ["homework", "assignment", "due ", "due.", "worksheet", "read chapter", "read pages", "please read", "quiz", "test on", "test is", "exam", "project", "essay", "problem set", "turn in", "submit", "study for"]
        var seen = Set<String>()
        return sentences(text).filter { s in
            let l = s.lowercased()
            return cues.contains { l.contains($0) } && seen.insert(l).inserted
        }.prefix(6).map { $0 }
    }

    /// The most frequent nouns, as a rough topic label.
    static func topNouns(_ text: String, count: Int) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let skip: Set<String> = ["thing", "lot", "question", "today", "time", "way", "everyone", "kind", "yeah", "okay", "class", "people", "minute", "something", "anything", "day", "week", "homework", "test", "chapter", "page", "worksheet", "textbook"]
        var freq: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard tag == .noun else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? String(text[range])
            let w = lemma.lowercased()
            if w.count > 3, !skip.contains(w) { freq[w, default: 0] += 1 }
            return true
        }
        return freq.filter { $0.value >= 2 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(count).map { $0.key.capitalized }
    }

    /// Picks the most representative sentences by word frequency.
    static func extractiveKeyPoints(_ text: String, count: Int) -> [String] {
        let sentences = sentences(text).filter { $0.split(separator: " ").count >= 6 }
        guard !sentences.isEmpty else { return [] }

        let stop: Set<String> = ["the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "it", "is", "that", "this", "you", "i", "we", "they", "be", "are", "was", "for", "with", "like", "just", "um", "uh", "yeah", "okay", "right", "know", "going", "have", "do", "what", "if", "at", "as", "can", "there", "about", "not", "all", "one", "get", "really"]
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !stop.contains($0) }
        }
        var freq: [String: Int] = [:]
        sentences.forEach { words($0).forEach { freq[$0, default: 0] += 1 } }
        let scored = sentences.enumerated().map { (i, s) -> (Int, Double) in
            let w = words(s)
            return (i, w.isEmpty ? 0 : Double(w.reduce(0) { $0 + (freq[$1] ?? 0) }) / Double(w.count).squareRoot())
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(count).map(\.0).sorted().map { sentences[$0] }
    }
}
