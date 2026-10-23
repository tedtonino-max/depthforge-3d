import ARKit
import SceneKit
import UIKit

/// A connected wire surface built from consensus surfels. Camera motion only
/// changes depth visibility; it does not hide the entire reconstruction.
final class FusedSurfaceOverlay {
    private let node = SCNNode()
    private var surfels: [Surfel] = []
    private var faces: [Int32] = []
    private var source: SCNGeometrySource?
    private var lastVisibility = -Double.infinity
    func attach(to root: SCNNode) { node.name = "ConsensusSurface"; root.addChildNode(node) }
    func clear() { node.geometry = nil; surfels = []; faces = []; source = nil }
    func hide() { node.isHidden = true }
    func show(_ update: SurfaceUpdate, pose: CameraPose, volume: ObjectScanVolume?) {
        surfels = update.visibleSurfels
        faces = update.triangles
        source = SCNGeometrySource(vertices: surfels.map { SCNVector3($0.position) })
        let visible = surfels.map { volume == nil || volume!.contains($0.position) }
        render(visible)
        lastVisibility = -.infinity
    }
    func refreshVisibility(_ frame: ARFrame) {
        guard frame.timestamp - lastVisibility >= 0.12, !surfels.isEmpty,
              let data = frame.sceneDepth else { return }
        lastVisibility = frame.timestamp
        let depth = data.depthMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        let row = CVPixelBufferGetBytesPerRow(depth), format = CVPixelBufferGetPixelFormatType(depth)
        guard format == kCVPixelFormatType_DepthFloat32 || format == kCVPixelFormatType_DepthFloat16 else { return }
        let k = frame.camera.intrinsics, size = frame.camera.imageResolution
        let sx = Float(w) / Float(size.width), sy = Float(h) / Float(size.height)
        let camera = DepthCamera(width: w, height: h, fx: k.columns.0.x * sx, fy: k.columns.1.y * sy,
                                 cx: k.columns.2.x * sx, cy: k.columns.2.y * sy)
        let pose = CameraPose(frame.camera.transform)
        render(surfels.map { s in
            let local = pose.local(s.position)
            guard let (x, y) = camera.pixel(local), dot(s.normal, unit(pose.position - s.position)) > 0.1 else { return false }
            let d = format == kCVPixelFormatType_DepthFloat16
                ? Float(base.advanced(by: y * row).assumingMemoryBound(to: Float16.self)[x])
                : base.advanced(by: y * row).assumingMemoryBound(to: Float.self)[x]
            return d.isFinite && abs(d + local.z) < 0.035
        })
    }
    private func render(_ visible: [Bool]) {
        guard let source else { return }
        var triangles: [Int32] = []
        for i in stride(from: 0, to: faces.count, by: 3) {
            let a = faces[i], b = faces[i + 1], c = faces[i + 2]
            if visible[Int(a)] && visible[Int(b)] && visible[Int(c)] { triangles += [a, b, c] }
        }
        let points = visible.indices.filter { visible[$0] }.map { Int32($0) }
        let surface = SCNGeometryElement(indices: triangles, primitiveType: .triangles)
        let wire = SCNGeometryElement(indices: triangles, primitiveType: .triangles)
        let dots = SCNGeometryElement(indices: points, primitiveType: .point)
        dots.pointSize = 0.003; dots.minimumPointScreenSpaceRadius = 1; dots.maximumPointScreenSpaceRadius = 2
        let geometry = SCNGeometry(sources: [source], elements: [surface, wire, dots])
        func material(_ opacity: CGFloat, lines: Bool = false) -> SCNMaterial {
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = UIColor.systemMint.withAlphaComponent(opacity)
            m.fillMode = lines ? .lines : .fill
            m.isDoubleSided = true; m.readsFromDepthBuffer = true; m.writesToDepthBuffer = false
            return m
        }
        geometry.materials = [material(0.06), material(0.9, lines: true), material(0.7)]
        node.geometry = geometry; node.isHidden = false
    }
}

/// The paint mask is attached to measured surfaces, with one small oriented dab
/// per stroke sample. It represents a union of areas, never a single fixed ring.
final class DetailZoneOverlay {
    private let node = SCNNode()
    func attach(to root: SCNNode) { root.addChildNode(node) }
    func clear() { node.childNodes.forEach { $0.removeFromParentNode() } }
    func show(_ zone: DetailZone, confirmed: Bool) {
        clear()
        for dab in zone.brush {
            let disk = SCNCylinder(radius: CGFloat(dab.radius), height: 0.001)
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = UIColor.systemMint.withAlphaComponent(confirmed ? 0.07 : 0.22)
            m.writesToDepthBuffer = false; m.isDoubleSided = true
            disk.firstMaterial = m
            let part = SCNNode(geometry: disk)
            part.simdPosition = dab.center + dab.normal * 0.004
            part.simdOrientation = simd_quatf(from: Vec3(0, 1, 0), to: dab.normal)
            node.addChildNode(part)
        }
    }
}
