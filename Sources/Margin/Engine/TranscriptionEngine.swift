import Foundation
import WhisperKit
import SpeakerKit

struct TimedWord: Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct SpeakerTurn: Sendable {
    var speaker: Int
    var start: Double
    var end: Double
}

enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case fast = "base.en"
    case balanced = "small.en"
    case accurate = "large-v3-v20240930_626MB"
    case multilingual = "large-v3-v20240930_turbo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast — Whisper Base (English, ~140 MB)"
        case .balanced: "Balanced — Whisper Small (English, ~480 MB)"
        case .accurate: "Accurate — Whisper Large v3 Turbo (~630 MB)"
        case .multilingual: "Max — Whisper Large v3 Turbo full (~1.6 GB)"
        }
    }

    static var current: WhisperModelChoice {
        WhisperModelChoice(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "") ?? .accurate
    }
}

/// Owns the on-device Whisper (WhisperKit) and Pyannote (SpeakerKit) models.
/// Everything runs locally on the Neural Engine / GPU via Core ML.
actor TranscriptionEngine {
    static let shared = TranscriptionEngine()

    private var whisper: WhisperKit?
    private var loadedModel: String?
    private var speakers: SpeakerKit?
    private var preparing: Task<Void, Error>?

    var isReady: Bool { whisper != nil }

    /// Downloads (first run only) and loads both models. Safe to call repeatedly.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let model = WhisperModelChoice.current.rawValue
        if whisper != nil, loadedModel == model, speakers != nil { return }
        if let preparing { return try await preparing.value }

        let task = Task {
            let base = NoteStore.modelsDir
            if whisper == nil || loadedModel != model {
                whisper = nil
                progress(0, "Downloading Whisper model")
                let folder = try await WhisperKit.download(variant: model, downloadBase: base) { p in
                    progress(p.fractionCompleted * 0.85, "Downloading Whisper model")
                }
                progress(0.86, "Loading Whisper model")
                let config = WhisperKitConfig(
                    model: model,
                    downloadBase: base,
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: false
                )
                whisper = try await WhisperKit(config)
                loadedModel = model
            }
            if speakers == nil {
                progress(0.93, "Preparing speaker model")
                let config = PyannoteConfig(downloadBase: base.path, load: true, verbose: false, logLevel: .error)
                speakers = try await SpeakerKit(config)
            }
            progress(1, "Ready")
        }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    /// Transcribes 16 kHz mono samples; word times are shifted by `offset` seconds.
    func transcribe(_ samples: [Float], offset: Double) async throws -> [TimedWord] {
        guard let whisper else { throw EngineError.notReady }
        guard samples.count > Int(Recorder.sampleRate * 0.5) else { return [] }

        let languageSetting = UserDefaults.standard.string(forKey: "language") ?? "en"
        let model = loadedModel ?? ""
        let englishOnly = model.hasSuffix(".en")
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: englishOnly ? "en" : (languageSetting == "auto" ? nil : languageSetting),
            temperatureFallbackCount: 3,
            usePrefillPrompt: languageSetting != "auto" || englishOnly,
            detectLanguage: languageSetting == "auto" && !englishOnly,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        var words: [TimedWord] = []
        for result in results {
            for segment in result.segments {
                if let segWords = segment.words, !segWords.isEmpty {
                    for w in segWords {
                        words.append(TimedWord(text: w.word, start: Double(w.start) + offset, end: Double(w.end) + offset))
                    }
                } else {
                    let text = Self.clean(segment.text)
                    if !text.isEmpty {
                        words.append(TimedWord(text: " " + text, start: Double(segment.start) + offset, end: Double(segment.end) + offset))
                    }
                }
            }
        }
        return words.filter { !Self.clean($0.text).isEmpty && !Self.isHallucination($0.text) }
    }

    /// Who spoke when. Speakers are renumbered by order of first appearance.
    func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        guard let speakers else { throw EngineError.notReady }
        let result = try await speakers.diarize(audioArray: samples)
        var order: [Int: Int] = [:]
        return result.segments
            .sorted { $0.startTime < $1.startTime }
            .compactMap { seg in
                guard let id = seg.speaker.speakerId ?? seg.speaker.speakerIds.first else { return nil }
                if order[id] == nil { order[id] = order.count }
                return SpeakerTurn(speaker: order[id]!, start: Double(seg.startTime), end: Double(seg.endTime))
            }
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHallucination(_ s: String) -> Bool {
        let t = clean(s).lowercased()
        return t == "[blank_audio]" || t == "[music]" || t == "(silence)" || t.hasPrefix("[") && t.hasSuffix("]")
    }
}

enum EngineError: LocalizedError {
    case notReady
    var errorDescription: String? { "The transcription model isn't loaded yet." }
}

/// Merges words with speaker turns into readable transcript lines.
enum TranscriptAssembler {
    static func lines(words: [TimedWord], turns: [SpeakerTurn]) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var lastSpeaker = turns.first?.speaker ?? -1
        for word in words {
            let mid = (word.start + word.end) / 2
            let speaker = speakerAt(mid, turns: turns) ?? lastSpeaker
            lastSpeaker = speaker
            let piece = word.text
            if var current = lines.last,
               current.speaker == speaker,
               word.start - current.end < 2.5,
               !(current.text.count > 600 && current.text.hasSuffix(".")) {
                current.text += piece
                current.end = word.end
                lines[lines.count - 1] = current
            } else {
                lines.append(TranscriptLine(speaker: speaker, start: word.start, end: word.end, text: piece))
            }
        }
        return lines.map {
            var l = $0
            l.text = l.text.trimmingCharacters(in: .whitespaces)
            return l
        }.filter { !$0.text.isEmpty }
    }

    private static func speakerAt(_ t: Double, turns: [SpeakerTurn]) -> Int? {
        if let hit = turns.first(where: { t >= $0.start && t <= $0.end }) { return hit.speaker }
        let nearest = turns.min { distance(t, $0) < distance(t, $1) }
        if let nearest, distance(t, nearest) < 1.5 { return nearest.speaker }
        return nil
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : max(0, t - turn.end)
    }
}
