import Foundation
import Observation
import AppKit
import WhisperKit

/// One recording's live state: its audio buffer, words transcribed so far, and the
/// background loop that transcribes ~30 s chunks while you're still talking.
@MainActor
final class RecordingSession {
    let noteID: UUID
    let buffer: SampleBuffer
    var cutIndex = 0
    var words: [TimedWord] = []
    var liveTask: Task<Void, Never>?
    var stopped = false

    init(noteID: UUID, buffer: SampleBuffer) {
        self.noteID = noteID
        self.buffer = buffer
    }
}

@MainActor @Observable
final class AppModel {
    let store = NoteStore()
    let recorder = Recorder()
    private let engine = TranscriptionEngine.shared
    private var session: RecordingSession?
    private var indicator: IndicatorController?
    private var hotKey: HotKey?

    var selectedNoteID: UUID?
    var modelProgress: Double = 0
    var modelStatus = "Preparing models"
    var modelReady = false
    var modelError: String?
    var processingCount = 0
    var alert: String?

    var isRecording: Bool { recorder.isRecording }
    var recordingNoteID: UUID? { session?.noteID }

    init() {
        indicator = IndicatorController(model: self)
        hotKey = HotKey(keyCode: 15 /* R */, modifiers: [.command, .option]) { [weak self] in
            self?.toggleRecording()
        }
        prepareModels()
    }

    // MARK: Models

