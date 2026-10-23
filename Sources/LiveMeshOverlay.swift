import ARKit
import Metal
import SceneKit
import UIKit

/// Renders ARKit's actual, incrementally updated `ARMeshAnchor` triangles.
/// This is deliberately separate from the fused PLY: it is immediate visual
/// feedback, while the fusion remains the measured export pipeline.
final class LiveMeshOverlay: NSObject, ARSCNViewDelegate {
    /// ARKit's reconstructed mesh is useful for room-scale orientation, but it
    /// does not become a denser object mesh after additional passes. Object
    /// scans therefore use ProgressiveDepthMeshOverlay instead.
    var displaysNativeMesh = true

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        return SCNNode(geometry: displaysNativeMesh ? geometry(from: meshAnchor.geometry) : nil)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.geometry = displaysNativeMesh ? geometry(from: meshAnchor.geometry) : nil
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
        let wireElement = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )
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
