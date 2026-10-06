import AVFoundation
import Observation

/// Thread-safe growing buffer of 16 kHz mono samples, written from the audio thread.
final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    var count: Int { lock.withLock { samples.count } }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func slice(_ range: Range<Int>) -> [Float] {
        lock.withLock {
            let r = range.clamped(to: 0..<samples.count)
            return Array(samples[r])
        }
    }

    func all() -> [Float] { lock.withLock { samples } }

    func reset() { lock.withLock { samples.removeAll(keepingCapacity: false) } }
}

/// Captures the microphone, resamples to 16 kHz mono (what Whisper wants),
/// keeps the samples in memory for live transcription, writes a WAV backup,
/// and publishes a rolling level history for the waveform.
@MainActor @Observable
final class Recorder {
    nonisolated static let sampleRate: Double = 16_000
    static let levelHistory = 48

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var levels: [Float] = Array(repeating: 0, count: Recorder.levelHistory)

    /// A fresh buffer per recording, so a finished session can keep processing its own audio.
    private(set) var buffer = SampleBuffer()

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL?) throws {
        guard !isRecording else { return }
        buffer = SampleBuffer()
        levels = Array(repeating: 0, count: Self.levelHistory)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw RecorderError.noInput }

        if let url {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        let sampleBuffer = buffer
        let file = self.file
        let ratio = Self.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] pcm, _ in
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return pcm
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
            let ptr = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
            sampleBuffer.append(ptr)
            try? file?.write(from: out)

            // Two level readings per tap for a smoother waveform.
            let half = max(1, ptr.count / 2)
            var readings: [Float] = []
            for start in stride(from: 0, to: ptr.count, by: half) {
                let end = min(ptr.count, start + half)
                var sum: Float = 0
                for i in start..<end { sum += ptr[i] * ptr[i] }
                let rms = sqrt(sum / Float(end - start))
                // Map roughly -55 dB...-10 dB onto 0...1.
                let db = 20 * log10(max(rms, 1e-6))
                readings.append(min(1, max(0, (db + 55) / 45)))
            }
            Task { @MainActor in self?.push(readings) }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        startedAt = Date()
        isRecording = true
    }

    private func push(_ readings: [Float]) {
        guard isRecording else { return }
        levels.append(contentsOf: readings)
        if levels.count > Self.levelHistory { levels.removeFirst(levels.count - Self.levelHistory) }
    }

    @discardableResult
    func stop() -> Double {
        guard isRecording else { return 0 }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil // closes the WAV
        isRecording = false
        startedAt = nil
        levels = Array(repeating: 0, count: Self.levelHistory)
        return Double(buffer.count) / Self.sampleRate
    }
}

enum RecorderError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone input is available." }
}
