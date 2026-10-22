import AppKit

/// One face reading paired with where on screen the user was looking (global CG coordinates, top-left origin).
/// `f` is the raw tracker vector: [yaw, pitch, roll, faceX, faceY, faceWidth, pupilX, pupilY] + eye-patch pixels.
struct Sample: Codable {
    var f: [Double]
    var x: Double
    var y: Double
    /// Where the head was pointing, if known; only these samples train the head (screen-choice) model.
    var hx: Double? = nil
    var hy: Double? = nil
    /// How much this sample counts (corrections 3, clicks 1, typing/confirmations 0.5). nil = 1.
    var w: Double? = nil
    /// Learned samples only: which situation it belongs to, and how far off the linear model was for it.
    var key: String? = nil
    var rx: Double? = nil
    var ry: Double? = nil
}

/// Linear ridge regression from a feature vector to a screen point.
// ponytail: linear; swap for a small polynomial/kNN model if accuracy on panes is too low.
struct Regressor: Codable {
    var mean: [Double]
    var std: [Double]
    var wx: [Double]
    var wy: [Double]
    var lambda: Double? = nil

    func predict(_ v: [Double]) -> CGPoint {
        let z = standardize(v)
        return CGPoint(x: dot(z, wx), y: dot(z, wy))
    }

    private func standardize(_ v: [Double]) -> [Double] {
        [1] + v.indices.map { (v[$0] - mean[$0]) / std[$0] }
    }

    static func fit(_ xs: [[Double]], _ ys: [Sample], lambda: Double) -> Regressor? {
        guard xs.count >= 20, let d = xs.first?.count else { return nil }
        let n = Double(xs.count)
        let mean = (0..<d).map { j in xs.map { $0[j] }.reduce(0, +) / n }
        let std = (0..<d).map { j in max(1e-6, (xs.map { pow($0[j] - mean[j], 2) }.reduce(0, +) / n).squareRoot()) }
        var r = Regressor(mean: mean, std: std, wx: [], wy: [], lambda: lambda)
        let k = d + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var bx = [Double](repeating: 0, count: k), by = bx
        for (x, s) in zip(xs, ys) {
            let z = r.standardize(x), w = s.w ?? 1
            for i in 0..<k {
                let wz = w * z[i]
                bx[i] += wz * s.x
                by[i] += wz * s.y
                for j in 0..<k { a[i][j] += wz * z[j] }
            }
        }
        for i in 1..<k { a[i][i] += lambda }
        guard let wx = solve(a, bx), let wy = solve(a, by) else { return nil }
        r.wx = wx
        r.wy = wy
        return r
    }

    /// Tries a few regularisation strengths, scoring each on every 4th dot (all of that dot's frames held out,
    /// so neighbouring frames can't leak), then refits on everything with the winner.
    static func bestFit(_ xs: [[Double]], _ ys: [Sample], lambda: Double?) -> Regressor? {
        if let lambda { return fit(xs, ys, lambda: lambda) }
        var dots: [String: Int] = [:]
        let group = ys.map { s in dots["\(Int(s.x)),\(Int(s.y))", default: dots.count] }
        let test = Set(group.indices.filter { group[$0] % 4 == 0 }), train = group.indices.filter { !test.contains($0) }
        guard test.count >= 5, train.count >= 20 else { return fit(xs, ys, lambda: 3) }
        let best = [0.3, 3, 30, 300].min { a, b in
            func err(_ l: Double) -> Double {
                guard let r = fit(train.map { xs[$0] }, train.map { ys[$0] }, lambda: l) else { return .infinity }
                return test.map { i in let p = r.predict(xs[i]); return hypot(p.x - ys[i].x, p.y - ys[i].y) }.reduce(0, +)
            }
            return err(a) < err(b)
        } ?? 3
        return fit(xs, ys, lambda: best)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p); b.swapAt(c, p)
            for r in (c + 1)..<n {
                let f = a[r][c] / a[c][c]
                for j in c..<n { a[r][j] -= f * a[c][j] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            x[r] = (b[r] - ((r + 1)..<n).reduce(0) { $0 + a[r][$1] * x[$1] }) / a[r][r]
        }
        return x
    }
}

