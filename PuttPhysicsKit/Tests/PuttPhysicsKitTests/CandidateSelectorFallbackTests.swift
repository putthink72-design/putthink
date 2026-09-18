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

    /// 옆경사: 정지점 좌우가 아니라 홀 평면을 맞춰 컵 근처를 지난다.
    func testShootingPassesNearHoleOnSideSlope() throws {
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 4,
            orientationADegrees: 0,
            alphaBDegrees: 4,
            orientationBDegrees: 0,
            boundaryY: 2.0
        )
        let holeDistance = 4.1
        let selection = CandidateSelector.select(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            strategy: .shooting
        )
        let primary = try XCTUnwrap(selection.primary)
        let forward = MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: primary.candidate.initialVelocity,
                initialDirectionDegrees: primary.candidate.directionDegrees,
                holeDistance: holeDistance,
                holeDirectionDegrees: 0
            ),
            terrain: terrain,
            recordTrajectory: true,
            ignoreCapture: true
        )
        XCTAssertLessThan(
            closestApproach(forward.trajectory, holeDistance: holeDistance),
            CandidateSelector.holeInCaptureRadius,
            "estimate/shooting path must thread the 108mm cup; β=\(primary.candidate.directionDegrees)"
        )
        XCTAssertTrue(
            selection.overrunPolicy.contains(primary.actualOverrunDistance),
            "cup-crossing speed should land in slope band \(selection.overrunPolicy.minMeters)–\(selection.overrunPolicy.maxMeters); overrun=\(primary.actualOverrunDistance)"
        )
    }

    func testSideSlopeCorridorNotDroppedForElevationOnlyNoiseFilter() throws {
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 3.5,
            orientationADegrees: 0,
            alphaBDegrees: 3.5,
            orientationBDegrees: 0,
            boundaryY: 1.5
        )
        let holeDistance = 4.1
        let cellSize = 0.2
        let width = 21
        let height = 28
        let originX = -2.0
        let originY = -0.4
        var heights = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                heights[y * width + x] = terrain.height(
                    at: PuttVector2(
                        x: originX + Double(x) * cellSize,
                        y: originY + Double(y) * cellSize
                    )
                )
            }
        }
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: cellSize,
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            heights: heights,
            holeDistance: holeDistance
        )
        XCTAssertLessThan(abs(context.field.height(at: context.holeLocal) - context.field.height(at: context.ballLocal)), 0.025)
        let rec = Gate55Validation.recommend(
            context: context,
            greenSpeed: greenSpeed,
            searchStrategy: .shooting
        )
        XCTAssertFalse(
            rec.corridorCandidates.isEmpty,
            "side-break service band must not be stripped as flat-noise; β=\(rec.directionDegrees) elev=\(rec.elevationDelta)"
        )
        for c in rec.corridorCandidates {
            XCTAssertTrue(
                rec.overrunPolicy.contains(c.actualOverrunDistance),
                "corridor \(c.actualOverrunDistance) outside \(rec.overrunPolicy.minMeters)–\(rec.overrunPolicy.maxMeters)"
            )
        }
        let approach = closestApproach(rec.trajectory, holeDistance: holeDistance)
        XCTAssertLessThan(
            approach,
            CandidateSelector.holeInCaptureRadius,
            "β=\(rec.directionDegrees) tier=\(rec.searchTier) overrun=\(rec.overrunDistance) closest=\(approach)"
        )
    }

    func testOverrunPolicyShrinksOnDownhillAndSideSlope() {
        let downhill = DualPlaneTerrainField(
            alphaADegrees: atan(0.03) * 180 / .pi,
            orientationADegrees: 90,
            alphaBDegrees: atan(0.03) * 180 / .pi,
            orientationBDegrees: 90,
            boundaryY: 20
        )
        let down = ServiceOverrunPolicy.make(terrain: downhill, holeDistance: 4)
        XCTAssertGreaterThan(down.alongDownhillPercent, 2.5)
        XCTAssertLessThan(down.preferredMeters, 0.25)
        XCTAssertGreaterThan(down.preferredMeters, 0.10)
        XCTAssertFalse(down.isRestLimit)
        XCTAssertTrue(down.contains(down.preferredMeters))
        XCTAssertFalse(down.contains(0.35))

        let side = DualPlaneTerrainField(
            alphaADegrees: atan(0.05) * 180 / .pi,
            orientationADegrees: 0,
            alphaBDegrees: atan(0.05) * 180 / .pi,
            orientationBDegrees: 0,
            boundaryY: 20
        )
        let across = ServiceOverrunPolicy.make(terrain: side, holeDistance: 4)
        XCTAssertGreaterThan(across.crossSlopePercent, 4.0)
        XCTAssertLessThan(abs(across.alongDownhillPercent), 0.6)
        XCTAssertLessThan(across.preferredMeters, 0.22)
        XCTAssertGreaterThan(across.preferredMeters, 0.08)
        XCTAssertFalse(across.contains(0.35))
    }

    func testOverrunPolicyRestLimitOnSteepDownhill() {
        let steep = DualPlaneTerrainField(
            alphaADegrees: atan(0.08) * 180 / .pi,
            orientationADegrees: 90,
            alphaBDegrees: atan(0.08) * 180 / .pi,
            orientationBDegrees: 90,
            boundaryY: 20
        )
        let policy = ServiceOverrunPolicy.make(terrain: steep, holeDistance: 4)
        XCTAssertTrue(policy.isRestLimit)
        XCTAssertEqual(policy.preferredMeters, 0, accuracy: 1e-9)
        XCTAssertTrue(policy.contains(0.0))
        XCTAssertTrue(policy.contains(0.08))
        XCTAssertFalse(policy.contains(0.35))
    }

    func testUphillKeepsFlatOverrunBand() {
        let uphill = DualPlaneTerrainField(
            alphaADegrees: atan(0.04) * 180 / .pi,
            orientationADegrees: 270,
            alphaBDegrees: atan(0.04) * 180 / .pi,
            orientationBDegrees: 270,
            boundaryY: 20
        )
        let policy = ServiceOverrunPolicy.make(terrain: uphill, holeDistance: 4)
        XCTAssertEqual(policy.preferredMeters, CandidateSelector.preferredOverrunMeters, accuracy: 1e-9)
        XCTAssertTrue(policy.contains(0.35))
        XCTAssertTrue(policy.contains(0.44))
        XCTAssertFalse(policy.isRestLimit)
    }

    func testDownhillRecommendCorridorFollowsShorterTarget() throws {
        let percent = 3.0
        let alpha = atan(percent / 100) * 180 / .pi
        let terrain = DualPlaneTerrainField(
            alphaADegrees: alpha,
            orientationADegrees: 90,
            alphaBDegrees: alpha,
            orientationBDegrees: 90,
            boundaryY: 20
        )
        let holeDistance = 4.0
        let cellSize = 0.2
        let width = 21
        let height = 28
        let originX = -2.0
        let originY = -0.4
        var heights = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                heights[y * width + x] = terrain.height(
                    at: PuttVector2(
                        x: originX + Double(x) * cellSize,
                        y: originY + Double(y) * cellSize
                    )
                )
            }
        }
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: cellSize,
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            heights: heights,
            holeDistance: holeDistance
        )
        let rec = Gate55Validation.recommend(
            context: context,
            greenSpeed: greenSpeed,
            searchStrategy: .shooting
        )
        XCTAssertLessThan(rec.overrunPolicy.preferredMeters, 0.25)
        XCTAssertGreaterThan(rec.overrunPolicy.preferredMeters, 0.10)
        XCTAssertFalse(rec.corridorCandidates.isEmpty)
        for c in rec.corridorCandidates {
            XCTAssertTrue(rec.overrunPolicy.contains(c.actualOverrunDistance))
            XCTAssertLessThan(c.actualOverrunDistance, 0.30)
        }
    }

    private func closestApproach(_ trajectory: [TrajectorySample], holeDistance: Double) -> Double {
        let hole = PuttVector2(x: 0, y: holeDistance)
        var best = Double.greatestFiniteMagnitude
        var previous: PuttVector2?
        for sample in trajectory {
            let point = sample.position
            best = min(best, hypot(point.x - hole.x, point.y - hole.y))
            if let previous {
                let along0 = previous.y
                let along1 = point.y
                if along0 <= holeDistance && along1 >= holeDistance {
                    let span = max(along1 - along0, 1e-12)
                    let t = (holeDistance - along0) / span
                    let crossed = PuttVector2(
                        x: previous.x + t * (point.x - previous.x),
                        y: previous.y + t * (point.y - previous.y)
                    )
                    best = min(best, hypot(crossed.x - hole.x, crossed.y - hole.y))
                }
            }
            previous = point
        }
        return best
    }
}
