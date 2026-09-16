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

    /// ignoreCapture 정지점이 홀 평면에 도달한 후보만 남긴다(홀 앞 정지는 오버런 0으로 위장 금지).
    func testDropsCandidatesThatStopShortOfHole() {
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 8,
            orientationADegrees: 0,
            alphaBDegrees: 8,
            orientationBDegrees: 0,
            boundaryY: 1.0
        )
        let selection = CandidateSelector.select(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: 6,
            velocityPointCount: 40,
            directionPointCount: 40
        )
        for ranked in selection.allCandidates {
            XCTAssertGreaterThanOrEqual(
                ranked.overrunStopPosition.y,
                6 + CandidateSelector.minAlongHoleMeters - 1e-6,
                "corridor candidate must reach hole plane; overrun=\(ranked.actualOverrunDistance)"
            )
        }
        if let primary = selection.primary {
            XCTAssertGreaterThanOrEqual(
                primary.overrunStopPosition.y,
                6 + CandidateSelector.minAlongHoleMeters - 1e-6
            )
        }
    }

    /// 평지 추천: 코리도 후보 정지가 홀에 닿고, 표시 궤적도 홀 근처까지 간다.
    func testFlatRecommendOverrunZeroReachesHole() throws {
        let n = 21 * 61
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: 0.25,
            originX: -2.5,
            originY: -0.5,
            width: 21,
            height: 61,
            heights: Array(repeating: 0.0, count: n),
            holeDistance: 5
        )
        let rec = Gate55Validation.recommend(
            context: context,
            greenSpeed: greenSpeed,
            velocityPointCount: 48,
            directionPointCount: 48
        )
        XCTAssertFalse(rec.corridorCandidates.isEmpty)
        for c in rec.corridorCandidates {
            XCTAssertGreaterThanOrEqual(
                c.overrunStopPosition.y,
                5 + CandidateSelector.minAlongHoleMeters - 1e-6
            )
        }
        if let last = rec.trajectory.last?.position {
            XCTAssertGreaterThanOrEqual(last.y, 5 * 0.92, "display traj should reach near hole")
        }
    }
}