    func prepareModels() {
        modelError = nil
        modelReady = false
        Task {
            do {
                try await engine.prepare { [weak self] p, status in
                    Task { @MainActor in
                        self?.modelProgress = p
                        self?.modelStatus = status
                    }
                }
                modelReady = true
            } catch {
                modelError = error.localizedDescription
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { Task { await startRecording() } }
    }

    func startRecording() async {
        guard !isRecording else { return }
        guard await Recorder.requestPermission() else {
            alert = "Margin needs microphone access. Enable it in System Settings → Privacy & Security → Microphone."
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }

        var note = Note(title: "Recording…", createdAt: Date())
        let keepAudio = UserDefaults.standard.object(forKey: "keepAudio") as? Bool ?? true
        // Audio is always written while recording (crash safety); removed later if not kept.
        let audioName = "\(note.id).wav"
        note.audioFileName = keepAudio ? audioName : nil

        do {
            try recorder.start(writingTo: NoteStore.audioDir.appendingPathComponent(audioName))
        } catch {
            alert = "Couldn't start recording: \(error.localizedDescription)"
            return
        }
        store.upsert(note)
        selectedNoteID = note.id

        let s = RecordingSession(noteID: note.id, buffer: recorder.buffer)
        session = s
        s.liveTask = Task { await liveLoop(s) }
        indicator?.update()
    }

    func stopRecording() {
        guard isRecording, let s = session else { return }
        let duration = recorder.stop()
        s.stopped = true
        session = nil
        store.update(s.noteID) {
            $0.duration = duration
            $0.status = .transcribing
            $0.title = "Transcribing…"
        }
        processingCount += 1
        indicator?.update()
        Task {
            await finish(s)
            processingCount -= 1
            indicator?.update()
        }
    }

    // MARK: Pipeline

    private func liveLoop(_ s: RecordingSession) async {
        let sr = Int(Recorder.sampleRate)
        let window = 28 * sr
        while !s.stopped {
            let available = s.buffer.count - s.cutIndex
            if available >= window, await engine.isReady {
                let cut = quietestPoint(in: s.buffer, from: s.cutIndex + 20 * sr, to: s.cutIndex + window)
                let samples = s.buffer.slice(s.cutIndex..<cut)
                let offset = Double(s.cutIndex) / Recorder.sampleRate
                s.cutIndex = cut
                if let words = try? await engine.transcribe(samples, offset: offset) {
                    s.words += words
                    let lines = TranscriptAssembler.lines(words: s.words, turns: [])
                    store.update(s.noteID, persist: false) { $0.lines = lines }
                }
            } else {
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Cut chunks at the quietest 20 ms frame so words aren't split across chunks.
    private func quietestPoint(in buffer: SampleBuffer, from: Int, to: Int) -> Int {
        let samples = buffer.slice(from..<to)
        let frame = 320
        var best = (index: to, energy: Float.greatestFiniteMagnitude)
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for j in i..<(i + frame) { e += samples[j] * samples[j] }
            if e < best.energy { best = (from + i + frame / 2, e) }
            i += frame
        }
        return best.index
    }

    private func finish(_ s: RecordingSession) async {
        await s.liveTask?.value
        do {
            if !(await engine.isReady) {
                store.update(s.noteID) { $0.statusDetail = "Waiting for the speech model to finish downloading…" }
                try await engine.prepare { _, _ in }
            }
            let all = s.buffer.all()
            let tail = Array(all[min(s.cutIndex, all.count)...])
            s.words += try await engine.transcribe(tail, offset: Double(s.cutIndex) / Recorder.sampleRate)
            try await diarizeAndSummarize(noteID: s.noteID, samples: all, words: s.words)
        } catch {
            fail(s.noteID, error)
        }
        cleanUpAudioIfNeeded(s.noteID)
    }

    /// Re-runs the whole pipeline from the saved WAV (for failed or interrupted notes).
    func retry(_ noteID: UUID) {
        guard let note = store.note(noteID) else { return }
        let url = NoteStore.audioDir.appendingPathComponent(note.audioFileName ?? "\(note.id).wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert = "The audio for this note wasn't kept, so it can't be re-transcribed."
            return
        }
        store.update(noteID) { $0.status = .transcribing; $0.statusDetail = nil }
        processingCount += 1
        indicator?.update()
        Task {
            do {
                try await engine.prepare { _, _ in }
                let samples = try await Task.detached { try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path) }.value
                store.update(noteID) { $0.duration = Double(samples.count) / Recorder.sampleRate }
                let words = try await engine.transcribe(samples, offset: 0)
                try await diarizeAndSummarize(noteID: noteID, samples: samples, words: words)
            } catch {
                fail(noteID, error)
            }
            processingCount -= 1
            indicator?.update()
        }
    }

    private func diarizeAndSummarize(noteID: UUID, samples: [Float], words: [TimedWord]) async throws {
        store.update(noteID, persist: false) { $0.statusDetail = "Identifying speakers…" }
        let turns = (try? await engine.diarize(samples)) ?? []
        let lines = TranscriptAssembler.lines(words: words, turns: turns)
        guard !lines.isEmpty else {
            store.update(noteID) {
                $0.lines = []
                $0.status = .ready
                $0.statusDetail = nil
                $0.title = "Silent recording"
                $0.summary = "No speech was detected."
            }
            return
        }
        store.update(noteID) {
            $0.lines = lines
            $0.status = .summarizing
            $0.statusDetail = "Writing notes…"
        }
        await summarize(noteID)
    }

    func summarize(_ noteID: UUID) async {
        guard let note = store.note(noteID) else { return }
        store.update(noteID, persist: false) { $0.status = .summarizing; $0.statusDetail = "Writing notes…" }
        let transcript = note.lines.map { "\(note.speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n")
        let notes = await NoteGenerator.generate(transcript: transcript, date: note.createdAt, classes: store.classes)
        store.update(noteID) {
            $0.title = notes.title
            $0.summary = notes.summary
            $0.keyPoints = notes.keyPoints
            $0.actionItems = notes.actionItems
            if !$0.manuallyFiled { $0.classID = notes.classID }
            $0.status = .ready
            $0.statusDetail = nil
        }
    }

    func regenerate(_ noteID: UUID) {
        processingCount += 1
        indicator?.update()
        Task {
            await summarize(noteID)
            processingCount -= 1
            indicator?.update()
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        store.update(id) {
            $0.status = .failed
            $0.statusDetail = error.localizedDescription
            if $0.title.hasSuffix("…") { $0.title = "Untitled recording" }
        }
    }

    private func cleanUpAudioIfNeeded(_ id: UUID) {
        guard let note = store.note(id), note.audioFileName == nil, note.status == .ready else { return }
        try? FileManager.default.removeItem(at: NoteStore.audioDir.appendingPathComponent("\(id).wav"))
    }

    func audioURL(for note: Note) -> URL? {
        guard let name = note.audioFileName else { return nil }
        let url = NoteStore.audioDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
