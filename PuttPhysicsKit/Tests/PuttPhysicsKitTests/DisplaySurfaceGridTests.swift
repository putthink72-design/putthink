import simd
import XCTest
@testable import PuttPhysicsKit

final class DisplaySurfaceGridTests: XCTestCase {
    func testRasterizeUsesMedianHeight() {
        let points: [SIMD3<Float>] = [
            SIMD3(0.01, 0.30, 0.01),
            SIMD3(0.02, 0.32, 0.02),
            SIMD3(0.03, 0.50, 0.03)
        ]
        let cells = DisplaySurfaceGrid.rasterize(worldPoints: points, cellSize: 0.05)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].height, 0.32, accuracy: 1e-5)
    }

    func testBuildCreatesRegularQuadFillForTentative() {
        var cells: [DisplaySurfaceGrid.Cell] = []
        for iz in Int32(0)..<3 {
            for ix in Int32(0)..<3 {
                cells.append(DisplaySurfaceGrid.Cell(ix: ix, iz: iz, height: 0.3))
            }
        }
        let split = DisplaySurfaceGrid.buildSplitMeshes(
            cells: cells,
            coverage: .empty,
            cellSize: 0.05,
            lineHalfWidth: 0.002
        )
        XCTAssertFalse(split.tentativeFill.isEmpty)
        XCTAssertFalse(split.tentativeLines.isEmpty)
        XCTAssertTrue(split.stableLines.isEmpty)
        // 2×2 완전 사각 = 4 quads × 2 triangles × 3 indices
        XCTAssertEqual(split.tentativeFill.indices.count, 4 * 6)
    }

    func testStableCellsUseWhiteLinesWithoutBlueFill() {
        var cells: [DisplaySurfaceGrid.Cell] = []
        for iz in Int32(0)..<2 {
            for ix in Int32(0)..<2 {
                cells.append(DisplaySurfaceGrid.Cell(ix: ix, iz: iz, height: 0.31))
            }
        }
        let keys = Set(cells.map(\.key))
        let coverage = ScanCoverageSnapshot(
            observedCellCount: keys.count,
            stableCellCount: keys.count,
            tentativeCellCount: 0,
            newlyStabilizedCount: 0,
            quality: .normal,
            meanDepthMeters: 1,
            cameraSpeedMetersPerSecond: 0,
            stableKeys: keys,
            tentativeKeys: [],
            cellHeights: [:]
        )
        let split = DisplaySurfaceGrid.buildSplitMeshes(
            cells: cells,
            coverage: coverage,
            cellSize: 0.05,
            lineHalfWidth: 0.002
        )
        XCTAssertTrue(split.tentativeFill.isEmpty)
        XCTAssertTrue(split.tentativeLines.isEmpty)
        XCTAssertFalse(split.stableLines.isEmpty)
    }

    func testFlattenToMedianHeightMakesHorizontalBoard() {
        let cells = [
            DisplaySurfaceGrid.Cell(ix: 0, iz: 0, height: 0.30),
            DisplaySurfaceGrid.Cell(ix: 1, iz: 0, height: 0.34),
            DisplaySurfaceGrid.Cell(ix: 0, iz: 1, height: 0.32)
        ]
        let flat = DisplaySurfaceGrid.flattenToMedianHeight(cells, lift: 0.004)
        XCTAssertEqual(flat.count, 3)
        for cell in flat {
            XCTAssertEqual(cell.height, 0.324, accuracy: 1e-5)
        }
    }

    func testDisplaySmoothingDoesNotFlattenLongSlope() {
        var cells: [DisplaySurfaceGrid.Cell] = []
        for iz in Int32(0)..<10 {
            cells.append(
                DisplaySurfaceGrid.Cell(
                    ix: 0,
                    iz: iz,
                    height: 0.30 + Float(iz) * 0.01
                )
            )
        }
        let smoothed = DisplaySurfaceGrid.smoothDisplayOnly(cells)
        let first = smoothed.first!.height
        let last = smoothed.last!.height
        XCTAssertGreaterThan(last - first, 0.07)
    }
}
