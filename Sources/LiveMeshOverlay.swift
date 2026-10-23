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
        let element = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.72)
        material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.45)
        material.fillMode = .lines
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }
}
