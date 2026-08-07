import Foundation
import XCTest
@testable import PuttPhysicsKit

final class Gate55ValidationTests: XCTestCase {
    func testMeasuredGridMode1ProducesTrajectory() throws {
        // 5×5 완만 오르막 격자 (직접 실측 축소재현 입력 형태)
        let cell = 0.2
        let width = 5
        let height = 8
        var heights = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                heights[y * width + x] = Double(y) * 0.01
            }
        }
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: cell,
            originX: -0.4,
            originY: -0.2,
            width: width,
            height: height,
            heights: heights,
            holeDistance: 1.2
        )
        let result = Gate55Validation.runForward(
            context: context,
            greenSpeed: 2.5,
            initialVelocity: 1.8,
            directionDegrees: 0
        )
        XCTAssertFalse(result.trajectory.isEmpty)
        XCTAssertGreaterThan(result.arcLength, 0.5)
        XCTAssertEqual(result.directionDegrees, 0, accuracy: 1e-9)
    }

    func testGreenMode2PrimaryAndFlatEquivalent() throws {
        let green = try loadGreen("128_001_2_03_4")
        let scenarios = try GreenAligner.defaultScenarios(for: green, holeCount: 1)
        let pair = try XCTUnwrap(scenarios.first)
        let context = try Gate55Validation.contextFromGreen(
            green,
            ballWorld: pair.ball,
            holeWorld: pair.hole
        )
        XCTAssertGreaterThan(context.holeDistance, 1.0)

        let recommendation = Gate55Validation.recommend(
            context: context,
            greenSpeed: 2.5
        )
        // 완만 그린은 후보가 없을 수 있으므로 구조만 검증. 후보가 있으면 평지환산이 양수.
        XCTAssertEqual(recommendation.horizontalDistance, context.holeDistance, accuracy: 1e-6)
        if recommendation.primary != nil {
            XCTAssertGreaterThan(recommendation.flatEquivalentDistance, 0)
            XCTAssertEqual(
                recommendation.distanceAdjustment,
                recommendation.flatEquivalentDistance - recommendation.horizontalDistance,
                accuracy: 1e-9
            )
            XCTAssertFalse(recommendation.trajectory.isEmpty)
            XCTAssertFalse(recommendation.strokeGuidance.isEmpty)
        }
    }

    func testScanPipelineContextAndCoordinateHelpers() throws {
        let start = ScanPose(worldX: 0, worldY: 1.2, worldZ: 0, timestamp: 0)
        let hole = ScanPose(worldX: 0, worldY: 1.2, worldZ: 3, timestamp: 10)
        let ret = ScanPose(worldX: 0, worldY: 1.208, worldZ: 0, timestamp: 20)
        var vertices: [ScanVertex] = []
        for row in 0...40 {
            for column in -10...10 {
                let z = Double(row) * 0.05
                let x = Double(column) * 0.05
                vertices.append(
                    ScanVertex(
                        worldX: x,
                        worldY: 1.2 + 0.005 * z,
                        worldZ: z,
                        timestamp: z / 3 * 20
                    )
                )
            }
        }
        let pipeline = try TerrainPipeline.process(
            vertices: vertices,
            startPose: start,
            holePose: hole,
            returnPose: ret
        )
        let context = try Gate55Validation.contextFromScan(
            result: pipeline,
            startPose: start,
            holePose: hole
        )
        XCTAssertEqual(context.holeDistance, 3, accuracy: 1e-6)
        XCTAssertNotNil(context.scanTransform)

        let transform = try XCTUnwrap(context.scanTransform)
        let worldHole = transform.world(localX: 0, localY: 3, height: 0)
        XCTAssertEqual(worldHole.worldX, 0, accuracy: 1e-6)
        XCTAssertEqual(worldHole.worldZ, 3, accuracy: 1e-6)

        let aim0 = transform.aimWorldDirection(betaDegrees: 0)
        XCTAssertEqual(aim0.dx, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(aim0.dz, 0.9)

        let aimRight = transform.aimWorldDirection(betaDegrees: 90)
        XCTAssertLessThan(aimRight.dx, -0.9) // 홀=+Z 일 때 우측 = −X (look × up)

        let forward = Gate55Validation.runForward(
            context: context,
            greenSpeed: 2.5,
            initialVelocity: 2.0,
            directionDegrees: 5
        )
        XCTAssertFalse(forward.trajectory.isEmpty)
    }

    func testDriftUsesCameraHeightNotGroundAnchor() throws {
        // 지면 앵커 Y와 카메라 Y를 분리했을 때 드리프트는 카메라만 사용해야 한다.
        let ballGround = ScanPose(worldX: 0, worldY: 0.30, worldZ: 0, timestamp: 0)
        let holeGround = ScanPose(worldX: 0, worldY: 0.31, worldZ: 3, timestamp: 10)
        let cameraStart = ScanPose(worldX: 0, worldY: 1.20, worldZ: 0, timestamp: 0)
        let cameraReturn = ScanPose(worldX: 0, worldY: 1.25, worldZ: 0, timestamp: 20)
        var vertices: [ScanVertex] = []
        for row in 0...20 {
            for column in -5...5 {
                let z = Double(row) * 0.1
                let x = Double(column) * 0.1
                vertices.append(
                    ScanVertex(
                        worldX: x,
                        worldY: 0.30 + 0.002 * z,
                        worldZ: z,
                        timestamp: z / 2 * 20
                    )
                )
            }
        }
        let result = try TerrainPipeline.process(
            vertices: vertices,
            startPose: ballGround,
            holePose: holeGround,
            returnPose: cameraReturn,
            cameraStartPose: cameraStart,
            cameraReturnPose: cameraReturn
        )
        XCTAssertEqual(result.driftMeters, 0.05, accuracy: 1e-12)

        let transform = try ScanCoordinateTransform(ball: ballGround, hole: holeGround)
        let aim0 = transform.aimWorldDirection(betaDegrees: 0)
        XCTAssertEqual(aim0.dx, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(aim0.dz, 0.9)
        // 원점은 지면 볼 앵커여야 한다 (카메라 높이 아님).
        XCTAssertEqual(transform.origin.worldY, 0.30, accuracy: 1e-12)
    }

    func testAimWorldDirectionMatchesPhysicsBetaSign() throws {
        // 볼 (0,0,0), 홀 (0,0,3) → +Z = 홀.
        // ARKit Y-up에서 진행방향 look의 우측은 look × up = −X.
        let ball = ScanPose(worldX: 0, worldY: 0.3, worldZ: 0, timestamp: 0)
        let hole = ScanPose(worldX: 0, worldY: 0.3, worldZ: 3, timestamp: 1)
        let transform = try ScanCoordinateTransform(ball: ball, hole: hole)

        let right = transform.aimWorldDirection(betaDegrees: 20)
        XCTAssertLessThan(right.dx, -0.2, "+β는 진행방향 기준 우측(홀=+Z이면 −X)")
        XCTAssertGreaterThan(right.dz, 0.8)

        let left = transform.aimWorldDirection(betaDegrees: -20)
        XCTAssertGreaterThan(left.dx, 0.2, "−β는 진행방향 기준 좌측(홀=+Z이면 +X)")

        let end = transform.world(localX: sin(-20 * .pi / 180) * 1.2, localY: cos(-20 * .pi / 180) * 1.2)
        XCTAssertGreaterThan(end.worldX, 0.2)
        XCTAssertGreaterThan(end.worldZ, 0.9)

        // 우측 기저가 look×up 인지 직접 확인
        XCTAssertEqual(transform.rightX, -1, accuracy: 1e-12)
        XCTAssertEqual(transform.rightZ, 0, accuracy: 1e-12)
    }

    func testFlatEquivalentMatchesGate2Defaults() {
        let v0 = 2.0
        let greenSpeed = 2.5
        let viaHelper = Gate55Validation.flatEquivalentDistance(
            initialVelocity: v0,
            greenSpeed: greenSpeed
        )
        let direct = FlatPuttPhysics.simulate(
            configuration: FlatPuttConfiguration(
                greenSpeed: greenSpeed,
                slopeDegrees: 0,
                initialVelocity: v0,
                initialDirectionDegrees: 0,
                holeDistance: 10_000,
                holeDirectionDegrees: 0
            ),
            recordTrajectory: false
        ).arcLength
        XCTAssertEqual(viaHelper, direct, accuracy: 1e-12)
        XCTAssertGreaterThan(viaHelper, 1.0)
    }

    /// 오르막이면 평지환산 > 실거리(더 세게), 내리막이면 그 반대.
    func testUphillNeedsHarderFlatEquivalentThanDownhill() throws {
        let uphill = try recommendOnUniformSlope(elevationDelta: 0.20, holeDistance: 5.2)
        let downhill = try recommendOnUniformSlope(elevationDelta: -0.20, holeDistance: 5.2)

        XCTAssertGreaterThan(uphill.elevationDelta, 0.15)
        XCTAssertLessThan(downhill.elevationDelta, -0.15)
        XCTAssertNotNil(uphill.primary)
        XCTAssertNotNil(downhill.primary)

        XCTAssertGreaterThan(
            uphill.flatEquivalentDistance,
            uphill.horizontalDistance,
            "오르막은 평지환산이 실거리보다 커야 함"
        )
        XCTAssertLessThan(
            downhill.flatEquivalentDistance,
            downhill.horizontalDistance,
            "내리막은 평지환산이 실거리보다 작아야 함"
        )
        XCTAssertGreaterThan(
            uphill.flatEquivalentDistance,
            downhill.flatEquivalentDistance,
            "같은 수평거리에서 오르막 평지환산 > 내리막 평지환산"
        )
    }

    /// 그린스피드를 낮출수록(느린 그린) 평지환산 안내 거리가 길어져야 한다.
    func testLowerGreenSpeedIncreasesFlatDisplayEquivalent() throws {
        let holeDistance = 5.0
        let cell = 0.05
        let width = 21
        let height = Int(ceil(holeDistance / cell)) + 5
        var heights = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let localY = Double(y) * cell - 0.2
                heights[y * width + x] = 0.35 * (localY / holeDistance)
            }
        }
        let gridContext = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: cell,
            originX: -0.5,
            originY: -0.2,
            width: width,
            height: height,
            heights: heights,
            holeDistance: holeDistance
        )
        let speeds = [1.8, 2.2, 2.6, 3.0, 3.4]
        let flats = speeds.map {
            Gate55Validation.recommend(
                context: gridContext,
                greenSpeed: $0,
                velocityPointCount: 45,
                directionPointCount: 45
            ).flatEquivalentDistance
        }
        for index in 0..<(flats.count - 1) {
            XCTAssertGreaterThan(
                flats[index],
                flats[index + 1],
                "느린 그린(\(speeds[index]))이 빠른 그린(\(speeds[index + 1]))보다 평지환산이 커야 함"
            )
        }
    }

    private func recommendOnUniformSlope(
        elevationDelta: Double,
        holeDistance: Double
    ) throws -> Gate55Recommendation {
        let cell = 0.05
        let width = 21
        let height = Int(ceil(holeDistance / cell)) + 5
        var heights = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let localY = Double(y) * cell - 0.2
                heights[y * width + x] = elevationDelta * (localY / holeDistance)
            }
        }
        let context = try Gate55Validation.contextFromMeasuredGrid(
            cellSize: cell,
            originX: -0.5,
            originY: -0.2,
            width: width,
            height: height,
            heights: heights,
            holeDistance: holeDistance
        )
        return Gate55Validation.recommend(context: context, greenSpeed: 2.5)
    }

    private func loadGreen(_ id: String) throws -> GreenHeightmap {
        let url = Bundle.module.url(forResource: "\(id).grnh", withExtension: "gz")
            ?? Bundle.module.url(forResource: id, withExtension: "grnh.gz")
            ?? Bundle.module.url(
                forResource: id,
                withExtension: "grnh.gz",
                subdirectory: "samples_all36"
            )
        let resolved = try XCTUnwrap(url, "missing resource \(id)")
        return try GreenHeightmapLoader.load(from: resolved)
    }
}
