import ARKit
import SceneKit
import simd
import UIKit

/// A bounded, measured preview mesh for object scans. Every patch is triangulated
/// directly from one LiDAR sceneDepth keyframe in world space. The sampling step
/// decreases across passes, so more measured vertices are shown as the operator
/// adds viewpoints. This is deliberately a preview; the PLY remains the actual
/// running multi-frame voxel fusion and no unmeasured surface is invented.
final class ProgressiveDepthMeshOverlay {
    private let root = SCNNode()
    private var patches: [SCNNode] = []
    private let maximumPatches = 8

    func attach(to sceneRoot: SCNNode) {
        root.name = "DepthForgeMeasuredDepthMesh"
        sceneRoot.addChildNode(root)
    }

    func reset() {
        patches.forEach { $0.removeFromParentNode() }
        patches.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func appendMeasuredPatch(
        from frame: ARFrame,
        captureTarget: CaptureTarget,
        profile: CaptureProfile,
        pass: Int,
        objectVolume: ObjectScanVolume?
    ) -> MeasuredMeshPatch? {
        guard captureTarget == .object,
              let mesh = makeGeometry(
                from: frame,
                sampleStep: sampleStep(for: pass, profile: profile),
                objectVolume: objectVolume
              ) else {
            return nil
        }
        let node = SCNNode(geometry: mesh.geometry)
        node.name = "DepthForgePatch-\(pass)"
        root.addChildNode(node)
        patches.append(node)
        while patches.count > maximumPatches {
            patches.removeFirst().removeFromParentNode()
        }
        return MeasuredMeshPatch(pass: pass, triangles: mesh.triangles)
    }

    private func sampleStep(for pass: Int, profile: CaptureProfile) -> Int {
        switch profile {
        case .maximumGeometry:
            switch pass {
            case 1: return 8
            case 2...3: return 6
            case 4...5: return 4
            case 6...7: return 3
            default: return 2
            }
        case .balanced:
            switch pass {
            case 1: return 8
            case 2...3: return 6
            case 4...6: return 5
            default: return 4
            }
        }
    }

    private func makeGeometry(
        from frame: ARFrame,
        sampleStep: Int,
        objectVolume: ObjectScanVolume?
    ) -> (geometry: SCNGeometry, triangles: Int)? {
        guard let depthData = frame.sceneDepth else { return nil }
        let depth = depthData.depthMap
        let confidence = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return nil }

        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depth)
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceRowBytes = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0
        let isFloat16 = CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat16
        guard let objectVolume else { return nil }

        let imageSize = frame.camera.imageResolution
        var intrinsics = frame.camera.intrinsics
        intrinsics.columns.0.x *= Float(width) / Float(imageSize.width)
        intrinsics.columns.1.y *= Float(height) / Float(imageSize.height)
        intrinsics.columns.2.x *= Float(width) / Float(imageSize.width)
        intrinsics.columns.2.y *= Float(height) / Float(imageSize.height)

        let xs = Array(Swift.stride(from: 0, to: width, by: sampleStep))
        let ys = Array(Swift.stride(from: 0, to: height, by: sampleStep))
        guard xs.count > 1, ys.count > 1 else { return nil }

