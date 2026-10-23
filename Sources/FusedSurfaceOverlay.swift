import ARKit
import SceneKit
import simd

final class FusedSurfaceOverlay {
    private let node = SCNNode()
    func attach(to root: SCNNode) { root.addChildNode(node) }
    func clear() { node.geometry = nil }
    func hide() { node.isHidden = true }
    func show(_ update: SurfaceUpdate, pose: CameraPose, volume: ObjectScanVolume?) {
        let mesh = update.mesh
        let source = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0) })
        let faces = SCNGeometryElement(indices: mesh.faces, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [faces])
        let material = SCNMaterial(); material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemMint.withAlphaComponent(0.65)
        material.isDoubleSided = true; material.writesToDepthBuffer = true
        geometry.materials = [material]; node.geometry = geometry; node.isHidden = false
    }
    func refreshVisibility(_ frame: ARFrame) { /* The scene depth buffer handles occlusion. */ }
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
            m.diffuse.contents = UIColor.systemOrange.withAlphaComponent(confirmed ? 0.42 : 0.65)
            m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false; m.isDoubleSided = true
            disk.firstMaterial = m
            let part = SCNNode(geometry: disk)
            part.renderingOrder = 100
            part.simdPosition = dab.center + dab.normal * 0.004
            part.simdOrientation = simd_quatf(from: Vec3(0, 1, 0), to: dab.normal)
            node.addChildNode(part)
        }
    }
}
