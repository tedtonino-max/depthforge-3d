import ARKit
import Combine
import ImageIO
import RoomPlan
import SceneKit
import simd
import SwiftUI

@MainActor
final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var quality = SurfaceQuality()
    @Published private(set) var statusLine = "Kies wat je wilt scannen"
    @Published private(set) var scanRoot: URL?
    @Published private(set) var objectScanVolume: ObjectScanVolume?
    @Published private(set) var detailZone: DetailZone?
    @Published private(set) var pendingZone: DetailZone?
    @Published private(set) var choosingDetail = false
    @Published private(set) var photos: [PhotoPreview] = []
    @Published private(set) var savedFrames = 0
    @Published private(set) var resourceNotice: String?
    @Published private(set) var roomNotice: String?
    @Published var captureProfile: CaptureProfile = .maximumGeometry
    @Published var selectedAreaOnly = false
    @Published var brushRadius: Float = 0.08
    @Published private(set) var meshFaces = 0
    private var lastBrushTime = -Double.infinity
    @Published var captureTarget: CaptureTarget = .object
    @Published var showShareSheet = false
    @Published private(set) var shareURL: URL?
    @Published var showSurface = true {
        didSet {
            if !showSurface { surfaceOverlay.hide() }
            else if let lastUpdate, let lastPose, trackingReady {
                surfaceOverlay.show(lastUpdate, pose: lastPose, volume: objectScanVolume)
                if let frame = sceneView.session.currentFrame { surfaceOverlay.refreshVisibility(frame) }
            }
        }
    }

    let sceneView = ARSCNView(frame: .zero)
    private let pipeline = CapturePipeline()
    nonisolated private let gate = FrameGate()
    private let surfaceOverlay = FusedSurfaceOverlay()
    private let volumeOverlay = ObjectScanVolumeOverlay()
    private let zoneOverlay = DetailZoneOverlay()
    private var roomSession: RoomCaptureSession?
    private var lastSaved: Double = 0
    private var lastConfigurationCheck: Double = 0
    private var interval: Double = 0.17
    private var generation = UUID()
    private var trackingReady = false
    private var finishStarted = false
    private var skipped = 0
    private var readyFrames = 0
    private var lastPose: CameraPose?
    private var lastUpdate: SurfaceUpdate?
    private var finalizeTask: Task<Void, Never>?

    override init() {
        super.init()
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = false
        surfaceOverlay.attach(to: sceneView.scene.rootNode)
        volumeOverlay.attach(to: sceneView.scene.rootNode)
        zoneOverlay.attach(to: sceneView.scene.rootNode)
    }

    func start() {
        guard state == .idle else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            state = .failed("Dit apparaat ondersteunt geen LiDAR-scans."); return
        }
        generation = UUID(); trackingReady = false; finishStarted = false
        photos = []; savedFrames = 0; meshFaces = 0; quality = SurfaceQuality(); roomNotice = nil
        resourceNotice = nil; objectScanVolume = nil; detailZone = nil; pendingZone = nil
        choosingDetail = false; shareURL = nil; scanRoot = nil; readyFrames = 0
        surfaceOverlay.clear(); volumeOverlay.reset(); zoneOverlay.clear()
        lastSaved = 0; skipped = 0; lastUpdate = nil; lastPose = nil
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth]
        configuration.planeDetection = [.horizontal, .vertical]
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        if captureTarget == .object {
            state = .framing; statusLine = "Teken een cirkel op de vloer rond het voorwerp"
        } else { beginRecording() }
    }

    func beginObjectVolume(at point: CGPoint) {
        guard state == .framing, let result = raycast(point, alignment: .horizontal) else {
            statusLine = "Richt op een zichtbare vloer en teken opnieuw"; return
        }
        objectScanVolume = ObjectScanVolume(center: CameraPose(result.worldTransform).position)
        if let objectScanVolume { volumeOverlay.show(objectScanVolume, isRecording: false) }
        statusLine = "Sleep de cirkel tot het voorwerp erin past"
    }
    func resizeObjectVolume(to point: CGPoint) {
        guard state == .framing, let current = objectScanVolume,
              let frame = sceneView.session.currentFrame else { return }
        // Intersect every drag with the SAME floor, rather than jumping between
        // estimated planes as a finger crosses furniture.
        let size = sceneView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let orientation = sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
        let inverse = frame.displayTransform(for: orientation, viewportSize: size).inverted()
        let imagePoint = CGPoint(x: point.x / size.width, y: point.y / size.height).applying(inverse)
        let k = frame.camera.intrinsics, resolution = frame.camera.imageResolution
        let local = Vec3((Float(imagePoint.x * resolution.width) - k.columns.2.x) / k.columns.0.x,
                         -(Float(imagePoint.y * resolution.height) - k.columns.2.y) / k.columns.1.y, -1)
        let pose = CameraPose(frame.camera.transform), ray = pose.rotate(local)
        guard abs(ray.y) > 0.01 else { return }
        let t = (current.y - pose.position.y) / ray.y
        guard t > 0 else { return }
        let p = pose.position + ray * t
        objectScanVolume = current.resized(to: length(Vec3(p.x - current.x, 0, p.z - current.z)))
        if let objectScanVolume { volumeOverlay.show(objectScanVolume, isRecording: false) }
    }
    func setVolumeHeight(_ height: Float) {
        guard state == .framing, var volume = objectScanVolume else { return }
        volume.height = min(3, max(0.2, height)); objectScanVolume = volume
        volumeOverlay.show(volume, isRecording: false)
    }
    func clearObjectVolume() {
        guard state == .framing else { return }
        objectScanVolume = nil; volumeOverlay.reset(); statusLine = "Teken opnieuw op de vloer"
    }
    func confirmObjectVolume() {
        guard state == .framing, objectScanVolume != nil else { return }
        volumeOverlay.setRecording(true); beginRecording()
    }
    private func beginRecording() {
        state = .preparing; statusLine = "Opname wordt voorbereid"
        let token = generation
        pipeline.begin(volume: captureTarget == .object ? objectScanVolume : nil, device: UIDevice.current.model) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let root):
                    self.scanRoot = root
                    if self.captureTarget == .room && !self.selectedAreaOnly { self.beginRoomCapture() }
                    self.ensureDepthConfiguration()
                    self.state = .recording
                    self.choosingDetail = self.captureTarget == .room && self.selectedAreaOnly
                    self.statusLine = self.choosingDetail ? ScanAdvice.focus.rawValue : ScanAdvice.holdSteady.rawValue
                case .failure(let error): self.fail(error)
                }
            }
        }
    }

    func chooseDetail() {
        guard state == .recording else { return }
        choosingDetail = true; pendingZone = nil; readyFrames = 0
        statusLine = "Schilder met je vinger over het gewenste gebied"
    }
    func selectDetail(at point: CGPoint) {
        guard choosingDetail, state == .recording, let frame = sceneView.session.currentFrame,
              frame.timestamp - lastBrushTime > 0.04 else { return }
        lastBrushTime = frame.timestamp
        guard let zone = DepthSelection.zone(frame: frame, point: point, viewport: sceneView.bounds.size,
            orientation: sceneView.window?.windowScene?.interfaceOrientation ?? .portrait) else {
            statusLine = "Dit punt heeft nog geen betrouwbare diepte; kies een naburig oppervlak"; return
        }
        if captureTarget == .object, objectScanVolume?.contains(zone.center) != true {
            statusLine = "Kies een detail binnen het scanvolume"; return
        }
        var painted = pendingZone ?? zone
        if painted.brush.contains(where: { length($0.center - zone.center) < brushRadius * 0.45 }) { return }
        guard painted.brush.count < 128 else { statusLine = "Gebied gemarkeerd; start de scan of wis de selectie"; return }
        painted.brush.append(DetailDab(center: zone.center, normal: zone.normal, radius: brushRadius))
        pendingZone = painted; zoneOverlay.show(painted, confirmed: false)
        statusLine = "Geschilderd gebied geselecteerd"
    }
    func confirmDetail() {
        guard let zone = pendingZone else { return }
        detailZone = zone; pendingZone = nil; choosingDetail = false; readyFrames = 0
        quality = SurfaceQuality(); zoneOverlay.show(zone, confirmed: true)
        statusLine = "Houd de detailzone in beeld en beweeg daarna zijwaarts"
    }
    func clearPaint() {
        pendingZone = nil; zoneOverlay.clear(); statusLine = "Schilder opnieuw over het gewenste gebied"
    }
    func cancelDetail() {
        if captureTarget == .room && selectedAreaOnly && detailZone == nil {
            statusLine = "Markeer eerst een gebied om deze scan te starten"; return
        }
        choosingDetail = false; pendingZone = nil
        if let zone = detailZone { zoneOverlay.show(zone, confirmed: true) } else { zoneOverlay.clear() }
        statusLine = captureTarget == .room && detailZone == nil ? ScanAdvice.focus.rawValue : ScanAdvice.holdSteady.rawValue
    }

    func pauseOrResume() {
        if state == .recording {
            state = .paused; sceneView.session.pause(); pipeline.resetStability()
            statusLine = "Opname gepauzeerd"
        } else if state == .paused || state == .review {
            if let config = sceneView.session.configuration { sceneView.session.run(config) }
            state = .recording; readyFrames = 0
            statusLine = "Ga verder vanuit een nieuwe hoek"
        }
    }
    func review() {
        guard state == .recording || state == .paused else { return }
        guard !(captureTarget == .room && selectedAreaOnly && detailZone == nil) else { return }
        state = .review; choosingDetail = false; sceneView.session.pause(); pipeline.resetStability()
        statusLine = "Controleer het bevestigde oppervlak; ontbrekend detail blijft open"
        if let lastUpdate, let lastPose, showSurface {
            surfaceOverlay.show(lastUpdate, pose: lastPose, volume: objectScanVolume)
            if let frame = sceneView.session.currentFrame { surfaceOverlay.refreshVisibility(frame) }
        }
    }
    func finish() {
        guard state == .review || state == .paused || state == .recording else { return }
        state = .finishing; statusLine = "Scan en foto's worden opgeslagen"
        sceneView.session.pause()
        if let roomSession {
            roomSession.stop(pauseARSession: true)
            let token = generation
            finalizeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.generation == token, !self.finishStarted else { return }
                self.roomNotice = "RoomPlan gaf geen resultaat; LiDAR en foto's zijn wel bewaard."
                self.finalize(room: nil)
            }
        } else { finalize(room: nil) }
    }
    private func finalize(room: CapturedRoom?) {
        guard !finishStarted, state == .finishing else { return }
        finishStarted = true; finalizeTask?.cancel()
        var roomFile: String?
        if let room, let root = scanRoot {
            do {
                try room.export(to: root.appendingPathComponent("room/room.usdz"), exportOptions: .parametric)
                roomFile = "room/room.usdz"
            } catch { roomNotice = "RoomPlan-export mislukt; LiDAR en foto's worden wel bewaard." }
        }
        let token = generation
        pipeline.finish(roomFile: roomFile, skipped: skipped) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let url): self.shareURL = url; self.state = .finished; self.statusLine = "Scan lokaal opgeslagen"
                case .failure(let error): self.fail(error)
                }
            }
        }
    }
    func exportAndShare() { if shareURL != nil { showShareSheet = true } }
    func returnToStart() {
        guard state == .finished || state == .framing || state == .idle || isFailed else { return }
        generation = UUID(); finalizeTask?.cancel()
        roomSession?.stop(pauseARSession: true); roomSession = nil; sceneView.session.pause()
        surfaceOverlay.clear(); volumeOverlay.reset(); zoneOverlay.clear(); state = .idle
    }
    private var isFailed: Bool { if case .failed = state { return true }; return false }
    private func fail(_ error: Error) {
        state = .failed(error.localizedDescription); sceneView.session.pause()
        statusLine = error.localizedDescription; surfaceOverlay.hide()
    }
    private func beginRoomCapture() {
        let room = RoomCaptureSession(arSession: sceneView.session)
        room.delegate = self; roomSession = room; room.run(configuration: .init())
    }
    private func ensureDepthConfiguration() {
        guard let current = sceneView.session.configuration as? ARWorldTrackingConfiguration,
              !current.frameSemantics.contains(.sceneDepth),
              let updated = current.copy() as? ARWorldTrackingConfiguration else { return }
        updated.frameSemantics.insert(.sceneDepth)
        sceneView.session.run(updated)
    }
    private func raycast(_ point: CGPoint, alignment: ARRaycastQuery.TargetAlignment) -> ARRaycastResult? {
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]
        for target in targets {
            if let query = sceneView.raycastQuery(from: point, allowing: target, alignment: alignment),
               let result = sceneView.session.raycast(query).first { return result }
        }
        return nil
    }
    private var imageOrientation: CGImagePropertyOrientation {
        switch sceneView.window?.windowScene?.interfaceOrientation ?? .portrait {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }

    private func receive(_ frame: ARFrame) {
        guard state == .recording, case .normal = frame.camera.trackingState else { gate.release(); return }
        trackingReady = true
        if choosingDetail { gate.release(); return }
        if captureTarget == .room && selectedAreaOnly && detailZone == nil { gate.release(); return }
        if showSurface { surfaceOverlay.refreshVisibility(frame) }
        if frame.timestamp - lastConfigurationCheck > 1 {
            lastConfigurationCheck = frame.timestamp; ensureDepthConfiguration()
        }
        guard frame.sceneDepth != nil else {
            statusLine = "LiDAR wordt voorbereid; richt op een herkenbaar oppervlak"; gate.release(); return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            pauseOrResume(); resourceNotice = "iPad te warm; laat hem afkoelen voor je hervat"; gate.release(); return
        }
        let desired = max(captureProfile.frameInterval, thermal == .serious ? 0.5 : interval)
        guard frame.timestamp - lastSaved >= desired else { gate.release(); return }
        if frame.timestamp - lastSaved > desired * 1.8 && lastSaved > 0 { skipped += 1 }
        lastSaved = frame.timestamp
        let token = generation, selectedZone = detailZone?.id
        pipeline.process(frame: frame, target: captureTarget, zone: detailZone, selectionOnly: captureTarget == .room && selectedAreaOnly,
            stride: thermal == .serious ? 4 : captureProfile.sampleStride,
            orientation: imageOrientation, skipped: skipped) { [weak self, gate] result in
            Task { @MainActor in
                defer { gate.release() }
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let output):
                    self.savedFrames = output.savedFrames
                    if let photo = output.photo { self.photos.append(photo) }
                    self.interval = min(1, max(self.captureProfile.frameInterval, output.duration * 1.2))
                    self.resourceNotice = output.surface.quality.capacityReached
                        ? "Scankaart vol; bestaande geometrie wordt nog verfijnd"
                        : (output.duration > 0.25 || output.surface.quality.limited || output.reducedDetail || thermal == .serious
                           ? "Lager opnametempo om camera en opslag soepel te houden" : nil)
                    guard selectedZone == self.detailZone?.id else { return }
                    self.quality = output.surface.quality
                    self.meshFaces = output.surface.triangles.count / 3
                    self.lastUpdate = output.surface; self.lastPose = output.pose
                    if self.showSurface, self.trackingReady, self.state == .recording {
                        self.surfaceOverlay.show(output.surface, pose: output.pose, volume: self.objectScanVolume)
                        if let current = self.sceneView.session.currentFrame {
                            self.surfaceOverlay.refreshVisibility(current)
                        }
                    }
                    guard self.state == .recording, self.trackingReady, !self.choosingDetail else { return }

                    self.readyFrames = self.quality.advice == .ready ? self.readyFrames + 1 : 0
                    self.statusLine = self.quality.advice == .ready && self.readyFrames < 3
                        ? ScanAdvice.holdSteady.rawValue : self.quality.advice.rawValue
                case .failure(let error):
                    if error is CaptureError { self.statusLine = error.localizedDescription }
                    else { self.fail(error) }
                }
            }
        }
    }
}

