import ARKit
import SceneKit
import simd

/// ARKit owns the persistent coarse topology; copied geometry owns its buffers.
@MainActor
final class BaseMeshOverlay {
    private let root = SCNNode()
    private var patches: [UUID: TriangleMesh] = [:]
    private var nodes: [UUID: SCNNode] = [:]
    private var faceCounts: [UUID: Int] = [:]
    var faceCount: Int { faceCounts.values.reduce(0, +) }
    func attach(to parent: SCNNode) { parent.addChildNode(root) }
    func setVisible(_ visible: Bool) { root.isHidden = !visible }
    func clear() { patches.removeAll(); faceCounts.removeAll(); nodes.values.forEach { $0.removeFromParentNode() }; nodes.removeAll() }
    func remove(_ ids: [UUID]) {
        for id in ids { patches[id] = nil; faceCounts[id] = nil; nodes.removeValue(forKey: id)?.removeFromParentNode() }
    }
    func update(_ anchors: [ARMeshAnchor]) {
        for anchor in anchors {
            let g = anchor.geometry, source = g.vertices
            var mesh = TriangleMesh()
            mesh.vertices.reserveCapacity(source.count)
            for i in 0..<source.count {
                let p = source.buffer.contents().advanced(by: source.offset + i * source.stride).assumingMemoryBound(to: Float.self)
                let world = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                mesh.vertices.append(Vec3(world.x, world.y, world.z))
            }
            let indices = g.faces.buffer.contents(), count = g.faces.count * g.faces.indexCountPerPrimitive
            guard g.faces.indexCountPerPrimitive == 3 else { continue }
            for i in 0..<count {
                let index = g.faces.bytesPerIndex == 2 ? Int(indices.assumingMemoryBound(to: UInt16.self)[i]) : Int(indices.assumingMemoryBound(to: UInt32.self)[i])
                guard index < mesh.vertices.count else { continue }
                mesh.faces.append(Int32(index))
            }
            guard mesh.faces.count == count else { continue }
            patches[anchor.identifier] = mesh; faceCounts[anchor.identifier] = g.faces.count
            let node = nodes[anchor.identifier] ?? SCNNode()
            if nodes[anchor.identifier] == nil { root.addChildNode(node); nodes[anchor.identifier] = node }
            let vertexSource = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0) })
            let fill = SCNGeometryElement(indices: mesh.faces, primitiveType: .triangles)
            let wire = SCNGeometryElement(indices: mesh.faces, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [vertexSource], elements: [fill, wire])
            let solid = SCNMaterial(); solid.lightingModel = .constant
            solid.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.16)
            solid.isDoubleSided = true; solid.writesToDepthBuffer = true
            let lines = SCNMaterial(); lines.lightingModel = .constant; lines.fillMode = .lines
            lines.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.8)
            lines.isDoubleSided = true; lines.writesToDepthBuffer = false
            geometry.materials = [solid, lines]; node.geometry = geometry
        }
    }
    func snapshot() -> TriangleMesh {
        var mesh = TriangleMesh()
        for patch in patches.values { mesh.append(patch) }
        return mesh
    }
}
