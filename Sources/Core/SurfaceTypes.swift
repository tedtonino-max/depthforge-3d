import Foundation

// No ARKit dependency: the exact production geometry runs in Swift tests.
typealias Vec3 = SIMD3<Float>
func dot(_ a: Vec3, _ b: Vec3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
func length(_ v: Vec3) -> Float { sqrt(dot(v, v)) }
func unit(_ v: Vec3) -> Vec3 { v / max(0.000001, length(v)) }
func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

struct CameraPose: Equatable {
    var right = Vec3(1, 0, 0)
    var up = Vec3(0, 1, 0)
    var back = Vec3(0, 0, 1)
    var position = Vec3.zero
    func world(_ p: Vec3) -> Vec3 { rotate(p) + position }
    func rotate(_ p: Vec3) -> Vec3 { right * p.x + up * p.y + back * p.z }
    func local(_ p: Vec3) -> Vec3 {
        let v = p - position
        return Vec3(dot(v, right), dot(v, up), dot(v, back))
    }
}

struct DepthCamera {
    var width: Int
    var height: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    // Image y points down; ARKit camera y points up, with forward along -z.
    func unproject(x: Int, y: Int, depth: Float) -> Vec3 {
        Vec3((Float(x) - cx) * depth / fx, -(Float(y) - cy) * depth / fy, -depth)
    }
    func pixel(_ p: Vec3) -> (Int, Int)? {
        guard p.z < -0.08 else { return nil }
        let x = fx * p.x / -p.z + cx, y = fy * -p.y / -p.z + cy
        guard x.isFinite, y.isFinite, x >= 1, y >= 1,
              x < Float(width - 1), y < Float(height - 1) else { return nil }
        return (Int(x.rounded()), Int(y.rounded()))
    }
}

struct ObjectScanVolume: Codable, Equatable {
    var x: Float; var y: Float; var z: Float
    var radius: Float; var height: Float
    init(center: Vec3, radius: Float = 0.24, height: Float = 1.5) {
        x = center.x; y = center.y; z = center.z
        self.radius = radius; self.height = height
    }
    var center: Vec3 { Vec3(x, y, z) }
    func resized(to radius: Float) -> Self {
        var result = self; result.radius = min(1.2, max(0.12, radius)); return result
    }
    func contains(_ p: Vec3) -> Bool {
        let dx = p.x - x, dz = p.z - z
        return dx * dx + dz * dz <= radius * radius && p.y >= y && p.y <= y + height
    }
}

/// A surface-oriented disk with a shallow depth band. It selects detail, not
/// the whole room's export boundary. Its ID isolates evidence after reselection.
struct DetailZone: Codable, Equatable {
    var id = UUID()
    var center: Vec3
    var normal: Vec3
    var radius: Float = 0.35
    var halfDepth: Float = 0.10
    func contains(_ p: Vec3) -> Bool {
        let delta = p - center, along = dot(delta, normal)
        return abs(along) <= halfDepth && dot(delta, delta) - along * along <= radius * radius
    }
}

struct DepthInput {
    var timestamp: Double
    var camera: DepthCamera
    var pose: CameraPose
    var depths: [Float]
    var confidence: [UInt8]
    var colors: [Vec3]
    var objectVolume: ObjectScanVolume?
    var detailZone: DetailZone?
    var isObject = true
    var baseStride = 2
    var detailStride = 1
    var processingBudget: Double = 0.10
    func valid(_ i: Int) -> Bool {
        i >= 0 && i < depths.count && confidence[i] == 2 &&
        depths[i].isFinite && depths[i] > 0.12 && depths[i] < 5
    }
    func visible(_ p: Vec3, tolerance: Float = 0.025) -> Bool {
        let local = pose.local(p)
        guard let (x, y) = camera.pixel(local) else { return false }
        let i = y * camera.width + x
        return valid(i) && abs(depths[i] + local.z) < tolerance
    }
}

struct Surfel {
    let id: Int
    var position: Vec3
    var normal: Vec3
    var color: Vec3
    var radius: Float
    var weight: Float = 1
    var observations = 1
    var residualSquared: Float = 0
    var firstView: Vec3
    var wideObservations = 0
    var lastFrame: Int
    var contradictions = 0
    var isStable: Bool { observations >= 4 && residualSquared < 0.000144 && contradictions == 0 }
    var hasAngles: Bool { wideObservations >= 3 }
}

enum ScanAdvice: String {
    case findSurface = "Breng het gekozen gebied duidelijk in beeld"
    case holdSteady = "Houd 1 seconde stil"
    case nextAngle = "Klaar voor de volgende hoek"
    case improve = "Dit detail is nog niet betrouwbaar; scan rustig opnieuw"
    case ready = "Deze zichtbare zone is goed genoeg om op te slaan"
    case focus = "Kies een detailzone op een wand of vloer"
    case budget = "Opname vertraagd; houd de iPad even stil"
    case capacity = "Geheugenlimiet bereikt; sla deze scan op"
}

struct SurfaceQuality: Equatable {
    var visible = 0
    var stable = 0
    var multipleAngles = 0
    var missing = 0
    var rmsResidual: Float = 0
    var totalStable = 0
    var accepted = 0
    var limited = false
    var capacityReached = false
    // Each quantity has a distinct meaning; no blended quality percentage.
    var coverage: Float { Float(stable) / Float(max(1, visible + missing)) }
    var angleCoverage: Float { Float(multipleAngles) / Float(max(1, visible + missing)) }
    var advice: ScanAdvice {
        if capacityReached { return .capacity }
        if limited { return .budget }
        if accepted < 24 || visible < 24 { return .findSurface }
        if rmsResidual > 0.012 { return .improve }
        if coverage < 0.8 { return .holdSteady }
        if angleCoverage < 0.65 { return .nextAngle }
        return .ready
    }
}

struct SurfaceUpdate {
    var quality: SurfaceQuality
    var visibleSurfels: [Surfel]
    var elapsed: Double
}