/// Two models: `head` (head pose only) decides which screen you face; `full` (head + eyes) finds the point on it.
struct GazeModel: Codable {
    var version = 3             // bump when the feature vector changes; older saved models are dropped
    var head: Regressor
    var full: Regressor
    var screens: String
    var camera = ""             // uniqueID of the camera this model reads
    var calib: [Sample] = []
    var keyboard: [Sample] = [] // face readings while looking at the keyboard
    /// Head or gaze points below this y (CG, global) mean "looking at the keyboard": hold focus.
    var keyboardLine: Double?
    /// What everyday use taught us (clicks, corrections, typing), kept balanced across situations.
    var learned: [Sample]? = nil
    var clicks: [Sample]? = nil      // older builds' rolling click window; folded into `learned` on load
    var medianWidth: Double? = nil   // face width during calibration, for the near/normal/far split
    var poseStd: [Double]? = nil     // spread of the first 8 raw features, to measure "similar situation"

    static let perSituation = 3, maxLearned = 1500

    /// Face width shrinks as you sit back; dividing by it makes the same head turn count for more at a distance.
    static func headFeatures(_ r: [Double]) -> [Double] {
        let w = max(r[5], 0.05)
        return [r[0], r[1], r[2], r[3], r[4], r[5], r[0] / w, r[1] / w]
    }

    static func fullFeatures(_ r: [Double]) -> [Double] {
        let w = max(r[5], 0.05)
        return headFeatures(r) + [r[6], r[7], (r[6] - 0.5) / w, (r[7] - 0.5) / w] + r[8...]
    }

    func predictHead(_ f: [Double]) -> CGPoint { head.predict(Self.headFeatures(f)) }

    /// Linear model plus the local correction learned from everyday use.
    func predict(_ f: [Double]) -> CGPoint {
        let p = full.predict(Self.fullFeatures(f))
        let c = correction(f, at: p)
        return CGPoint(x: p.x + c.x, y: p.y + c.y)
    }

    /// Nearby remembered situations (similar head pose, position, eyes and predicted spot) vote with how far off
    /// the linear model was for them. Few or distant neighbours → little correction.
    // ponytail: brute-force scan of ≤1500 samples per frame; a k-d tree if `maxLearned` ever grows a lot.
    func correction(_ f: [Double], at p: CGPoint) -> CGPoint {
        guard let l = learned, !l.isEmpty, let sd = poseStd else { return .zero }
        var sw = 0.0, sx = 0.0, sy = 0.0
        for s in l {
            guard let rx = s.rx, let ry = s.ry else { continue }
            var d2 = 0.0
            for j in 0..<8 { let d = (f[j] - s.f[j]) / sd[j]; d2 += d * d }
            let dx = (p.x - (s.x - rx)) / 300, dy = (p.y - (s.y - ry)) / 300   // where the linear model put that sample
            d2 += dx * dx + dy * dy
            let w = exp(-d2 / 2) * (s.w ?? 1)
            sw += w; sx += w * rx; sy += w * ry
        }
        return CGPoint(x: sx / (sw + 1), y: sy / (sw + 1))   // the +1 is a prior pulling toward "no correction"
    }

