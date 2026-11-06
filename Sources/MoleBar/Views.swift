import SwiftUI
import ServiceManagement

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var apps: [RunningApp] = []
    @Published var page = 0
    @Published var showLog = false
    var demo: Snapshot?
    @Published var sortMode = 0          // 0 impact, 1 CPU, 2 memory
    @Published var showAllApps = false
    func quit(_ a: RunningApp, force: Bool) {
        if force { a.app.forceTerminate() } else { a.app.terminate() }
        confirming = nil
    }
    func impact(_ a: RunningApp) -> Double { max(a.cpu, a.memMB / max(1, snap.memTotalGB * 1024) * 100 * 2) }
    func sorted(_ list: [RunningApp]) -> [RunningApp] {
        switch sortMode {
        case 1: return list.sorted { $0.cpu > $1.cpu }
        case 2: return list.sorted { $0.memMB > $1.memMB }
        default: return list.sorted { impact($0) > impact($1) }
        }
    }
    @Published var query = ""
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {}
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
    @Published var confirming: pid_t?
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 45)
    let cleaner = Cleaner()
    private let sampler = StatsSampler()
    private var timer: Timer?
    private var ticks = 0
    var onUpdate: (() -> Void)?

    func start() {
        _ = sampler.sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }
    func tick() {
        snap = demo ?? sampler.sample()
        cpuHistory.append(snap.cpu); cpuHistory.removeFirst()
        onUpdate?()
        ticks += 1
        guard ticks % 2 == 0 else { return }   // app list shells out to ps, so refresh it every 2s
        DispatchQueue.global().async {
            let a = AppsMonitor.snapshot()
            DispatchQueue.main.async { self.apps = a }
        }
    }
}

final class Flag: ObservableObject { @Published var on = false }

// MARK: - Design tokens


func statusColor(_ s: HealthStatus) -> Color {
    s == .good ? Color(red: 0.19, green: 0.82, blue: 0.51) : s == .busy ? Color(red: 1.0, green: 0.68, blue: 0.2) : Color(red: 1.0, green: 0.32, blue: 0.33)
}
func level(_ v: Double) -> Color { statusColor(v > 85 ? .stressed : v > 65 ? .busy : .good) }
func rate(_ b: Double) -> String { b > 1e6 ? String(format: "%.1f MB/s", b / 1e6) : String(format: "%.0f KB/s", b / 1e3) }
func rounded(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .rounded) }

struct Card<Content: View>: View {
    var pad: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(pad)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

// MARK: - Root

/// How opaque the navy is over the blurred backdrop (1 = solid, lower = more see-through).
let glassOpacity = 0.80

/// Blurs whatever is behind the popover.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.appearance = NSAppearance(named: .vibrantDark)   // stay dark even over a white window or in Light Mode
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct RootView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 8) {
            TabHeader(m: m)
            ZStack {
                if m.page == 0 {
                    HomeView(m: m).transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    AppsPage(m: m).transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.22), value: m.page)
            .clipped()
            HStack {
                Button { m.toggleLaunchAtLogin() } label: {
                    HStack(spacing: 4) { Image(systemName: m.launchAtLogin ? "checkmark.circle.fill" : "circle"); Text("Start at login") }
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 4) { Image(systemName: "power"); Text("Quit") }
                }
            }.font(rounded(10, .medium)).foregroundStyle(.tertiary).buttonStyle(.plain)
        }
        .padding(14).frame(width: 320, height: 480)
        .background(
            ZStack {
                VisualEffect()
                // navy: lighter at the top (#0C2037), darkening to near-black at the bottom (#01060F); kept mostly opaque so text stays readable
                LinearGradient(colors: [Color(red: 0.047, green: 0.125, blue: 0.215), Color(red: 0.004, green: 0.024, blue: 0.060)], startPoint: .top, endPoint: .bottom)
                    .opacity(glassOpacity)
            }
        )
        .environment(\.colorScheme, .dark)
    }
}

/// Two tabs in one slim row.
struct TabHeader: View {
    @ObservedObject var m: Model
    @Namespace private var pill
    private let items = ["Overview", "Apps"]
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(0..<items.count, id: \.self) { i in
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { m.page = i } } label: {
                        Text(items[i]).font(rounded(12))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .foregroundStyle(m.page == i ? Color.primary : Color.secondary)
                            .background {
                                if m.page == i {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.12))
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

// MARK: - Overview

func memText(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb) }

struct HomeView: View {
    @ObservedObject var m: Model
    var body: some View {
        let sorted = m.sorted(m.apps)
        let logOpen = m.showLog && !m.cleaner.running && !m.cleaner.output.isEmpty
        VStack(spacing: 11) {
            RingsCard(s: m.snap)
            TilesRow(s: m.snap)
            if !logOpen {
                // Show as many apps as fit; rows share any spare height so there is never a gap or a scroll.
                GeometryReader { g in
                    let rows = Array(sorted.prefix(max(3, Int(g.size.height / 37))))
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, a in
                            AppRow(a: a, m: m)
                            if i < rows.count - 1 { Spacer(minLength: 1) }
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            CleanRow(c: m.cleaner, snap: m.snap, m: m)
        }
    }
}

/// One compact row for the whole scan/clean flow, so the popover keeps the same height while cleaning.
struct CleanRow: View {
    @ObservedObject var c: Cleaner
    let snap: Snapshot
    @ObservedObject var m: Model

    func pill(_ label: String, primary: Bool, color: Color? = nil, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label).font(rounded(10.5, primary ? .bold : .semibold))
                .foregroundStyle(primary ? Color.black.opacity(0.85) : (color ?? Color.primary))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(primary ? Color.white : Color.primary.opacity(0.1)))
        }.buttonStyle(.plain)
    }

