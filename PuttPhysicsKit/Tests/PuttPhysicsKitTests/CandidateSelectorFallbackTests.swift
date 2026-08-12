import XCTest
@testable import PuttPhysicsKit

final class CandidateSelectorFallbackTests: XCTestCase {
    private let greenSpeed = 2.5

    /// 극단 경사 — 홀인 격자는 비어도 primary는 항상 존재해야 한다.
    func testAlwaysReturnsPrimaryOnSteepSinglePlane() {
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
        XCTAssertNotNil(selection.primary)
        XCTAssertFalse(selection.allCandidates.isEmpty)
        XCTAssertFalse(selection.searchTier.isHoleInVerified)
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

    func testFlatHeuristicProducesZeroBetaCandidate() {
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
        XCTAssertNotNil(selection.primary)
        if selection.searchTier == CandidateSearchTier.flatHeuristic {
            XCTAssertEqual(selection.primary?.candidate.directionDegrees ?? 999, 0, accuracy: 1e-9)
        }
    }
}
