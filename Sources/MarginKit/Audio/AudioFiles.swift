import AVFoundation
import UniformTypeIdentifiers
import WhisperKit

enum AudioFiles {
    static let importTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, UTType("com.apple.m4a-audio") ?? .audio, .movie]

    /// Compresses 16 kHz mono samples to a small AAC .m4a (≈14 MB/hour) for syncing.
    static func writeM4A(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let chunk = 16_000 * 10
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: buf)
            i += n
        }
    }

    /// Decodes any audio file (Voice Memos m4a, mp3, wav…) to 16 kHz mono samples.
    static func loadSamples(_ url: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        }.value
    }

    static func creationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }
}
