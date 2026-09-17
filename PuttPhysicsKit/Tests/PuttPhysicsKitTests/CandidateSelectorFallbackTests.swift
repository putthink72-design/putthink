import XCTest
@testable import PuttPhysicsKit

final class CandidateSelectorFallbackTests: XCTestCase {
    private let greenSpeed = 2.5

    /// 극단 경사여도 빈 후보·재스캔 티어로 끝내지 않는다.
    func testReturnsDrawablePathOnSteepSinglePlane() {
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
        XCTAssertNotEqual(selection.searchTier, .noPath)
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
        XCTAssertGreaterThan(selection.searchTier.displayPriority, CandidateSearchTier.noPath.displayPriority)
    }

    func testSteepPutDoesNotInventVerifiedZeroBetaPath() {
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
        XCTAssertNotEqual(selection.searchTier, .noPath)
    }

    func testShootingFallbackIsNotNoPath() {
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
            velocityPointCount: 9,
            directionPointCount: 9,
            strategy: .shooting
        )
        XCTAssertNotNil(selection.primary)
        XCTAssertNotEqual(selection.searchTier, .noPath)
        XCTAssertFalse(selection.usedRelaxedCaptureRadius)
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

    /// 평지 추천: 코리도는 홀 뒤 34–44cm만, 표시 궤적도 홀 근처까지 간다.
    func testFlatRecommendServiceCorridorStaysPastHole() throws {
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
            XCTAssertTrue(
                CandidateSelector.isServiceOverrun(c.actualOverrunDistance),
                "corridor overrun \(c.actualOverrunDistance) must be 0.34–0.44m"
            )
        }
        if let last = rec.trajectory.last?.position {
            XCTAssertGreaterThanOrEqual(last.y, 5 * 0.92, "display traj should reach near hole")
        }
        if let primary = rec.primary {
            XCTAssertGreaterThanOrEqual(
                primary.overrunStopPosition.y,
                5 + CandidateSelector.serviceOverrunMinMeters - 0.02
            )
        }
    }

    func testShootingSearchFindsVerifiedPathOnFlatGreen() throws {
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
            searchStrategy: .shooting
        )
        XCTAssertNotNil(rec.primary)
        XCTAssertEqual(rec.searchTier, .verified)
        XCTAssertFalse(rec.trajectory.isEmpty)
        XCTAssertGreaterThan(rec.flatEquivalentDistance, 0)
        if let primary = rec.primary {
            XCTAssertTrue(
                CandidateSelector.isServiceOverrun(primary.actualOverrunDistance),
                "flat shooting primary overrun \(primary.actualOverrunDistance)"
            )
            XCTAssertTrue(primary.searchTier.isHoleInVerified)
        }
    }

    func testShootingSearchDoesNotUseRelaxedCapture() throws {
        let n = 21 * 61
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: 0.25,
            originX: -2.5,
            originY: -0.5,
            width: 21,
            height: 61,
            heights: Array(repeating: 0.0, count: n),
            holeDistance: 4
        )
        let rec = Gate55Validation.recommend(
            context: context,
            greenSpeed: greenSpeed,
            searchStrategy: .shooting
        )
        if let primary = rec.primary {
            XCTAssertFalse(primary.usedRelaxedCaptureRadius)
            XCTAssertEqual(primary.searchTier, .verified)
        }
    }

    func testOnlyFivePointFourCmCountsAsHoleInVerified() {
        XCTAssertTrue(CandidateSearchTier.verified.isHoleInVerified)
        XCTAssertFalse(CandidateSearchTier.relaxedCapture.isHoleInVerified)
        XCTAssertFalse(CandidateSearchTier.expandedSearch.isHoleInVerified)
        XCTAssertFalse(CandidateSearchTier.proximityEstimate.isHoleInVerified)
        XCTAssertTrue(CandidateSelector.isServiceOverrun(0.34))
        XCTAssertTrue(CandidateSelector.isServiceOverrun(0.44))
        XCTAssertFalse(CandidateSelector.isServiceOverrun(0.0))
        XCTAssertFalse(CandidateSelector.isServiceOverrun(0.33))
        XCTAssertTrue(CandidateSelector.meetsServiceLine(searchTier: .verified, overrunDistance: 0.0))
        XCTAssertTrue(CandidateSelector.meetsServiceLine(searchTier: .proximityEstimate, overrunDistance: 0.35))
        XCTAssertFalse(CandidateSelector.meetsServiceLine(searchTier: .proximityEstimate, overrunDistance: 0.10))
    }

    func testRecommendNeverBlanksTrajectoryWithin12m() throws {
        let n = 21 * 81
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: 0.25,
            originX: -2.5,
            originY: -0.5,
            width: 21,
            height: 81,
            heights: Array(repeating: 0.0, count: n),
            holeDistance: 12
        )
        let rec = Gate55Validation.recommend(
            context: context,
            greenSpeed: greenSpeed,
            searchStrategy: .shooting
        )
        XCTAssertNotNil(rec.primary)
        XCTAssertGreaterThanOrEqual(rec.trajectory.count, 2)
        XCTAssertNotEqual(rec.searchTier, .noPath)
        XCTAssertGreaterThan(rec.trajectory.last?.position.y ?? 0, 8)
    }

    func testShootingFallbackRaisesPastHoleOnFlatGreen() throws {
        let n = 21 * 61
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: 0.25,
            originX: -2.5,
            originY: -0.5,
            width: 21,
            height: 61,
            heights: Array(repeating: 0.0, count: n),
            holeDistance: 6
        )
        let rec = Gate55Validation.recommend(
            context: context,
            greenSpeed: greenSpeed,
            searchStrategy: .shooting
        )
        let primary = try XCTUnwrap(rec.primary)
        XCTAssertGreaterThanOrEqual(
            primary.actualOverrunDistance,
            CandidateSelector.serviceOverrunMinMeters - 0.02,
            "fallback/shooting must not recommend dying short of the 34cm band"
        )
    }
}
