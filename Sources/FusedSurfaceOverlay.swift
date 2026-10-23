import SceneKit
import UIKit

/// One replaceable geometry buffer of oriented consensus surfels. Tiny tangent
/// disks represent the fused surface; no camera-aligned depth planes accumulate.
final class FusedSurfaceOverlay {
    private let node = SCNNode()
    private(set) var pose: CameraPose?
    func attach(to root: SCNNode) { node.name = "ConsensusSurface"; root.addChildNode(node) }
    func clear() { node.geometry = nil; pose = nil }
    func hide() { node.isHidden = true }
    func show(_ surfels: [Surfel], pose: CameraPose, volume: ObjectScanVolume?) {
        self.pose = pose
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        vertices.reserveCapacity(surfels.count * 7)
        indices.reserveCapacity(surfels.count * 18)
        for s in surfels {
            let tangent = unit(cross(s.normal, abs(s.normal.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)))
            let bitangent = cross(s.normal, tangent)
            let center = Int32(vertices.count)
            var ring: [Vec3] = []
            for i in 0..<6 {
                let angle = Float(i) * .pi / 3
                ring.append(s.position + (tangent * cos(angle) + bitangent * sin(angle)) * s.radius)
            }
            // Avoid drawing across the explicit object boundary.
            if let volume, !ring.allSatisfy({ volume.contains($0) }) { continue }
            vertices.append(SCNVector3(s.position))
            vertices.append(contentsOf: ring.map { SCNVector3($0) })
            for i in 0..<6 { indices += [center, center + 1 + Int32(i), center + 1 + Int32((i + 1) % 6)] }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemMint.withAlphaComponent(0.20)
        material.isDoubleSided = false
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true
        geometry.materials = [material]
        node.geometry = geometry; node.isHidden = false
    }
    func hideIfViewChanged(_ current: CameraPose) {
        guard let pose else { return }
        // Visibility was tested against measured depth for the last fused frame.
        // Hide stale visibility promptly until the next result, avoiding x-ray
        // geometry on the far side when the camera moves or tracking recovers.
        if length(current.position - pose.position) > 0.04 || dot(current.back, pose.back) < 0.997 {
            hide()
        }
    }
}

final class DetailZoneOverlay {
    private let node = SCNNode()
    func attach(to root: SCNNode) { root.addChildNode(node) }
    func clear() { node.geometry = nil }
    func show(_ zone: DetailZone, confirmed: Bool) {
        let ring = SCNTorus(ringRadius: CGFloat(zone.radius), pipeRadius: 0.004)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = (confirmed ? UIColor.systemMint : UIColor.systemYellow).withAlphaComponent(0.7)
        ring.firstMaterial = material
        node.geometry = ring
        node.simdPosition = zone.center + zone.normal * 0.005
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: zone.normal)
    }
}