    var body: some View {
        let previewed = c.summary != nil && c.lastMode == "Preview" && !c.running
        let hasLog = !c.output.isEmpty && !c.running
        let title: String = {
            if c.running { return (c.lastMode == "Preview" ? "Scanning" : "Cleaning") + " · " + c.currentSection }
            if previewed { return "\(c.summary ?? "") can be freed" }
            if hasLog { return c.summary.map { "Freed \($0)" } ?? "Done" }
            return "Free up space"
        }()
        Card(pad: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: hasLog && !previewed ? "checkmark" : "sparkles").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.primary.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(rounded(11.5, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        if c.running {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.1))
                                    Capsule().fill(Color.white).frame(width: max(6, g.size.width * c.progress))
                                        .animation(.easeOut(duration: 0.4), value: c.progress)
                                }
                            }.frame(height: 4).padding(.top, 4)
                        } else if hasLog {
                            Button { withAnimation(.easeInOut(duration: 0.25)) { m.showLog.toggle() } } label: {
                                Text(m.showLog ? "hide log" : "show log")
                                    .font(rounded(9.5)).foregroundStyle(.secondary).lineLimit(1)
                            }.buttonStyle(.plain)
                        } else {
                            Text(String(format: "%.0f GB free", snap.diskFreeGB)).font(rounded(9.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if c.running {
                        Text("\(Int(c.progress * 100))%").font(rounded(11.5, .bold)).monospacedDigit()
                        pill("Stop", primary: false, color: statusColor(.stressed)) { c.stop() }
                    } else {
                        if !previewed { pill("Scan", primary: false) { c.start(dryRun: true) } }
                        pill("Clean", primary: true) { c.start(dryRun: false) }
                    }
                }
                if hasLog && m.showLog {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            Text(c.output.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).id("end")
                        }
                        .onChange(of: c.output) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .padding(8).frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.18)))
                }
            }
        }
        // Fixed height in every state, so nothing shifts when a scan or clean starts.
        .frame(height: hasLog && m.showLog ? nil : 52)
    }
}

/// Live power from the charger, shown top-right of the status card so it is always visible on laptops.
func powerBadge(_ s: Snapshot) -> (caption: String, value: String, icon: String)? {
    guard s.batteryPct != nil else { return nil }
    if s.plugged, s.justPlugged, (s.powerInWatts ?? 0) < 0.5 { return ("Plugged in", "Connecting…", "bolt.fill") }
    if s.plugged, let w = s.powerInWatts, w < 0.5 { return ("Plugged in", (s.batteryPct ?? 0) >= 99 ? "Idle" : "Not charging", "bolt.slash") }
    if s.plugged, let w = s.powerInWatts { return ("Power in", String(format: "%.1f W", w), "bolt.fill") }
    if s.plugged { return ("Charger", s.adapterWatts.map { String(format: "%.0f W", $0) } ?? "Connected", "bolt.fill") }
    return ("On battery", s.systemLoadWatts.map { String(format: "%.1f W", $0) } ?? "—", "bolt.slash")
}

