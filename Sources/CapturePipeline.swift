import ARKit
import Foundation
import ImageIO

struct PipelineResult {
    let surface: SurfaceUpdate
    let pose: CameraPose
    let photo: PhotoPreview?
    let savedFrames: Int
    let duration: Double
    let reducedDetail: Bool
}

/// Single admitted ARFrame, one serial worker, no pending image backlog. The
/// controller only admits another frame after completion (including JPEG/disk).
final class CapturePipeline {
    private let queue = DispatchQueue(label: "com.depthforge.capture", qos: .userInitiated)
    private let fusion = GeometryFusion()
    private let store = DepthProjectStore()
    private var selector = PhotoSelector()
    private var sequence = 0
    private var volume: ObjectScanVolume?
    private var activeZone: UUID?
    private var photoTarget: Vec3?
    private var photoCount = 0
    private var detailStride = 1
    private var fastFrames = 0

    func begin(volume: ObjectScanVolume?, device: String, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                self.fusion.reset(); self.selector = PhotoSelector(); self.sequence = 0
                self.volume = volume; self.activeZone = nil; self.photoTarget = nil; self.photoCount = 0
                self.detailStride = 1; self.fastFrames = 0
                completion(.success(try self.store.beginNewScan(objectVolume: volume, device: device)))
            } catch { completion(.failure(error)) }
        }
    }

    func process(frame: ARFrame, target: CaptureTarget, zone: DetailZone?, stride: Int,
                 orientation: CGImagePropertyOrientation, skipped: Int,
                 completion: @escaping (Result<PipelineResult, Error>) -> Void) {
        queue.async {
            autoreleasepool {
                let start = Date.timeIntervalSinceReferenceDate
                guard let input = self.fusion.input(frame: frame, target: target, volume: self.volume,
                    zone: zone, stride: stride, detailStride: self.detailStride, budget: 0.09) else {
                    completion(.failure(CaptureError.noDepth)); return
                }
                if self.activeZone != zone?.id {
                    self.activeZone = zone?.id; self.selector = PhotoSelector(); self.photoTarget = nil
                }
                if let zone { self.store.register(zone) }
                let update = self.fusion.surface.integrate(input)
                if update.quality.limited {
                    self.detailStride = min(3, self.detailStride + 1); self.fastFrames = 0
                } else if update.elapsed < 0.05 {
                    self.fastFrames += 1
                    if self.fastFrames >= 20 { self.detailStride = max(1, self.detailStride - 1); self.fastFrames = 0 }
                } else { self.fastFrames = 0 }
                if self.photoTarget == nil, update.visibleSurfels.count >= 24 {
                    self.photoTarget = zone?.center ?? update.visibleSurfels.reduce(Vec3.zero) { $0 + $1.position } / Float(update.visibleSurfels.count)
                }
                let targetPoint = zone?.center ?? self.photoTarget
                let light = frame.lightEstimate?.ambientIntensity ?? 0
                // Exposure and pose gates are conservative heuristics, not a
                // claim of image sharpness or texture reconstruction quality.
                let exposureOK = light > 150 && frame.camera.exposureDuration < 1.0 / 45.0
                let photo = self.photoCount < 24 && (targetPoint.map {
                    self.selector.candidate(timestamp: frame.timestamp, pose: input.pose, target: $0,
                        visible: update.quality.stable >= 24 && input.visible($0, tolerance: 0.15), exposureOK: exposureOK)
                } ?? false)
                let direction = targetPoint.map { input.pose.position - $0 } ?? Vec3.zero
                let angle = Int((atan2(direction.x, direction.z) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
                do {
                    self.sequence += 1
                    let preview = try self.store.append(frame: frame, sequence: self.sequence,
                        photoAngle: photo ? angle : nil, zoneID: zone?.id, orientation: orientation)
                    if preview != nil, let targetPoint {
                        self.photoCount += 1
                        self.selector.commit(timestamp: frame.timestamp, pose: input.pose, target: targetPoint)
                    }
                    if self.sequence % 30 == 0 || preview != nil {
                        try self.store.checkpoint(roomPlanFile: nil, skipped: skipped)
                    }
                    completion(.success(PipelineResult(surface: update, pose: input.pose, photo: preview,
                        savedFrames: self.store.frameCount, duration: Date.timeIntervalSinceReferenceDate - start,
                        reducedDetail: self.detailStride > 1)))
                } catch { completion(.failure(error)) }
            }
        }
    }

    func finish(roomFile: String?, skipped: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                guard let root = self.store.root else { throw CocoaError(.fileNoSuchFile) }
                let url = root.appendingPathComponent("exports/fused-surface.ply")
                try self.fusion.plyData(volume: self.volume).write(to: url, options: .atomic)
                try self.store.close(roomPlanFile: roomFile, skipped: skipped)
                completion(.success(url))
            } catch { completion(.failure(error)) }
        }
    }
    func resetStability() { queue.async { self.selector.resetStability() } }
}

enum CaptureError: LocalizedError {
    case noDepth
    var errorDescription: String? { "Nog geen bruikbare LiDAR-diepte en confidence." }
}

/// The AR delegate may run off-main. This gate prevents retaining a growing
/// number of ARFrames while the UI or storage is busy.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }; busy = true; return true
    }
    func release() { lock.lock(); busy = false; lock.unlock() }
}
