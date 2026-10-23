import ARKit
import Metal
import SceneKit
import UIKit

/// Renders ARKit's actual, incrementally updated `ARMeshAnchor` triangles.
/// This is deliberately separate from the fused PLY: it is immediate visual
/// feedback, while the fusion remains the measured export pipeline.
final class LiveMeshOverlay: NSObject, ARSCNViewDelegate {
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        return SCNNode(geometry: geometry(from: meshAnchor.geometry))
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.geometry = geometry(from: meshAnchor.geometry)
    }

    private func geometry(from mesh: ARMeshGeometry) -> SCNGeometry {
        let source = SCNGeometrySource(
            buffer: mesh.vertices.buffer,
            vertexFormat: mesh.vertices.format,
            semantic: .vertex,
            vertexCount: mesh.vertices.count,
            dataOffset: mesh.vertices.offset,
            dataStride: mesh.vertices.stride
        )
        let surfaceElement = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )
        surfaceElement.materialIndex = 0
        let wireElement = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )
        wireElement.materialIndex = 1
        let geometry = SCNGeometry(sources: [source], elements: [surfaceElement, wireElement])

        let surface = SCNMaterial()
        surface.lightingModel = .constant
        surface.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.18)
        surface.emission.contents = UIColor.systemTeal.withAlphaComponent(0.12)
        surface.isDoubleSided = true
        surface.writesToDepthBuffer = false

        let wire = SCNMaterial()
        wire.lightingModel = .constant
        wire.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.86)
        wire.emission.contents = UIColor.systemTeal.withAlphaComponent(0.48)
        wire.fillMode = .lines
        wire.isDoubleSided = true
        wire.writesToDepthBuffer = false
        geometry.materials = [surface, wire]
        return geometry
    }
}
