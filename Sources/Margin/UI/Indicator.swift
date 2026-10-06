import AppKit
import SwiftUI

/// A tiny floating Liquid Glass capsule that sits just under the menu bar while recording.
@MainActor
final class IndicatorController {
    static let size = NSSize(width: 240, height: 44)
    private let panel: NSPanel
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: IndicatorController.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        panel.contentView = NSHostingView(rootView: IndicatorView(model: model).frame(width: Self.size.width, height: Self.size.height))
    }

    func update() {
        guard let model else { return }
        let visible = model.isRecording || model.processingCount > 0
        if visible, !panel.isVisible {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        } else if !visible, panel.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { [panel] in
                MainActor.assumeIsolated { panel.orderOut(nil) }
            }
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let size = Self.size
        let visible = screen.visibleFrame
        let placeBottom = UserDefaults.standard.string(forKey: "indicatorPosition") == "bottom"
        let y = placeBottom ? visible.minY + 18 : visible.maxY - size.height - 6
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
    }
}

struct IndicatorView: View {
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                RecordingDot()
                Waveform(levels: model.recorder.levels, barCount: 22)
                    .frame(width: 66, height: 16)
                if let start = model.recorder.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(ctx.date.timeIntervalSince(start).clock)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                if hovering {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(.red, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                ProgressView().controlSize(.mini)
                Text("Writing notes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(7)
        .contentShape(.capsule)
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hovering = h } }
        .onTapGesture { if model.isRecording { model.stopRecording() } }
        .help(model.isRecording ? "Click to stop recording (⌥⌘R)" : "Transcribing on-device")
        .animation(.smooth, value: model.isRecording)
    }
}

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
