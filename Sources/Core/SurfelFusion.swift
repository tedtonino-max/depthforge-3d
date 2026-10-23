import Foundation

/// Persistent oriented surface elements, associated projectively in each new
/// depth frame. There are no keyframe meshes and no unbounded patch history.
/// Only the worker queue may access this state.
final class SurfelFusion {
    private(set) var surfels: [Int: Surfel] = [:]
    private var nextID = 0
    private var frameNumber = 0
    private var lastTimestamp = -Double.infinity
    let capacity: Int
    let renderLimit: Int
    init(capacity: Int = 100_000, renderLimit: Int = 16_000) {
        self.capacity = capacity; self.renderLimit = renderLimit
    }
    func reset() {
        surfels.removeAll(keepingCapacity: true)
        nextID = 0; frameNumber = 0; lastTimestamp = -.infinity
    }

    func integrate(_ input: DepthInput) -> SurfaceUpdate {
        let start = Date.timeIntervalSinceReferenceDate
        let camera = input.camera, count = camera.width * camera.height
        guard camera.width > 2, camera.height > 2, camera.fx > 0, camera.fy > 0,
              input.depths.count == count, input.confidence.count == count,
              input.colors.count == count, input.timestamp > lastTimestamp,
              (!input.isObject || input.objectVolume != nil),
              (!input.selectionOnly || input.detailZone != nil) else {
            return SurfaceUpdate(quality: SurfaceQuality(), visibleSurfels: [], elapsed: 0)
        }
        lastTimestamp = input.timestamp; frameNumber += 1
        // Reserve capacity for new evidence rather than letting unconfirmed
        // samples occupy the entire scan. Established geometry is retained.
        if surfels.count > capacity * 9 / 10 {
            let tentative = surfels.values.filter { !$0.isStable }.sorted { $0.lastFrame < $1.lastFrame }
            for s in tentative.prefix(max(1, capacity / 5)) { surfels.removeValue(forKey: s.id) }
        }
        func resolution(_ p: Vec3) -> Float {
            input.detailZone?.contains(p) == true ? 0.004 : (input.isObject ? 0.008 : 0.020)
        }
        // A world-space index catches reprojection misses and prevents repeated
        // passes from allocating another nearly identical layer of surfels.
        var spatial: [SurfaceBin: Int] = [:]
        var redundant: [Int] = []
        for s in surfels.values {
            let key = SurfaceBin(s.position, normal: s.normal, size: resolution(s.position))
            if let id = spatial[key], let old = surfels[id], dot(old.normal, s.normal) > 0.9 {
                if s.observations > old.observations { redundant.append(id); spatial[key] = s.id }
                else { redundant.append(s.id) }
            } else { spatial[key] = s.id }
        }
        for id in redundant { surfels.removeValue(forKey: id) }
        var projected = [Int](repeating: -1, count: count)
        var zBuffer = [Float](repeating: .infinity, count: count)
        var removals: [Int] = []
        var quality = SurfaceQuality()

        // Reproject the ONE persistent surface. Occluded elements are preserved;
        // high-confidence free-space contradictions retire obsolete geometry.
        for (id, var s) in surfels {
            if !s.isStable && frameNumber - s.lastFrame > 30 { removals.append(id); continue }
            let local = input.pose.local(s.position)
            guard let (x, y) = camera.pixel(local) else { continue }
            let i = y * camera.width + x, predicted = -local.z
            if input.valid(i), input.depths[i] - predicted > max(0.04, predicted * 0.025),
               dot(s.normal, unit(input.pose.position - s.position)) > 0.2 {
                s.contradictions += 1
                if s.contradictions >= 4 { removals.append(id); continue }
                surfels[id] = s
            }
            if predicted < zBuffer[i] { projected[i] = id; zBuffer[i] = predicted }
        }
        for id in removals { surfels.removeValue(forKey: id) }

        var touched = Set<Int>()
        var residualSum: Float = 0
        var inspected = 0
        let phase = frameNumber
        // A changing sample phase fills gaps between passes. Detail zones always
        // sample every depth pixel; coarse room regions consume fewer resources.
        let rows = camera.height - 2
        scan: for rowIndex in 0..<rows {
            // Rotate priority so a bounded frame cannot starve the bottom of an
            // object indefinitely when the device is under sustained load.
            let y = 1 + (rowIndex + frameNumber * 7) % rows
            if rowIndex % 8 == 0 && Date.timeIntervalSinceReferenceDate - start > input.processingBudget {
                quality.limited = true; break scan
            }
            for x in 1..<(camera.width - 1) {
                let i = y * camera.width + x, d = input.depths[i]
                guard d.isFinite, d > 0.12, d < 5 else { continue }
                let local = camera.unproject(x: x, y: y, depth: d)
                let world = input.pose.world(local)
                if input.isObject, input.objectVolume?.contains(world) != true { continue }
                let inFocus = input.detailZone?.contains(world) == true
                if input.selectionOnly && !inFocus { continue }
                let stride = inFocus || input.isObject ? max(1, input.detailStride) : max(2, input.baseStride)
                if x % stride != phase % stride || y % stride != phase % stride { continue }
                let guidesSelection = input.detailZone == nil || inFocus
                if guidesSelection { inspected += 1 }
                guard input.valid(i), let normal = measuredNormal(input, x: x, y: y) else {
                    if guidesSelection { quality.missing += 1 }
                    continue
                }
                let view = unit(input.pose.position - world)
                let incidence = dot(normal, view)
                guard incidence > 0.25 else { continue }
                // Spatial sampling density, never an accuracy claim. A closer
                // pass shrinks the support disk and refines position/normal.
                let spacing: Float = input.isObject || inFocus ? 0.003 : 0.012
                let radius = max(spacing, min(0.025, d / camera.fx * Float(stride) * 0.65))
                let distanceGate = min(0.035, 0.010 + d * 0.006)
                var match: Int?
                var best: Float = .infinity
                let bin = SurfaceBin(world, normal: normal, size: resolution(world))
                for oy in -1...1 {
                    for ox in -1...1 {
                        let j = (y + oy) * camera.width + x + ox
                        let id = projected[j]
                        guard id >= 0, let candidate = surfels[id],
                              dot(candidate.normal, normal) > 0.80 else { continue }
                        let delta = world - candidate.position
                        let plane = abs(dot(delta, candidate.normal))
                        let tangent = length(delta - candidate.normal * dot(delta, candidate.normal))
                        guard plane < distanceGate,
                              tangent < max(radius, candidate.radius) * 1.5 else { continue }
                        let score = plane + tangent
                        if score < best { best = score; match = id }
                    }
                }
                if match == nil, let id = spatial[bin], let candidate = surfels[id],
                   dot(candidate.normal, normal) > 0.75,
                   length(candidate.position - world) < max(distanceGate, resolution(world) * 1.8) {
                    match = id
                }
                let id: Int
                if let match, var s = surfels[match] {
                    id = match
                    // Several pixels in one frame are NOT independent evidence.
                    if !touched.contains(id) {
                        let residual = dot(world - s.position, s.normal)
                        let w = max(0.1, incidence * incidence) / max(1, d * d)
                        let effective = min(32, s.weight)
                        let alpha = w / (effective + w)
                        let refined = s.position + (world - s.position) * alpha
                        if (!input.isObject || input.objectVolume?.contains(refined) == true) &&
                           (!input.selectionOnly || input.detailZone?.contains(refined) == true) {
                            s.position = refined
                        }
                        s.normal = unit(s.normal * (1 - alpha) + normal * alpha)
                        s.color += (input.colors[i] - s.color) * alpha
                        s.radius = min(s.radius, radius)
                        s.weight = min(32, effective + w)
                        s.residualSquared = s.residualSquared * 0.8 + residual * residual * 0.2
                        s.observations = min(65_535, s.observations + 1)
                        if dot(s.firstView, view) < 0.94 { s.wideObservations = min(255, s.wideObservations + 1) }
                        s.lastFrame = frameNumber; s.contradictions = 0
                        surfels[id] = s
                    }
                } else {
                    guard surfels.count < capacity else { quality.capacityReached = true; continue }
                    id = nextID; nextID += 1
                    surfels[id] = Surfel(id: id, position: world, normal: normal,
                        color: input.colors[i], radius: radius, firstView: view, lastFrame: frameNumber)
                    spatial[bin] = id
                    // New elements participate immediately in association, but
                    // cannot gain multiple observations from this same frame.
                    projected[i] = id; zBuffer[i] = d
                }
                touched.insert(id)
                guard let s = surfels[id] else { continue }
                if guidesSelection {
                    quality.accepted += 1; quality.visible += 1
                    if s.isStable { quality.stable += 1 }
                    if s.isStable && s.hasAngles { quality.multipleAngles += 1 }
                    residualSum += s.residualSquared
                }
            }
        }
        quality.rmsResidual = sqrt(residualSum / Float(max(1, quality.visible)))
        quality.totalStable = surfels.values.reduce(0) { $0 + ($1.isStable ? 1 : 0) }
        // Mark the view incomplete if work was truncated; it may never turn green.
        if quality.limited { quality.missing += max(1, inspected) }
        // Visibility is based on current measured depth for ALL confirmed
        // elements, not only this frame's subsample. This prevents alternating
        // sparse rows or budget truncation from making the surface flicker.
        let ids = Set(projected.filter { $0 >= 0 }).union(touched).filter { id in
            guard let s = surfels[id], s.isStable,
                  dot(s.normal, unit(input.pose.position - s.position)) > 0.15 else { return false }
            return input.visible(s.position)
        }.sorted()
        let step = max(1, Int(ceil(Double(ids.count) / Double(max(1, renderLimit)))))
        let visible = Swift.stride(from: 0, to: ids.count, by: step).compactMap { surfels[ids[$0]] }
        let triangles = SurfaceMesher.triangles(visible, camera: camera, pose: input.pose)
        return SurfaceUpdate(quality: quality, visibleSurfels: visible,
                             elapsed: Date.timeIntervalSinceReferenceDate - start, camera: camera, triangles: triangles)
    }

