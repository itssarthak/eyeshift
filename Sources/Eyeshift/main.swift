import AppKit
import AVFoundation
import Carbon.HIToolbox
import UserNotifications

if CommandLine.arguments.contains("--selftest") {
    GazeModel.selfTest()
    Focuser.selfTest()
    OneEuro.selfTest()
    print("selftest ok")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let trackers = [Tracker(secondary: false), Tracker(secondary: true)]
    private static let modelKeys = ["model", "model2"]
    private let focuser = Focuser()
    private var models = AppDelegate.modelKeys.map { GazeModel.load($0) }   // one per camera slot
    private var cameraIDs: [String?] = [nil, nil]                            // camera each slot is actually reading
    private var calibration: Calibration?
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "g")
    private var smoothed: CGPoint?
    private var smoothedHead: CGPoint?
    private var gazeFilter = OneEuro(), headFilter = OneEuro()
    private var faceVisible = false
    private var latest: [(f: [Double], at: Date)?] = [nil, nil]
    private var recentClicks: [Int: [Bool]] = [:]       // per screen: did we predict the clicked screen/spot?
    /// Our last focus change, kept briefly to learn whether it was right (you typed on) or wrong (you clicked elsewhere).
    private var lastSwitch: (at: Date, target: CGRect, readings: [Reading], gaze: CGPoint)?
    private var unfitted = [0, 0]       // per camera: samples remembered since the last refit
    private var lastCaretSample = Date.distantPast
    private var lastAccuracyAlert: [Int: Date] = [:]
    private var dot: NSPanel?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private let defaults = UserDefaults.standard

    private var paused = false { didSet { refreshStatus() } }

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: settingDefaults)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        for (i, t) in trackers.enumerated() { t.onFeatures = { [weak self] f, id in self?.handle(i, f, id) } }
        registerHotKey()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clicked() }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.typed() }
        focuser.onAction = { [weak self] target in
            guard let self, let g = self.smoothed else { return }
            self.settleLastSwitch()
            self.lastSwitch = (Date(), target, self.readings(), g)
        }

        // macOS drops the Accessibility grant on every rebuild, so check every launch, not just the first
        if !AXIsProcessTrusted() {
            // the prompt also lists Eyeshift in System Settings so there's a box to tick
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            showWelcome()
            waitForAccessibility()
        } else if !defaults.bool(forKey: "welcomed") {
            showWelcome()
        }
        defaults.set(true, forKey: "welcomed")
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { return }  // the welcome guide shows how to allow it
                self.trackers.forEach { $0.start() }
                if self.models[0] == nil, self.welcomeWindow?.isVisible != true { self.calibrate() }
            }
        }

        // stop the camera while the Mac is asleep or locked
        let ws = NSWorkspace.shared.notificationCenter, dn = DistributedNotificationCenter.default()
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.trackers.forEach { $0.stop() } }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.trackers.forEach { $0.start() } }
        }
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.trackers.forEach { $0.stop() } }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.trackers.forEach { $0.start() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.models = AppDelegate.modelKeys.map { GazeModel.load($0) }  // nil if this screen layout was never calibrated
            self?.recentClicks = [:]
            self?.refreshStatus()
        }
        // settings window writes straight to UserDefaults; pick up the bits that need action
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.showDot(self.defaults.bool(forKey: "showDot"))
            if (self.defaults.string(forKey: "camera2") ?? "").isEmpty { self.cameraIDs[1] = nil; self.latest[1] = nil }
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { self.trackers.forEach { $0.start() } }  // no-op unless the camera choice changed
        }
        showDot(defaults.bool(forKey: "showDot"))
    }

    private func handle(_ i: Int, _ f: [Double]?, _ camera: String) {
        cameraIDs[i] = camera
        if let calibration { if let f { calibration.add(f, camera: i) }; return }
        latest[i] = f.map { ($0, Date()) }
        let r = readings()
        faceVisible = !r.isEmpty
        defer { refreshStatus() }
        if let ls = lastSwitch, Date().timeIntervalSince(ls.at) > 5 { settleLastSwitch() }
        guard !paused, !r.isEmpty else { return }
        smoothed = gazeFilter.filter(blend(r) { $0.predict($1) })
        smoothedHead = headFilter.filter(blend(r) { $0.predictHead($1) })
        if let dot, let s = smoothed {
            let h = NSScreen.screens.first?.frame.height ?? 0
            dot.setFrameOrigin(NSPoint(x: s.x - 8, y: h - s.y - 8))
        }
        let lines = r.compactMap { x in x.model.keyboardLine.map { ($0, x.weight) } }
        let kb = lines.isEmpty ? nil : lines.map { $0.0 * $0.1 }.reduce(0, +) / lines.map(\.1).reduce(0, +)
        focuser.update(gaze: smoothed!, head: smoothedHead!, keyboardLine: kb)
    }

    private typealias Reading = (slot: Int, model: GazeModel, f: [Double], weight: Double)

    /// Fresh face readings from every camera with a model trained on that same camera.
    private func readings() -> [Reading] {
        (0..<trackers.count).compactMap { i in
            guard let m = models[i], m.camera == cameraIDs[i], let (f, at) = latest[i], Date().timeIntervalSince(at) < 0.25 else { return nil }
            return (i, m, f, Self.weight(f))
        }
    }

    /// Trust a camera more the more squarely you face it (eyes are only readable head-on) and the closer you are.
    static func weight(_ f: [Double]) -> Double { exp(-pow(f[0] / 0.4, 2)) * max(f[5], 0.01) }

    private func blend(_ r: [Reading], _ predict: (GazeModel, [Double]) -> CGPoint) -> CGPoint {
        let total = r.map(\.weight).reduce(0, +)
        return r.reduce(CGPoint.zero) { acc, x in
            let p = predict(x.model, x.f)
            return CGPoint(x: acc.x + p.x * x.weight / total, y: acc.y + p.y * x.weight / total)
        }
    }


    // MARK: clicks: learning + accuracy watch

    /// A click is where you were almost certainly looking: use it to learn, and to notice when we're off.
    private func clicked() {
        let r = readings()
        guard !paused, calibration == nil, !r.isEmpty, Date().timeIntervalSince(focuser.lastOwnClick) > 0.3 else { return }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let click = CGPoint(x: NSEvent.mouseLocation.x, y: h - NSEvent.mouseLocation.y)
        let screens = Focuser.screensCG()
        guard let s = screens.firstIndex(where: { $0.contains(click) }) else { return }
        let p = blend(r) { $0.predict($1) }
        let err = hypot(p.x - click.x, p.y - click.y)

        let headScreen = Focuser.screen(facing: blend(r) { $0.predictHead($1) }, screens, current: nil, turn: 0.5, hysteresis: 0, offScreen: 0.2)
        watchAccuracy(screen: s, hit: headScreen == s && err < 0.25 * screens[s].width)

        guard defaults.bool(forKey: "learnClicks") else { return }
        // clicking somewhere else right after we moved focus = we got it wrong, and the click is the right answer.
        // Learn from what the face looked like when we decided, and weigh it heavily.
        if let ls = lastSwitch, Date().timeIntervalSince(ls.at) < 4, !ls.target.contains(click) {
            lastSwitch = nil
            for x in ls.readings { remember(x.slot, Sample(f: x.f, x: click.x, y: click.y, hx: click.x, hy: click.y, w: 3)) }
        }
        // skip clicks made while clearly looking elsewhere
        guard err < 0.4 * screens[s].width else { return }
        for x in r { remember(x.slot, Sample(f: x.f, x: click.x, y: click.y, hx: click.x, hy: click.y)) }
    }

    /// No click-away within 5 s and you typed into what we focused = we got it right. Reinforce gently, with
    /// the gaze pulled inside the focused window (we know you were looking there, not exactly where).
    private func settleLastSwitch() {
        guard let ls = lastSwitch else { return }
        lastSwitch = nil
        let typedSince = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < Date().timeIntervalSince(ls.at)
        guard typedSince, defaults.bool(forKey: "learnClicks") else { return }
        let t = ls.target.insetBy(dx: min(40, ls.target.width / 4), dy: min(40, ls.target.height / 4))
        let p = CGPoint(x: min(max(ls.gaze.x, t.minX), t.maxX), y: min(max(ls.gaze.y, t.minY), t.maxY))
        for x in ls.readings { remember(x.slot, Sample(f: x.f, x: p.x, y: p.y, hx: p.x, hy: p.y, w: 0.5)) }
    }

    /// While typing with eyes on the screen you're looking near the text cursor: a free sample every couple of seconds.
    private func typed() {
        guard defaults.bool(forKey: "learnClicks"), !paused, calibration == nil, !focuser.atKeyboard,
              Date().timeIntervalSince(lastCaretSample) > 2, let caret = caretRect() else { return }
        let r = readings()
        guard !r.isEmpty, let screen = Focuser.screensCG().first(where: { $0.contains(CGPoint(x: caret.midX, y: caret.midY)) }) else { return }
        let c = CGPoint(x: caret.midX, y: caret.midY), g = blend(r) { $0.predict($1) }
        guard hypot(g.x - c.x, g.y - c.y) < 0.3 * screen.width else { return }   // probably looking elsewhere
        lastCaretSample = Date()
        for x in r { remember(x.slot, Sample(f: x.f, x: c.x, y: c.y, hx: c.x, hy: c.y, w: 0.5)) }
    }

    /// Screen rectangle of the text cursor in the focused app, if it exposes one.
    private func caretRect() -> CGRect? {
        guard let el: AXUIElement = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return nil }
        var range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        AXValueGetValue(bounds as! AXValue, .cgRect, &r)
        return r.width >= 0 && r.height > 2 ? r : nil
    }

    /// Stores a sample in that camera's situation memory; refits every 10 new samples.
    // ponytail: refit runs on the main thread (~tens of ms at full memory); move off-main if it ever stutters.
    private func remember(_ slot: Int, _ s: Sample) {
        guard let m = models[slot] else { return }
        models[slot] = m.remembering(s)
        unfitted[slot] += 1
        guard unfitted[slot] >= 10, let fitted = models[slot]?.refit() else { return }
        unfitted[slot] = 0
        models[slot] = fitted
        fitted.save(Self.modelKeys[slot])
    }

    private func watchAccuracy(screen s: Int, hit: Bool) {
        var r = (recentClicks[s] ?? []) + [hit]
        if r.count > 10 { r.removeFirst() }
        recentClicks[s] = r
        guard r.count == 10, r.filter({ !$0 }).count >= 5,
              Date().timeIntervalSince(lastAccuracyAlert[s] ?? .distantPast) > 3600 else { return }
        lastAccuracyAlert[s] = Date()
        recentClicks[s] = []
        let c = UNMutableNotificationContent()
        c.title = "Eyeshift accuracy dropped"
        c.body = "Focus keeps missing on \(NSScreen.screens[s].localizedName). Click to recalibrate."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "accuracy-\(s)", content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.calibrate() }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    // MARK: menu

    private func buildMenu() {
        let m = NSMenu()
        statusLine.isEnabled = false
        m.addItem(statusLine)
        m.addItem(.separator())
        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(pauseItem)
        m.addItem(withTitle: "Recalibrate…", action: #selector(calibrate), keyEquivalent: "")
        m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        m.addItem(withTitle: "Welcome Guide…", action: #selector(showWelcome), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Eyeshift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = m
        refreshStatus()
    }

    private func refreshStatus() {
        var line: String
        if models[0] == nil { line = "Not calibrated for these screens" }
        else if cameraIDs.indices.contains(where: { cameraIDs[$0] != nil && models[$0]?.camera != cameraIDs[$0] }) { line = "Camera changed — please recalibrate" }
        else if paused { line = "Paused" }
        else if !faceVisible { line = "No face in view" }
        else if focuser.atKeyboard { line = "Looking at keyboard — holding focus" }
        else if let s = focuser.facing, s < NSScreen.screens.count { line = "Facing: \(NSScreen.screens[s].localizedName)" }
        else { line = "Looking away" }
        let learned = models.compactMap { $0?.learned?.count }.max() ?? 0
        if learned > 0 { line += " · learned \(learned) moments" }
        if statusLine.title != line { statusLine.title = line }
        let pauseTitle = paused ? "Resume Tracking" : "Pause Tracking"
        if pauseItem.title != pauseTitle { pauseItem.title = pauseTitle }
        let icon = paused || models[0] == nil ? "eye.slash" : "eye"
        if statusItem.button?.image?.accessibilityDescription != icon {
            statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: icon)
        }
    }

    @objc private func togglePause() { paused.toggle() }

    @objc private func showSettings() { showWindow(&settingsWindow, "Eyeshift Settings", SettingsView()) }

    @objc private func showWelcome() {
        showWindow(&welcomeWindow, "Welcome to Eyeshift", WelcomeView { [weak self] in
            self?.welcomeWindow?.orderOut(nil)
            self?.calibrate()
        })
    }

    /// Once Accessibility is ticked, carry on by ourselves: close the guide and calibrate if needed.
    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted() else { return }
            t.invalidate()
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }  // guide still has the camera step
            self.welcomeWindow?.orderOut(nil)
            if self.models[0] == nil { self.calibrate() }
        }
    }

    @objc private func calibrate() {
        guard calibration == nil else { return }
        // calibrating without Accessibility works but focus would never move — send them to the guide instead
        guard AXIsProcessTrusted() else { showWelcome(); waitForAccessibility(); return }
        smoothed = nil
        smoothedHead = nil
        gazeFilter = OneEuro()
        headFilter = OneEuro()
        calibration = Calibration(cameras: cameraIDs) { [weak self] result in
            guard let self else { return }
            self.calibration = nil
            if let result {
                for (i, m) in result.enumerated() {
                    if let m { m.save(Self.modelKeys[i]) } else { GazeModel.remove(Self.modelKeys[i]) }
                    self.models[i] = m
                }
                self.recentClicks = [:]
            }
            self.refreshStatus()
        }
        calibration?.start()
    }

    private func showDot(_ on: Bool) {
        if on, dot == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 16, height: 16), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.ignoresMouseEvents = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let v = NSView(frame: p.contentLayoutRect)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.7).cgColor
            v.layer?.cornerRadius = 8
            p.contentView = v
            p.orderFrontRegardless()
            dot = p
        } else if !on, dot != nil {
            dot?.orderOut(nil)
            dot = nil
        }
    }

    // MARK: ⇧⌘G pause hotkey

    private func registerHotKey() {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x474C_4E43, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue().paused.toggle()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

/// One Euro filter (Casiez et al.): heavy smoothing while the point is still, little lag when it moves fast.
struct OneEuro {
    var minCutoff = 0.8   // Hz; lower = steadier when still
    var beta = 0.004      // higher = less lag on fast moves
    private var last: (p: CGPoint, d: CGPoint, t: Date)?

    mutating func filter(_ p: CGPoint, at t: Date = Date()) -> CGPoint {
        guard let l = last else { last = (p, .zero, t); return p }
        let dt = max(t.timeIntervalSince(l.t), 1e-3)
        func alpha(_ cutoff: Double) -> Double { let r = 2 * Double.pi * cutoff * dt; return r / (r + 1) }
        let raw = CGPoint(x: (p.x - l.p.x) / dt, y: (p.y - l.p.y) / dt)
        let ad = alpha(1)
        let d = CGPoint(x: l.d.x + ad * (raw.x - l.d.x), y: l.d.y + ad * (raw.y - l.d.y))
        let a = alpha(minCutoff + beta * hypot(d.x, d.y))
        let out = CGPoint(x: l.p.x + a * (p.x - l.p.x), y: l.p.y + a * (p.y - l.p.y))
        last = (out, d, t)
        return out
    }

    static func selfTest() {
        var f = OneEuro()
        let t0 = Date()
        var out = CGPoint.zero
        // jitter around (100,100) should settle near it
        for i in 0..<60 { out = f.filter(CGPoint(x: 100 + (i % 2 == 0 ? 20 : -20), y: 100), at: t0 + Double(i) / 15) }
        precondition(abs(out.x - 100) < 12, "one euro not smoothing: \(out)")
        // a big jump should be followed within half a second
        for i in 60..<68 { out = f.filter(CGPoint(x: 1500, y: 100), at: t0 + Double(i) / 15) }
        precondition(out.x > 1200, "one euro lags too much: \(out)")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