    /// Situation = how you sit (face left/centre/right, up/middle/down, near/normal/far) × where you looked (screen, 4×3 cell).
    func situation(_ s: Sample) -> String {
        let f = s.f, mw = medianWidth ?? 0.25
        let px = min(2, max(0, Int(f[3] * 3))), py = min(2, max(0, Int(f[4] * 3)))
        let dist = f[5] < mw * 0.88 ? 0 : f[5] > mw * 1.12 ? 2 : 1
        let screens = Focuser.screensCG(), p = CGPoint(x: s.x, y: s.y)
        guard let k = screens.firstIndex(where: { $0.contains(p) }) else { return "\(px)\(py)\(dist)-off" }
        let r = screens[k]
        return "\(px)\(py)\(dist)-\(k)-\(Int((p.x - r.minX) / r.width * 4))\(Int((p.y - r.minY) / r.height * 3))"
    }

    /// Remembers a sample. It only pushes out an older one from the same situation, so a posture you use
    /// rarely is never forgotten just because it's old. Call `refit()` to learn from what was added.
    func remembering(_ s: Sample) -> GazeModel {
        var m = self, s = s
        s.key = situation(s)
        var l = learned ?? []
        let same = l.indices.filter { l[$0].key == s.key }
        if same.count >= Self.perSituation { l.remove(at: same[0]) }
        l.append(s)
        if l.count > Self.maxLearned {
            // over budget: drop the oldest sample of the most crowded situation
            let groups = Dictionary(grouping: l.indices) { l[$0].key ?? "" }
            if let crowded = groups.max(by: { $0.value.count < $1.value.count }) { l.remove(at: crowded.value[0]) }
        }
        m.learned = l
        return m
    }

    /// Refits on calibration + everything learned, reusing the regularisation chosen at calibration.
    func refit() -> GazeModel? {
        GazeModel.fit(calib: calib, learned: learned ?? [], keyboard: keyboard, camera: camera, lambdas: (head.lambda ?? 3, full.lambda ?? 3))
    }

