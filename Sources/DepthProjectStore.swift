import ARKit
import Foundation
import UIKit

final class DepthProjectStore {
    private let encoder = JSONEncoder()
    private(set) var root: URL?
    private(set) var frameCount = 0
    private var objectScanRegion: ObjectScanRegion?
    private var indexHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.depthforge.writer", qos: .utility)

    func beginNewScan(objectRegion: ObjectScanRegion?) throws -> URL {
        let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = applicationSupport.appendingPathComponent("DepthForgeScans/\(id)", isDirectory: true)
        for component in [destination, destination.appendingPathComponent("frames"), destination.appendingPathComponent("room"), destination.appendingPathComponent("exports")] {
            try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        }
        let indexURL = destination.appendingPathComponent("frames/index.jsonl")
        guard FileManager.default.createFile(atPath: indexURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: indexURL.path])
        }
        root = destination; frameCount = 0; objectScanRegion = objectRegion
        indexHandle = try FileHandle(forWritingTo: indexURL)
        try checkpoint(roomPlanFile: nil)
        return destination
    }

    func append(frame: ARFrame, sequence: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let root else { completion(.failure(CocoaError(.fileNoSuchFile))); return }
        guard let depth = frame.sceneDepth else { completion(.failure(CocoaError(.fileReadUnknown))); return }
        let confidence = depth.confidenceMap
        let depthCopy = PixelBufferCopy.make(depth.depthMap)
        let confidenceCopy = confidence.map(PixelBufferCopy.make)
        let jpeg = PixelBufferCopy.jpeg(frame.capturedImage)
        let transform = frame.camera.transform.codableColumnMajor
        let intrinsics = frame.camera.intrinsics.codableColumnMajor
        let tracking = String(describing: frame.camera.trackingState)
        let timestamp = frame.timestamp
        let depthWidth = CVPixelBufferGetWidth(depth.depthMap)
        let depthHeight = CVPixelBufferGetHeight(depth.depthMap)
        let depthPixelFormat = CVPixelBufferGetPixelFormatType(depth.depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depth.depthMap)
        let confidenceBytesPerRow = confidence.map { CVPixelBufferGetBytesPerRow($0) }
        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let prefix = String(format: "%06d", sequence)
                let frameDirectory = root.appendingPathComponent("frames")
                let depthName = "frames/\(prefix).depthraw"
                try depthCopy.write(to: root.appendingPathComponent(depthName), options: .atomic)
                let confidenceName: String?
                if let confidenceCopy {
                    confidenceName = "frames/\(prefix).confidence8"
                    try confidenceCopy.write(to: root.appendingPathComponent(confidenceName!), options: .atomic)
                } else {
                    confidenceName = nil
                }
                var imageName: String?
                if let jpeg {
                    let name = "frames/\(prefix).jpg"
                    try jpeg.write(to: root.appendingPathComponent(name), options: .atomic)
                    imageName = name
                }
                let record = FrameRecord(sequence: sequence, timestamp: timestamp, depthFile: depthName, confidenceFile: confidenceName, imageFile: imageName, depthWidth: depthWidth, depthHeight: depthHeight, depthPixelFormat: depthPixelFormat, depthBytesPerRow: depthBytesPerRow, confidenceBytesPerRow: confidenceBytesPerRow, imageWidth: imageWidth, imageHeight: imageHeight, cameraTransform: transform, intrinsics: intrinsics, tracking: tracking)
                let line = try self.encoder.encode(record) + Data([0x0A])
                self.indexHandle?.write(line)
                self.frameCount += 1
                _ = frameDirectory // makes the intent explicit: all record paths are scan-root relative
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    func checkpoint(roomPlanFile: String?) throws {
        try queue.sync {
            guard let root else { return }
            let manifest = ScanManifest(createdAt: Date(), device: UIDevice.current.model, frames: frameCount, roomPlanFile: roomPlanFile, objectScanRegion: objectScanRegion)
            try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    func close(roomPlanFile: String?) throws { try checkpoint(roomPlanFile: roomPlanFile); try indexHandle?.close(); indexHandle = nil }

}

private enum PixelBufferCopy {
    static func make(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer)
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: rowBytes * height)
    }

    static func jpeg(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        return try? CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
    }
}