struct Tile: View {
    let icon: String, caption: String, value: String
    var iconColor: Color = .secondary
    var valueColor: Color = .primary
    var body: some View {
        Card(pad: 8) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(iconColor)
                    .frame(width: 25, height: 25).background(Circle().fill(Color.primary.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption.uppercased()).font(.system(size: 7.5, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    Text(value).font(.system(size: 15, weight: .light)).foregroundStyle(valueColor).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Battery health and Power in (live watts from the charger), side by side.
/// Desktop Macs have no battery, so the row is empty and the app list takes the space.
struct TilesRow: View {
    let s: Snapshot
    var body: some View {
        if let p = powerBadge(s) {
            HStack(spacing: 8) {
                if let h = s.batteryHealth {
                    Tile(icon: "heart.fill", caption: "Battery health", value: "\(h)%",
                         valueColor: h < 60 ? statusColor(.stressed) : h < 80 ? statusColor(.busy) : .primary)
                }
                Tile(icon: p.icon, caption: p.caption, value: p.value, iconColor: s.plugged ? statusColor(.good) : .secondary)
            }
        }
    }
}

struct RingsCard: View {
    let s: Snapshot
    var body: some View {
        Card(pad: 8) {
            let used = s.diskTotalGB - s.diskFreeGB
            HStack(alignment: .top) {
                Ring(value: s.cpu, label: "CPU", sub: String(format: "Load %.2f", s.load.0), base: Color(red: 0.96, green: 0.48, blue: 0.40))
                Ring(value: s.memPressure, label: "Memory", sub: String(format: "%.1f / %.0f GB", s.memUsedGB, s.memTotalGB), base: Color(red: 0.29, green: 0.60, blue: 0.95))
                Ring(value: s.diskTotalGB > 0 ? used / s.diskTotalGB * 100 : 0, label: "Disk", sub: String(format: "%.0f GB free", s.diskFreeGB), base: Color(red: 0.40, green: 0.88, blue: 0.30))
            }
        }
    }
}

// MARK: - Components

/// Holds the arc's displayed value so only the arc's length animates (explicitly), never the ring's position.
/// An implicit `.animation(value:)` on the arc also animated layout changes, so the arc slid away from its track
/// when the popover opened or reflowed.
final class RingState: ObservableObject {
    @Published var shown: Double = 0
}

struct Ring: View {
    let value: Double, label: String, sub: String, base: Color
    @StateObject private var st = RingState()
    private var ringColor: Color { value > 85 ? statusColor(.stressed) : value > 65 ? statusColor(.busy) : base }
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(min(max(st.shown, 1), 100) / 100))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value))").font(.system(size: 19, weight: .light)) + Text("%").font(.system(size: 9, weight: .regular)).foregroundColor(.secondary)
            }.frame(width: 58, height: 58)
            Text(label.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(1.2).padding(.top, 5)
            Text(sub).font(.system(size: 8, weight: .regular)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .onAppear { st.shown = value }   // no animation on first draw
        .onChange(of: value) { v in withAnimation(.easeOut(duration: 0.6)) { st.shown = v } }
    }
}

// MARK: - Apps

struct AppRow: View {
    let a: RunningApp
    @ObservedObject var m: Model
    @StateObject private var hover = Flag()
    var body: some View {
        let memPct = a.memMB / max(1, m.snap.memTotalGB * 1024) * 100
        let imp = m.impact(a)
        let hot: Color? = imp >= 80 ? statusColor(.stressed) : imp >= 50 ? statusColor(.busy) : nil
        let barVal = m.sortMode == 2 ? memPct * 2 : m.sortMode == 1 ? a.cpu : imp
        let confirming = m.confirming == a.id
        HStack(spacing: 10) {
            Image(nsImage: a.icon ?? NSImage()).resizable().frame(width: 28, height: 28)
            if confirming {
                Text("Force quit \(a.name)?").font(rounded(12, .semibold)).lineLimit(1)
                Spacer()
                Button("Cancel") { m.confirming = nil }.buttonStyle(.plain).font(rounded(11, .medium)).foregroundStyle(.secondary)
                Button { m.quit(a, force: true) } label: {
                    Text("Force quit").font(rounded(11, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(statusColor(.stressed)))
                }.buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.name).font(rounded(12.5, .semibold)).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(hot ?? Color.primary.opacity(0.3)).frame(width: max(3, g.size.width * min(1, barVal / 100)))
                        }
                    }.frame(height: 3)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f%%", a.cpu)).font(rounded(12, .semibold)).foregroundStyle(a.cpu >= 50 ? (hot ?? .primary) : .primary)
                    Text(memText(a.memMB)).font(rounded(10, .regular)).foregroundStyle(memPct >= 25 ? (hot ?? .secondary) : .secondary)
                }.frame(width: 62, alignment: .trailing).monospacedDigit()
                Button { if NSEvent.modifierFlags.contains(.option) { m.quit(a, force: true) } else { m.confirming = a.id } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(hover.on ? .white : .secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(hover.on ? statusColor(.stressed) : Color.primary.opacity(0.08)))
                }.buttonStyle(.plain).help("Force quit \(a.name) (⌥-click to skip confirmation)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill((hot ?? Color.primary).opacity(hot != nil ? 0.10 : (hover.on || confirming ? 0.07 : 0))))
        .onHover { hover.on = $0 }
    }
}

struct AppsPage: View {
    @ObservedObject var m: Model
    var body: some View {
        let all = m.sorted(m.apps)
        let searching = !m.query.isEmpty
        let matches = all.filter { !searching || $0.name.localizedCaseInsensitiveContains(m.query) }
        let limit = (searching || m.showAllApps || matches.count <= 10) ? matches.count : 8
        let visible = Array(matches.prefix(limit))
        let hidden = matches.count - visible.count
        VStack(alignment: .leading, spacing: 8) {
            if m.apps.count > 10 || searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search apps", text: $m.query).textFieldStyle(.plain).font(rounded(12, .medium))
                    if searching {
                        Button { m.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(visible) { AppRow(a: $0, m: m) }
                    if hidden > 0 || (m.showAllApps && !searching && matches.count > 8) {
                        Button { withAnimation(.easeInOut(duration: 0.22)) { m.showAllApps.toggle() } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: m.showAllApps ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                                Text(m.showAllApps ? "Show fewer" : "Show \(hidden) more").font(rounded(11, .semibold))
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
