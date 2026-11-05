import AppKit

struct RunningApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    var cpu: Double
    var memMB: Double
    let app: NSRunningApplication
}

enum AppsMonitor {
    /// Per-app CPU/memory, with helper/child processes rolled up into their parent app.
    static func snapshot() -> [RunningApp] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let byPid = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })

        var parent: [pid_t: pid_t] = [:]
        var stats: [pid_t: (cpu: Double, rss: Double)] = [:]
        let out = run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss="])
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 4, let pid = pid_t(f[0]), let pp = pid_t(f[1]),
                  let cpu = Double(f[2]), let rss = Double(f[3]) else { continue }
            parent[pid] = pp; stats[pid] = (cpu, rss)
        }
        var totals: [pid_t: (Double, Double)] = [:]
        for (pid, st) in stats {
            var cur = pid, hops = 0
            while hops < 12 {
                if byPid[cur] != nil { let t = totals[cur] ?? (0, 0); totals[cur] = (t.0 + st.cpu, t.1 + st.rss); break }
                guard let p = parent[cur], p > 1 else { break }
                cur = p; hops += 1
            }
        }
        return apps.map {
            let t = totals[$0.processIdentifier] ?? (0, 0)
            return RunningApp(id: $0.processIdentifier, name: $0.localizedName ?? "Unknown", icon: $0.icon,
                              cpu: t.0, memMB: t.1 / 1024, app: $0)
        }.sorted { $0.cpu > $1.cpu }
    }
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
