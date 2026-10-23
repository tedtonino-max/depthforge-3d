import ARKit
import Foundation
import UIKit

final class DepthProjectStore {
    private let encoder = JSONEncoder()
    private(set) var root: URL?
    private(set) var frameCount = 0
    private var indexHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.depthforge.writer", qos: .utility)

    func beginNewScan() throws -> URL {
        let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent("DepthForgeScans/\(id)", isDirectory: true)
        for component in [destination, destination.appendingPathComponent("frames"), destination.appendingPathComponent("room"), destination.appendingPathComponent("exports")] {
            try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        }
        root = destination; frameCount = 0
        FileManager.default.createFile(atPath: destination.appendingPathComponent("frames/index.jsonl").path, contents: nil)
        indexHandle = try FileHandle(forWritingTo: destination.appendingPathComponent("frames/index.jsonl"))
        try checkpoint(roomPlanFile: nil)
        return destination
    }

    func append(frame: ARFrame, sequence: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let root else { completion(.failure(CocoaError(.fileNoSuchFile))); return }
        let depth = frame.sceneDepth
        guard let depth, let confidence = depth.confidenceMap else { completion(.failure(CocoaError(.fileReadUnknown))); return }
        let depthCopy = PixelBufferCopy.make(depth.depthMap)
        let confidenceCopy = PixelBufferCopy.make(confidence)
        let jpeg = PixelBufferCopy.jpeg(frame.capturedImage)
        let transform = frame.camera.transform.codableColumnMajor
        let intrinsics = frame.camera.intrinsics.codableColumnMajor
        let tracking = String(describing: frame.camera.trackingState)
        let timestamp = frame.timestamp
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let prefix = String(format: "%06d", sequence)
                let frameDirectory = root.appendingPathComponent("frames")
                let depthName = "frames/\(prefix).depthraw", confidenceName = "frames/\(prefix).confidence8", imageName = "frames/\(prefix).jpg"
                try depthCopy.write(to: root.appendingPathComponent(depthName), options: .atomic)
                try confidenceCopy.write(to: root.appendingPathComponent(confidenceName), options: .atomic)
                guard let jpeg else { throw CocoaError(.fileWriteUnknown) }
                try jpeg.write(to: root.appendingPathComponent(imageName), options: .atomic)
                let record = FrameRecord(sequence: sequence, timestamp: timestamp, depthFile: depthName, confidenceFile: confidenceName, imageFile: imageName, depthWidth: CVPixelBufferGetWidth(depth.depthMap), depthHeight: CVPixelBufferGetHeight(depth.depthMap), depthPixelFormat: CVPixelBufferGetPixelFormatType(depth.depthMap), depthBytesPerRow: CVPixelBufferGetBytesPerRow(depth.depthMap), confidenceBytesPerRow: CVPixelBufferGetBytesPerRow(confidence), imageWidth: CVPixelBufferGetWidth(frame.capturedImage), imageHeight: CVPixelBufferGetHeight(frame.capturedImage), cameraTransform: transform, intrinsics: intrinsics, tracking: tracking)
                let line = try self.encoder.encode(record) + Data([0x0A])
                self.indexHandle?.write(line)
                self.frameCount += 1
                _ = frameDirectory // makes the intent explicit: all record paths are scan-root relative
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    func checkpoint(roomPlanFile: String?) throws {
        guard let root else { return }
        let manifest = ScanManifest(createdAt: Date(), device: UIDevice.current.model, frames: frameCount, roomPlanFile: roomPlanFile)
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
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
