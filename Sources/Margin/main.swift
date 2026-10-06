import Foundation
import WhisperKit

// `Margin --selftest file.wav [Class Name ...]` runs the full pipeline headlessly and prints the result.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--selftest" {
    let path = args[2]
    let classes = args.dropFirst(3).enumerated().map { ClassFolder(name: $1, colorIndex: $0) }
    Task {
        do {
            let engine = TranscriptionEngine.shared
            try await engine.prepare { p, s in print(String(format: "[%3.0f%%] %@", p * 100, s)) }
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            let t0 = Date()
            let words = try await engine.transcribe(samples, offset: 0)
            let turns = try await engine.diarize(samples)
            let lines = TranscriptAssembler.lines(words: words, turns: turns)
            print(String(format: "\nTranscribed + diarized %.0fs of audio in %.1fs\n", Double(samples.count) / 16000, Date().timeIntervalSince(t0)))
            for l in lines { print("Speaker \(l.speaker + 1) [\(l.start.clock)]: \(l.text)") }
            let transcript = lines.map { "Speaker \($0.speaker + 1): \($0.text)" }.joined(separator: "\n")
            print("\nAI available: \(NoteGenerator.aiAvailable)")
            let notes = await NoteGenerator.generate(transcript: transcript, date: Date(), classes: classes)
            print("Title: \(notes.title)\nSummary: \(notes.summary)")
            notes.keyPoints.forEach { print(" • \($0)") }
            notes.actionItems.forEach { print(" ☐ \($0)") }
            print("Filed into: \(classes.first { $0.id == notes.classID }?.name ?? "Unsorted")")
            exit(0)
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    MarginApp.main()
}
