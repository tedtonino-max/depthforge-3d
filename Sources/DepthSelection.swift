import ARKit
import UIKit

enum DepthSelection {
    /// Read only five native depth samples at the tap. This works on object
    /// surfaces that ARKit has not classified as a large horizontal/vertical plane.
    static func zone(frame: ARFrame, point: CGPoint, viewport: CGSize,
                     orientation: UIInterfaceOrientation) -> DetailZone? {
        guard viewport.width > 0, viewport.height > 0,
              let depth = frame.sceneDepth, let confidence = depth.confidenceMap else { return nil }
        let buffer = depth.depthMap, w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h else { return nil }
        let uv = CGPoint(x: point.x / viewport.width, y: point.y / viewport.height)
            .applying(frame.displayTransform(for: orientation, viewportSize: viewport).inverted())
        guard uv.x > 0, uv.x < 1, uv.y > 0, uv.y < 1 else { return nil }
        let x = Int(uv.x * CGFloat(w)), y = Int(uv.y * CGFloat(h))
        guard x > 0, x < w - 1, y > 0, y < h - 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let db = CVPixelBufferGetBaseAddress(buffer), let cb = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let dr = CVPixelBufferGetBytesPerRow(buffer), cr = CVPixelBufferGetBytesPerRow(confidence)
        let k = frame.camera.intrinsics, resolution = frame.camera.imageResolution
        let sx = Float(w) / Float(resolution.width), sy = Float(h) / Float(resolution.height)
        let camera = DepthCamera(width: w, height: h, fx: k.columns.0.x * sx,
            fy: k.columns.1.y * sy, cx: k.columns.2.x * sx, cy: k.columns.2.y * sy)
        func sample(_ x: Int, _ y: Int) -> Vec3? {
            let d = db.advanced(by: y * dr).assumingMemoryBound(to: Float.self)[x]
            guard cb.advanced(by: y * cr).assumingMemoryBound(to: UInt8.self)[x] == 2,
                  d.isFinite, d > 0.12, d < 5 else { return nil }
            return camera.unproject(x: x, y: y, depth: d)
        }
        guard let p = sample(x, y) else { return nil }
        let tolerance = max(0.018, -p.z * 0.015)
        func near(_ x: Int, _ y: Int) -> Vec3? {
            guard let n = sample(x, y), abs(n.z - p.z) < tolerance else { return nil }; return n
        }
        let dx = near(x + 1, y).map { $0 - p } ?? near(x - 1, y).map { p - $0 }
        let dy = near(x, y + 1).map { $0 - p } ?? near(x, y - 1).map { p - $0 }
        guard let dx, let dy else { return nil }
        var n = cross(dx, dy)
        guard length(n) > 0.0000001 else { return nil }
        if dot(n, -p) < 0 { n = -n }
        let pose = CameraPose(frame.camera.transform)
        return DetailZone(center: pose.world(p), normal: unit(pose.rotate(n)))
    }
}
