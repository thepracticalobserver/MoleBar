import Foundation

/// Runs Mole's `mo clean` and streams its output.
@MainActor
final class Cleaner: ObservableObject {
    @Published var output = ""
    @Published var running = false
    @Published var lastMode: String?
    private var process: Process?

    /// Mole prints one "➤ Section" header per category; use that for a progress estimate.
    var sectionsDone: Int { output.components(separatedBy: "\n").filter { $0.hasPrefix("➤") }.count }
    var currentSection: String {
        output.components(separatedBy: "\n").last { $0.hasPrefix("➤") }.map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) } ?? "Starting…"
    }
    var expectedSections: Int { let n = UserDefaults.standard.integer(forKey: "moSections"); return n >= 10 ? n : 24 }
    var progress: Double { running ? min(0.97, Double(sectionsDone) / Double(expectedSections)) : (output.isEmpty ? 0 : 1) }

    /// e.g. "9.48GB" parsed from Mole's summary line
    var summary: String? {
        let pats = ["Potential space:\\s*([0-9.,]+\\s?[KMGT]?B)", "(?:freed|reclaimed|Space freed)[:\\s]*([0-9.,]+\\s?[KMGT]?B)"]
        for p in pats {
            if let r = output.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let m = String(output[r])
                if let n = m.range(of: "[0-9.,]+\\s?[KMGT]?B", options: .regularExpression) { return String(m[n]) }
            }
        }
        return nil
    }

    static var moPath: String? {
        ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", NSHomeDirectory() + "/.local/bin/mo"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(dryRun: Bool) {
        guard !running else { return }
        guard let mo = Self.moPath else { output = "Mole not found. Install with: brew install mole"; return }
        output = ""; running = true; lastMode = dryRun ? "Preview" : "Clean"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mo)
        p.arguments = ["clean"] + (dryRun ? ["--dry-run"] : [])
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "dumb"; env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = Cleaner.strip(String(decoding: d, as: UTF8.self))
            Task { @MainActor in self?.output += text }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                if let n = self?.sectionsDone, n >= 10 { UserDefaults.standard.set(n, forKey: "moSections") }
                if self?.lastMode == "Clean" { UserDefaults.standard.set(Date(), forKey: "lastClean") }
                self?.running = false; self?.process = nil
            }
        }
        do { try p.run(); process = p } catch { output = "Failed to launch: \(error)"; running = false }
    }

    func stop() { process?.terminate() }

    nonisolated static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
         .replacingOccurrences(of: "\r", with: "\n")
    }
}
