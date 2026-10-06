import Foundation
import AppKit

/// Runs the user's own `claude` CLI (Claude Code) headlessly. It authenticates with the
/// claude.ai login from `claude auth login`, so it counts against the normal Pro/Max plan —
/// API-key variables are stripped from its environment so it can never fall back to API billing.
enum ClaudeCLI {
    struct Status: Equatable {
        var installed: Bool
        var loggedIn: Bool
        var email: String?
        var usesSubscription: Bool
    }

    private static let searchPaths = [
        "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        "~/.npm-global/bin/claude", "~/.bun/bin/claude", "~/.volta/bin/claude",
    ]

    static func executable() -> URL? {
        if let custom = UserDefaults.standard.string(forKey: "claudePath"), !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        for p in searchPaths {
            let path = (p as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // Ask a login shell, which knows the user's PATH (GUI apps don't).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = Pipe()
        try? shell.run()
        shell.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            env.removeValue(forKey: key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        return env
    }

    private static var workDir: URL { Library.ensure(Library.localSupport.appendingPathComponent("Claude", isDirectory: true)) }

    static func status() async -> Status {
        guard let exe = executable() else { return Status(installed: false, loggedIn: false, usesSubscription: false) }
        guard let (out, _) = try? await run(exe, ["auth", "status"], stdin: nil, timeout: 20),
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Status(installed: true, loggedIn: false, usesSubscription: false)
        }
        let method = json["authMethod"] as? String ?? ""
        return Status(
            installed: true,
            loggedIn: json["loggedIn"] as? Bool ?? false,
            email: json["email"] as? String,
            usesSubscription: method == "claude.ai" || method.contains("oauth")
        )
    }

    /// Opens Terminal running `claude auth login --claudeai` (browser sign-in to the Claude plan).
    static func openLogin() {
        let exe = executable()?.path ?? "claude"
        let script = Library.localSupport.appendingPathComponent("claude-login.command")
        let body = """
        #!/bin/zsh
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        echo "Signing Margin in to your Claude plan…"
        "\(exe)" auth login --claudeai
        echo
        echo "Done. You can close this window and return to Margin."
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    /// One prompt → one answer. No tools, no plugins/hooks/MCP, nothing touches the filesystem.
    static func ask(prompt: String, system: String, resume: String? = nil, keepSession: Bool = false) async throws -> (text: String, sessionID: String?) {
        guard let exe = executable() else { throw BrainError.unavailable("Claude Code isn't installed.") }
        var args = ["-p", "--output-format", "json", "--tools", "", "--safe-mode", "--system-prompt", system]
        if let model = UserDefaults.standard.string(forKey: "claudeModel"), !model.isEmpty { args += ["--model", model] }
        if let resume { args += ["--resume", resume] } else if !keepSession { args.append("--no-session-persistence") }
        let (out, err) = try await run(exe, args, stdin: prompt, timeout: 900)
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrainError.badOutput(err.isEmpty ? String(out.prefix(300)) : String(err.prefix(300)))
        }
        let text = json["result"] as? String ?? ""
        if json["is_error"] as? Bool == true {
            throw BrainError.unavailable(text.isEmpty ? "Claude returned an error." : text)
        }
        return (text, json["session_id"] as? String)
    }

    private static func run(_ exe: URL, _ args: [String], stdin: String?, timeout: TimeInterval) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.environment = environment
                p.currentDirectoryURL = workDir
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Drain both pipes concurrently so a full stderr can't deadlock us.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

struct ClaudeBrain: NotesBrain {
    let name = "Claude"

    /// `claude auth status` spawns a process, so the answer is cached for a minute.
    nonisolated(unsafe) private static var cache: (Date, Bool)?

    func isAvailable() async -> Bool {
        guard UserDefaults.standard.object(forKey: "useClaude") as? Bool ?? true else { return false }
        if let (date, value) = Self.cache, Date().timeIntervalSince(date) < 60 { return value }
        let s = await ClaudeCLI.status()
        let ok = s.loggedIn && s.usesSubscription
        Self.cache = (Date(), ok)
        return ok
    }

    static func invalidate() { cache = nil }

    func writeNotes(transcript: String, title: String, className: String?, date: Date, classes: [String]) async throws -> BrainNotes {
        let prompt = BrainPrompt.notesPrompt(transcript: transcript, title: title, className: className, date: date, classes: classes)
        let (text, _) = try await ClaudeCLI.ask(prompt: prompt, system: LaTeXSheet.instructions)
        return try BrainPrompt.parse(text)
    }

    func fixLaTeX(body: String, error: String) async throws -> String {
        let prompt = """
        This LaTeX body failed to compile. Fix it and reply with only the corrected body inside <latex></latex>.
        Keep the same content and sections.

        Compiler error:
        \(error)

        <latex>
        \(body)
        </latex>
        """
        let (text, _) = try await ClaudeCLI.ask(prompt: prompt, system: LaTeXSheet.instructions)
        guard let fixed = BrainPrompt.block("latex", in: text) else { throw BrainError.badOutput(String(text.prefix(200))) }
        return BrainPrompt.stripFences(fixed)
    }

    func ask(question: String, transcript: String, title: String, history: [ChatMessage], sessionID: String?) async throws -> (answer: String, sessionID: String?) {
        if let sessionID, let r = try? await ClaudeCLI.ask(prompt: question, system: BrainPrompt.askSystem, resume: sessionID) {
            return (r.text, r.sessionID ?? sessionID)
        }
        // New conversation (or the old session is gone): include the transcript and prior turns.
        var prompt = "Class recording: \"\(title)\"\n\nTranscript:\n\(transcript)\n\n"
        let prior = history.filter { !$0.pending }
        if !prior.isEmpty {
            prompt += "Earlier in this conversation:\n" + prior.map { "\($0.role == .user ? "Student" : "You"): \($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        prompt += "Question: \(question)"
        let r = try await ClaudeCLI.ask(prompt: prompt, system: BrainPrompt.askSystem, keepSession: true)
        return (r.text, r.sessionID)
    }
}

/// Compiles sheets with tectonic (or pdflatex/xelatex from MacTeX if that's what's installed).
struct TeXCompiler: SheetCompiler {
    static func engine() -> (URL, [String])? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/tectonic", "/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic", "\(home)/.cargo/bin/tectonic"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return (URL(fileURLWithPath: p), ["-X", "compile", "--untrusted", "sheet.tex"])
        }
        for p in ["/Library/TeX/texbin/pdflatex", "/opt/homebrew/bin/pdflatex"] where FileManager.default.isExecutableFile(atPath: p) {
            return (URL(fileURLWithPath: p), ["-interaction=nonstopmode", "-halt-on-error", "sheet.tex"])
        }
        return nil
    }

    func isAvailable() async -> Bool { Self.engine() != nil }

    func compile(_ tex: String) async throws -> Data {
        guard let (exe, args) = Self.engine() else { throw BrainError.unavailable("No LaTeX engine installed (brew install tectonic).") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-tex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try tex.write(to: dir.appendingPathComponent("sheet.tex"), atomically: true, encoding: .utf8)

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.currentDirectoryURL = dir
                let log = Pipe()
                p.standardOutput = log
                p.standardError = log
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let output = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if let pdf = try? Data(contentsOf: dir.appendingPathComponent("sheet.pdf")), p.terminationStatus == 0 {
                    cont.resume(returning: pdf)
                } else {
                    let errorLines = output.components(separatedBy: "\n").filter { $0.contains("error") || $0.hasPrefix("!") || $0.contains("l.") }
                    cont.resume(throwing: BrainError.compileFailed(String((errorLines.isEmpty ? [String(output.suffix(800))] : errorLines).prefix(12).joined(separator: "\n"))))
                }
            }
        }
    }
}
