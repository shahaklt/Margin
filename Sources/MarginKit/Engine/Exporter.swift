import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Builds export files for a note: transcript (txt / md / srt), notes (md), LaTeX sheet (tex / pdf) and audio.
enum Exporter {
    enum Kind: String, CaseIterable, Identifiable {
        case sheetPDF, sheetTeX, notesMarkdown, transcriptText, transcriptSRT, audio

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sheetPDF: "Note Sheet (PDF)"
            case .sheetTeX: "Note Sheet (LaTeX .tex)"
            case .notesMarkdown: "Notes + Transcript (Markdown)"
            case .transcriptText: "Transcript (Plain Text)"
            case .transcriptSRT: "Transcript (Subtitles .srt)"
            case .audio: "Original Audio"
            }
        }

        var icon: String {
            switch self {
            case .sheetPDF: "doc.richtext"
            case .sheetTeX: "function"
            case .notesMarkdown: "doc.text"
            case .transcriptText: "text.quote"
            case .transcriptSRT: "captions.bubble"
            case .audio: "waveform"
            }
        }
    }

    static func markdown(_ note: Note, className: String?) -> String {
        var md = "# \(note.title)\n\n"
        md += "*\(note.createdAt.formatted(date: .complete, time: .shortened)) · \(note.duration.friendlyDuration)"
        if let className { md += " · \(className)" }
        md += "*\n\n"
        if !note.summary.isEmpty { md += "## Summary\n\n\(note.summary)\n\n" }
        if !note.keyPoints.isEmpty { md += "## Key Points\n\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !note.actionItems.isEmpty { md += "## To Do\n\n" + note.actionItems.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n" }
        md += "## Transcript\n\n"
        for line in note.lines {
            md += "**\(note.speakerName(line.speaker))** `\(line.start.clock)`  \n\(line.text)\n\n"
        }
        return md
    }

    static func plainText(_ note: Note) -> String {
        var out = "\(note.title)\n\(note.createdAt.formatted(date: .complete, time: .shortened))\n\n"
        for line in note.lines { out += "[\(line.start.clock)] \(note.speakerName(line.speaker)): \(line.text)\n\n" }
        return out
    }

    static func srt(_ note: Note) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return note.lines.enumerated().map { i, l in
            "\(i + 1)\n\(ts(l.start)) --> \(ts(max(l.end, l.start + 1)))\n\(note.speakerName(l.speaker)): \(l.text)\n"
        }.joined(separator: "\n")
    }

    static func baseName(_ note: Note) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "\(df.string(from: note.createdAt)) \(NoteStore.sanitize(note.title))"
    }

    /// Which exports exist right now for this note.
    @MainActor static func available(_ note: Note, store: NoteStore) -> [Kind] {
        Kind.allCases.filter { kind in
            switch kind {
            case .sheetPDF: store.sheetPDF(note.id) != nil
            case .sheetTeX: FileManager.default.fileExists(atPath: store.sheetURL(note.id, "tex").path)
            case .audio: store.audioURL(note) != nil
            default: !note.lines.isEmpty
            }
        }
    }

    /// Writes one export to a temp file and returns its URL (for Save panels and the share sheet).
    @MainActor static func file(_ kind: Kind, note: Note, store: NoteStore) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MarginExport-\(note.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = baseName(note)
        func write(_ text: String, _ ext: String) throws -> URL {
            let url = dir.appendingPathComponent("\(base).\(ext)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func copy(_ src: URL?, _ name: String) throws -> URL {
            guard let src else { throw CocoaError(.fileNoSuchFile) }
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: src, to: url)
            return url
        }
        switch kind {
        case .notesMarkdown: return try write(markdown(note, className: store.folder(note.classID)?.name), "md")
        case .transcriptText: return try write(plainText(note), "txt")
        case .transcriptSRT: return try write(srt(note), "srt")
        case .sheetTeX: return try write(store.sheetTeX(note.id) ?? "", "tex")
        case .sheetPDF: return try copy(store.sheetPDF(note.id), "\(base).pdf")
        case .audio:
            let src = store.audioURL(note)
            return try copy(src, "\(base).\(src?.pathExtension ?? "m4a")")
        }
    }

    @MainActor static func all(note: Note, store: NoteStore) -> [URL] {
        available(note, store: store).compactMap { try? file($0, note: note, store: store) }
    }
}

/// Wraps an on-disk file for SwiftUI's cross-platform `.fileExporter`.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }

    var contentType: UTType { UTType(filenameExtension: url.pathExtension) ?? .data }
}
