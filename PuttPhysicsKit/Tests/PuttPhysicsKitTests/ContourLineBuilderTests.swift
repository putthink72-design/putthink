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

    func testAlongTrackSlopeContoursAreCrossTrackNearCenter() {
        // y(퍼트) 방향 경사 → 등고는 대략 상수 y, x를 가로지름. 축이 바뀌면 |x|≈y로 “오른쪽”에 보임.
        let map = makeRampMap(
            slopeAlongY: 0.02,
            width: 41,
            height: 41,
            originX: -1.0,
            originY: 0
        )
        let lines = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                maxLevels: 12,
                corridorHalfWidth: 1.0,
                holeDistance: 2.0,
                corridorMargin: 0.1,
                requireKnownCell: false,
                requireMeasuredCell: false,
                smoothIterations: 1
            )
        )
        XCTAssertFalse(lines.isEmpty)
        var meanAbsX = 0.0
        var meanYSpan = 0.0
        var meanXSpan = 0.0
        for line in lines {
            let xs = line.points.map(\.x)
            let ys = line.points.map(\.y)
            meanAbsX += xs.map(abs).reduce(0, +) / Double(xs.count)
            meanYSpan += (ys.max() ?? 0) - (ys.min() ?? 0)
            meanXSpan += (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        let n = Double(lines.count)
        meanAbsX /= n
        meanYSpan /= n
        meanXSpan /= n
        XCTAssertLessThan(meanAbsX, 0.55, "횡단 등고의 평균 |x|는 복도 중앙 근처여야 함")
        XCTAssertGreaterThan(meanXSpan, meanYSpan, "퍼트 방향 경사 등고는 x 방향으로 더 길어야 함 (축 스왑 방지)")
    }

    func testMeasuredOnlySkipsExtrapolatedFlank() {
        var values = Array(repeating: 0.0, count: 21 * 21)
        var measured = Array(repeating: false, count: 21 * 21)
        // 오른쪽 플랭크(x≥0.3)만 실측 + y 경사
        for y in 0..<21 {
            for x in 0..<21 {
                let wx = -0.5 + Double(x) * 0.05
                if wx >= 0.3 {
                    values[y * 21 + x] = Double(y) * 0.01
                    measured[y * 21 + x] = true
                }
            }
        }
        // 왼쪽은 외삽처럼 값이 채워졌지만 measured=false
        for y in 0..<21 {
            for x in 0..<21 where !measured[y * 21 + x] {
                values[y * 21 + x] = Double(y) * 0.01
            }
        }
        let map = HeightMap(
            cellSize: 0.05,
            originX: -0.5,
            originY: 0,
            width: 21,
            height: 21,
            values: values,
            measuredMask: measured,
            interpolatedMask: measured.map { !$0 }
        )
        let measuredOnly = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                maxLevels: 10,
                corridorHalfWidth: 0.5,
                requireKnownCell: true,
                requireMeasuredCell: true,
                smoothIterations: 0,
                maxSegmentLength: 0.05
            )
        )
        XCTAssertFalse(measuredOnly.isEmpty)
        for line in measuredOnly {
            let meanX = ContourLineBuilder.meanLateral(line)
            XCTAssertGreaterThan(meanX, 0.15, "실측-only면 등고 무게중심이 오른쪽 실측 구역에 있어야 함")
        }
        let anyCell = ContourLineBuilder.build(
            map: map,
            configuration: ContourBuildConfiguration(
                intervalMeters: 0.01,
                maxLevels: 10,
                corridorHalfWidth: 0.5,
                requireKnownCell: false,
                requireMeasuredCell: false,
                smoothIterations: 0,
                maxSegmentLength: 0.05
            )
        )
        XCTAssertFalse(anyCell.isEmpty)
        // 전체 셀이면 횡단 등고가 중앙까지 뻗어 mean |x|가 더 작아질 수 있음
        let measuredMeanAbs = measuredOnly.map { ContourLineBuilder.minAbsLateral($0) }.min() ?? 99
        let anyMeanAbs = anyCell.map { ContourLineBuilder.minAbsLateral($0) }.min() ?? 99
        XCTAssertGreaterThanOrEqual(measuredMeanAbs, anyMeanAbs - 0.05)
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
