import AppKit

/// Dims every screen and, one screen at a time (Space to start each), runs three phases:
/// red = eyes only over a 4×4 grid + shared edges; blue = point your nose at the dot (teaches the head model);
/// green = keep looking at the dot while moving your head around (teaches the gaze model to cancel head movement).
/// Esc cancels.
final class Calibration {
    private enum Kind { case eyes, nose, move }
    private struct Step { let p: CGPoint; let kind: Kind }   // p in global CG coordinates
    private struct Block { let screen: Int; let name: String; let steps: [Step] }
    private var blocks: [Block] = []
    private var views: [DotView] = []
    private var windows: [NSWindow] = []
    private var samples: [[Sample]]    // per camera
    private let cameras: [String?]       // uniqueID per camera slot, nil = slot off
    private var b = 0, i = 0
    private var target: (step: Step, center: CGPoint)?   // set while sampling
    private var waitingForSpace = true
    private var keyboardStep = false
    private var collectingKeyboard = false
    private var keyboard: [[Sample]]
    private var cancelled = false
    private var keyMonitor: Any?
    private let onDone: ([GazeModel?]?) -> Void

    /// `onDone` gets one model per camera slot (nil where that camera saw too little), or nil if cancelled.
    init(cameras: [String?], onDone: @escaping ([GazeModel?]?) -> Void) {
        self.onDone = onDone
        self.cameras = cameras
        samples = cameras.map { _ in [] }
        keyboard = cameras.map { _ in [] }
        let rects = Focuser.screensCG()
        for (k, r) in rects.enumerated() {
            func at(_ fx: Double, _ fy: Double) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) }
            var eyes: [CGPoint] = []
            let grid = [0.08, 0.36, 0.64, 0.92]
            for fy in grid { for fx in grid { eyes.append(at(fx, fy)) } }
            for (j, o) in rects.enumerated() where j != k { eyes += Self.edgePoints(r, o) }
            let nose = [at(0.2, 0.2), at(0.8, 0.2), at(0.8, 0.8), at(0.2, 0.8), at(0.5, 0.5)]
            let move = [at(0.5, 0.5), at(0.25, 0.3), at(0.75, 0.7)]
            let steps = eyes.map { Step(p: $0, kind: .eyes) } + nose.map { Step(p: $0, kind: .nose) } + move.map { Step(p: $0, kind: .move) }
            blocks.append(Block(screen: k, name: NSScreen.screens[k].localizedName, steps: steps))
        }
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
            w.isOpaque = false
            w.isReleasedWhenClosed = false
            let v = DotView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            windows.append(w)
            views.append(v)
        }
    }

    /// Three points just inside `r` along the edge it shares with `o` — where screen mix-ups happen.
    static func edgePoints(_ r: CGRect, _ o: CGRect) -> [CGPoint] {
        let along = [0.25, 0.5, 0.75]
        let y0 = max(r.minY, o.minY), y1 = min(r.maxY, o.maxY), x0 = max(r.minX, o.minX), x1 = min(r.maxX, o.maxX)
        var pts: [CGPoint] = []
        if y1 - y0 > 50 {
            if abs(r.maxX - o.minX) < 2 { pts += along.map { CGPoint(x: r.maxX - 0.05 * r.width, y: y0 + (y1 - y0) * $0) } }
            if abs(r.minX - o.maxX) < 2 { pts += along.map { CGPoint(x: r.minX + 0.05 * r.width, y: y0 + (y1 - y0) * $0) } }
        }
        if x1 - x0 > 50 {
            if abs(r.maxY - o.minY) < 2 { pts += along.map { CGPoint(x: x0 + (x1 - x0) * $0, y: r.maxY - 0.05 * r.height) } }
            if abs(r.minY - o.maxY) < 2 { pts += along.map { CGPoint(x: x0 + (x1 - x0) * $0, y: r.minY + 0.05 * r.height) } }
        }
        return pts
    }

    func start() {
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.cancel(); return nil }
            if e.keyCode == 49, self.waitingForSpace {
                self.waitingForSpace = false
                if self.keyboardStep { self.recordKeyboard() } else { self.next() }
                return nil
            }
            return e
        }
        prompt(done: nil)
    }

    func add(_ f: [Double], camera i: Int) {
        if let (step, center) = target {
            // the head model learns where the head points: the screen centre while only the eyes move,
            // the dot itself when the nose points at it, and nothing while the head is deliberately wandering
            let head: CGPoint? = step.kind == .eyes ? center : step.kind == .nose ? step.p : nil
            samples[i].append(Sample(f: f, x: step.p.x, y: step.p.y, hx: head.map { Double($0.x) }, hy: head.map { Double($0.y) }))
        }
        if collectingKeyboard { keyboard[i].append(Sample(f: f, x: 0, y: 0)) }
    }

    private func prompt(done: String?) {
        let block = blocks[b]
        for (k, v) in views.enumerated() {
            v.dot = nil
            v.hint = nil
            v.message = k == block.screen
                ? (done.map { "✓ \($0) calibrated.\n\n" } ?? "") + "Press Space to calibrate \(block.name) (about 45 seconds).\n\n● Red dot: face the middle of the screen, follow it with your eyes only.\n● Blue dot: point your nose at it.\n● Green dot: keep your eyes on it and slowly move your head around —\n   left, right, up, down, closer and farther."
                : "Look at the other screen."
            v.needsDisplay = true
        }
        waitingForSpace = true
    }

    private func next() {
        guard !cancelled else { return }
        let block = blocks[b]
        guard i < block.steps.count else {
            b += 1
            i = 0
            if b < blocks.count { prompt(done: block.name) } else { keyboardPrompt(done: block.name) }
            return
        }
        let step = block.steps[i]
        let p = step.p
        let w = windows[block.screen]
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let v = views[block.screen]
        let r = Focuser.screensCG()[block.screen]
        // a new phase gets a moment for the instruction to sink in
        let phaseStart = i == 0 || block.steps[i - 1].kind != step.kind
        let (settle, collect): (Double, Double)
        switch step.kind {
        case .eyes: (settle, collect) = (0.6, 1.0); v.color = .systemRed; v.hint = "Head still — follow the red dot with your eyes"
        case .nose: (settle, collect) = (1.0, 1.0); v.color = .systemBlue; v.hint = "Point your nose at the blue dot"
        case .move: (settle, collect) = (0.5, 4.0); v.color = .systemGreen; v.hint = "Eyes on the green dot — slowly move your head around"
        }
        let lead = phaseStart && i > 0 ? 1.5 : 0
        v.message = nil
        v.dot = CGPoint(x: p.x - w.frame.minX, y: primaryH - p.y - w.frame.minY)
        v.needsDisplay = true
        // let the eyes (or head) land, then sample
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + settle) { if !self.cancelled { self.target = (step, CGPoint(x: r.midX, y: r.midY)) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + settle + collect) {
            self.target = nil
            self.i += 1
            self.next()
        }
    }

    /// Last step: learn what "looking at the keyboard" looks like, so typing heads-down never moves focus.
    private func keyboardPrompt(done: String) {
        let lowest = Focuser.screensCG().indices.max { Focuser.screensCG()[$0].maxY < Focuser.screensCG()[$1].maxY } ?? 0
        for (k, v) in views.enumerated() {
            v.dot = nil
            v.hint = nil
            v.message = k == lowest ? "✓ \(done) calibrated.\n\nLast step: look down at your keyboard the way you do while typing,\nand press Space. Keep looking at it for 3 seconds." : ""
            v.needsDisplay = true
        }
        keyboardStep = true
        waitingForSpace = true
    }

    private func recordKeyboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if !self.cancelled { self.collectingKeyboard = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard !self.cancelled else { return }
            self.collectingKeyboard = false
            self.finish(self.cameras.indices.map { i in
                self.cameras[i].flatMap { GazeModel.fit(calib: self.samples[i], keyboard: self.keyboard[i], camera: $0) }
            })
        }
    }

    private func cancel() {
        cancelled = true
        target = nil
        finish(nil)
    }

    private func finish(_ models: [GazeModel?]?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        onDone(models)
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class DotView: NSView {
    var dot: CGPoint?
    var color = NSColor.systemRed
    var message: String?
    var hint: String?   // current phase, shown at the top

    override func draw(_ dirtyRect: NSRect) {
        if let message {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = message as NSString
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .medium), .paragraphStyle: style]
            let size = text.boundingRect(with: NSSize(width: bounds.width - 80, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: attrs).size
            text.draw(in: NSRect(x: 40, y: bounds.midY - size.height / 2, width: bounds.width - 80, height: size.height), withAttributes: attrs)
        }
        if let hint {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (hint as NSString).draw(in: NSRect(x: 40, y: bounds.maxY - 90, width: bounds.width - 80, height: 40),
                                    withAttributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 24, weight: .semibold), .paragraphStyle: style])
        }
        let hint = "Esc to cancel" as NSString
        hint.draw(at: NSPoint(x: 40, y: 40), withAttributes: [.foregroundColor: NSColor.gray, .font: NSFont.systemFont(ofSize: 14)])
        guard let d = dot else { return }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: d.x - 14, y: d.y - 14, width: 28, height: 28)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: d.x - 3, y: d.y - 3, width: 6, height: 6)).fill()
    }
}
