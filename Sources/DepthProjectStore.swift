import ARKit
import Foundation
import ImageIO
import UIKit

/// Owned exclusively by CapturePipeline's serial worker. Encoding, disk writes,
/// manifest checkpoints and close all share the same ordering.
final class DepthProjectStore {
    private let encoder = JSONEncoder()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private(set) var root: URL?
    private(set) var frameCount = 0
    private var createdAt = Date()
    private var volume: ObjectScanVolume?
    private var zones: [DetailZone] = []
    private var photos: [PhotoRecord] = []
    private var indexHandle: FileHandle?

    func beginNewScan(objectVolume: ObjectScanVolume?, device: String) throws -> URL {
        try indexHandle?.close()
        createdAt = Date(); self.device = device
        let id = ISO8601DateFormatter().string(from: createdAt).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6)
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = base.appendingPathComponent("DepthForgeScans/\(id)", isDirectory: true)
        for path in ["", "frames", "photos", "room", "exports"] {
            try FileManager.default.createDirectory(at: destination.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let index = destination.appendingPathComponent("frames/index.jsonl")
        guard FileManager.default.createFile(atPath: index.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        root = destination; frameCount = 0; volume = objectVolume; zones = []; photos = []
        indexHandle = try FileHandle(forWritingTo: index)
        try checkpoint(roomPlanFile: nil, skipped: 0)
        return destination
    }
    private var device = "iPad"
    func register(_ zone: DetailZone) {
        if !zones.contains(where: { $0.id == zone.id }) { zones.append(zone) }
    }

    func append(frame: ARFrame, sequence: Int, photoAngle: Int?, zoneID: UUID?,
                orientation: CGImagePropertyOrientation) throws -> PhotoPreview? {
        guard let root, let depth = frame.sceneDepth, let handle = indexHandle else { throw CocoaError(.fileWriteUnknown) }
        let prefix = String(format: "%06d", sequence)
        let depthName = "frames/\(prefix).depthraw"
        try bytes(depth.depthMap).write(to: root.appendingPathComponent(depthName), options: .atomic)
        var confidenceName: String?
        if let confidence = depth.confidenceMap {
            let name = "frames/\(prefix).confidence8"
            try bytes(confidence).write(to: root.appendingPathComponent(name), options: .atomic)
            confidenceName = name
        }
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        var imageName: String?
        if let jpeg = imageContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) {
            let name = "frames/\(prefix).jpg"
            try jpeg.write(to: root.appendingPathComponent(name), options: .atomic)
            imageName = name
        }
        let record = FrameRecord(sequence: sequence, timestamp: frame.timestamp, depthFile: depthName,
            confidenceFile: confidenceName, imageFile: imageName,
            depthWidth: CVPixelBufferGetWidth(depth.depthMap), depthHeight: CVPixelBufferGetHeight(depth.depthMap),
            depthPixelFormat: CVPixelBufferGetPixelFormatType(depth.depthMap), depthBytesPerRow: CVPixelBufferGetBytesPerRow(depth.depthMap),
            confidenceBytesPerRow: depth.confidenceMap.map { CVPixelBufferGetBytesPerRow($0) },
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage), imageHeight: CVPixelBufferGetHeight(frame.capturedImage),
            cameraTransform: frame.camera.transform.codableColumnMajor, intrinsics: frame.camera.intrinsics.codableColumnMajor,
            tracking: String(describing: frame.camera.trackingState))
        try handle.write(contentsOf: encoder.encode(record) + Data([0x0A]))
        frameCount += 1
        guard let photoAngle, let imageName else { return nil }
        let oriented = image.oriented(orientation)
        let scale = 240 / max(oriented.extent.width, oriented.extent.height)
        let small = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = imageContext.jpegRepresentation(of: small, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]),
              let thumbnail = UIImage(data: jpeg) else { return nil }
        let thumbnailName = "photos/\(prefix)-thumb.jpg"
        try jpeg.write(to: root.appendingPathComponent(thumbnailName), options: .atomic)
        photos.append(PhotoRecord(id: sequence, imageFile: imageName, thumbnailFile: thumbnailName,
            cameraTransform: frame.camera.transform.codableColumnMajor, timestamp: frame.timestamp,
            angleDegrees: photoAngle, detailZoneID: zoneID))
        return PhotoPreview(id: sequence, thumbnail: thumbnail, angleDegrees: photoAngle)
    }
    func checkpoint(roomPlanFile: String?, skipped: Int) throws {
        guard let root else { return }
        let manifest = ScanManifest(createdAt: createdAt, device: device, frames: frameCount,
            roomPlanFile: roomPlanFile, objectScanVolume: volume, detailZones: zones,
            selectedPhotos: photos, deferredCaptureIntervals: skipped)
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        try indexHandle?.synchronize()
    }
    func close(roomPlanFile: String?, skipped: Int) throws {
        try checkpoint(roomPlanFile: roomPlanFile, skipped: skipped)
        try indexHandle?.close(); indexHandle = nil
    }
    private func bytes(_ buffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes: base, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
}
