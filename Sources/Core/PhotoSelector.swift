import Foundation

/// Pose stability and angular novelty are independent of surface readiness.
/// A failed JPEG write never consumes a viewpoint.
struct PhotoSelector {
    private var previous: (Double, CameraPose)?
    private var steadySince: Double?
    private var views: [(Vec3, Vec3)] = []
    private var lastPhoto = -Double.infinity
    var maximum = 24
    mutating func resetStability() { previous = nil; steadySince = nil }
    mutating func candidate(timestamp: Double, pose: CameraPose, target: Vec3,
                            visible: Bool, exposureOK: Bool) -> Bool {
        defer { previous = (timestamp, pose) }
        guard let old = previous, timestamp - old.0 < 0.6 else { steadySince = nil; return false }
        let dt = max(0.001, timestamp - old.0)
        let speed = length(pose.position - old.1.position) / Float(dt)
        let angle = acos(min(1, max(-1, dot(pose.back, old.1.back)))) / Float(dt)
        guard visible, exposureOK, speed < 0.05, angle < 0.12 else { steadySince = nil; return false }
        if steadySince == nil { steadySince = timestamp }
        guard timestamp - (steadySince ?? timestamp) >= 0.8,
              timestamp - lastPhoto >= 2, views.count < maximum else { return false }
        let direction = unit(pose.position - target)
        // Turning in place is not a new view of the same object.
        return views.allSatisfy { length(pose.position - $0.0) >= 0.10 && dot(direction, $0.1) < 0.966 }
    }
    mutating func commit(timestamp: Double, pose: CameraPose, target: Vec3) {
        views.append((pose.position, unit(pose.position - target))); lastPhoto = timestamp
    }
}
