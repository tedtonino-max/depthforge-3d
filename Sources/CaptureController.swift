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
    @Published var showShareSheet = false
    @Published private(set) var shareURL: URL?

    let sceneView = ARSCNView(frame: .zero)
    private let store = DepthProjectStore()
    private let fusion = GeometryFusion()
    private var roomSession: RoomCaptureSession?
    private var lastSavedTimestamp: TimeInterval = 0
    private var lastHeatmapTimestamp: TimeInterval = 0
    private var sequence = 0
    private var completedRoom: CapturedRoom?
    private let accelerator = MetalFusionAccelerator()

    override init() {
        super.init()
        sceneView.session.delegate = self
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
            fusion.reset(); sequence = 0; completedRoom = nil; lastSavedTimestamp = 0; lastHeatmapTimestamp = 0
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { configuration.sceneReconstruction = .meshWithClassification }
            configuration.planeDetection = [.horizontal, .vertical]
            sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            let room = RoomCaptureSession(arSession: sceneView.session)
            room.delegate = self
            room.run(configuration: .init())
            roomSession = room
            state = .recording
            statusLine = "Leg eerst veel overlap vast; de kwaliteitslaag toont waar meer data nodig is."
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
}

extension CaptureController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording, case .normal = frame.camera.trackingState else { return }
            guard frame.sceneDepth != nil else {
                self.statusLine = "LiDAR-diepte wordt geïnitialiseerd…"
                return
            }
            let timestamp = frame.timestamp
            guard timestamp - self.lastSavedTimestamp >= 0.25 else { return } // preserves enough CPU headroom for tracking
            self.lastSavedTimestamp = timestamp; self.sequence += 1
            self.quality = self.fusion.integrate(frame: frame)
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
                self.projectedCells = self.fusion.projectedCells(camera: frame.camera, viewport: self.sceneView.bounds.size)
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
