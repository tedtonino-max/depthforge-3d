import SceneKit
import simd

/// A decimated view of the app's own multi-frame fusion. Unlike ARKit's mesh,
/// these measured surfels visibly become denser every time a new depth frame is
/// fused, making acquisition progress observable without inventing triangles.
final class FusedSurfelOverlay {
    private let node = SCNNode()

    func attach(to root: SCNNode) {
        guard node.parent == nil else { return }
        node.renderingOrder = 2
        root.addChildNode(node)
    }

    func clear() { node.geometry = nil }

    func update(_ surfels: [(position: SIMD3<Float>, color: SIMD3<UInt8>)]) {
        guard !surfels.isEmpty else { clear(); return }
        var positions = Data(capacity: surfels.count * MemoryLayout<SIMD3<Float>>.stride)
        var colors = Data(capacity: surfels.count * 3)
        for surfel in surfels {
            var position = surfel.position
            withUnsafeBytes(of: &position) { positions.append(contentsOf: $0) }
            colors.append(surfel.color.x)
            colors.append(surfel.color.y)
            colors.append(surfel.color.z)
        }
        let vertex = SCNGeometrySource(
            data: positions, semantic: .vertex, vectorCount: surfels.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let color = SCNGeometrySource(
            data: colors, semantic: .color, vectorCount: surfels.count,
            usesFloatComponents: false, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<UInt8>.size, dataOffset: 0, dataStride: 3
        )
        let points = SCNGeometryElement(indices: nil, primitiveType: .point, primitiveCount: surfels.count)
        points.pointSize = 3
        points.minimumPointScreenSpaceRadius = 1
        points.maximumPointScreenSpaceRadius = 4
        let geometry = SCNGeometry(sources: [vertex, color], elements: [points])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        node.geometry = geometry
    }
}
