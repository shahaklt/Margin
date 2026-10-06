import Foundation

/// The note-sheet format. Every lesson produces the same document: a fixed preamble and header
/// written here, and a body with these sections (in this order) written by Claude, or built
/// locally from the on-device notes when Claude isn't available.
enum LaTeXSheet {
    static let sections = """
    \\section{Overview}            2-4 sentences: what this lesson was about and how it connects to the unit.
    \\section{Reminders \\& Announcements}  Put inside \\begin{reminders}...\\end{reminders}. Every test/quiz/exam \
    date, homework, reading, project, due date, schedule change, and "this will be on the test" remark, \
    each as an \\item with the date in bold when known. If none were mentioned write \\item None mentioned.
    \\section{Key Equations}        Each important formula in its own \\begin{keyeq}{Short name} ... \\end{keyeq} box \
    containing a displayed equation (equation environment) followed by a short itemized list defining every \
    variable/unit and when to use it. Write \\textit{No equations this lesson.} if there were none.
    \\section{Core Concepts}        The main teaching content as \\subsection{...}s per topic, using concise \
    itemize bullets. Bold (\\textbf) key terms. Include the reasoning, not just facts.
    \\section{Definitions}          A description list (\\begin{description} \\item[Term] meaning).
    \\section{Examples \\& Worked Problems}  Every example or problem worked in class, with steps (use align* for math).
    \\section{Review Questions}     4-8 questions a student should be able to answer after this lesson.
    """

    static let instructions = """
    You turn raw class-recording transcripts into a polished study note sheet in LaTeX.
    Rules:
    - Ignore small talk, greetings, attendance, logistics chatter, jokes, off-topic tangents and filler words. \
    Keep only what a student needs to learn the material and to not miss deadlines.
    - The transcript comes from speech recognition: silently fix misheard technical terms \
    (e.g. "metosis" -> mitosis) and reconstruct spoken math as proper LaTeX \
    ("x squared plus two x" -> $x^2 + 2x$).
    - Never invent content that wasn't taught. If something is unclear, omit it.
    - Write the body only, with exactly these sections in this order:
    \(sections)
    - Use only these packages (already loaded): amsmath, amssymb, mathtools, siunitx, enumitem, xcolor, tcolorbox, \
    hyperref, booktabs. Do not write \\documentclass, \\usepackage, \\begin{document} or \\end{document}.
    - Escape special characters in text (& % $ # _ { } ~ ^ \\). Use \\% for percent.
    """

    static func document(title: String, className: String?, date: Date, duration: Double, body: String) -> String {
        let subtitle = [className, date.formatted(date: .complete, time: .shortened), duration > 0 ? duration.friendlyDuration : nil]
            .compactMap { $0 }.map(escape).joined(separator: " \\textperiodcentered{} ")
        return """
        \\documentclass[11pt]{article}
        \\usepackage[margin=0.8in]{geometry}
        \\usepackage[T1]{fontenc}
        \\usepackage{lmodern}
        \\usepackage{amsmath,amssymb,mathtools}
        \\usepackage{siunitx}
        \\usepackage{booktabs}
        \\usepackage[shortlabels]{enumitem}
        \\usepackage[dvipsnames]{xcolor}
        \\usepackage[most]{tcolorbox}
        \\usepackage{titlesec}
        \\usepackage{fancyhdr}
        \\usepackage[hidelinks]{hyperref}

        \\definecolor{accent}{HTML}{5856D6}
        \\definecolor{alert}{HTML}{FF3B30}
        \\setlist{itemsep=2pt, topsep=4pt}
        \\titleformat{\\section}{\\large\\bfseries\\color{accent}}{}{0pt}{}[\\vspace{-0.6em}\\textcolor{accent!40}{\\rule{\\linewidth}{0.6pt}}]
        \\titleformat{\\subsection}{\\normalsize\\bfseries}{}{0pt}{}
        \\titlespacing*{\\section}{0pt}{1.2em}{0.6em}
        \\setcounter{secnumdepth}{0}
        \\pagestyle{fancy}\\fancyhf{}
        \\fancyhead[L]{\\small\\color{gray}\(escape(className ?? "Class Notes"))}
        \\fancyhead[R]{\\small\\color{gray}\(escape(date.formatted(date: .abbreviated, time: .omitted)))}
        \\fancyfoot[C]{\\small\\color{gray}\\thepage}
        \\renewcommand{\\headrulewidth}{0pt}

        \\newtcolorbox{reminders}{enhanced, breakable, colback=alert!5, colframe=alert!70!black, boxrule=0.6pt,
          arc=3pt, left=6pt, right=6pt, top=4pt, bottom=4pt, before upper={\\begin{itemize}[leftmargin=1.2em]}, after upper={\\end{itemize}}}
        \\newtcolorbox{keyeq}[1]{enhanced, breakable, colback=accent!4, colframe=accent!60, boxrule=0.6pt, arc=3pt,
          fonttitle=\\bfseries\\small, coltitle=accent!80!black, colbacktitle=accent!10, title={#1}, left=6pt, right=6pt}

        \\begin{document}
        {\\LARGE\\bfseries \(escape(title))\\par}
        \\vspace{2pt}{\\color{gray}\(subtitle)\\par}
        \\vspace{6pt}

        \(body)

        \\end{document}
        """
    }

    /// Body built from on-device notes (no Claude). Same section order so sheets look consistent.
    static func localBody(_ note: Note) -> String {
        func items(_ list: [String], empty: String) -> String {
            list.isEmpty ? "\\item \(empty)" : list.map { "\\item \(escape($0))" }.joined(separator: "\n")
        }
        let reminders = note.actionItems
        return """
        \\section{Overview}
        \(note.summary.isEmpty ? "\\textit{No summary available.}" : escape(note.summary))

        \\section{Reminders \\& Announcements}
        \\begin{reminders}
        \(items(reminders, empty: "None mentioned"))
        \\end{reminders}

        \\section{Key Equations}
        \\textit{Equations are extracted when Margin writes the sheet with Claude.}

        \\section{Core Concepts}
        \\begin{itemize}
        \(items(note.keyPoints, empty: "No key points detected."))
        \\end{itemize}

        \\section{Review Questions}
        \\textit{Sign in to Claude in Margin's settings and choose Rewrite to generate the full sheet.}
        """
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "&", "%", "$", "#", "_", "{", "}": out += "\\\(ch)"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(ch)
            }
        }
        return out
    }
}
