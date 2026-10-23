import ARKit
import Foundation
import simd
import UIKit

/// Sparse, running geometric fusion. Each cell retains the measured centroid,
/// observation count, depth variance and incoming viewing directions; it never
/// invents geometry in unobserved space.
final class GeometryFusion {
    private(set) var voxels: [VoxelKey: FusedVoxel] = [:]
    let cellSize: Float

    init(cellSize: Float = 0.008) { self.cellSize = cellSize } // 8 mm bins; not an accuracy claim

    func reset() { voxels.removeAll(keepingCapacity: true) }

    func integrate(frame: ARFrame, sampleStride: Int = 4, captureTarget: CaptureTarget = .object) -> QualitySummary {
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
        let targetDepth = captureTarget == .object
            ? estimatedTargetDepth(base: depthBase, rowBytes: depthRow, width: depthWidth, height: depthHeight, isFloat16: isFloat16)
            : nil
        for y in Swift.stride(from: 0, to: depthHeight, by: sampleStride) {
            let confidenceLine = confidenceBase.map { $0.advanced(by: y * (confidenceRow ?? 0)).assumingMemoryBound(to: UInt8.self) }
            for x in Swift.stride(from: 0, to: depthWidth, by: sampleStride) {
                if let confidenceLine, confidenceLine[x] < 1 { continue }
                let distance = depthValue(base: depthBase, rowBytes: depthRow, x: x, y: y, isFloat16: isFloat16)
                guard distance.isFinite, distance > 0.08, distance < 8 else { continue }
                if captureTarget == .object {
                    let normalizedX = Float(x) / Float(depthWidth)
                    let normalizedY = Float(y) / Float(depthHeight)
                    // The window is deliberately conservative: it gives a tangible
                    // object-focused PLY without pretending to segment the object.
                    guard normalizedX > 0.18, normalizedX < 0.82, normalizedY > 0.14, normalizedY < 0.86 else { continue }
                    if let targetDepth, abs(distance - targetDepth) > 0.35 { continue }
                }
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
        let viewDiversity = values.isEmpty ? 0 : values.reduce(Float(0)) { $0 + $1.viewDiversity } / Float(values.count)
        let advice: RescanAdvice
        if values.isEmpty { advice = .moveCloser }
        else if weak > strong { advice = .revisit }
        else if consistency < 0.6 { advice = .holdSteady }
        else if values.filter({ $0.viewDiversity < 0.12 && $0.observations > 4 }).count > strong / 3 { advice = .changeAngle }
        else { advice = .complete }
        return QualitySummary(usableMeasurements: usable, coveredCells: strong, weakCells: weak, meanConsistency: consistency, meanViewDiversity: viewDiversity, advice: advice)
    }

    func plyData() -> Data {
        let selected = voxels.values.filter { $0.observations >= 1 }
        var output = "ply\nformat ascii 1.0\ncomment DepthForge fused measured points only\nelement vertex \(selected.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar observations\nproperty float quality\nend_header\n"
        for v in selected {
            output += "\(v.position.x) \(v.position.y) \(v.position.z) \(v.color.x) \(v.color.y) \(v.color.z) \(min(255, v.observations)) \(v.quality)\n"
        }
        return output.data(using: .utf8) ?? Data()
    }

    func visualSurfels(maximum: Int = 35_000) -> [(position: SIMD3<Float>, color: SIMD3<UInt8>)] {
        let values = Array(voxels.values)
        guard !values.isEmpty else { return [] }
        let step = max(1, values.count / maximum)
        return values.enumerated().compactMap { index, voxel in
            index.isMultiple(of: step) ? (voxel.position, voxel.color) : nil
        }
    }

    func projectedCells(camera: ARCamera, viewport: CGSize, orientation: UIInterfaceOrientation) -> [ProjectedQualityCell] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        // Thousands of individual voxels can project to the same screen area. Aggregate
        // them to a coarse screen grid so the camera remains visible while scanning.
        let side = max(CGFloat(54), min(CGFloat(76), min(viewport.width, viewport.height) / 12))
        var buckets: [ScreenGridKey: ScreenGridBucket] = [:]
        for voxel in voxels.values {
            guard voxel.observations >= 2 else { continue }
            let p = camera.projectPoint(voxel.position, orientation: orientation, viewportSize: viewport)
            guard p.x.isFinite, p.y.isFinite, p.x >= 0, p.y >= 0, p.x <= viewport.width, p.y <= viewport.height else { continue }
            let key = ScreenGridKey(x: Int(p.x / side), y: Int(p.y / side))
            if var bucket = buckets[key] {
                bucket.qualityTotal += voxel.quality
                bucket.count += 1
                buckets[key] = bucket
            } else {
                let center = CGPoint(x: (CGFloat(key.x) + 0.5) * side, y: (CGFloat(key.y) + 0.5) * side)
                buckets[key] = ScreenGridBucket(point: center, qualityTotal: voxel.quality, count: 1)
            }
        }
        return buckets.values.compactMap { bucket in
            guard bucket.count >= 2 else { return nil }
            return ProjectedQualityCell(
                point: bucket.point,
                normalizedPoint: CGPoint(x: bucket.point.x / viewport.width, y: bucket.point.y / viewport.height),
                quality: bucket.qualityTotal / Float(bucket.count)
            )
        }
    }

    private func estimatedTargetDepth(base: UnsafeMutableRawPointer, rowBytes: Int, width: Int, height: Int, isFloat16: Bool) -> Float? {
        let centerX = width / 2, centerY = height / 2
        var samples: [Float] = []
        for y in max(0, centerY - 5)...min(height - 1, centerY + 5) {
            for x in max(0, centerX - 5)...min(width - 1, centerX + 5) {
                let value = depthValue(base: base, rowBytes: rowBytes, x: x, y: y, isFloat16: isFloat16)
                if value.isFinite, value > 0.08, value < 8 { samples.append(value) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func depthValue(base: UnsafeMutableRawPointer, rowBytes: Int, x: Int, y: Int, isFloat16: Bool) -> Float {
        if isFloat16 {
            return Float(base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)[x])
        }
        return base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)[x]
    }
}

struct ProjectedQualityCell: Identifiable {
    let id = UUID(); let point: CGPoint; let normalizedPoint: CGPoint; let quality: Float
}

private struct ScreenGridKey: Hashable { let x: Int; let y: Int }
private struct ScreenGridBucket {
    let point: CGPoint
    var qualityTotal: Float
    var count: Int
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