        let invalid = UInt32.max
        var grid = Array(repeating: invalid, count: xs.count * ys.count)
        var localDepths = Array(repeating: Float.nan, count: xs.count * ys.count)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<UInt8>] = []
        positions.reserveCapacity(grid.count)
        colors.reserveCapacity(grid.count)
        let colorSampler = DepthMeshColorSampler(buffer: frame.capturedImage)

        for (row, y) in ys.enumerated() {
            let confidenceLine = confidenceBase?.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
            for (column, x) in xs.enumerated() {
                if let confidenceLine, confidenceLine[x] < 1 { continue }
                let distance = depthValue(base: depthBase, rowBytes: depthRowBytes, x: x, y: y, isFloat16: isFloat16)
                guard distance.isFinite, distance > 0.08, distance < 8 else { continue }
                let local = SIMD4<Float>(
                    (Float(x) - intrinsics.columns.2.x) * distance / intrinsics.columns.0.x,
                    (Float(y) - intrinsics.columns.2.y) * distance / intrinsics.columns.1.y,
                    -distance,
                    1
                )
                let world = simd_mul(frame.camera.transform, local)
                guard objectVolume.contains(SIMD3<Float>(world.x, world.y, world.z)) else { continue }
                let gridIndex = row * xs.count + column
                grid[gridIndex] = UInt32(positions.count)
                localDepths[gridIndex] = distance
                positions.append(SIMD3<Float>(world.x, world.y, world.z))
                let color = colorSampler.color(depthX: x, depthY: y, depthWidth: width, depthHeight: height)
                colors.append(SIMD4<UInt8>(color.x, color.y, color.z, 255))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(max(0, (xs.count - 1) * (ys.count - 1) * 6))
        // Do not bridge depth discontinuities (for example foreground lamp to wall).
        let maximumDepthJump: Float = 0.045
        for row in 0..<(ys.count - 1) {
            for column in 0..<(xs.count - 1) {
                let a = row * xs.count + column
                let b = a + 1
                let c = a + xs.count
                let d = c + 1
                let depthValues = [localDepths[a], localDepths[b], localDepths[c], localDepths[d]]
                guard grid[a] != invalid, grid[b] != invalid, grid[c] != invalid, grid[d] != invalid,
                      let low = depthValues.min(), let high = depthValues.max(),
                      high - low <= maximumDepthJump else { continue }
                indices += [grid[a], grid[c], grid[b], grid[b], grid[c], grid[d]]
            }
        }
        guard positions.count >= 3, indices.count >= 3 else { return nil }

        let positionData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(
            data: positionData,
            semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: false,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<UInt8>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<UInt8>>.stride
        )
        let triangleCount = indices.count / 3
        let wire = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: triangleCount, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [source, colorSource], elements: [wire])
        geometry.materials = [wireMaterial()]
        return (geometry, triangleCount)
    }

    private func wireMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        // Outline-only: the real camera feed remains visible while the mesh
        // grows. Per-vertex RGB still modulates the subtle scan lines.
        material.diffuse.contents = UIColor.systemMint.withAlphaComponent(0.42)
        material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.18)
        material.fillMode = .lines
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }

    private func depthValue(base: UnsafeMutableRawPointer, rowBytes: Int, x: Int, y: Int, isFloat16: Bool) -> Float {
        if isFloat16 {
            return Float(base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)[x])
        }
        return base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)[x]
    }
}

private final class DepthMeshColorSampler {
    private let buffer: CVPixelBuffer

    init(buffer: CVPixelBuffer) {
        self.buffer = buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
    }

    deinit { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    func color(depthX: Int, depthY: Int, depthWidth: Int, depthHeight: Int) -> SIMD3<UInt8> {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            return SIMD3(repeating: 180)
        }
        let imageWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let imageX = min(imageWidth - 1, max(0, depthX * imageWidth / depthWidth))
        let imageY = min(imageHeight - 1, max(0, depthY * imageHeight / depthHeight))
        let y = Float(yBase.advanced(by: imageY * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)[imageX])
        let chroma = cbcrBase.advanced(by: (imageY / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let cb = Float(chroma[(imageX / 2) * 2]) - 128
        let cr = Float(chroma[(imageX / 2) * 2 + 1]) - 128
        return SIMD3(
            UInt8(max(0, min(255, Int(y + 1.402 * cr)))),
            UInt8(max(0, min(255, Int(y - 0.344 * cb - 0.714 * cr)))),
            UInt8(max(0, min(255, Int(y + 1.772 * cb))))
        )
    }
}

struct MeasuredMeshPatch {
    let pass: Int
    let triangles: Int
}