    private func measuredNormal(_ input: DepthInput, x: Int, y: Int) -> Vec3? {
        let c = input.camera, i = y * c.width + x, d = input.depths[i]
        // One-sided derivatives preserve narrow foreground structures when the
        // opposite neighbour is background. Never bridge a depth discontinuity.
        let tolerance = max(0.018, d * 0.015)
        func neighbour(_ nx: Int, _ ny: Int) -> Vec3? {
            let j = ny * c.width + nx
            guard input.valid(j), abs(input.depths[j] - d) < tolerance else { return nil }
            return c.unproject(x: nx, y: ny, depth: input.depths[j])
        }
        let p = c.unproject(x: x, y: y, depth: d)
        let dx = neighbour(x + 1, y).map { $0 - p } ?? neighbour(x - 1, y).map { p - $0 }
        let dy = neighbour(x, y + 1).map { $0 - p } ?? neighbour(x, y - 1).map { p - $0 }
        guard let dx, let dy else { return nil }
        var n = cross(dx, dy)
        guard length(n) > 0.0000001 else { return nil }
        if dot(n, -p) < 0 { n = -n }
        return unit(input.pose.rotate(unit(n)))
    }

    func plyData(volume: ObjectScanVolume?, selection: DetailZone? = nil) -> Data {
        let selected = surfels.values.filter { $0.isStable && (volume == nil || volume!.contains($0.position)) && (selection == nil || selection!.contains($0.position)) }.sorted { $0.id < $1.id }
        var text = "ply\nformat ascii 1.0\ncomment DepthForge consensus surfels; radius is support, not accuracy\nelement vertex \(selected.count)\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty ushort observations\nproperty float radius\nend_header\n"
        for s in selected {
            let c = s.color
            text += "\(s.position.x) \(s.position.y) \(s.position.z) \(s.normal.x) \(s.normal.y) \(s.normal.z) \(Int(min(255, max(0, c.x)))) \(Int(min(255, max(0, c.y)))) \(Int(min(255, max(0, c.z)))) \(s.observations) \(s.radius)\n"
        }
        return Data(text.utf8)
    }
}

private struct SurfaceBin: Hashable {
    let x: Int; let y: Int; let z: Int; let side: Int; let scale: Int
    init(_ p: Vec3, normal: Vec3, size: Float) {
        scale = Int((size * 10000).rounded())
        x = Int(floor(p.x / size)); y = Int(floor(p.y / size)); z = Int(floor(p.z / size))
        let a = Vec3(abs(normal.x), abs(normal.y), abs(normal.z))
        let axis = a.x > a.y && a.x > a.z ? 0 : (a.y > a.z ? 1 : 2)
        side = axis * 2 + (normal[axis] < 0 ? 1 : 0)
    }
}
