import Foundation

/// A world-space mesh snapshot. Faces persist independently of the current view.
struct TriangleMesh {
    var vertices: [Vec3] = []
    var faces: [Int32] = []
    func clipped(volume: ObjectScanVolume?, selection: DetailZone?) -> TriangleMesh {
        var result = TriangleMesh(), mapped: [Int32: Int32] = [:]
        for i in stride(from: 0, to: faces.count, by: 3) {
            let face = Array(faces[i..<i+3])
            guard face.allSatisfy({ index in
                let p = vertices[Int(index)]
                return (volume?.contains(p) ?? true) && (selection?.contains(p) ?? true)
            }) else { continue }
            for index in face {
                if mapped[index] == nil { mapped[index] = Int32(result.vertices.count); result.vertices.append(vertices[Int(index)]) }
                result.faces.append(mapped[index]!)
            }
        }
        return result
    }
    mutating func append(_ other: TriangleMesh) {
        let offset = Int32(vertices.count)
        vertices += other.vertices; faces += other.faces.map { $0 + offset }
    }
    func plyData() -> Data {
        var text = "ply\nformat ascii 1.0\ncomment DepthForge persistent world-space mesh\nelement vertex \(vertices.count)\nproperty float x\nproperty float y\nproperty float z\nelement face \(faces.count / 3)\nproperty list uchar int vertex_indices\nend_header\n"
        for p in vertices { text += "\(p.x) \(p.y) \(p.z)\n" }
        for i in stride(from: 0, to: faces.count, by: 3) { text += "3 \(faces[i]) \(faces[i+1]) \(faces[i+2])\n" }
        return Data(text.utf8)
    }
}

/// Connectivity references persistent surfel IDs, not per-frame screen pixels.
final class PersistentDetailMesh {
    private struct Key: Hashable { let a: Int; let b: Int; let c: Int }
    private var faces: [Key: [Int]] = [:]
    let capacity = 100_000
    func reset() { faces.removeAll(keepingCapacity: true) }
    func update(visible: [Surfel], triangles: [Int32], all: [Int: Surfel]) {
        // Remove only invalidated geometry, never geometry merely out of view.
        faces = faces.filter { _, ids in ids.allSatisfy { all[$0]?.isStable == true } }
        for i in stride(from: 0, to: triangles.count, by: 3) {
            let ids = (0..<3).map { visible[Int(triangles[i+$0])].id }, sorted = ids.sorted()
            let key = Key(a: sorted[0], b: sorted[1], c: sorted[2])
            if faces[key] != nil || faces.count < capacity { faces[key] = ids }
        }
    }
    func snapshot(_ surfels: [Int: Surfel], selection: DetailZone? = nil) -> TriangleMesh {
        var mesh = TriangleMesh(), mapped: [Int: Int32] = [:]
        for ids in faces.values {
            let points = ids.compactMap { surfels[$0] }
            guard points.count == 3, points.allSatisfy({ $0.isStable && (selection?.contains($0.position) ?? true) }) else { continue }
            // Refined vertices must still form a local face, not a stretched bridge.
            guard (0..<3).allSatisfy({ length(points[$0].position - points[($0+1)%3].position) < 0.05 }) else { continue }
            for p in points {
                if mapped[p.id] == nil { mapped[p.id] = Int32(mesh.vertices.count); mesh.vertices.append(p.position) }
                mesh.faces.append(mapped[p.id]!)
            }
        }
        return mesh
    }
}
