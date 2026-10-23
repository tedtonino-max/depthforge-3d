import XCTest
@testable import DepthForgeCore

final class SurfaceTests: XCTestCase {
    let camera = DepthCamera(width: 64, height: 48, fx: 70, fy: 70, cx: 32, cy: 24)

    func plane(time: Double, pose: CameraPose = CameraPose(), z: Float = -1,
               confidence: UInt8 = 2, noise: Float = 0) -> DepthInput {
        var depths: [Float] = []
        for y in 0..<camera.height {
            for x in 0..<camera.width {
                let ray = pose.rotate(camera.unproject(x: x, y: y, depth: 1))
                let d = (z - pose.position.z) / ray.z
                // Deterministic sub-centimetre variation across independent frames.
                depths.append(d + sin(Float(x * 13 + y * 7) + Float(time) * 11) * noise)
            }
        }
        return DepthInput(timestamp: time, camera: camera, pose: pose, depths: depths,
            confidence: Array(repeating: confidence, count: depths.count),
            colors: Array(repeating: Vec3(90, 120, 150), count: depths.count), isObject: false,
            baseStride: 2, processingBudget: 10)
    }

    func testCameraAxesAndProjectionRoundTrip() {
        let top = camera.unproject(x: 32, y: 10, depth: 1)
        XCTAssertGreaterThan(top.y, 0)
        XCTAssertEqual(top.z, -1)
        XCTAssertEqual(camera.pixel(top)?.0, 32)
        XCTAssertEqual(camera.pixel(top)?.1, 10)
        let pose = CameraPose(right: Vec3(0, 0, -1), up: Vec3(0, 1, 0), back: Vec3(1, 0, 0), position: Vec3(2, 3, 4))
        XCTAssertLessThan(length(pose.local(pose.world(top)) - top), 0.00001)
        XCTAssertNil(camera.pixel(Vec3(0, 0, 1)))
    }

    func testOneFrameAndDuplicateTimestampNeverBecomeConsensus() {
        let fusion = SurfelFusion()
        let first = fusion.integrate(plane(time: 1))
        XCTAssertTrue(first.visibleSurfels.isEmpty)
        XCTAssertTrue(fusion.surfels.values.allSatisfy { $0.observations == 1 })
        _ = fusion.integrate(plane(time: 1))
        XCTAssertTrue(fusion.surfels.values.allSatisfy { $0.observations == 1 })
        XCTAssertFalse(String(decoding: fusion.plyData(volume: nil), as: UTF8.self).contains("element vertex 1\n"))
    }

    func testRepeatedNoisyPlaneRefinesOneSurfaceWithoutGrowingByPass() {
        let fusion = SurfelFusion()
        var result = fusion.integrate(plane(time: 1, noise: 0.003))
        for i in 2...10 { result = fusion.integrate(plane(time: Double(i), noise: 0.003)) }
        let early = fusion.surfels.count
        for i in 11...40 { result = fusion.integrate(plane(time: Double(i), noise: 0.003)) }
        XCTAssertGreaterThan(result.visibleSurfels.count, 100)
        XCTAssertLessThan(fusion.surfels.count, early * 2)
        let stable = fusion.surfels.values.filter(\.isStable)
        let rms = sqrt(stable.reduce(Float(0)) { $0 + pow($1.position.z + 1, 2) } / Float(stable.count))
        XCTAssertLessThan(rms, 0.002)
        XCTAssertTrue(stable.allSatisfy { $0.normal.z > 0.9 })
        XCTAssertEqual(result.quality.advice, .nextAngle)
    }

    func testChangedCameraDistanceDoesNotCorruptSurfaceConsistency() {
        let fusion = SurfelFusion()
        for i in 1...8 { _ = fusion.integrate(plane(time: Double(i))) }
        var pose = CameraPose(); pose.position.z = 0.35
        var result = fusion.integrate(plane(time: 9, pose: pose))
        for i in 10...20 { result = fusion.integrate(plane(time: Double(i), pose: pose)) }
        XCTAssertLessThan(result.quality.rmsResidual, 0.001)
        XCTAssertGreaterThan(result.quality.stable, 100)
        XCTAssertTrue(fusion.surfels.values.filter(\.isStable).allSatisfy { abs($0.position.z + 1) < 0.001 })
    }

    func testReadinessRequiresIndependentAngles() {
        var quality = SurfaceQuality(visible: 100, stable: 90, multipleAngles: 0, missing: 0,
                                     rmsResidual: 0.002, totalStable: 100, accepted: 100)
        XCTAssertEqual(quality.advice, .nextAngle)
        quality.multipleAngles = 80
        XCTAssertEqual(quality.advice, .ready)
        quality.missing = 60
        XCTAssertNotEqual(quality.advice, .ready)
        quality.missing = 0; quality.limited = true
        XCTAssertNotEqual(quality.advice, .ready)
        quality.limited = false; quality.rmsResidual = 0.025
        XCTAssertEqual(quality.advice, .improve)
    }

    func testAngleEvidenceComesFromCameraTranslationAroundSurface() {
        let fusion = SurfelFusion()
        for i in 1...8 { _ = fusion.integrate(plane(time: Double(i))) }
        var pose = CameraPose(); pose.position.x = 0.4
        for i in 9...20 { _ = fusion.integrate(plane(time: Double(i), pose: pose)) }
        XCTAssertGreaterThan(fusion.surfels.values.filter { $0.isStable && $0.hasAngles }.count, 50)
    }

