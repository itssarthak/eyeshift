import AVFoundation
import Vision

/// Camera → face features: [yaw, pitch, roll, faceX, faceY, faceWidth, pupilX, pupilY] + two eye patches
/// (12×6 greyscale each, normalised) — the eye pixels themselves carry far more gaze signal than one pupil point.
/// Frames stay in memory and are dropped after Vision reads them.
final class Tracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue with the reading (nil when no face is visible) and the camera's uniqueID.
    var onFeatures: (([Double]?, String) -> Void)?
    /// The optional second camera ("camera2" setting); off when that setting is empty.
    let secondary: Bool
    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let request = VNDetectFaceLandmarksRequest()
    private var lastFrame = CMTime.zero
    private var cameraID: String?

    init(secondary: Bool) {
        self.secondary = secondary
        queue = DispatchQueue(label: secondary ? "eyeshift.camera2" : "eyeshift.camera")
    }

    /// Built-in and external cameras (no iPhone Continuity Camera).
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
    }

    /// Starts the camera, or switches to the one chosen in Settings ("camera" = uniqueID; empty = external if plugged in,
    /// else built-in — never the one picked as second camera).
    func start() {
        queue.async { [self] in
            let d = UserDefaults.standard
            let second = d.string(forKey: "camera2") ?? ""
            let devices = Self.cameras()
            let pick: AVCaptureDevice?
            if secondary {
                pick = second.isEmpty ? nil : devices.first { $0.uniqueID == second }
            } else {
                let want = d.string(forKey: "camera") ?? ""
                let others = devices.filter { $0.uniqueID != second }
                pick = others.first { $0.uniqueID == want } ?? others.first { $0.deviceType == .external } ?? others.first
            }
            guard let dev = pick else {
                if session.isRunning { session.stopRunning() }
                if !secondary { NSLog("Eyeshift: no camera") }
                return
            }
            if dev.uniqueID != cameraID, let input = try? AVCaptureDeviceInput(device: dev) {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                // a preset the camera can't do makes addInput throw, so reset, attach, then pick the best it supports
                session.sessionPreset = .high
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    NSLog("Eyeshift: can't use camera \(dev.localizedName)")
                    return
                }
                session.addInput(input)
                // bigger eyes in the frame = better gaze; fall back to 720p on cameras that can't do 1080p
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                else if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                if session.outputs.isEmpty {
                    let out = AVCaptureVideoDataOutput()
                    out.alwaysDiscardsLateVideoFrames = true
                    // plane 0 = luminance, read directly to find the iris
                    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                    out.setSampleBufferDelegate(self, queue: queue)
                    session.addOutput(out)
                }
                session.commitConfiguration()
                cameraID = dev.uniqueID
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeGetSeconds(CMTimeSubtract(t, lastFrame)) >= 1.0 / 15, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastFrame = t
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([request])
        let face = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width })
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let f = face.flatMap { features($0, pb) }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let id = cameraID ?? ""
        DispatchQueue.main.async { self.onFeatures?(f, id) }
    }

    private func features(_ face: VNFaceObservation, _ pb: CVPixelBuffer) -> [Double]? {
        guard let lm = face.landmarks else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidthOfPlane(pb, 0), height: CVPixelBufferGetHeightOfPlane(pb, 0))
        func eye(_ e: VNFaceLandmarkRegion2D?, _ p: VNFaceLandmarkRegion2D?) -> CGPoint? {
            e.flatMap { iris($0.pointsInImage(imageSize: size), pb) } ?? pupil(e, p)
        }
        guard let l = eye(lm.leftEye, lm.leftPupil), let r = eye(lm.rightEye, lm.rightPupil),
              let le = lm.leftEye, let re = lm.rightEye,
              let lp = patch(le.pointsInImage(imageSize: size), pb), let rp = patch(re.pointsInImage(imageSize: size), pb) else { return nil }
        let b = face.boundingBox
        let base: [Double] = [face.yaw?.doubleValue ?? 0, face.pitch?.doubleValue ?? 0, face.roll?.doubleValue ?? 0,
                              Double(b.midX), Double(b.midY), Double(b.width), Double(l.x + r.x) / 2, Double(l.y + r.y) / 2]
        return base + lp + rp
    }

    static let patchW = 12, patchH = 6

    /// A small greyscale picture of the eye (box-averaged cells), normalised to zero mean / unit spread so lighting doesn't matter.
    private func patch(_ outline: [CGPoint], _ pb: CVPixelBuffer) -> [Double]? {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0), !outline.isEmpty else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let px = base.assumingMemoryBound(to: UInt8.self)
        let xs = outline.map(\.x), ys = outline.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 - x0 >= 8 else { return nil }
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, pw = (x1 - x0) * 1.3, ph = pw * 0.5
        let cw = pw / Double(Self.patchW), ch = ph / Double(Self.patchH)
        var v: [Double] = []
        for gy in 0..<Self.patchH {
            for gx in 0..<Self.patchW {
                let ax = cx - pw / 2 + Double(gx) * cw, ay = cy + ph / 2 - Double(gy + 1) * ch  // top row first
                var sum = 0.0, n = 0.0
                for y in Int(ay)..<max(Int(ay) + 1, Int(ay + ch)) where y >= 0 && y < h {
                    for x in Int(ax)..<max(Int(ax) + 1, Int(ax + cw)) where x >= 0 && x < w {
                        sum += Double(px[(h - 1 - y) * row + x]); n += 1
                    }
                }
                guard n > 0 else { return nil }
                v.append(sum / n)
            }
        }
        let mean = v.reduce(0, +) / Double(v.count)
        let sd = max(1, (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot())
        return v.map { ($0 - mean) / sd }
    }

    /// Iris position inside the eye outline, 0…1 on each axis (y up), from the darkest pixels inside the eye.
    /// Much finer than Vision's pupil landmark, which barely moves when only the eyes move.
    private func iris(_ outline: [CGPoint], _ pb: CVPixelBuffer) -> CGPoint? {
        guard outline.count >= 3, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let px = base.assumingMemoryBound(to: UInt8.self)
        let xs = outline.map(\.x), ys = outline.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 - x0 >= 8, y1 - y0 >= 3 else { return nil }
        var inside: [(x: Double, y: Double, lum: Double)] = []
        for y in Int(y0)...Int(y1) where y >= 0 && y < h {
            for x in Int(x0)...Int(x1) where x >= 0 && x < w {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                guard contains(outline, p) else { continue }
                inside.append((p.x, p.y, Double(px[(h - 1 - y) * row + x])))  // Vision's y is up, buffer rows go down
            }
        }
        guard inside.count >= 12 else { return nil }
        // weight the darkest quarter of the eye: iris + pupil, not eyelid or sclera
        let cut = inside.map(\.lum).sorted()[inside.count / 4]
        var sw = 0.0, sx = 0.0, sy = 0.0
        for p in inside where p.lum <= cut {
            let wgt = cut - p.lum + 1
            sw += wgt; sx += wgt * p.x; sy += wgt * p.y
        }
        guard sw > 0 else { return nil }
        return CGPoint(x: (sx / sw - x0) / (x1 - x0), y: (sy / sw - y0) / (y1 - y0))
    }

    private func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Fallback: Vision's pupil landmark inside the eye outline, 0…1 on each axis.
    private func pupil(_ eye: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let e = eye?.normalizedPoints, !e.isEmpty, let p = pupil?.normalizedPoints.first else { return nil }
        let xs = e.map(\.x), ys = e.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 > x0, y1 > y0 else { return nil }
        return CGPoint(x: (p.x - x0) / (x1 - x0), y: (p.y - y0) / (y1 - y0))
    }
}
