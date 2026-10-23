import ARKit
import Foundation
import simd

/// ARKit adapter. All pixel access and fusion run on the bounded capture worker.
final class GeometryFusion {
    let surface = SurfelFusion()
    func reset() { surface.reset() }
    func input(frame: ARFrame, target: CaptureTarget, volume: ObjectScanVolume?,
               zone: DetailZone?, stride: Int, detailStride: Int, budget: Double) -> DepthInput? {
        guard let data = frame.sceneDepth, let confidence = data.confidenceMap else { return nil }
        let depth = data.depthMap
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height else { return nil }
        let format = CVPixelBufferGetPixelFormatType(depth)
        guard format == kCVPixelFormatType_DepthFloat32 || format == kCVPixelFormatType_DepthFloat16 else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(depth), let cb = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(depth), cr = CVPixelBufferGetBytesPerRow(confidence)
        var depths = [Float](repeating: 0, count: width * height)
        var confidences = [UInt8](repeating: 0, count: width * height)
        var colors = [Vec3](repeating: Vec3(repeating: 180), count: width * height)
        let sampler = YCbCrSampler(buffer: frame.capturedImage)
        for y in 0..<height {
            let cl = cb.advanced(by: y * cr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let i = y * width + x
                depths[i] = format == kCVPixelFormatType_DepthFloat16
                    ? Float(base.advanced(by: y * row).assumingMemoryBound(to: Float16.self)[x])
                    : base.advanced(by: y * row).assumingMemoryBound(to: Float.self)[x]
                confidences[i] = cl[x]
                colors[i] = sampler.color(x: x, y: y, width: width, height: height)
            }
        }
        let k = frame.camera.intrinsics, resolution = frame.camera.imageResolution
        let sx = Float(width) / Float(resolution.width), sy = Float(height) / Float(resolution.height)
        let camera = DepthCamera(width: width, height: height, fx: k.columns.0.x * sx,
            fy: k.columns.1.y * sy, cx: k.columns.2.x * sx, cy: k.columns.2.y * sy)
        return DepthInput(timestamp: frame.timestamp, camera: camera, pose: CameraPose(frame.camera.transform),
            depths: depths, confidence: confidences, colors: colors, objectVolume: volume,
            detailZone: zone, isObject: target == .object, baseStride: stride,
            detailStride: detailStride, processingBudget: budget)
    }
    func plyData(volume: ObjectScanVolume?) -> Data { surface.plyData(volume: volume) }
}

extension CameraPose {
    init(_ m: simd_float4x4) {
        self.init(right: Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                  up: Vec3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                  back: Vec3(m.columns.2.x, m.columns.2.y, m.columns.2.z),
                  position: Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
    }
}

private final class YCbCrSampler {
    private let buffer: CVPixelBuffer
    init(buffer: CVPixelBuffer) { self.buffer = buffer; CVPixelBufferLockBaseAddress(buffer, .readOnly) }
    deinit { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    func color(x: Int, y: Int, width: Int, height: Int) -> Vec3 {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return Vec3(repeating: 180) }
        let ix = min(CVPixelBufferGetWidthOfPlane(buffer, 0) - 1, x * CVPixelBufferGetWidthOfPlane(buffer, 0) / width)
        let iy = min(CVPixelBufferGetHeightOfPlane(buffer, 0) - 1, y * CVPixelBufferGetHeightOfPlane(buffer, 0) / height)
        let luminance = Float(yBase.advanced(by: iy * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)[ix])
        let line = cBase.advanced(by: iy / 2 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let cb = Float(line[ix / 2 * 2]) - 128, cr = Float(line[ix / 2 * 2 + 1]) - 128
        return Vec3(min(255, max(0, luminance + 1.402 * cr)),
                    min(255, max(0, luminance - 0.344 * cb - 0.714 * cr)),
                    min(255, max(0, luminance + 1.772 * cb)))
    }
}
