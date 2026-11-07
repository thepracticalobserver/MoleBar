import AppKit
import SwiftUI

enum IconStyle: String, CaseIterable {
    case dot, glass, heartbeat, percent
    var title: String {
        switch self {
        case .dot: return "Dot"
        case .glass: return "Glass"
        case .heartbeat: return "Heartbeat"
        case .percent: return "CPU %"
        }
    }
}

func statusColorFill(_ st: HealthStatus) -> NSColor { st == .good ? .systemGreen : st == .busy ? .systemOrange : .systemRed }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var item: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Dot only: a fixed, compact width, so the popover never shifts when the status changes.
        item.length = 18
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.setValue(true, forKey: "shouldHideAnchor")
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: RootView(m: model))
        model.onUpdate = { [weak self] in self?.refreshIcon() }
        model.start()
        installHover()
        updatePointerWatch()
        if let i = CommandLine.arguments.firstIndex(of: "--icon-test"), i + 1 < CommandLine.arguments.count {
            iconTest(to: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
        }
    }

    /// Dev helper: capture this app's own window for each tab, for reviewing the UI headlessly.
    func snapshot(to dir: String) {
        let win = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 320, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(white: 0.04, alpha: 1)
        win.contentView = NSHostingView(rootView: RootView(m: model))
        win.orderFrontRegardless()
        let names = ["home", "apps", "scanned", "cleaning"]
        func shoot(_ i: Int) {
            guard i < names.count else { NSApp.terminate(nil); return }
            model.page = i == 1 ? 1 : 0
            if i == 2 {
                model.cleaner.running = false; model.cleaner.lastMode = "Preview"
                model.cleaner.output = "➤ App caches\n  ✓ Nothing to clean\n\n➤ Browsers\n  → Chrome cache 1.2GB\n  → Safari cache 340MB\n\nDry run complete - no changes made\nPotential space: 9.48GB | Items: 507"
            }
            if i == 3 { model.cleaner.running = true; model.cleaner.lastMode = "Clean"; model.cleaner.output = (0..<9).map { "➤ Section \($0)\n  ✓ ok" }.joined(separator: "\n") + "\n➤ Browsers" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming]) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(names[i]).png"))
                }
                shoot(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { shoot(0) }
    }

    // MARK: Menu bar icon (style is user-selectable from the right-click menu)
    // Dot, Glass and Heartbeat are Core Animation layers, so they animate on the GPU and cost the app essentially no CPU.
    var style: IconStyle = IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .dot
    let content = CALayer()
    var builtKey = ""
    var statusKey = ""
    var orb = CAShapeLayer(), ripple = CAShapeLayer()
    var levelLayer = CALayer(), waveLayer = CAShapeLayer()
    var beatLayer = CAShapeLayer()

    /// Dev helper: render each icon style/status into this app's own (flipped, like the status button) test window and save PNGs.
    func iconTest(to dir: String) {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let v = Flipped(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        let win = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 160, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = v
        win.orderFrontRegardless()
        guard let host = v.layer, let b = item.button else { return }
        model.onUpdate = nil
        content.removeFromSuperlayer()
        host.addSublayer(content)
        content.isGeometryFlipped = host.isGeometryFlipped
        content.bounds = CGRect(x: 0, y: 0, width: 30, height: 20)
        content.position = CGPoint(x: 80, y: 50)
        content.setAffineTransform(CGAffineTransform(scaleX: 4, y: 4))
        var jobs: [(IconStyle, HealthStatus)] = []
        for st in [IconStyle.dot, .glass, .heartbeat] { for h in [HealthStatus.good, .busy, .stressed] { jobs.append((st, h)) } }
        func go(_ i: Int) {
            guard i < jobs.count else { NSApp.terminate(nil); return }
            style = jobs[i].0
            buildIcon(b, reduce: true, dark: true)
            applyStatus(jobs[i].1, reduce: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming]) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(jobs[i].0.rawValue)-\(jobs[i].1.rawValue.replacingOccurrences(of: " ", with: "_")).png"))
                }
                go(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go(0) }
    }

    func statusColor(_ st: HealthStatus) -> NSColor { st == .good ? .systemGreen : st == .busy ? .systemOrange : .systemRed }
    func intensity(_ st: HealthStatus) -> CGFloat { st == .good ? 0 : st == .busy ? 0.5 : 1 }

    func refreshIcon() {
        guard let b = item.button else { return }
        let s = model.snap
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        b.wantsLayer = true
        guard let host = b.layer else { return }
        if content.superlayer == nil { host.addSublayer(content) }
        content.isGeometryFlipped = host.isGeometryFlipped
        content.bounds = CGRect(x: 0, y: 0, width: 30, height: 20)
        content.position = CGPoint(x: b.bounds.midX, y: b.bounds.midY)
        b.setAccessibilityLabel("MoleBar: " + (s.status == .stressed ? "Strained" : s.status.rawValue))
        let bk = "\(style.rawValue)|\(reduce)|\(dark)"
        if bk != builtKey { builtKey = bk; statusKey = ""; buildIcon(b, reduce: reduce, dark: dark) }
        if style == .percent { b.title = "\(Int(s.cpu.rounded()))%" }
        if s.status.rawValue != statusKey { statusKey = s.status.rawValue; applyStatus(s.status, reduce: reduce) }
    }

    func buildIcon(_ b: NSStatusBarButton, reduce: Bool, dark: Bool) {
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        b.title = ""; b.image = nil; b.imagePosition = .noImage
        let fg = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.78)
        switch style {
        case .dot:
            item.length = 18
            orb = CAShapeLayer(); ripple = CAShapeLayer()
            for l in [ripple, orb] {
                l.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
                l.position = CGPoint(x: 15, y: 10)
                content.addSublayer(l)
            }
            ripple.fillColor = nil; ripple.lineWidth = 1
        case .glass:
            item.length = 22
            let cup = CGMutablePath()
            cup.move(to: CGPoint(x: 9.5, y: 17.5)); cup.addLine(to: CGPoint(x: 20.5, y: 17.5))
            cup.addLine(to: CGPoint(x: 19, y: 4.5)); cup.addQuadCurve(to: CGPoint(x: 18, y: 3.5), control: CGPoint(x: 18.9, y: 3.5))
            cup.addLine(to: CGPoint(x: 12, y: 3.5)); cup.addQuadCurve(to: CGPoint(x: 11, y: 4.5), control: CGPoint(x: 11.1, y: 3.5))
            cup.closeSubpath()
            let clip = CALayer(); clip.frame = content.bounds
            let mask = CAShapeLayer(); mask.path = cup; mask.fillColor = NSColor.black.cgColor
            clip.mask = mask
            levelLayer = CALayer(); waveLayer = CAShapeLayer()
            levelLayer.position = CGPoint(x: 0, y: 3.5)
            levelLayer.addSublayer(waveLayer)
            clip.addSublayer(levelLayer)
            content.addSublayer(clip)
            let outline = CAShapeLayer(); outline.path = cup; outline.fillColor = nil
            outline.strokeColor = fg.cgColor; outline.lineWidth = 1.4; outline.lineJoin = .round
            content.addSublayer(outline)
        case .heartbeat:
            item.length = 32
            let clip = CALayer(); clip.frame = CGRect(x: 1, y: 2, width: 28, height: 16); clip.masksToBounds = true
            beatLayer = CAShapeLayer(); beatLayer.fillColor = nil
            beatLayer.lineWidth = 1.5; beatLayer.lineCap = .round; beatLayer.lineJoin = .round
            clip.addSublayer(beatLayer)
            content.addSublayer(clip)
        case .percent:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.font = font
            let w = ("100%" as NSString).size(withAttributes: [.font: font]).width
            item.length = ceil(w + 8 + 6 + 14)
            b.imagePosition = .imageLeading
        }
    }

    func applyStatus(_ st: HealthStatus, reduce: Bool) {
        let c = statusColor(st).cgColor
        let p = intensity(st)
        switch style {
        case .dot:
            orb.fillColor = c; ripple.strokeColor = c
            orb.removeAllAnimations(); ripple.removeAllAnimations()
            orb.transform = CATransform3DMakeScale(0.78 + p * 0.1, 0.78 + p * 0.1, 1)
            ripple.opacity = 0
            if reduce { return }
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.72 + p * 0.06
            pulse.toValue = 0.95 + p * 0.3
            pulse.duration = 2.1 - p * 1.5          // Good ~2.1s per breath, Strained ~0.6s
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            orb.add(pulse, forKey: "pulse")
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.8; grow.toValue = 1.9
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55; fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = 1.7 - p * 0.9
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.add(g, forKey: "ripple")
        case .glass:
            // Good empty, Busy half, Strained full; the surface sloshes faster and higher as it fills.
            let level: CGFloat = st == .good ? 0 : st == .busy ? 0.5 : 0.96
            levelLayer.position = CGPoint(x: 0, y: 3.5 + level * 14)
            waveLayer.fillColor = c
            let amp: CGFloat = 0.5 + p * 0.9
            let w = CGMutablePath()
            w.move(to: CGPoint(x: 0, y: -30))
            for x in stride(from: CGFloat(0), through: 60, by: 1) { w.addLine(to: CGPoint(x: x, y: amp * sin(2 * .pi * x / 9))) }
            w.addLine(to: CGPoint(x: 60, y: -30)); w.closeSubpath()
            waveLayer.path = w
            waveLayer.opacity = st == .good ? 0 : 1
            waveLayer.removeAllAnimations()
            if !reduce {
                let slosh = CABasicAnimation(keyPath: "position.x")
                slosh.fromValue = 0; slosh.toValue = -9
                slosh.duration = 1.8 - p * 1.1
                slosh.repeatCount = .infinity
                waveLayer.add(slosh, forKey: "slosh")
            }
        case .heartbeat:
            let amp: CGFloat = st == .good ? 2 : st == .busy ? 4.5 : 6.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 8))
            for k in 0..<4 {
                let x = CGFloat(k) * 14
                for (dx, dy) in [(3.0, 0.0), (4.0, 0.2), (5.0, 0.0), (6.0, 0.0), (7.0, 1.0), (8.0, -0.6), (9.0, 0.0), (10.5, 0.0), (11.5, 0.25), (12.5, 0.0), (14.0, 0.0)] {
                    path.addLine(to: CGPoint(x: x + CGFloat(dx), y: 8 + amp * CGFloat(dy)))
                }
            }
            beatLayer.path = path
            beatLayer.strokeColor = c
            beatLayer.removeAllAnimations()
            if !reduce {
                let scroll = CABasicAnimation(keyPath: "position.x")
                scroll.fromValue = 0; scroll.toValue = -14
                scroll.duration = 1.7 - p * 1.1
                scroll.repeatCount = .infinity
                beatLayer.add(scroll, forKey: "scroll")
            }
        case .percent:
            let d = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
                statusColorFill(st).setFill(); NSBezierPath(ovalIn: r).fill(); return true
            }
            d.isTemplate = false
            item.button?.image = d
        }
    }

    func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        let styles = NSMenu()
        for st in IconStyle.allCases {
            let mi = NSMenuItem(title: st.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = st.rawValue; mi.state = st == style ? .on : .off
            styles.addItem(mi)
        }
        let sub = NSMenuItem(title: "Menu bar icon", action: nil, keyEquivalent: "")
        sub.submenu = styles
        menu.addItem(sub)
        let hover = NSMenuItem(title: "Open on hover", action: #selector(toggleHover), keyEquivalent: "")
        hover.target = self; hover.state = UserDefaults.standard.bool(forKey: "openOnHover") ? .on : .off
        menu.addItem(hover)
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = model.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MoleBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = IconStyle(rawValue: raw) else { return }
        style = st
        UserDefaults.standard.set(raw, forKey: "iconStyle")
        refreshIcon()
    }
    @objc func toggleLogin() { model.toggleLaunchAtLogin() }

    // MARK: Open on hover (optional, off by default; toggle in the right-click menu)
    // Hovering the menu bar item opens the popover; moving away closes it. Clicking the item or anything inside the
    // popover "pins" it open, so it behaves like a normal click-opened popover from then on.
    var hoverOpened = false
    var hoverTimer: Timer?
    var hoverDelay: DispatchWorkItem?
    var outsideTicks = 0

    func installHover() {
        guard let b = item.button else { return }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, self.hoverOpened, e.window != nil, e.window === self.popover.contentViewController?.view.window {
                    self.hoverOpened = false; self.stopHoverTimer()
                }
            }
            return e
        }
    }

    // The status bar button doesn't reliably deliver tracking-area events, so while the option is on we watch the
    // pointer position a few times a second instead (cheap, and needs no permissions).
    var pointerWasOver = false
    var pointerTimer: Timer?

    func updatePointerWatch() {
        pointerTimer?.invalidate(); pointerTimer = nil; pointerWasOver = false
        guard UserDefaults.standard.bool(forKey: "openOnHover") else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pointerTick() } }
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    func pointerTick() {
        guard let b = item.button, let w = b.window else { return }
        let over = w.convertToScreen(b.convert(b.bounds, to: nil)).insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        if over && !pointerWasOver { mouseEntered() } else if !over && pointerWasOver { mouseExited() }
        pointerWasOver = over
    }

    func mouseEntered() {
        guard UserDefaults.standard.bool(forKey: "openOnHover"), !popover.isShown, item.menu == nil else { return }
        hoverDelay?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.openFromHover() } }
        hoverDelay = w
        hoverCue(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)   // a short pause, so passing over the icon doesn't pop it open
    }
    func mouseExited() { hoverDelay?.cancel(); hoverDelay = nil; hoverCue(false) }

    /// While the pause runs, the icon swells slightly so you can see the popover is about to open.
    func hoverCue(_ on: Bool) {
        let to: CGFloat = on ? 1.2 : 1
        let from = (content.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (on ? 1 : 1.2)
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = from; a.toValue = to
        a.duration = on ? 0.3 : 0.15
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(a, forKey: "cue")
        content.transform = CATransform3DMakeScale(to, to, 1)
    }

    func openFromHover() {
        guard !popover.isShown else { return }
        hoverCue(false)
        showPopover(activate: false)
        hoverOpened = true
        outsideTicks = 0
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.hoverTick() } }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    func hoverTick() {
        guard hoverOpened, popover.isShown, let b = item.button, let bw = b.window,
              let pw = popover.contentViewController?.view.window else { hoverOpened = false; stopHoverTimer(); return }
        let button = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let zone = button.union(pw.frame).insetBy(dx: -8, dy: -8)   // button + popover + the gap between them
        if zone.contains(NSEvent.mouseLocation) { outsideTicks = 0; return }
        outsideTicks += 1
        if outsideTicks >= 3 { popover.performClose(nil); hoverOpened = false; stopHoverTimer() }   // ~0.45s outside
    }

    func stopHoverTimer() { hoverTimer?.invalidate(); hoverTimer = nil }

    @objc func toggleHover() {
        let on = !UserDefaults.standard.bool(forKey: "openOnHover")
        UserDefaults.standard.set(on, forKey: "openOnHover")
        updatePointerWatch()
    }

    func showPopover(activate: Bool) {
        guard let b = item.button else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        if let w = popover.contentViewController?.view.window {
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x, y: w.frame.origin.y + 8))
            if activate { w.makeKey() }
        }
    }

    @objc func toggle() {
        guard item.button != nil else { return }
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        hoverDelay?.cancel(); hoverCue(false)
        if hoverOpened && popover.isShown { hoverOpened = false; stopHoverTimer(); return }   // a click pins a hover-opened popover
        if popover.isShown { popover.performClose(nil) } else { showPopover(activate: true) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
