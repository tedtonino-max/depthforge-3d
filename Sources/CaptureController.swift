import ARKit
import Combine
import RoomPlan
import SceneKit
import simd
import SwiftUI

@MainActor
final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var quality = QualitySummary()
    @Published private(set) var projectedCells: [ProjectedQualityCell] = []
    @Published private(set) var statusLine = "Klaar voor een LiDAR-scan"
    @Published private(set) var scanRoot: URL?
    @Published private(set) var metalEnabled = false
    @Published private(set) var roomPlanAvailable = false
    @Published private(set) var liveMeshPasses = 0
    @Published private(set) var liveMeshTriangles = 0
    @Published var captureProfile: CaptureProfile = .maximumGeometry
    @Published var captureTarget: CaptureTarget = .object
    @Published private(set) var objectScanVolume: ObjectScanVolume?
    @Published var showShareSheet = false
    @Published private(set) var shareURL: URL?

    let sceneView = ARSCNView(frame: .zero)
    private let store = DepthProjectStore()
    private let fusion = GeometryFusion()
    private var roomSession: RoomCaptureSession?
    private var lastSavedTimestamp: TimeInterval = 0
    private var lastHeatmapTimestamp: TimeInterval = 0
    private var lastPreviewMeshTimestamp: TimeInterval = 0
    private var lastConfigurationCheckTimestamp: TimeInterval = 0
    private var sequence = 0
    private var completedRoom: CapturedRoom?
    private let accelerator = MetalFusionAccelerator()
    private let liveMeshOverlay = LiveMeshOverlay()
    private let progressiveMesh = ProgressiveDepthMeshOverlay()
    private let objectVolumeOverlay = ObjectScanVolumeOverlay()

    override init() {
        super.init()
        sceneView.session.delegate = self
        sceneView.delegate = liveMeshOverlay
        sceneView.automaticallyUpdatesLighting = true
        progressiveMesh.attach(to: sceneView.scene.rootNode)
        objectVolumeOverlay.attach(to: sceneView.scene.rootNode)
        metalEnabled = accelerator.isAvailable
    }

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            state = .failed("Dit apparaat ondersteunt geen LiDAR sceneDepth.")
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { configuration.sceneReconstruction = .meshWithClassification }
        configuration.planeDetection = [.horizontal, .vertical]
        liveMeshOverlay.displaysNativeMesh = captureTarget == .room
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        if captureTarget == .object {
            progressiveMesh.reset()
            objectVolumeOverlay.reset()
            objectScanVolume = nil
            liveMeshPasses = 0
            liveMeshTriangles = 0
            state = .framing
            statusLine = "Plaats en verschuif het scanvak. Er wordt nog niets opgeslagen."
            return
        }
        beginRecording()
    }

    func confirmObjectVolume() {
        guard state == .framing, objectScanVolume != nil else {
            statusLine = "Teken eerst een cirkel op de vloer rond het voorwerp."
            return
        }
        objectVolumeOverlay.setRecording(true)
        beginRecording()
    }

    func beginObjectVolume(at point: CGPoint) {
        guard state == .framing, let ground = groundPoint(at: point) else {
            statusLine = "Richt eerst op een zichtbare vloer en teken de cirkel opnieuw."
            return
        }
        let volume = ObjectScanVolume(center: ground)
        objectScanVolume = volume
        objectVolumeOverlay.show(volume, isRecording: false)
        statusLine = "Scanvolume geplaatst. Sleep verder om de cirkel rond het voorwerp te zetten."
    }

    func resizeObjectVolume(to point: CGPoint) {
        guard state == .framing,
              let current = objectScanVolume,
              let ground = groundPoint(at: point) else { return }
        let delta = ground - current.center
        objectScanVolume = current.resized(to: simd_length(SIMD2(delta.x, delta.z)))
        if let objectScanVolume { objectVolumeOverlay.show(objectScanVolume, isRecording: false) }
    }

    func clearObjectVolume() {
        guard state == .framing else { return }
        objectScanVolume = nil
        objectVolumeOverlay.reset()
        statusLine = "Teken een nieuwe cirkel op de vloer rond het voorwerp."
    }

    private func beginRecording() {
        do {
            scanRoot = try store.beginNewScan(objectVolume: captureTarget == .object ? objectScanVolume : nil)
            fusion.reset(); progressiveMesh.reset(); projectedCells = []; quality = QualitySummary(); sequence = 0; completedRoom = nil; roomPlanAvailable = false; shareURL = nil; liveMeshPasses = 0; liveMeshTriangles = 0; lastSavedTimestamp = 0; lastHeatmapTimestamp = 0; lastPreviewMeshTimestamp = 0; lastConfigurationCheckTimestamp = 0
            // For object mode the visible mesh must be the measured progressive
            // depth mesh, not ARKit's coarse room reconstruction.
            liveMeshOverlay.displaysNativeMesh = captureTarget == .room
            if captureTarget == .room { beginRoomCapture() }
            ensureGeometryDepthConfiguration()
            state = .recording
            statusLine = captureTarget == .object
                ? "Scanvolume actief. Beweeg rustig om het voorwerp vanuit nieuwe hoeken te meten."
                : "LiDAR wordt gestart; richt op een wand of object met detail."
        } catch { state = .failed("Lokale opslag kon niet worden voorbereid: \(error.localizedDescription)") }
    }

    func pauseOrResume() {
        switch state {
        case .recording:
            // A pause must freeze the visual mesh and all incoming frames, not merely
            // skip the PLY writer. RoomPlan is restarted on resume for room scans.
            state = .paused
            roomSession?.stop(pauseARSession: true)
            roomSession = nil
            sceneView.session.pause()
            statusLine = "Scan is gepauzeerd. Mesh en opname staan stil."
        case .paused:
            if let configuration = sceneView.session.configuration {
                sceneView.session.run(configuration, options: [])
            }
            if captureTarget == .room { beginRoomCapture() }
            state = .recording
            statusLine = "Opname hervat. Beweeg vanuit een nieuwe hoek."
        default: break
        }
    }

    func returnToStart() {
        roomSession?.stop(pauseARSession: true)
        roomSession = nil
        sceneView.session.pause()
        projectedCells = []
        quality = QualitySummary()
        progressiveMesh.reset()
        objectVolumeOverlay.reset()
        objectScanVolume = nil
        liveMeshPasses = 0
        liveMeshTriangles = 0
        state = .idle
        statusLine = "Kies eerst wat je wilt scannen."
    }

    func finish() {
        guard state == .recording || state == .paused else { return }
        state = .finishing; statusLine = "RoomPlan en de gefuseerde point cloud worden lokaal afgerond…"
        roomSession?.stop(pauseARSession: true)
        if roomSession == nil { finalize(room: nil) }
    }

    func exportAndShare() {
        guard let root = scanRoot else { return }
        do {
            let ply = root.appendingPathComponent("exports/\(root.lastPathComponent).ply")
            try fusion.plyData().write(to: ply, options: .atomic)
            shareURL = ply; showShareSheet = true
            statusLine = "PLY-export gemaakt; de volledige ruwe scanmap blijft lokaal beschikbaar."
        } catch { statusLine = "Export mislukt: \(error.localizedDescription)" }
    }

    private func finalize(room: CapturedRoom?) {
        do {
            var roomFile: String?
            if let room, let root = scanRoot {
                let url = root.appendingPathComponent("room/room.usdz")
                try room.export(to: url, exportOptions: .parametric)
                roomFile = "room/room.usdz"; roomPlanAvailable = true
            }
            if let root = scanRoot { try fusion.plyData().write(to: root.appendingPathComponent("exports/fused-live.ply"), options: .atomic) }
            try store.close(roomPlanFile: roomFile)
            state = .finished
            statusLine = "Opname veilig opgeslagen. Export bevat ruwe frames, poses, calibratie en PLY."
        } catch { state = .failed("Afronden mislukt: \(error.localizedDescription)") }
    }

    private func beginRoomCapture() {
        let room = RoomCaptureSession(arSession: sceneView.session)
        room.delegate = self
        room.run(configuration: .init())
        roomSession = room
    }

    /// RoomPlan can replace the shared AR session configuration when it begins a capture.
    /// Reapply required semantics without resetting tracking, then verify again during capture.
    private func ensureGeometryDepthConfiguration() {
        guard let current = sceneView.session.configuration as? ARWorldTrackingConfiguration,
              let updated = current.copy() as? ARWorldTrackingConfiguration else { return }
        var changed = false
        if !updated.frameSemantics.contains(.sceneDepth) {
            updated.frameSemantics.insert(.sceneDepth)
            changed = true
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth), !updated.frameSemantics.contains(.smoothedSceneDepth) {
            updated.frameSemantics.insert(.smoothedSceneDepth)
            changed = true
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification), !updated.sceneReconstruction.contains(.meshWithClassification) {
            updated.sceneReconstruction.insert(.meshWithClassification)
            changed = true
        }
        if changed { sceneView.session.run(updated, options: []) }
    }
}

