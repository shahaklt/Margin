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
    /// `queued`: audio is saved and waiting for a device (usually the Mac) to transcribe it.
    case recording, queued, transcribing, summarizing, ready, failed
}

/// State of the LaTeX note sheet. `pending` means "a Mac signed in to Claude should write it".
enum SheetStatus: String, Codable {
    case none, pending, generating, ready, failed
}

enum Device: String, Codable {
    case mac, iphone

    static var current: Device {
        #if os(macOS)
        .mac
        #else
        .iphone
        #endif
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    /// A question asked on a device without Claude, waiting for the Mac to answer.
    var pending = false
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var updatedAt = Date()
    var origin: Device = .current
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
    /// File name inside the synced Audio folder (m4a for recordings, original format for imports).
    var audioFileName: String?
    var sourceName: String?
    var notesEngine: String?
    var sheetStatus: SheetStatus = .none
    var sheetError: String?
    var chat: [ChatMessage] = []
    var claudeSessionID: String?

    init(title: String, createdAt: Date) {
        self.title = title
        self.createdAt = createdAt
    }

    // Tolerant decoding so notes written by older versions (or the other device) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        origin = try c.decodeIfPresent(Device.self, forKey: .origin) ?? .mac
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        classID = try c.decodeIfPresent(UUID.self, forKey: .classID)
        manuallyFiled = try c.decodeIfPresent(Bool.self, forKey: .manuallyFiled) ?? false
        status = try c.decodeIfPresent(NoteStatus.self, forKey: .status) ?? .ready
        statusDetail = try c.decodeIfPresent(String.self, forKey: .statusDetail)
        lines = try c.decodeIfPresent([TranscriptLine].self, forKey: .lines) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        speakerNames = try c.decodeIfPresent([Int: String].self, forKey: .speakerNames) ?? [:]
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        notesEngine = try c.decodeIfPresent(String.self, forKey: .notesEngine)
        sheetStatus = try c.decodeIfPresent(SheetStatus.self, forKey: .sheetStatus) ?? .none
        sheetError = try c.decodeIfPresent(String.self, forKey: .sheetError)
        chat = try c.decodeIfPresent([ChatMessage].self, forKey: .chat) ?? []
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
    }

    var isBusy: Bool { status == .recording || status == .transcribing || status == .summarizing }

    var speakerCount: Int { Set(lines.map(\.speaker).filter { $0 >= 0 }).count }

    func speakerName(_ index: Int) -> String {
        if index < 0 { return "Speaker" }
        return speakerNames[index] ?? "Speaker \(index + 1)"
    }

    var plainTranscript: String { lines.map(\.text).joined(separator: " ") }

    /// "Name: text" per line — what language models see.
    var labeledTranscript: String {
        lines.map { "[\($0.start.clock)] \(speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    var snippet: String {
        if !summary.isEmpty { return summary }
        return String(plainTranscript.prefix(160))
    }

    var hasPendingQuestion: Bool { chat.contains { $0.pending } }
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
