import Foundation

/// Connectivity is rebuilt from the persistent fused surface, never from raw
/// keyframe patches. Neighbour faces cannot cross depth gaps or opposed normals.
enum SurfaceMesher {
    static func triangles(_ surfels: [Surfel], camera: DepthCamera, pose: CameraPose) -> [Int32] {
        let step = 2, width = (camera.width + 1) / 2, height = (camera.height + 1) / 2
        var grid = [Int](repeating: -1, count: width * height)
        var depths = [Float](repeating: .infinity, count: grid.count)
        for (index, s) in surfels.enumerated() {
            let p = pose.local(s.position)
            guard s.isStable, let (x, y) = camera.pixel(p) else { continue }
            let cell = y / step * width + x / step
            if -p.z < depths[cell] { grid[cell] = index; depths[cell] = -p.z }
        }
        var result: [Int32] = []
        func append(_ a: Int, _ b: Int, _ c: Int) {
            guard a >= 0, b >= 0, c >= 0, a != b, b != c, c != a else { return }
            let sa = surfels[a], sb = surfels[b], sc = surfels[c]
            for (u, v) in [(sa, sb), (sb, sc), (sc, sa)] {
                let delta = v.position - u.position
                guard length(delta) < min(0.05, max(0.014, (u.radius + v.radius) * 3)),
                      abs(dot(delta, u.normal)) < 0.012,
                      dot(u.normal, v.normal) > 0.65 else { return }
            }
            let n = cross(sb.position - sa.position, sc.position - sa.position)
            guard length(n) > 0.0000001 else { return }
            if dot(n, sa.normal) > 0 { result += [Int32(a), Int32(b), Int32(c)] }
            else { result += [Int32(a), Int32(c), Int32(b)] }
        }
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let a = grid[y * width + x], b = grid[y * width + x + 1]
                let c = grid[(y + 1) * width + x], d = grid[(y + 1) * width + x + 1]
                append(a, c, b); append(b, c, d)
            }
        }
        return result
    }
}
