import ARKit
import Foundation
import simd

enum ScanState: Equatable { case idle, recording, paused, finishing, finished, failed(String) }

enum CaptureProfile: String, CaseIterable, Identifiable {
    case maximumGeometry
    case balanced

    var id: String { rawValue }
    var title: String { self == .maximumGeometry ? "Maximum geometry" : "Balanced" }
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
            ? "Houd het voorwerp binnen het middenkader"
            : "Leg de volledige kamer vast met RoomPlan"
    }
}

enum RescanAdvice: String, Codable, CaseIterable {
    case moveCloser = "Ga 20–40 cm dichterbij en houd het oppervlak in beeld."
    case changeAngle = "Beweeg zijwaarts: dit gebied heeft te weinig kijkhoeken."
    case holdSteady = "Houd de iPad stil: de metingen zijn nog niet consistent."
    case revisit = "Volg de gemarkeerde zones en neem twee extra kijkhoeken."
    case complete = "Dit zichtbare gebied heeft voldoende bruikbare data."
}

struct QualitySummary: Equatable {
    var usableMeasurements = 0
    var coveredCells = 0
    var weakCells = 0
    var meanConsistency: Float = 0
    var meanViewDiversity: Float = 0
    var advice: RescanAdvice = .moveCloser
    var status: String { "\(coveredCells) sterke · \(weakCells) opnieuw scannen · \(usableMeasurements) metingen" }
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
    let schema = "depthforge/1"
    let createdAt: Date
    let device: String
    let depthFormat = "Native sceneDepth CVPixelBuffer bytes; per-frame pixel format and row stride are recorded"
    let confidenceFormat = "UInt8 ARConfidenceLevel: 0 low, 1 medium, 2 high"
    var frames: Int
    var roomPlanFile: String?
}

struct VoxelKey: Hashable {
    let x: Int; let y: Int; let z: Int
    init(_ point: SIMD3<Float>, cellSize: Float) {
        x = Int(floor(point.x / cellSize)); y = Int(floor(point.y / cellSize)); z = Int(floor(point.z / cellSize))
    }
}

struct FusedVoxel {
    var position: SIMD3<Float>
    var color: SIMD3<UInt8>
    var observations: Int = 0
    var meanDepth: Float = 0
    var depthM2: Float = 0
    var viewDirectionSum = SIMD3<Float>(repeating: 0)

    mutating func add(position newPoint: SIMD3<Float>, color newColor: SIMD3<UInt8>, depth: Float, viewDirection: SIMD3<Float>) {
        observations += 1
        let count = Float(observations)
        position += (newPoint - position) / count
        color = SIMD3<UInt8>(
            UInt8((Int(color.x) * (observations - 1) + Int(newColor.x)) / observations),
            UInt8((Int(color.y) * (observations - 1) + Int(newColor.y)) / observations),
            UInt8((Int(color.z) * (observations - 1) + Int(newColor.z)) / observations)
        )
        let delta = depth - meanDepth
        meanDepth += delta / count
        depthM2 += delta * (depth - meanDepth)
        viewDirectionSum += simd_normalize(viewDirection)
    }

    var consistency: Float {
        guard observations > 1 else { return 0 }
        return 1 / (1 + sqrt(max(0, depthM2 / Float(observations - 1))) * 150)
    }
    var viewDiversity: Float { min(1, 1 - simd_length(viewDirectionSum) / Float(max(observations, 1))) }
    /// Coverage is intentionally independent from camera-angle diversity. A stable
    /// surface may become green after a few measurements; a separate instruction
    /// then asks the user to add another angle instead of leaving the map red.
    var quality: Float {
        let coverage = min(1, Float(observations) / 3) * 0.60 + consistency * 0.40
        return min(1, coverage * 0.85 + viewDiversity * 0.15)
    }
}

extension simd_float4x4 {
    var codableColumnMajor: [Float] { (0..<4).flatMap { column in (0..<4).map { self[column][$0] } } }
}

extension simd_float3x3 {
    var codableColumnMajor: [Float] { (0..<3).flatMap { column in (0..<3).map { self[column][$0] } } }
}
