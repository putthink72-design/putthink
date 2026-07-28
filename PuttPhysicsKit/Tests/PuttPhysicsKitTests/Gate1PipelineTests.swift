import XCTest
@testable import PuttPhysicsKit

final class Gate1PipelineTests: XCTestCase {
    func testCoordinateTransformAlignsHoleWithPositiveY() throws {
        let ball = ScanPose(worldX: 1, worldY: 2, worldZ: 3, timestamp: 0)
        let hole = ScanPose(worldX: 4, worldY: 2.2, worldZ: 7, timestamp: 5)
        let transform = try ScanCoordinateTransform(ball: ball, hole: hole)
        let vertex = ScanVertex(worldX: 4, worldY: 2.2, worldZ: 7, timestamp: 5)

        let local = transform.local(vertex: vertex, scanStart: 0, scanEnd: 10)

        XCTAssertEqual(local.x, 0, accuracy: 1e-12)
        XCTAssertEqual(local.y, 5, accuracy: 1e-12)
        XCTAssertEqual(local.height, 0.2, accuracy: 1e-12)
        XCTAssertEqual(local.progress, 0.5, accuracy: 1e-12)
    }

    func testDriftCorrectionIsLinearByProgress() {
        let vertices = [
            LocalVertex(x: 0, y: 0, height: 1, progress: 0),
            LocalVertex(x: 0, y: 1, height: 1, progress: 0.5),
            LocalVertex(x: 0, y: 2, height: 1, progress: 1)
        ]

        let corrected = DriftCorrector.correct(vertices, drift: 0.1)

        XCTAssertEqual(corrected[0].height, 1, accuracy: 1e-12)
        XCTAssertEqual(corrected[1].height, 0.95, accuracy: 1e-12)
        XCTAssertEqual(corrected[2].height, 0.9, accuracy: 1e-12)
    }

    func testRasterizerUsesMedianAndTracksInterpolationMask() throws {
        let vertices = [
            LocalVertex(x: 0, y: 0, height: 0, progress: 0),
            LocalVertex(x: 0, y: 0, height: 10, progress: 0),
            LocalVertex(x: 0, y: 0, height: 2, progress: 0),
            LocalVertex(x: 0.1, y: 0, height: 4, progress: 0)
        ]

        let map = try HeightMapRasterizer.rasterize(vertices: vertices, cellSize: 0.05)

        XCTAssertEqual(map.width, 3)
        XCTAssertEqual(map.value(x: 0, y: 0), 2, accuracy: 1e-12)
        XCTAssertEqual(map.value(x: 2, y: 0), 4, accuracy: 1e-12)
        XCTAssertTrue(map.measuredMask[map.index(x: 0, y: 0)])
        XCTAssertFalse(map.measuredMask[map.index(x: 1, y: 0)])
        XCTAssertTrue(map.interpolatedMask[map.index(x: 1, y: 0)])
        XCTAssertEqual(map.value(x: 1, y: 0), 3, accuracy: 1e-12)
    }

    func testGaussianSmoothingReducesImpulseAndPreservesConstantMap() {
        let constant = makeMap(width: 7, height: 7, values: Array(repeating: 2, count: 49))
        XCTAssertEqual(GaussianSmoother.smooth(constant, sigma: 1.5).values, constant.values)

        var impulseValues = Array(repeating: 0.0, count: 49)
        impulseValues[24] = 1
        let impulse = makeMap(width: 7, height: 7, values: impulseValues)
        let smoothed = GaussianSmoother.smooth(impulse, sigma: 1.5)

        XCTAssertGreaterThan(smoothed.values[24], 0)
        XCTAssertLessThan(smoothed.values[24], 1)
        XCTAssertGreaterThan(smoothed.values[23], 0)
    }

    func testGradientBuilderRecoversPlaneIncludingEdges() {
        let width = 6
        let height = 5
        let cellSize = 0.05
        var values: [Double] = []
        for y in 0..<height {
            for x in 0..<width {
                values.append(0.02 * Double(x) * cellSize - 0.03 * Double(y) * cellSize + 0.4)
            }
        }
        let map = makeMap(width: width, height: height, cellSize: cellSize, values: values)

        let gradient = GradientFieldBuilder.build(from: map)

        for index in values.indices {
            XCTAssertEqual(gradient.dx[index], 0.02, accuracy: 1e-10)
            XCTAssertEqual(gradient.dy[index], -0.03, accuracy: 1e-10)
        }
    }

    func testDetrendingRemovesPlanarSlope() {
        let width = 10
        let height = 10
        var values: [Double] = []
        for y in 0..<height {
            for x in 0..<width {
                values.append(Double(x) * 0.001 + Double(y) * 0.002 + (x.isMultiple(of: 2) ? 0.0005 : -0.0005))
            }
        }
        let map = makeMap(width: width, height: height, values: values)

        let noise = HeightMapNoiseEstimator.detrendedStandardDeviation(map: map, region: .center)

        XCTAssertEqual(noise, 0.0005, accuracy: 0.0001)
    }

    func testPipelineProducesBeforeAfterAndGradient() throws {
        let start = ScanPose(worldX: 0, worldY: 1, worldZ: 0, timestamp: 0)
        let hole = ScanPose(worldX: 0, worldY: 1, worldZ: 1, timestamp: 5)
        let end = ScanPose(worldX: 0, worldY: 1.02, worldZ: 0, timestamp: 10)
        let vertices = [
            ScanVertex(worldX: 0, worldY: 1, worldZ: 0, timestamp: 0),
            ScanVertex(worldX: 0, worldY: 1.01, worldZ: 0.5, timestamp: 5),
            ScanVertex(worldX: 0, worldY: 1.02, worldZ: 1, timestamp: 10)
        ]

        let result = try TerrainPipeline.process(
            vertices: vertices,
            startPose: start,
            holePose: hole,
            returnPose: end
        )

        XCTAssertEqual(result.driftMeters, 0.02, accuracy: 1e-12)
        XCTAssertEqual(result.uncorrected.values.last!, 0.02, accuracy: 1e-12)
        XCTAssertEqual(result.corrected.values.last!, 0, accuracy: 1e-12)
        XCTAssertEqual(result.gradient.width, result.smoothed.width)
    }

    func testSigmaSweepAndRepeatScanRMSProduceDiagnostics() {
        let first = makeMap(
            width: 3,
            height: 2,
            values: [0, 0.001, 0.002, 0, 0.001, 0.002]
        )
        let second = makeMap(
            width: 3,
            height: 2,
            values: [0.001, 0.002, 0.003, 0.001, 0.002, 0.003]
        )

        let sigmaSweep = HeightMapNoiseEstimator.sigmaSweep(
            correctedMap: first,
            region: NormalizedRegion(minX: 0, maxX: 1, minY: 0, maxY: 1)
        )
        let comparisons = RepeatScanComparator.compare(
            namedMaps: [("first", first), ("second", second)]
        )

        XCTAssertEqual(sigmaSweep.map(\.sigma), [0.75, 1.5, 2.25])
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons[0].commonCellCount, 6)
        XCTAssertEqual(comparisons[0].rmsMillimeters, 1, accuracy: 1e-12)
    }

    private func makeMap(
        width: Int,
        height: Int,
        cellSize: Double = 0.05,
        values: [Double]
    ) -> HeightMap {
        HeightMap(
            cellSize: cellSize,
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            values: values,
            measuredMask: Array(repeating: true, count: values.count),
            interpolatedMask: Array(repeating: false, count: values.count)
        )
    }
}