    func testLowConfidenceInvalidDepthAndBackgroundCannotEnterObjectPLY() {
        let volume = ObjectScanVolume(center: Vec3(0, -0.2, -1), radius: 0.16, height: 0.4)
        let fusion = SurfelFusion()
        for i in 1...8 {
            var frame = plane(time: Double(i)); frame.objectVolume = volume; frame.isObject = true
            frame.depths[0] = .nan; frame.depths[1] = .infinity; frame.depths[2] = -1
            _ = fusion.integrate(frame)
        }
        XCTAssertGreaterThan(fusion.surfels.count, 0)
        XCTAssertTrue(fusion.surfels.values.allSatisfy { volume.contains($0.position) })
        let text = String(decoding: fusion.plyData(volume: volume), as: UTF8.self)
        let rows = text.components(separatedBy: "end_header\n")[1].split(separator: "\n")
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let values = row.split(separator: " ").compactMap { Float($0) }
            XCTAssertTrue(volume.contains(Vec3(values[0], values[1], values[2])))
            XCTAssertGreaterThanOrEqual(values[9], 4)
        }
        let weak = SurfelFusion()
        for i in 1...10 { _ = weak.integrate(plane(time: Double(i), confidence: 1)) }
        XCTAssertTrue(weak.surfels.isEmpty)
        XCTAssertFalse(volume.contains(Vec3(0, -0.201, -1)))
    }

    func testObjectWithoutConfirmedVolumeCapturesNothing() {
        let fusion = SurfelFusion()
        var frame = plane(time: 1); frame.isObject = true
        _ = fusion.integrate(frame)
        XCTAssertTrue(fusion.surfels.isEmpty)
    }

    func testThinLegsStaySeparateFromBackgroundAndDoNotBridgeEdges() {
        let fusion = SurfelFusion()
        for time in 1...12 {
            var frame = plane(time: Double(time), z: -2)
            frame.isObject = true
            frame.objectVolume = ObjectScanVolume(center: Vec3(0, -0.4, -1), radius: 0.42, height: 0.8)
            for y in 8..<42 {
                for x in [20, 21, 22, 40, 41, 42] {
                    frame.depths[y * camera.width + x] = 1 + sin(Float(time)) * 0.002
                }
            }
            _ = fusion.integrate(frame)
        }
        let stable = fusion.surfels.values.filter(\.isStable)
        XCTAssertGreaterThan(stable.filter { $0.position.x < -0.1 }.count, 10)
        XCTAssertGreaterThan(stable.filter { $0.position.x > 0.1 }.count, 10)
        XCTAssertTrue(stable.allSatisfy { abs($0.position.z + 1) < 0.01 })
        XCTAssertTrue(stable.allSatisfy { abs($0.position.x) > 0.1 })
    }

    func testRepeatedFreeSpaceContradictionReplacesOldSurfaceButOcclusionDoesNot() {
        let fusion = SurfelFusion()
        for i in 1...8 { _ = fusion.integrate(plane(time: Double(i))) }
        let original = Set(fusion.surfels.keys)
        for i in 9...16 { _ = fusion.integrate(plane(time: Double(i), z: -0.6)) }
        XCTAssertGreaterThan(Set(fusion.surfels.keys).intersection(original).count, original.count / 2)
        // A farther high-confidence surface is evidence the nearer one is gone.
        for i in 17...32 { _ = fusion.integrate(plane(time: Double(i), z: -2)) }
        XCTAssertLessThan(fusion.surfels.values.filter { $0.isStable && $0.position.z > -1.5 }.count, 10)
    }

    func testDetailDiskHasSurfaceOrientationAndIncreasesRoomSampling() {
        let zone = DetailZone(center: Vec3(0, 0, -1), normal: Vec3(0, 0, 1), radius: 0.25)
        XCTAssertTrue(zone.contains(Vec3(0.1, 0.1, -1.05)))
        XCTAssertFalse(zone.contains(Vec3(0, 0, -1.2)))
        XCTAssertFalse(zone.contains(Vec3(0.3, 0, -1)))
        let coarse = SurfelFusion(), detail = SurfelFusion()
        var frame = plane(time: 1); frame.baseStride = 4
        _ = coarse.integrate(frame)
        frame.detailZone = zone
        _ = detail.integrate(frame)
        let a = coarse.surfels.values.filter { zone.contains($0.position) }.count
        let b = detail.surfels.values.filter { zone.contains($0.position) }.count
        XCTAssertGreaterThan(b, a * 2)
    }

    func testCapacityRenderBudgetAndResetAreBounded() {
        let fusion = SurfelFusion(capacity: 80, renderLimit: 20)
        var result = fusion.integrate(plane(time: 1))
        for i in 2...10 { result = fusion.integrate(plane(time: Double(i))) }
        XCTAssertLessThanOrEqual(fusion.surfels.count, 80)
        XCTAssertLessThanOrEqual(result.visibleSurfels.count, 20)
        XCTAssertTrue(result.quality.capacityReached)
        XCTAssertNotEqual(result.quality.advice, .ready)
        fusion.reset()
        XCTAssertTrue(fusion.surfels.isEmpty)
        _ = fusion.integrate(plane(time: 1))
        XCTAssertFalse(fusion.surfels.isEmpty)
    }

    func testDeadlineCannotProduceReadyOrUnboundedWork() {
        let fusion = SurfelFusion()
        var frame = plane(time: 1); frame.processingBudget = 0
        let result = fusion.integrate(frame)
        XCTAssertTrue(result.quality.limited)
        XCTAssertNotEqual(result.quality.advice, .ready)
    }
}
