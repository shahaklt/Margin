import SwiftUI

struct RecordingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Symmetric, rounded bars driven by recent microphone levels.
struct Waveform: View {
    var levels: [Float]
    var barCount: Int
    var color: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let samples = resample(levels, to: barCount)
            let gap: CGFloat = 1.6
            let w = max(1, (geo.size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: gap) {
                ForEach(samples.indices, id: \.self) { i in
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: w, height: max(2, CGFloat(samples[i]) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.interpolatingSpring(stiffness: 260, damping: 22), value: samples)
        }
    }

    private func resample(_ input: [Float], to n: Int) -> [Float] {
        guard !input.isEmpty else { return Array(repeating: 0, count: n) }
        let tail = Array(input.suffix(n))
        let padded = Array(repeating: Float(0), count: max(0, n - tail.count)) + tail
        // Taper the edges so the shape reads like a voice, not a meter.
        return padded.enumerated().map { i, v in
            let x = Float(i) / Float(max(1, n - 1))
            let taper = 0.55 + 0.45 * sin(.pi * x)
            return min(1, v * taper * 1.15)
        }
    }
}
