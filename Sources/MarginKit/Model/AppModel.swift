import Foundation
import Observation
import WhisperKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One recording's live state: its audio buffer, words transcribed so far, and the
/// background loop that transcribes ~30 s chunks while you're still talking.
@MainActor
final class RecordingSession {
    let noteID: UUID
    let buffer: SampleBuffer
    let wavURL: URL
    var cutIndex = 0
    var words: [TimedWord] = []
    var liveTask: Task<Void, Never>?
    var stopped = false

    init(noteID: UUID, buffer: SampleBuffer, wavURL: URL) {
        self.noteID = noteID
        self.buffer = buffer
        self.wavURL = wavURL
    }
}

@MainActor @Observable
final class AppModel {
    let store = NoteStore()
    let recorder = Recorder()
    private let engine = TranscriptionEngine.shared
    /// Writes full notes + LaTeX and answers questions (Claude on the Mac; nil on iPhone).
    let brain: NotesBrain?
    let compiler: SheetCompiler?
    private var session: RecordingSession?
    private var inFlight: Set<UUID> = []
    private var backgroundTimer: Timer?

    var selectedNoteID: UUID?
    var modelProgress: Double = 0
    var modelStatus = "Preparing models"
    var modelReady = false
    var modelError: String?
    var processingCount = 0 { didSet { onActivityChange?() } }
    var alert: String?
    var brainAvailable = false

    /// The Mac uses this to show/hide its floating indicator.
    var onActivityChange: (() -> Void)?

    var isRecording: Bool { recorder.isRecording }
    var recordingNoteID: UUID? { session?.noteID }

    /// iPhone setting: transcribe on the phone, or just upload audio and let the Mac do everything.
    var transcribeOnThisDevice: Bool {
        #if os(macOS)
        true
        #else
        UserDefaults.standard.string(forKey: "phoneTranscription") != "mac"
        #endif
    }