extension CaptureController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording, case .normal = frame.camera.trackingState else { return }
            let timestamp = frame.timestamp
            if timestamp - self.lastConfigurationCheckTimestamp >= 0.5 {
                self.lastConfigurationCheckTimestamp = timestamp
                self.ensureGeometryDepthConfiguration()
            }
            guard frame.sceneDepth != nil else {
                self.statusLine = "LiDAR-diepte wordt voorbereid; richt op een wand met structuur…"
                return
            }
            guard timestamp - self.lastSavedTimestamp >= self.captureProfile.frameInterval else { return }
            self.lastSavedTimestamp = timestamp; self.sequence += 1
            let orientation = self.sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
            let viewport = self.sceneView.bounds.size
            self.quality = self.fusion.integrate(frame: frame, sampleStride: self.captureProfile.sampleStride, captureTarget: self.captureTarget, objectVolume: self.objectScanVolume)
            if self.captureTarget == .object,
               timestamp - self.lastPreviewMeshTimestamp >= 0.8 {
                self.lastPreviewMeshTimestamp = timestamp
                let nextPass = self.liveMeshPasses + 1
                if let patch = self.progressiveMesh.appendMeasuredPatch(
                    from: frame,
                    captureTarget: self.captureTarget,
                    profile: self.captureProfile,
                    pass: nextPass,
                    objectVolume: self.objectScanVolume
                ) {
                    self.liveMeshPasses = patch.pass
                    self.liveMeshTriangles = patch.triangles
                }
            }
            self.store.append(frame: frame, sequence: self.sequence) { result in
                Task { @MainActor [weak self] in
                    if case .failure(let error) = result {
                        self?.state = .failed("Opslaan mislukt: \(error.localizedDescription)")
                        self?.statusLine = "Opslaan mislukt: \(error.localizedDescription)"
                    }
                }
            }
            if timestamp - self.lastHeatmapTimestamp > 0.5 {
                self.lastHeatmapTimestamp = timestamp
                self.projectedCells = self.fusion.projectedCells(camera: frame.camera, viewport: viewport, orientation: orientation)
                self.statusLine = self.quality.advice.rawValue
                try? self.store.checkpoint(roomPlanFile: self.roomPlanAvailable ? "room/room.usdz" : nil)
            }
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            if case .normal = camera.trackingState { return }
            self.statusLine = "Tracking is onvoldoende; opname wacht op stabiele positie."
        }
    }

    private func groundPoint(at point: CGPoint) -> SIMD3<Float>? {
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]
        for target in targets {
            guard let query = sceneView.raycastQuery(from: point, allowing: target, alignment: .horizontal),
                  let result = sceneView.session.raycast(query).first else { continue }
            let transform = result.worldTransform
            return SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }
        return nil
    }
}

extension CaptureController: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            guard self.captureTarget == .room else { return }
            switch instruction {
            case .moveCloseToWall: self.statusLine = "Ga 20–40 cm dichterbij voor meer detail."
            case .moveAwayFromWall: self.statusLine = "Ga iets naar achteren zodat het oppervlak volledig zichtbaar is."
            case .slowDown: self.statusLine = "Beweeg rustiger voor stabiele diepte en scherpe texturen."
            case .turnOnLight: self.statusLine = "Meer licht helpt de RGB-texturen en tracking."
            case .lowTexture: self.statusLine = "Richt op een hoek, rand of object met meer visueel detail."
            case .normal: break
            @unknown default: break
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .finishing else { return }
            if let error { self.statusLine = "RoomPlan niet beschikbaar: \(error.localizedDescription)"; self.finalize(room: nil); return }
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.finalize(room: room)
            } catch {
                self.statusLine = "RoomPlan-resultaat kon niet worden opgebouwd; ruwe scan blijft behouden."
                self.finalize(room: nil)
            }
        }
    }
}