    /// `lambda` nil = pick regularisation by holding out some calibration points and testing on them.
    static func fit(calib: [Sample], learned: [Sample] = [], keyboard: [Sample] = [], camera: String = "",
                    lambda: Double? = nil, lambdas: (Double, Double)? = nil) -> GazeModel? {
        let s = calib + learned
        let h = s.compactMap { x in x.hx.map { Sample(f: x.f, x: $0, y: x.hy ?? x.y, w: x.w) } }
        guard let head = Regressor.bestFit(h.map { headFeatures($0.f) }, h, lambda: lambdas?.0 ?? lambda),
              let full = Regressor.bestFit(s.map { fullFeatures($0.f) }, s, lambda: lambdas?.1 ?? lambda) else { return nil }
        var m = GazeModel(head: head, full: full, screens: screenSignature(), camera: camera, calib: calib, keyboard: keyboard)
        m.keyboardLine = keyboardLine(m, bottom: Double(Focuser.screensCG().map(\.maxY).max() ?? 0))
        let widths = calib.map { $0.f[5] }.sorted()
        m.medianWidth = widths.isEmpty ? nil : widths[widths.count / 2]
        m.poseStd = (0..<8).map { j in
            let v = calib.map { $0.f[j] }, mean = v.reduce(0, +) / Double(max(v.count, 1))
            return max(1e-3, (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(v.count, 1))).squareRoot())
        }
        // residuals against the new linear model drive the local correction
        m.learned = learned.map { x in
            var x = x
            let p = full.predict(fullFeatures(x.f))
            x.rx = x.x - p.x; x.ry = x.y - p.y
            return x
        }
        return m
    }

    /// Halfway between the bottom of the lowest screen and where the keyboard pose lands.
    static func keyboardLine(_ m: GazeModel, bottom: Double) -> Double? {
        guard !m.keyboard.isEmpty else { return nil }
        let ky = m.keyboard.map { m.predictHead($0.f).y }.reduce(0, +) / Double(m.keyboard.count)
        return ky > bottom ? (bottom + ky) / 2 : nil
    }

    /// Calibration is only valid for the screen layout it was made on.
    static func screenSignature() -> String {
        NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" }.joined(separator: ";")
    }

    /// Thousands of samples are too big for UserDefaults; models live in ~/Library/Application Support/Eyeshift/.
    static func url(_ key: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eyeshift/\(key).json")
    }

    static func load(_ key: String = "model") -> GazeModel? {
        guard let data = (try? Data(contentsOf: url(key))) ?? UserDefaults.standard.data(forKey: key),  // older builds kept it in defaults
              var m = try? JSONDecoder().decode(GazeModel.self, from: data),
              m.version == 3, m.screens == screenSignature() else { return nil }
        if m.learned == nil {
            // migrate: old models had no situation memory or residuals
            if m.medianWidth == nil, let r = fit(calib: m.calib, keyboard: m.keyboard, camera: m.camera) { m = r }
            for c in m.clicks ?? [] { m = m.remembering(c) }
            m.clicks = nil
            m.learned = m.learned ?? []
            m = m.refit() ?? m
        }
        return m
    }

    func save(_ key: String = "model") {
        let u = Self.url(key)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self), (try? data.write(to: u, options: .atomic)) != nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(key))
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func selfTest() {
        func sample(_ shift: Double) -> Sample {
            var f = (0..<32).map { _ in Double.random(in: -1...1) }
            f[5] = Double.random(in: 0.15...0.35)
            let x = 500 + 300 * f[0] - 100 * f[6] + 80 * f[20] + shift, y = 400 - 200 * f[1] + 50 * f[7]
            return Sample(f: f, x: x, y: y, hx: x, hy: y)
        }
        let samples = (0..<300).map { _ in sample(0) }
        precondition(fit(calib: samples) != nil, "auto-regularised fit failed")
        guard let m = fit(calib: samples, lambda: 0.001) else { fatalError("fit failed") }
        for s in samples.prefix(20) {
            let q = m.predict(s.f)
            precondition(abs(q.x - s.x) < 1 && abs(q.y - s.y) < 1, "bad prediction \(q) vs \(s)")
        }
        // distance compensation: x depends on yaw scaled by 1/faceWidth
        let far = (0..<200).map { _ -> Sample in
            var f = (0..<8).map { _ in Double.random(in: -1...1) }
            f[5] = Double.random(in: 0.1...0.4)
            return Sample(f: f, x: 1000 + 60 * f[0] / f[5], y: 0, hx: 1000 + 60 * f[0] / f[5], hy: 0)
        }
        guard let d = fit(calib: far, lambda: 0.001) else { fatalError("fit failed") }
        for s in far.prefix(20) { precondition(abs(d.predictHead(s.f).x - s.x) < 1, "distance compensation broken") }

        // situation memory: many samples from one situation keep only the newest few
        var mem = m
        let one = sample(0)
        for _ in 0..<50 { mem = mem.remembering(one) }
        precondition(mem.learned?.count == perSituation, "situation memory not capped")

        // local correction: when sitting far right (faceX > 0.7) the user's gaze lands 150pt further right than
        // the linear model thinks. After learning from that, predictions in that posture should improve a lot
        // while other postures stay put.
        func rightSample() -> Sample {
            var s = sample(0)
            s.f[3] = Double.random(in: 0.75...0.95)
            s.x += 150; s.hx = s.x
            return s
        }
        var smart = m
        for _ in 0..<150 { smart = smart.remembering(rightSample()) }
        guard let learnt = smart.refit() else { fatalError("refit failed") }
        let probes = (0..<30).map { _ in rightSample() }
        let errBefore = probes.map { abs(m.predict($0.f).x - $0.x) }.reduce(0, +)
        let errAfter = probes.map { abs(learnt.predict($0.f).x - $0.x) }.reduce(0, +)
        precondition(errAfter < errBefore * 0.5, "local correction didn't help: \(errAfter) vs \(errBefore)")
        var left = sample(0)
        left.f[3] = -0.9
        precondition(abs(learnt.predict(left.f).x - m.predict(left.f).x) < 60, "correction leaked into other postures")
    }
}

private func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
