import XCTest
@testable import PuttPhysicsKit

final class ContourLineBuilderTests: XCTestCase {
    func testFlatPlaneProducesNoContours() {
        let map = makeRampMap(slopeAlongY: 0, width: 8, height: 8)
        let lines = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                corridorHalfWidth: nil,
                requireKnownCell: false
            )
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testUniformSlopeProducesMultipleLevels() {
        // y 방향으로 0 → 0.08m (8cm) 상승 → 1cm 등고 약 7~8개
        let map = makeRampMap(slopeAlongY: 0.08 / 7.0, width: 8, height: 8)
        let lines = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                maxLevels: 20,
                corridorHalfWidth: nil,
                requireKnownCell: false
            )
        )
        XCTAssertGreaterThanOrEqual(lines.count, 5)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.points.count, 2)
            for point in line.points {
                XCTAssertEqual(point.height, line.level, accuracy: 1e-9)
            }
        }
    }

    func testCorridorClipsFarSideContours() {
        let map = makeRampMap(slopeAlongY: 0.02, width: 21, height: 21, originX: -0.5, originY: 0)
        let clipped = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                corridorHalfWidth: 0.15,
                holeDistance: 0.8,
                corridorMargin: 0.1,
                requireKnownCell: false
            )
        )
        XCTAssertFalse(clipped.isEmpty)
        for line in clipped {
            for point in line.points {
                XCTAssertLessThanOrEqual(abs(point.x), 0.25)
            }
        }
    }

    func testCatmullRomProducesDenserSmootherCurve() {
        let raw: [ContourPoint] = [
            ContourPoint(x: 0, y: 0, height: 0.01),
            ContourPoint(x: 0.1, y: 0.05, height: 0.01),
            ContourPoint(x: 0.2, y: 0, height: 0.01),
            ContourPoint(x: 0.3, y: 0.04, height: 0.01)
        ]
        let curve = ContourLineBuilder.catmullRomResample(raw, samplesPerSegment: 6)
        XCTAssertGreaterThan(curve.count, raw.count)
        XCTAssertEqual(curve.first?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(curve.last?.x ?? -1, 0.3, accuracy: 1e-9)
    }

    func testSmallHeightRangeStillProducesContours() {
        // 고도차 6mm < 기본 1cm 간격이어도 등고가 나와야 한다.
        let map = makeRampMap(slopeAlongY: 0.006 / 7.0, width: 8, height: 8)
        let lines = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                corridorHalfWidth: nil,
                requireKnownCell: false,
                smoothIterations: 1
            )
        )
        XCTAssertFalse(lines.isEmpty, "작은 고도 범위에서도 적응형 등고 레벨이 필요")
    }

    func testSmoothIncreasesPointCountAndKeepsEndpoints() {
        let raw: [ContourPoint] = [
            ContourPoint(x: 0, y: 0, height: 0.01),
            ContourPoint(x: 0.05, y: 0.05, height: 0.01),
            ContourPoint(x: 0.10, y: 0, height: 0.01)
        ]
        let smoothed = ContourLineBuilder.smooth(raw, iterations: 2)
        XCTAssertGreaterThan(smoothed.count, raw.count)
        XCTAssertEqual(smoothed.first?.x ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(smoothed.last?.x ?? -1, 0.10, accuracy: 1e-12)
    }

    private func makeRampMap(
        slopeAlongY: Double,
        width: Int,
        height: Int,
        originX: Double = 0,
        originY: Double = 0,
        cellSize: Double = 0.05
    ) -> HeightMap {
        var values = Array(repeating: 0.0, count: width * height)
        let measured = Array(repeating: true, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = Double(y) * slopeAlongY
            }
        }
        return HeightMap(
            cellSize: cellSize,
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            values: values,
            measuredMask: measured,
            interpolatedMask: Array(repeating: false, count: width * height)
        )
    }
}
