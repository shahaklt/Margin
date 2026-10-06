#if os(iOS)
import UIKit

/// The iPhone can't run LaTeX, so it renders the same sheet layout (same sections, same colors)
/// from HTML to a paginated PDF. A Mac signed in to Claude later replaces it with the full LaTeX sheet.
enum SheetPDFRenderer {
    @MainActor static func pdf(for note: Note, className: String?) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html(for: note, className: className))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 54, dy: 54), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    static func html(for note: Note, className: String?) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func list(_ items: [String], empty: String) -> String {
            items.isEmpty ? "<li>\(empty)</li>" : items.map { "<li>\(esc($0))</li>" }.joined()
        }
        let meta = [className, note.createdAt.formatted(date: .complete, time: .shortened), note.duration > 0 ? note.duration.friendlyDuration : nil]
            .compactMap { $0 }.map(esc).joined(separator: " · ")
        return """
        <html><head><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; color: #1c1c1e; line-height: 1.4; }
        h1 { font-size: 20pt; margin: 0 0 2pt 0; }
        .meta { color: #8e8e93; margin-bottom: 14pt; }
        h2 { font-size: 12.5pt; color: #5856D6; border-bottom: 0.6pt solid #c7c6f3; padding-bottom: 2pt; margin: 16pt 0 6pt 0; }
        .reminders { background: #fff1f0; border: 0.6pt solid #b3261e; border-radius: 4pt; padding: 4pt 10pt; }
        ul { margin: 4pt 0; padding-left: 16pt; } li { margin: 2pt 0; }
        .muted { color: #8e8e93; font-style: italic; }
        </style></head><body>
        <h1>\(esc(note.title))</h1>
        <div class="meta">\(meta)</div>
        <h2>Overview</h2>
        <p>\(note.summary.isEmpty ? "<span class='muted'>No summary available.</span>" : esc(note.summary))</p>
        <h2>Reminders &amp; Announcements</h2>
        <div class="reminders"><ul>\(list(note.actionItems, empty: "None mentioned"))</ul></div>
        <h2>Key Equations</h2>
        <p class="muted">Equations are extracted when your Mac writes the sheet with Claude.</p>
        <h2>Core Concepts</h2>
        <ul>\(list(note.keyPoints, empty: "No key points detected."))</ul>
        <h2>Review Questions</h2>
        <p class="muted">Your Mac adds review questions, definitions and worked examples when it writes the full sheet with Claude.</p>
        </body></html>
        """
    }
}
#endif