extension CaptureController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard gate.take() else { return }
        Task { @MainActor [weak self, gate] in
            guard let self else { gate.release(); return }; self.receive(frame)
        }
    }
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording || self.state == .framing else { return }
            if case .normal = camera.trackingState {
                self.trackingReady = true; self.readyFrames = 0
                self.statusLine = self.state == .framing ? "Teken een cirkel op de vloer" : "Tracking hersteld; houd het gebied even in beeld"
                return
            }
            self.trackingReady = false; self.readyFrames = 0; self.surfaceOverlay.hide(); self.pipeline.resetStability()
            switch camera.trackingState {
            case .limited(.initializing): self.statusLine = "Houd de iPad rustig terwijl tracking start"
            case .limited(.excessiveMotion): self.statusLine = "Beweeg langzamer; de opname wacht even"
            case .limited(.insufficientFeatures): self.statusLine = "Richt kort op een rand of herkenbare structuur"
            case .limited(.relocalizing): self.statusLine = "Tracking herstelt; houd de iPad bij je scan"
            case .notAvailable: self.statusLine = "Tracking tijdelijk niet beschikbaar"
            default: self.statusLine = "Wacht op stabiele tracking"
            }
        }
    }
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            if self?.state == .recording { self?.pauseOrResume() }
        }
    }
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.fail(error) }
    }
}

extension CaptureController: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.roomSession === session, self.state == .finishing, !self.finishStarted else { return }
            let token = self.generation
            if let error { self.roomNotice = "RoomPlan: \(error.localizedDescription)"; self.finalize(room: nil); return }
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                guard self.generation == token else { return }; self.finalize(room: room)
            } catch {
                self.roomNotice = "RoomPlan kon niet afronden; de LiDAR-scan blijft behouden."
                self.finalize(room: nil)
            }
        }
    }
}
