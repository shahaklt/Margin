import Foundation
import SwiftUI

struct ClassFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Optional hint words that help auto-filing (e.g. "mitosis, enzyme, cell").
    var keywords: [String] = []
    var colorIndex: Int = 0

    var color: Color { Palette.color(colorIndex) }
}

enum Palette {
    static let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .indigo, .brown, .gray]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

struct TranscriptLine: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Speaker index in order of first appearance; -1 while not yet diarized.
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
}

enum NoteStatus: String, Codable {
    case recording, transcribing, summarizing, ready, failed
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var duration: Double = 0
    var classID: UUID?
    /// True once the user has filed the note by hand, so auto-filing never overrides it.
    var manuallyFiled = false
    var status: NoteStatus = .recording
    var statusDetail: String?
    var lines: [TranscriptLine] = []
    var summary: String = ""
    var keyPoints: [String] = []
    var actionItems: [String] = []
    var speakerNames: [Int: String] = [:]
    var audioFileName: String?

    var isBusy: Bool { status == .recording || status == .transcribing || status == .summarizing }

    var speakerCount: Int { Set(lines.map(\.speaker).filter { $0 >= 0 }).count }

    func speakerName(_ index: Int) -> String {
        if index < 0 { return "Speaker" }
        return speakerNames[index] ?? "Speaker \(index + 1)"
    }

    var plainTranscript: String { lines.map(\.text).joined(separator: " ") }

    var snippet: String {
        if !summary.isEmpty { return summary }
        return String(plainTranscript.prefix(160))
    }
}

extension Double {
    var clock: String {
        let s = Int(self.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    var friendlyDuration: String {
        let m = Int(self / 60)
        if m < 1 { return "<1 min" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) hr \(m % 60) min"
    }
}
