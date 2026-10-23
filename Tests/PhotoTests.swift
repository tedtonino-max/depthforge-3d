import XCTest
@testable import DepthForgeCore

final class PhotoTests: XCTestCase {
    func testPhotoRequiresStableVisibleWellExposedNewAngle() {
        var selector = PhotoSelector()
        let pose = CameraPose(), target = Vec3(0, 0, -1)
        for i in 0...10 {
            XCTAssertFalse(selector.candidate(timestamp: Double(i) * 0.2, pose: pose,
                target: target, visible: false, exposureOK: true))
        }
        for i in 11...20 {
            XCTAssertFalse(selector.candidate(timestamp: Double(i) * 0.2, pose: pose,
                target: target, visible: true, exposureOK: false))
        }
        var accepted = false
        for i in 21...30 {
            accepted = selector.candidate(timestamp: Double(i) * 0.2, pose: pose,
                target: target, visible: true, exposureOK: true) || accepted
        }
        XCTAssertTrue(accepted)
        selector.commit(timestamp: 6, pose: pose, target: target)
        for i in 31...50 {
            XCTAssertFalse(selector.candidate(timestamp: Double(i) * 0.2, pose: pose,
                target: target, visible: true, exposureOK: true))
        }
        var next = pose; next.position.x = 0.5
        for i in 51...60 {
            accepted = selector.candidate(timestamp: Double(i) * 0.2, pose: next,
                target: target, visible: true, exposureOK: true)
        }
        XCTAssertTrue(accepted)
    }

    func testTrackingGapOrMovementRestartsStability() {
        var selector = PhotoSelector()
        var pose = CameraPose()
        for i in 1...20 {
            pose.position.x += 0.02
            XCTAssertFalse(selector.candidate(timestamp: Double(i) * 0.2, pose: pose,
                target: Vec3(0, 0, -1), visible: true, exposureOK: true))
        }
        selector.resetStability()
        XCTAssertFalse(selector.candidate(timestamp: 20, pose: pose, target: Vec3(0, 0, -1), visible: true, exposureOK: true))
    }
}
