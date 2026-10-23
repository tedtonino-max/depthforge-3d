import ARKit
import Foundation
import simd
import UIKit

enum ScanState: Equatable { case idle, framing, preparing, recording, paused, review, finishing, finished, failed(String) }

enum CaptureProfile: String, CaseIterable, Identifiable {
    case maximumGeometry
    case balanced

    var id: String { rawValue }
    var title: String { self == .maximumGeometry ? "Maximaal detail" : "Gebalanceerd" }
    var detail: String { self == .maximumGeometry ? "Dichte fusie en vaker ruwe frames" : "Rustiger voor lange scans" }
    var frameInterval: TimeInterval { self == .maximumGeometry ? 0.17 : 0.25 }
    var sampleStride: Int { self == .maximumGeometry ? 2 : 4 }
}

/// The raw depth frames always remain complete. This choice only controls the
/// live fusion and its guidance, so a small object does not become a room-sized
/// PLY by accident.
enum CaptureTarget: String, CaseIterable, Identifiable {
    case object
    case room

    var id: String { rawValue }
    var title: String { self == .object ? "Voorwerp" : "Ruimte" }
    var detail: String {
        self == .object
            ? "Teken een scanvolume rond het voorwerp"
            : "Leg de volledige kamer vast met RoomPlan"
    }
}

struct FrameRecord: Codable {
    let sequence: Int
    let timestamp: TimeInterval
    let depthFile: String
    let confidenceFile: String?
    /// JPEG is best effort: ARKit depth and pose must remain usable if the RGB encoder declines a frame.
    let imageFile: String?
    let depthWidth: Int
    let depthHeight: Int
    let depthPixelFormat: UInt32
    let depthBytesPerRow: Int
    let confidenceBytesPerRow: Int?
    let imageWidth: Int
    let imageHeight: Int
    let cameraTransform: [Float]
    let intrinsics: [Float]
    let tracking: String
}

struct ScanManifest: Codable {
    let schema = "depthforge/3"
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let meshFiles = ["exports/base-mesh.ply", "exports/detail-mesh.ply"]
    let createdAt: Date
    let device: String
    let depthFormat = "Native sceneDepth CVPixelBuffer bytes; per-frame pixel format and row stride are recorded"
    let confidenceFormat = "UInt8 ARConfidenceLevel: 0 low, 1 medium, 2 high"
    var frames: Int
    var roomPlanFile: String?
    var objectScanVolume: ObjectScanVolume?
    var detailZones: [DetailZone] = []
    var selectedPhotos: [PhotoRecord] = []
    var deferredCaptureIntervals: Int = 0
}

extension simd_float4x4 {
    var codableColumnMajor: [Float] { (0..<4).flatMap { column in (0..<4).map { self[column][$0] } } }
}

extension simd_float3x3 {
    var codableColumnMajor: [Float] { (0..<3).flatMap { column in (0..<3).map { self[column][$0] } } }
}

struct PhotoRecord: Codable, Identifiable {
    let id: Int
    let imageFile: String
    let thumbnailFile: String
    let cameraTransform: [Float]
    let timestamp: TimeInterval
    let angleDegrees: Int
    let detailZoneID: UUID?
}

struct PhotoPreview: Identifiable {
    let id: Int
    let thumbnail: UIImage
    let angleDegrees: Int
}
