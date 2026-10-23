import ARKit
import Foundation
import simd

/// Sparse, running geometric fusion. Each cell retains the measured centroid,
/// observation count, depth variance and incoming viewing directions; it never
/// invents geometry in unobserved space.
final class GeometryFusion {
    private(set) var voxels: [VoxelKey: FusedVoxel] = [:]
    let cellSize: Float

    init(cellSize: Float = 0.008) { self.cellSize = cellSize } // 8 mm bins; not an accuracy claim

    func reset() { voxels.removeAll(keepingCapacity: true) }

    func integrate(frame: ARFrame, sampleStride: Int = 4) -> QualitySummary {
        guard let depthData = frame.sceneDepth else { return summary() }
        let confidence = depthData.confidenceMap
        let depth = depthData.depthMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return summary() }
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let depthWidth = CVPixelBufferGetWidth(depth), depthHeight = CVPixelBufferGetHeight(depth)
        let depthRow = CVPixelBufferGetBytesPerRow(depth)
        let confidenceRow = confidence.map(CVPixelBufferGetBytesPerRow)
        let imageSize = frame.camera.imageResolution
        var intrinsics = frame.camera.intrinsics
        intrinsics.columns.0.x *= Float(depthWidth) / Float(imageSize.width)
        intrinsics.columns.1.y *= Float(depthHeight) / Float(imageSize.height)
        intrinsics.columns.2.x *= Float(depthWidth) / Float(imageSize.width)
        intrinsics.columns.2.y *= Float(depthHeight) / Float(imageSize.height)
        let cameraPosition = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        let sampler = YCbCrSampler(buffer: frame.capturedImage)

        let isFloat16 = CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat16
        for y in Swift.stride(from: 0, to: depthHeight, by: sampleStride) {
            let confidenceLine = confidenceBase.map { $0.advanced(by: y * (confidenceRow ?? 0)).assumingMemoryBound(to: UInt8.self) }
            for x in Swift.stride(from: 0, to: depthWidth, by: sampleStride) {
                if let confidenceLine, confidenceLine[x] < 1 { continue }
                let distance: Float
                if isFloat16 {
                    let line = depthBase.advanced(by: y * depthRow).assumingMemoryBound(to: Float16.self)
                    distance = Float(line[x])
                } else {
                    let line = depthBase.advanced(by: y * depthRow).assumingMemoryBound(to: Float.self)
                    distance = line[x]
                }
                guard distance.isFinite, distance > 0.08, distance < 8 else { continue }
                let local = SIMD4<Float>((Float(x) - intrinsics.columns.2.x) * distance / intrinsics.columns.0.x,
                                         (Float(y) - intrinsics.columns.2.y) * distance / intrinsics.columns.1.y,
                                         -distance, 1)
                let world4 = simd_mul(frame.camera.transform, local)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                let direction = world - cameraPosition
                let key = VoxelKey(world, cellSize: cellSize)
                let color = sampler.color(depthX: x, depthY: y, depthWidth: depthWidth, depthHeight: depthHeight)
                if var voxel = voxels[key] {
                    voxel.add(position: world, color: color, depth: distance, viewDirection: direction)
                    voxels[key] = voxel
                } else {
                    voxels[key] = FusedVoxel(position: world, color: color, observations: 1, meanDepth: distance, viewDirectionSum: simd_normalize(direction))
                }
            }
        }
        return summary()
    }

    func summary() -> QualitySummary {
        let values = Array(voxels.values)
        let usable = values.reduce(0) { $0 + $1.observations }
        let strong = values.filter { $0.quality >= 0.55 }.count
        let weak = max(0, values.count - strong)
        let consistency = values.isEmpty ? 0 : values.reduce(Float(0)) { $0 + $1.consistency } / Float(values.count)
        let advice: RescanAdvice
        if values.isEmpty { advice = .moveCloser }
        else if weak > strong { advice = .revisit }
        else if consistency < 0.6 { advice = .holdSteady }
        else if values.filter({ $0.viewDiversity < 0.12 && $0.observations > 4 }).count > strong / 3 { advice = .changeAngle }
        else { advice = .complete }
        return QualitySummary(usableMeasurements: usable, coveredCells: strong, weakCells: weak, meanConsistency: consistency, advice: advice)
    }

    func plyData() -> Data {
        let selected = voxels.values.filter { $0.observations >= 1 }
        var output = "ply\nformat ascii 1.0\ncomment DepthForge fused measured points only\nelement vertex \(selected.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar observations\nproperty float quality\nend_header\n"
        for v in selected {
            output += "\(v.position.x) \(v.position.y) \(v.position.z) \(v.color.x) \(v.color.y) \(v.color.z) \(min(255, v.observations)) \(v.quality)\n"
        }
        return output.data(using: .utf8) ?? Data()
    }

    func projectedCells(camera: ARCamera, viewport: CGSize) -> [ProjectedQualityCell] {
        voxels.values.compactMap { voxel in
            guard voxel.observations >= 2 else { return nil }
            let p = camera.projectPoint(voxel.position, orientation: .landscapeRight, viewportSize: viewport)
            guard p.x.isFinite, p.y.isFinite, p.x >= 0, p.y >= 0, p.x <= viewport.width, p.y <= viewport.height else { return nil }
            return ProjectedQualityCell(point: p, quality: voxel.quality)
        }
    }
}

struct ProjectedQualityCell: Identifiable {
    let id = UUID(); let point: CGPoint; let quality: Float
}

private final class YCbCrSampler {
    private let buffer: CVPixelBuffer
    init(buffer: CVPixelBuffer) { self.buffer = buffer; CVPixelBufferLockBaseAddress(buffer, .readOnly) }
    deinit { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    func color(depthX: Int, depthY: Int, depthWidth: Int, depthHeight: Int) -> SIMD3<UInt8> {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return SIMD3(repeating: 180) }
        let imageX = min(CVPixelBufferGetWidthOfPlane(buffer, 0) - 1, max(0, depthX * CVPixelBufferGetWidthOfPlane(buffer, 0) / depthWidth))
        let imageY = min(CVPixelBufferGetHeightOfPlane(buffer, 0) - 1, max(0, depthY * CVPixelBufferGetHeightOfPlane(buffer, 0) / depthHeight))
        let y = Float(yBase.advanced(by: imageY * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)[imageX])
        let chroma = cbcrBase.advanced(by: (imageY / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let cb = Float(chroma[(imageX / 2) * 2]) - 128, cr = Float(chroma[(imageX / 2) * 2 + 1]) - 128
        return SIMD3(UInt8(max(0, min(255, Int(y + 1.402 * cr)))), UInt8(max(0, min(255, Int(y - 0.344 * cb - 0.714 * cr)))), UInt8(max(0, min(255, Int(y + 1.772 * cb)))) )
    }
}
