import simd
import XCTest
@testable import PuttPhysicsKit

final class LiDARDeviceProfileTests: XCTestCase {
    func testCorridorStaysSixMetersOnBallHoleOrthogonal() {
        XCTAssertEqual(PuttScanCorridor.orthogonalWidth, 6.0, accuracy: 1e-12)
        XCTAssertEqual(PuttScanCorridor.orthogonalHalfWidth, 3.0, accuracy: 1e-12)
        XCTAssertEqual(PuttScanCorridor.margins(for: .competition).lateralHalfWidth, 3.0, accuracy: 1e-12)
        XCTAssertEqual(PuttScanCorridor.margins(for: .tuning).lateralHalfWidth, 3.0, accuracy: 1e-12)
    }

    func testSixteenProKeepsLidarMetadataWithoutPathBias() {
        let profile = LiDARDeviceProfile.resolve(machineIdentifier: "iPhone17,1")
        XCTAssertEqual(profile.layout, .cameraBumpLeftBack)
        XCTAssertEqual(profile.productName, "iPhone 16 Pro")
        XCTAssertEqual(profile.fusionPathBiasMeters, 0, accuracy: 1e-12)
        let end = profile.pathEndXZ(
            cameraXZ: SIMD2<Double>(0, 0),
            cameraRightXZ: SIMD2<Double>(1, 0)
        )
        XCTAssertEqual(end.x, 0, accuracy: 1e-12)
        XCTAssertEqual(end.y, 0, accuracy: 1e-12)
    }

    func testSeventeenProKeepsLidarOffsetButNoPathBias() {
        let profile = LiDARDeviceProfile.resolve(machineIdentifier: "iPhone18,1")
        XCTAssertEqual(profile.layout, .plateauRightBack)
        XCTAssertEqual(profile.productName, "iPhone 17 Pro")
        XCTAssertLessThan(profile.lidarFromCameraImageRightMeters, 0)
        XCTAssertEqual(profile.fusionPathBiasMeters, 0, accuracy: 1e-12)
        XCTAssertTrue(profile.isInTargetBand(normalizedX: 0.5))
        XCTAssertEqual(profile.twistActionLabel(normalizedX: 0.5), "안정 유지")
        let end = profile.pathEndXZ(
            cameraXZ: SIMD2<Double>(0, 8),
            cameraRightXZ: SIMD2<Double>(1, 0)
        )
        XCTAssertEqual(end.x, 0, accuracy: 1e-12)
        XCTAssertEqual(end.y, 8, accuracy: 1e-12)
    }

    func testSixteenProTargetBandIsWideForStableGrip() {
        let profile = LiDARDeviceProfile.resolve(machineIdentifier: "iPhone17,1")
        XCTAssertTrue(profile.isInTargetBand(normalizedX: 0.5))
        XCTAssertTrue(profile.isInTargetBand(normalizedX: 0.75))
        XCTAssertEqual(profile.twistActionLabel(normalizedX: 0.5), "안정 유지")
        XCTAssertEqual(profile.twistActionLabel(normalizedX: 0.02), "볼·홀이 화면 왼쪽 밖")
    }

    func testSeventeenProMaxUsesWiderPlateauOffset() {
        let pro = LiDARDeviceProfile.resolve(machineIdentifier: "iPhone18,1")
        let max = LiDARDeviceProfile.resolve(machineIdentifier: "iPhone18,2")
        XCTAssertEqual(max.productName, "iPhone 17 Pro Max")
        XCTAssertLessThan(max.lidarFromCameraImageRightMeters, pro.lidarFromCameraImageRightMeters)
    }

    func testUnknownMachineDoesNotShiftCorridorPath() {
        let profile = LiDARDeviceProfile.resolve(machineIdentifier: "Mac16,1")
        XCTAssertEqual(profile.layout, .unknown)
        let end = profile.pathEndXZ(
            cameraXZ: SIMD2<Double>(1, 2),
            cameraRightXZ: SIMD2<Double>(0, 1)
        )
        XCTAssertEqual(end.x, 1, accuracy: 1e-12)
        XCTAssertEqual(end.y, 2, accuracy: 1e-12)
    }
}
