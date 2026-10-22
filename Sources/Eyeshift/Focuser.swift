import AppKit
import ApplicationServices

/// Turns a stream of gaze points into focus changes: screen → window → split pane.
final class Focuser {
    /// Apps whose split panes we focus; everything else switches by whole window.
    private static let paneApps: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.vscodium",
        "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode", "com.google.android.studio",
    ]
    private static let electronApps: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.vscodium", "co.zeit.hyper",
    ]

    private struct Win { let pid: pid_t; let el: AXUIElement }
    private var lastWindowOnScreen: [Int: Win] = [:]
    private var candidate: (key: String, since: Date)?
    private var lastAction = Date.distantPast
    private(set) var lastOwnClick = Date.distantPast
    /// Screen the head is turned toward, for the menu's "Facing:" line. nil = looking away.
    private(set) var facing: Int?
    private(set) var atKeyboard = false
    /// Called after every focus change we make, with the frame of what we focused.
    var onAction: ((CGRect) -> Void)?
    private var electronPrimed: Set<pid_t> = []
    private let me = getpid()
    private let defaults = UserDefaults.standard

    // MARK: tunables (user-facing ones live in Settings)
    private let mouseHold = 1.5        // no focus moves this long after mouse/trackpad use
    private let screenTypingPause = 0.6  // screens may switch this soon after typing; panes wait the full typing pause
    private let hysteresis = 0.05      // going back across a boundary needs this much extra turn
    private let offScreen = 0.2        // further than this (fraction of width) from every screen = looking away

    static func screensCG() -> [CGRect] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: h - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    /// `gaze` (head + eyes) picks the window/pane; `head` (head pose only) picks the screen.
    func update(gaze p: CGPoint, head h: CGPoint, keyboardLine: Double?) {
        let screens = Self.screensCG()
        // looking down at the keyboard (head or just eyes): keep focus exactly where it is
        atKeyboard = keyboardLine.map { h.y > $0 || p.y > $0 } ?? false
        guard !atKeyboard else { candidate = nil; return }
        let front = frontWindow()
        let current = front.flatMap { frame($0.el) }.flatMap { f in screens.firstIndex { $0.contains(CGPoint(x: f.midX, y: f.midY)) } }
        if let front, let current { lastWindowOnScreen[current] = front }
        facing = Self.screen(facing: h, screens, current: current, turn: defaults.double(forKey: "headTurn") / 100, hysteresis: hysteresis, offScreen: offScreen)

        let keyAgo = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let waitTyping = defaults.bool(forKey: "waitTyping")
        guard !mouseBusy(), Date().timeIntervalSince(lastAction) > 0.5, let s = facing else { candidate = nil; return }

        if s != current {
            guard !waitTyping || keyAgo > screenTypingPause else { candidate = nil; return }
            let delay = defaults.double(forKey: "switchDelay") / 1000
            if let w = lastWindowOnScreen[s], let f = frame(w.el), screens[s].contains(CGPoint(x: f.midX, y: f.midY)) {
                act("screen:\(s)", delay, f) { self.focus(w, pointerTo: CGPoint(x: f.midX, y: f.midY)) }
            } else if let w = window(at: screens[s].contains(p) ? p : CGPoint(x: screens[s].midX, y: screens[s].midY)), let f = frame(w.el) {
                act("screen:\(s)", delay, f) { self.focus(w, pointerTo: CGPoint(x: f.midX, y: f.midY)) }
            }
            return
        }

        guard defaults.bool(forKey: "paneFocus"), !waitTyping || keyAgo > defaults.double(forKey: "typingPause") else { candidate = nil; return }
        let delay = defaults.double(forKey: "paneDelay") / 1000
        let margin = defaults.double(forKey: "edgeMargin")

        // Reading near the edge of the focused window must not hand focus to its neighbour:
        // stay until the gaze is clearly past the edge. Same for the focused pane inside it.
        if let front, let ff = frame(front.el), ff.insetBy(dx: -margin, dy: -margin).contains(p) {
            let current = focusedPane(front)
            if let current, current.insetBy(dx: -margin, dy: -margin).contains(p) { candidate = nil; return }
            guard let pane = pane(at: p, in: front), pane != current else { candidate = nil; return }
            act("pane:\(pane)", delay, pane) { self.focusPane(pane, pid: front.pid) }
            return
        }
        guard let w = window(at: p) else { candidate = nil; return }
        act("win:\(w.pid):\(String(describing: frame(w.el)))", delay, frame(w.el)) { self.focus(w, pointerTo: nil) }
    }

    /// The pane holding the app's keyboard focus, if it's a pane app.
    private func focusedPane(_ w: Win) -> CGRect? {
        guard let el: AXUIElement = attr(AXUIElementCreateApplication(w.pid), kAXFocusedUIElementAttribute), let f = frame(el) else { return nil }
        return pane(at: CGPoint(x: f.midX, y: f.midY), in: w)
    }

    /// Runs `action` once the same target has been held for `dwell` seconds.
    private func act(_ key: String, _ dwell: Double, _ target: CGRect?, _ action: () -> Void) {
        let now = Date()
        guard let c = candidate, c.key == key else { candidate = (key, now); return }
        guard now.timeIntervalSince(c.since) >= dwell else { return }
        action()
        if let target { onAction?(target) }
        candidate = nil
        lastAction = now
    }

    // MARK: screens

    /// Which screen the head points at. Leaving the current screen means turning `turn` of the way
    /// from its centre toward another screen's centre (plus `hysteresis`), so boundaries don't flicker.
    static func screen(facing h: CGPoint, _ screens: [CGRect], current: Int?, turn: Double, hysteresis: Double, offScreen: Double) -> Int? {
        let d = screens.map { distance(h, $0) }
        guard let nearest = d.indices.min(by: { d[$0] < d[$1] }), d[nearest] < offScreen * screens[nearest].width else { return nil }
        guard let c = current, c < screens.count else { return nearest }
        let cc = CGPoint(x: screens[c].midX, y: screens[c].midY)
        var best = c, bestT = turn + hysteresis
        for (k, r) in screens.enumerated() where k != c {
            let v = CGPoint(x: r.midX - cc.x, y: r.midY - cc.y), u = CGPoint(x: h.x - cc.x, y: h.y - cc.y)
            let t = (u.x * v.x + u.y * v.y) / (v.x * v.x + v.y * v.y)
            if t > bestT { best = k; bestT = t }
        }
        return best
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    static func selfTest() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 600), right = CGRect(x: 1000, y: 0, width: 1000, height: 600)
        let s = [left, right]
        func pick(_ x: Double, _ cur: Int?) -> Int? { screen(facing: CGPoint(x: x, y: 300), s, current: cur, turn: 0.5, hysteresis: 0.05, offScreen: 0.2) }
        precondition(pick(900, 0) == 0, "switched before the boundary")
        precondition(pick(1100, 0) == 1, "didn't switch past the boundary")
        precondition(pick(980, 1) == 1 && pick(900, 1) == 0, "hysteresis wrong")
        precondition(pick(3000, 0) == nil, "looking away should be ignored")
    }

    // MARK: user activity

    private func mouseBusy() -> Bool {
        let mouse = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        // our own fallback clicks don't count as the user using the mouse
        return mouse < mouseHold && Date().timeIntervalSince(lastOwnClick) > mouse + 0.2
    }

    // MARK: windows

    private func frontWindow() -> Win? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != me else { return nil }
        let pid = app.processIdentifier
        guard let el: AXUIElement = attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        return Win(pid: pid, el: el)
    }

    /// Topmost normal window under the point.
    private func window(at p: CGPoint) -> Win? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd), r.width > 50, r.contains(p) else { continue }
            let wins: [AXUIElement] = attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
            return wins.first { frame($0).map { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2 } ?? false }
                .map { Win(pid: pid, el: $0) }
        }
        return nil
    }

    private func focus(_ w: Win, pointerTo: CGPoint?) {
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        if let p = pointerTo { CGWarpMouseCursorPosition(p) }
    }

    // MARK: panes

    /// The split pane (scroll/text area) under the point, if it's a real sub-region of the window.
    private func pane(at p: CGPoint, in w: Win) -> CGRect? {
        guard let bundle = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier,
              Self.paneApps.contains(bundle) || bundle.hasPrefix("com.jetbrains."),
              let wf = frame(w.el) else { return nil }
        if Self.electronApps.contains(bundle), !electronPrimed.contains(w.pid) {
            // Electron only builds its accessibility tree when asked
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            electronPrimed.insert(w.pid)
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
              var el = hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(el, &owner) == .success, owner == w.pid else { return nil }   // gaze is over another app
        for _ in 0..<15 {
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            if ["AXScrollArea", "AXTextArea"].contains(role), let f = frame(el),
               f.width * f.height < 0.85 * wf.width * wf.height, f.width * f.height > 0.03 * wf.width * wf.height {
                return f
            }
            guard let parent: AXUIElement = attr(el, kAXParentAttribute) else { break }
            el = parent
        }
        return nil
    }

    private func focusPane(_ pane: CGRect, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        let center = CGPoint(x: pane.midX, y: pane.midY)
        if let f: AXUIElement = attr(app, kAXFocusedUIElementAttribute), let ff = frame(f), pane.contains(CGPoint(x: ff.midX, y: ff.midY)) {
            return  // already there
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &hit) == .success,
              let el = hit else { return }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let f: AXUIElement = attr(app, kAXFocusedUIElementAttribute), let ff = frame(f), pane.contains(CGPoint(x: ff.midX, y: ff.midY)) {
            return
        }
        // Some terminals/editors only move pane focus on a real click. Never click into another app.
        var owner: pid_t = 0
        guard defaults.bool(forKey: "clickFallback"), AXUIElementGetPid(el, &owner) == .success, owner == pid else { return }
        let back = CGEvent(source: nil)?.location
        lastOwnClick = Date()
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cgSessionEventTap)
        }
        if let back { CGWarpMouseCursorPosition(back) }
    }
}

// MARK: AX helpers

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
    return v as? T
}

func frame(_ el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
          let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
