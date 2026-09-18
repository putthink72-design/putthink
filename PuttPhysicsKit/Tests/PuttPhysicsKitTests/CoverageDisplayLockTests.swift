import simd
import XCTest
@testable import PuttPhysicsKit

final class CoverageDisplayLockTests: XCTestCase {
    func testCentroidIsMeanOfCenters() {
        let centers = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.10, 0.20)
        ]
        let centroid = CoverageDisplayLock.centroidXZ(of: centers)
        XCTAssertNotNil(centroid)
        XCTAssertEqual(centroid!.x, Float(0.05), accuracy: 1e-5)
        XCTAssertEqual(centroid!.y, Float(0.10), accuracy: 1e-5)
    }

    func testSettleNeedsDurationInsideSmallWindow() {
        var settle = CoverageOriginSettle()
        XCTAssertFalse(settle.observe(SIMD2(0, 0), now: 1.0))
        XCTAssertFalse(settle.observe(SIMD2(0.002, 0.001), now: 1.2))
        XCTAssertTrue(settle.observe(SIMD2(0.0025, 0.0015), now: 1.56))
        var jumped = CoverageOriginSettle()
        XCTAssertFalse(jumped.observe(SIMD2(0, 0), now: 1.0))
        XCTAssertFalse(jumped.observe(SIMD2(0.05, 0), now: 1.2))
        XCTAssertFalse(jumped.observe(SIMD2(0.052, 0), now: 1.4))
        XCTAssertTrue(jumped.observe(SIMD2(0.053, 0), now: 1.76))
    }

    func testQuickDisplaySettlesFasterThanDefault() {
        var quick = CoverageOriginSettle.quickDisplay
        XCTAssertFalse(quick.observe(SIMD2(0, 0), now: 1.0))
        XCTAssertFalse(quick.observe(SIMD2(0.005, 0), now: 1.05))
        XCTAssertTrue(quick.observe(SIMD2(0.006, 0), now: 1.13))
    }

    func testPointInsideSameCellDoesNotCreateNeighbor() {
        let lift: Float = 0.004
        let existingKey = CoverageDisplayLock.packedKey(ix: 0, iz: 0)
        let existing = [
            existingKey: DisplaySurfaceGrid.Cell(ix: 0, iz: 0, height: lift)
        ]
        let origin = CoverageDisplayLock.cellCenterXZ(existingKey)
        let resolved = CoverageDisplayLock.resolveLocalCell(
            localX: origin.x + 0.010,
            localZ: origin.y,
            existing: existing,
            lift: lift
        )
        XCTAssertFalse(resolved.created)
        XCTAssertEqual(resolved.key, existingKey)
    }

    func testAdjacentFiveCentimetreCellIsKept() {
        let lift: Float = 0.004
        let existingKey = CoverageDisplayLock.packedKey(ix: 0, iz: 0)
        let existing = [
            existingKey: DisplaySurfaceGrid.Cell(ix: 0, iz: 0, height: lift)
        ]
        let origin = CoverageDisplayLock.cellCenterXZ(existingKey)
        let resolved = CoverageDisplayLock.resolveLocalCell(
            localX: origin.x + 0.028,
            localZ: origin.y,
            existing: existing,
            lift: lift
        )
        XCTAssertTrue(resolved.created)
        XCTAssertEqual(resolved.cell.ix, 1)
        XCTAssertEqual(resolved.cell.iz, 0)
    }

    func testWorldToLocalCellPreservesWorldCenter() {
        let cellSize = CoverageDisplayLock.cellSizeMeters
        let anchorKey = CoverageDisplayLock.packedKey(ix: 10, iz: -3)
        let worldKey = CoverageDisplayLock.packedKey(ix: 12, iz: -1)
        let worldCenter = CoverageDisplayLock.cellCenterXZ(worldKey)
        let corner = CoverageDisplayLock.stickCornerXZ(anchorKey: anchorKey)
        let localCenter = CoverageDisplayLock.localCellCenterXZ(
            worldKey: worldKey,
            anchorKey: anchorKey
        )
        let reconstructed = corner + localCenter
        XCTAssertEqual(reconstructed.x, worldCenter.x, accuracy: 1e-5)
        XCTAssertEqual(reconstructed.y, worldCenter.y, accuracy: 1e-5)
    }

    func testFloorRequantizationBiasesGridRightOfWorld() {
        let cellSize = CoverageDisplayLock.cellSizeMeters
        let keys: [Int64] = [0, 1, 2].map {
            CoverageDisplayLock.packedKey(ix: Int32($0), iz: 0)
        }
        let centers = keys.map { CoverageDisplayLock.cellCenterXZ($0) }
        let centroid = CoverageDisplayLock.centroidXZ(of: centers)!
        XCTAssertEqual(centroid.x, 0.075, accuracy: 1e-5)

        // 이전 방식: centroid에 스틱 + floor(local/cellSize) → 양 끝 칸이 2.5cm 밀림.
        for worldKey in [keys[0], keys[2]] {
            let worldCenter = CoverageDisplayLock.cellCenterXZ(worldKey)
            let localX = worldCenter.x - centroid.x
            let flooredIX = Int32(floor(localX / cellSize))
            let biasedCenter = centroid.x + (Float(flooredIX) + 0.5) * cellSize
            XCTAssertEqual(biasedCenter - worldCenter.x, 0.025, accuracy: 1e-5)
        }

        // 수정: 격자 모서리 앵커 + 정수 오프셋은 오차 0.
        let anchorKey = CoverageDisplayLock.gridAnchorKey(for: centroid)
        let corner = CoverageDisplayLock.stickCornerXZ(anchorKey: anchorKey)
        for worldKey in keys {
            let worldCenter = CoverageDisplayLock.cellCenterXZ(worldKey)
            let localCenter = CoverageDisplayLock.localCellCenterXZ(
                worldKey: worldKey,
                anchorKey: anchorKey
            )
            let reconstructed = corner + localCenter
            XCTAssertEqual(reconstructed.x, worldCenter.x, accuracy: 1e-5)
            XCTAssertEqual(reconstructed.y, worldCenter.y, accuracy: 1e-5)
        }
    }

    func testPlantedGridDoesNotMoveWhenBallCellDiffers() {
        let plantCentroid = SIMD2<Float>(0.12, 0.08)
        let plantKey = CoverageDisplayLock.gridAnchorKey(for: plantCentroid)
        let ballKey = CoverageDisplayLock.gridAnchorKey(for: SIMD2(1.02, 0.33))
        XCTAssertNotEqual(plantKey, ballKey)

        let worldKey = CoverageDisplayLock.packedKey(ix: 8, iz: 3)
        let localAtPlant = CoverageDisplayLock.localCellKey(worldKey: worldKey, anchorKey: plantKey)
        let localIfReplantedAtBall = CoverageDisplayLock.localCellKey(worldKey: worldKey, anchorKey: ballKey)
        XCTAssertNotEqual(localAtPlant, localIfReplantedAtBall)

        let worldCenter = CoverageDisplayLock.cellCenterXZ(worldKey)
        let reconstructed = CoverageDisplayLock.stickCornerXZ(anchorKey: plantKey)
            + CoverageDisplayLock.localCellCenterXZ(worldKey: worldKey, anchorKey: plantKey)
        XCTAssertEqual(reconstructed.x, worldCenter.x, accuracy: 1e-5)
        XCTAssertEqual(reconstructed.y, worldCenter.y, accuracy: 1e-5)
    }

    func testRigidWorldShiftDetectsOriginNotWalk() {
        XCTAssertTrue(
            CoverageDisplayLock.isRigidWorldShift(
                cameraDelta: SIMD2(0.08, 0),
                boardDelta: SIMD2(0.08, 0.01)
            )
        )
        XCTAssertFalse(
            CoverageDisplayLock.isRigidWorldShift(
                cameraDelta: SIMD2(0.20, 0),
                boardDelta: SIMD2(0.02, 0)
            )
        )
        XCTAssertFalse(
            CoverageDisplayLock.isRigidWorldShift(
                cameraDelta: SIMD2(0.08, 0),
                boardDelta: SIMD2(0, 0.08)
            )
        )
    }

    func testBallRelativeLocalKeysSurviveOriginShift() {
        let ball = SIMD2<Float>(1.02, 0.40)
        let cell = SIMD2<Float>(1.12, 0.45)
        let shift = SIMD2<Float>(0.08, -0.03)
        let before = CoverageDisplayLock.localCellKey(worldCenter: cell, relativeToBall: ball)
        let after = CoverageDisplayLock.localCellKey(
            worldCenter: cell + shift,
            relativeToBall: ball + shift
        )
        XCTAssertEqual(before, after)
    }

    func testGridAnchorKeySnapsToContainingCell() {
        let key = CoverageDisplayLock.gridAnchorKey(for: SIMD2(0.076, -0.011))
        let (ix, iz) = CoverageDisplayLock.unpack(key)
        XCTAssertEqual(ix, 1)
        XCTAssertEqual(iz, -1)
    }

    func testFiveCentimetreNewGroundCreatesNeighborCell() {
        let lift: Float = 0.004
        let existingKey = CoverageDisplayLock.packedKey(ix: 0, iz: 0)
        let existing = [
            existingKey: DisplaySurfaceGrid.Cell(ix: 0, iz: 0, height: lift)
        ]
        let origin = CoverageDisplayLock.cellCenterXZ(existingKey)
        let resolved = CoverageDisplayLock.resolveLocalCell(
            localX: origin.x + 0.050,
            localZ: origin.y,
            existing: existing,
            lift: lift
        )
        XCTAssertTrue(resolved.created)
        XCTAssertEqual(resolved.cell.ix, 1)
        XCTAssertEqual(resolved.cell.iz, 0)
    }
}