    init(brain: NotesBrain? = nil, compiler: SheetCompiler? = nil) {
        self.brain = brain
        self.compiler = compiler
        store.onRemoteChange = { [weak self] in self?.processBackgroundWork() }
        if transcribeOnThisDevice { prepareModels() }
        Task { await refreshBrain() }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.processBackgroundWork() }
        }
    }

    func refreshBrain() async {
        brainAvailable = await brain?.isAvailable() ?? false
        processBackgroundWork()
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
                processBackgroundWork()
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
            alert = "Margin needs microphone access. Enable it in Settings → Privacy & Security → Microphone."
            #if os(macOS)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            #endif
            return
        }

        let note = Note(title: "Recording…", createdAt: Date())
        // A local WAV is written while recording for crash safety; it's compressed into the synced library after.
        let wav = Library.recordingDir.appendingPathComponent("\(note.id).wav")
        do {
            try recorder.start(writingTo: wav)
        } catch {
            alert = "Couldn't start recording: \(error.localizedDescription)"
            return
        }
        store.locallyBusy.insert(note.id)
        store.upsert(note)
        selectedNoteID = note.id

        let s = RecordingSession(noteID: note.id, buffer: recorder.buffer, wavURL: wav)
        session = s
        if transcribeOnThisDevice { s.liveTask = Task { await liveLoop(s) } }
        onActivityChange?()
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
        Task {
            await finish(s)
            store.locallyBusy.remove(s.noteID)
            processingCount -= 1
            processBackgroundWork()
        }
    }

    // MARK: Importing voice memos / audio files

    func importAudio(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var note = Note(title: url.deletingPathExtension().lastPathComponent, createdAt: AudioFiles.creationDate(url))
            note.sourceName = url.lastPathComponent
            let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
            note.audioFileName = "\(note.id).\(ext)"
            do {
                try store.coordinatedCopy(url, to: store.audioDir.appendingPathComponent(note.audioFileName!))
            } catch {
                alert = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                continue
            }
            note.status = transcribeOnThisDevice ? .transcribing : .queued
            note.statusDetail = transcribeOnThisDevice ? nil : "Waiting for your Mac to transcribe…"
            store.upsert(note)
            selectedNoteID = note.id
            if transcribeOnThisDevice { retry(note.id) }
        }
    }

    // MARK: Live transcription

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
        let all = s.buffer.all()
        let keepAudio = UserDefaults.standard.object(forKey: "keepAudio") as? Bool ?? true

        // Compress into the synced library (needed anyway if the Mac will transcribe it).
        if keepAudio || !transcribeOnThisDevice {
            let name = "\(s.noteID).m4a"
            let tmp = Library.recordingDir.appendingPathComponent(name)
            if (try? AudioFiles.writeM4A(all, to: tmp)) != nil,
               (try? store.coordinatedCopy(tmp, to: store.audioDir.appendingPathComponent(name))) != nil {
                try? FileManager.default.removeItem(at: tmp)
                store.update(s.noteID) { $0.audioFileName = name }
            }
        }

        guard transcribeOnThisDevice else {
            store.update(s.noteID) {
                $0.status = .queued
                $0.title = "Recording — \($0.createdAt.formatted(date: .abbreviated, time: .shortened))"
                $0.statusDetail = "Waiting for your Mac to transcribe…"
            }
            try? FileManager.default.removeItem(at: s.wavURL)
            return
        }

        do {
            if !(await engine.isReady) {
                store.update(s.noteID) { $0.statusDetail = "Waiting for the speech model to finish loading…" }
                try await engine.prepare { _, _ in }
            }
            let tail = Array(all[min(s.cutIndex, all.count)...])
            s.words += try await engine.transcribe(tail, offset: Double(s.cutIndex) / Recorder.sampleRate)
            try await diarizeAndWrite(noteID: s.noteID, samples: all, words: s.words)
            if store.note(s.noteID)?.status == .ready { try? FileManager.default.removeItem(at: s.wavURL) }
        } catch {
            fail(s.noteID, error)
        }
    }

    /// Re-runs the whole pipeline from saved audio (failed/interrupted notes, imports, queued phone recordings).
    func retry(_ noteID: UUID) {
        guard let note = store.note(noteID), !inFlight.contains(noteID) else { return }
        let local = Library.recordingDir.appendingPathComponent("\(note.id).wav")
        guard let url = store.audioURL(note) ?? (FileManager.default.fileExists(atPath: local.path) ? local : nil) else {
            if note.status != .queued { alert = "The audio for this note isn't available on this device yet." }
            return
        }
        inFlight.insert(noteID)
        store.locallyBusy.insert(noteID)
        store.update(noteID) { $0.status = .transcribing; $0.statusDetail = "Transcribing…" }
        processingCount += 1
        Task {
            do {
                try await engine.prepare { _, _ in }
                let samples = try await AudioFiles.loadSamples(url)
                store.update(noteID) { $0.duration = Double(samples.count) / Recorder.sampleRate }
                let words = try await engine.transcribe(samples, offset: 0)
                try await diarizeAndWrite(noteID: noteID, samples: samples, words: words)
            } catch {
                fail(noteID, error)
            }
            inFlight.remove(noteID)
            store.locallyBusy.remove(noteID)
            processingCount -= 1
        }
    }

    private func diarizeAndWrite(noteID: UUID, samples: [Float], words: [TimedWord]) async throws {
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
        await writeLocalNotes(noteID)
        await writeSheet(noteID)
    }

    // MARK: Notes

    /// Fast first pass: on-device model (Apple Intelligence) or the statistical fallback.
    private func writeLocalNotes(_ noteID: UUID) async {
        guard let note = store.note(noteID) else { return }
        let transcript = note.lines.map { "\(note.speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n")
        let notes = await NoteGenerator.generate(transcript: transcript, date: note.createdAt, classes: store.classes)
        store.update(noteID) {
            $0.title = notes.title
            $0.summary = notes.summary
            $0.keyPoints = notes.keyPoints
            $0.actionItems = notes.actionItems
            if !$0.manuallyFiled { $0.classID = notes.classID }
            $0.notesEngine = NoteGenerator.aiAvailable ? "Apple Intelligence" : "On-device"
            $0.status = .ready
            $0.statusDetail = nil
            $0.sheetStatus = .pending
        }
    }

    /// Full LaTeX note sheet. With Claude: rewrites the notes too. Without: builds a sheet from local notes.
    /// On iPhone (no brain, no TeX) it stays `pending` for the Mac to pick up.
    func writeSheet(_ noteID: UUID) async {
        guard let note = store.note(noteID), !note.lines.isEmpty else { return }
        let useBrain = await brain?.isAvailable() ?? false
        let canCompile = await compiler?.isAvailable() ?? false
        guard useBrain || canCompile else { return }

        store.locallyBusy.insert(noteID)
        defer { store.locallyBusy.remove(noteID) }
        store.update(noteID) { $0.sheetStatus = .generating; $0.sheetError = nil }

        var title = note.title
        var className = store.folder(note.classID)?.name
        var body = LaTeXSheet.localBody(note)
        var engineName = note.notesEngine

        if useBrain, let brain {
            do {
                let r = try await brain.writeNotes(
                    transcript: note.labeledTranscript, title: note.title, className: className,
                    date: note.createdAt, classes: store.classes.map(\.name))
                body = r.latexBody
                title = r.title
                engineName = brain.name
                let picked = r.className.flatMap { name in store.classes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
                store.update(noteID) {
                    $0.title = r.title
                    if !r.summary.isEmpty { $0.summary = r.summary }
                    if !r.keyPoints.isEmpty { $0.keyPoints = r.keyPoints }
                    $0.actionItems = r.actionItems
                    // Claude has read the whole lesson, so its call (including "none of these") wins over the offline guess.
                    if !$0.manuallyFiled { $0.classID = picked?.id }
                    $0.notesEngine = brain.name
                }
                className = store.folder(store.note(noteID)?.classID)?.name
            } catch {
                store.update(noteID) { $0.sheetError = "Claude: \(error.localizedDescription)" }
            }
        }

        guard let current = store.note(noteID) else { return }
        var tex = LaTeXSheet.document(title: title, className: className, date: current.createdAt, duration: current.duration, body: body)
        var pdf: Data?
        if canCompile, let compiler {
            do {
                pdf = try await compiler.compile(tex)
            } catch {
                // One repair round with Claude, then fall back to the always-valid local sheet.
                if useBrain, let brain, let fixed = try? await brain.fixLaTeX(body: body, error: error.localizedDescription) {
                    let fixedTex = LaTeXSheet.document(title: title, className: className, date: current.createdAt, duration: current.duration, body: fixed)
                    if let p = try? await compiler.compile(fixedTex) { tex = fixedTex; pdf = p }
                }
                if pdf == nil {
                    let localTex = LaTeXSheet.document(title: title, className: className, date: current.createdAt, duration: current.duration, body: LaTeXSheet.localBody(current))
                    pdf = try? await compiler.compile(localTex)
                    store.update(noteID) { $0.sheetError = "Claude's LaTeX didn't compile; showing a basic sheet. \(error.localizedDescription)" }
                    if pdf != nil { tex = localTex }
                }
            }
        }
        store.saveSheet(noteID, tex: tex, pdf: pdf)
        store.update(noteID) {
            $0.sheetStatus = .ready
            $0.notesEngine = engineName
        }
    }

    func regenerate(_ noteID: UUID) {
        guard !inFlight.contains(noteID) else { return }
        inFlight.insert(noteID)
        processingCount += 1
        Task {
            if store.note(noteID)?.status == .ready {
                if await brain?.isAvailable() ?? false {
                    await writeSheet(noteID)
                } else {
                    await writeLocalNotes(noteID)
                    await writeSheet(noteID)
                }
            }
            inFlight.remove(noteID)
            processingCount -= 1
        }
    }

    // MARK: Ask about a note

    func ask(_ noteID: UUID, _ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        store.update(noteID) { $0.chat.append(ChatMessage(role: .user, text: q, pending: true)) }
        answerPending(noteID)
    }

    private func answerPending(_ noteID: UUID) {
        guard let brain, !inFlight.contains(noteID) else { return }
        inFlight.insert(noteID)
        Task {
            defer { inFlight.remove(noteID) }
            guard await brain.isAvailable() else { return }
            while let note = store.note(noteID), let pending = note.chat.first(where: { $0.pending }) {
                let history = note.chat.prefix { $0.id != pending.id }
                do {
                    let r = try await brain.ask(question: pending.text, transcript: note.labeledTranscript, title: note.title,
                                                history: Array(history), sessionID: note.claudeSessionID)
                    store.update(noteID) {
                        if let i = $0.chat.firstIndex(where: { $0.id == pending.id }) { $0.chat[i].pending = false }
                        $0.chat.append(ChatMessage(role: .assistant, text: r.answer))
                        $0.claudeSessionID = r.sessionID
                    }
                } catch {
                    store.update(noteID) {
                        if let i = $0.chat.firstIndex(where: { $0.id == pending.id }) { $0.chat[i].pending = false }
                        $0.chat.append(ChatMessage(role: .assistant, text: "⚠️ \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    func clearChat(_ noteID: UUID) {
        store.update(noteID) { $0.chat = []; $0.claudeSessionID = nil }
    }

    // MARK: Work handed over by the other device

    /// The Mac transcribes queued phone recordings, writes pending sheets, and answers questions asked on the phone.
    func processBackgroundWork() {
        guard !isRecording else { return }
        for note in store.notes where !inFlight.contains(note.id) && !store.locallyBusy.contains(note.id) {
            if note.status == .queued, transcribeOnThisDevice, modelReady {
                retry(note.id)
            } else if note.status == .ready, note.sheetStatus == .pending, compiler != nil || brain != nil {
                inFlight.insert(note.id)
                Task {
                    await writeSheet(note.id)
                    inFlight.remove(note.id)
                }
            } else if note.hasPendingQuestion, brain != nil {
                answerPending(note.id)
            }
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        store.update(id) {
            $0.status = .failed
            $0.statusDetail = error.localizedDescription
            if $0.title.hasSuffix("…") { $0.title = "Untitled recording" }
        }
    }
}
