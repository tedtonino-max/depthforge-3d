import ARKit
import Combine
import RoomPlan
import SceneKit
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
    @Published var captureProfile: CaptureProfile = .maximumGeometry
    @Published var captureTarget: CaptureTarget = .object
    @Published var showShareSheet = false
    @Published private(set) var shareURL: URL?

    let sceneView = ARSCNView(frame: .zero)
    private let store = DepthProjectStore()
    private let fusion = GeometryFusion()
    private var roomSession: RoomCaptureSession?
    private var lastSavedTimestamp: TimeInterval = 0
    private var lastHeatmapTimestamp: TimeInterval = 0
    private var lastConfigurationCheckTimestamp: TimeInterval = 0
    private var sequence = 0
    private var completedRoom: CapturedRoom?
    private let accelerator = MetalFusionAccelerator()
    private let liveMeshOverlay = LiveMeshOverlay()

    override init() {
        super.init()
        sceneView.session.delegate = self
        sceneView.delegate = liveMeshOverlay
        sceneView.automaticallyUpdatesLighting = true
        metalEnabled = accelerator.isAvailable
    }

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            state = .failed("Dit apparaat ondersteunt geen LiDAR sceneDepth.")
            return
        }
        do {
            scanRoot = try store.beginNewScan()
            fusion.reset(); projectedCells = []; quality = QualitySummary(); sequence = 0; completedRoom = nil; roomPlanAvailable = false; shareURL = nil; lastSavedTimestamp = 0; lastHeatmapTimestamp = 0; lastConfigurationCheckTimestamp = 0
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { configuration.sceneReconstruction = .meshWithClassification }
            configuration.planeDetection = [.horizontal, .vertical]
            sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            let room = RoomCaptureSession(arSession: sceneView.session)
            room.delegate = self
            room.run(configuration: .init())
            roomSession = room
            ensureGeometryDepthConfiguration()
            state = .recording
            statusLine = captureTarget == .object
                ? "Plaats het voorwerp volledig binnen het middenkader."
                : "LiDAR wordt gestart; richt op een wand of object met detail."
        } catch { state = .failed("Lokale opslag kon niet worden voorbereid: \(error.localizedDescription)") }
    }

    func pauseOrResume() {
        switch state {
        case .recording:
            // Keep RoomPlan's shared session alive; ending it here would finalize
            // the RoomPlan result instead of merely pausing raw-frame acceptance.
            state = .paused; statusLine = "Opname gepauzeerd; bestaande data is veilig op schijf."
        case .paused:
            state = .recording; statusLine = "Opname hervat. Scan zwakke gebieden vanaf een andere hoek."
        default: break
        }
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
            self.quality = self.fusion.integrate(frame: frame, sampleStride: self.captureProfile.sampleStride, captureTarget: self.captureTarget)
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
                let orientation = self.sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
                self.projectedCells = self.fusion.projectedCells(camera: frame.camera, viewport: self.sceneView.bounds.size, orientation: orientation)
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
            guard let self else { return }
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
