import XCTest
@testable import PuttPhysicsKit

final class CandidateSelectorFallbackTests: XCTestCase {
    private let greenSpeed = 2.5

    /// 극단 경사 — 홀인 격자가 비면 primary 없이 재스캔 티어를 반환한다.
    func testReturnsNoPathOnSteepSinglePlane() {
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 12,
            orientationADegrees: 90,
            alphaBDegrees: 12,
            orientationBDegrees: 90,
            boundaryY: 1.8
        )
        let selection = CandidateSelector.select(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: 10,
            velocityPointCount: 24,
            directionPointCount: 24
        )
        XCTAssertNil(selection.primary)
        XCTAssertTrue(selection.allCandidates.isEmpty)
        XCTAssertEqual(selection.searchTier, .noPath)
        XCTAssertFalse(selection.usedRelaxedCaptureRadius)
    }

    func testLongPuttUsesExpandedSearchBeforeEstimate() {
        let terrain = SineRidgeTerrainField()
        let selection = CandidateSelector.select(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: 4,
            velocityPointCount: 36,
            directionPointCount: 36
        )
        XCTAssertNotNil(selection.primary)
        XCTAssertTrue(selection.searchTier.isHoleInVerified)
    }

    func testSteepPutDoesNotInventZeroBetaPath() {
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 14,
            orientationADegrees: 0,
            alphaBDegrees: 14,
            orientationBDegrees: 0,
            boundaryY: 0.5
        )
        let selection = CandidateSelector.select(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: 12,
            velocityPointCount: 16,
            directionPointCount: 16
        )
        if selection.primary == nil {
            XCTAssertEqual(selection.searchTier, .noPath)
        } else {
            XCTAssertTrue(selection.searchTier.isHoleInVerified)
        }
    }
}
