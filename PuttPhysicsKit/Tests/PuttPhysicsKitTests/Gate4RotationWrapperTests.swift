import Foundation
import XCTest
@testable import PuttPhysicsKit

final class Gate4RotationWrapperTests: XCTestCase {
    private let greenSpeed = 2.5
    private let positionTolerance = 1e-4 // 0.1 mm

    func testFrameRotationMapsLocalGravityOntoDescent() {
        // 국소 중력 방향 (−1, 0)을 회전하면 전역 하강 단위벡터와 일치해야 한다.
        let samples: [Double] = [-.pi / 2, 0, .pi / 2, .pi, -.pi, 0.35, -1.1]
        for descent in samples {
            let psi = MultibreakPuttPhysics.frameRotation(forDescentAzimuth: descent)
            let mapped = MultibreakPuttPhysics.rotate(PuttVector2(x: -1, y: 0), by: psi)
            let expected = PuttVector2(x: sin(descent), y: cos(descent))
            XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-12, "d=\(descent)")
            XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-12, "d=\(descent)")
        }
    }

    func testOriginalAxisPlaneMatchesFlatEngine() {
        let alphaDegrees = 2.0
        let terrain = DualPlaneTerrainField(
            alphaADegrees: alphaDegrees,
            orientationADegrees: 0,
            alphaBDegrees: alphaDegrees,
            orientationBDegrees: 0,
            boundaryY: 100
        )
        let configuration = MultibreakPuttConfiguration(
            greenSpeed: greenSpeed,
            initialVelocity: 2.4,
            initialDirectionDegrees: 4,
            holeDistance: 4,
            holeDirectionDegrees: 0
        )

        let wrapped = MultibreakPuttPhysics.simulate(
            configuration: configuration,
            terrain: terrain
        )
        let flat = FlatPuttPhysics.simulate(
            configuration: FlatPuttConfiguration(
                greenSpeed: greenSpeed,
                slopeDegrees: alphaDegrees,
                initialVelocity: configuration.initialVelocity,
                initialDirectionDegrees: configuration.initialDirectionDegrees,
                holeDistance: configuration.holeDistance,
                holeDirectionDegrees: configuration.holeDirectionDegrees
            )
        )

        assertResultsMatch(wrapped, flat, context: "θ=0 original axis")
    }

    func testRotatedPlaneMatchesRotatedFlatEngine() {
        let alphaDegrees = 3.0
        let orientation = 35.0
        let terrain = DualPlaneTerrainField(
            alphaADegrees: alphaDegrees,
            orientationADegrees: orientation,
            alphaBDegrees: 1,
            orientationBDegrees: 10,
            boundaryY: 100
        )
        let configuration = MultibreakPuttConfiguration(
            greenSpeed: greenSpeed,
            initialVelocity: 2.6,
            initialDirectionDegrees: -6,
            holeDistance: 5,
            holeDirectionDegrees: 2
        )

        let wrapped = MultibreakPuttPhysics.simulate(
            configuration: configuration,
            terrain: terrain
        )
        let reference = simulateFlatInOrientedFrame(
            alphaDegrees: alphaDegrees,
            orientationDegrees: orientation,
            configuration: configuration
        )

        assertResultsMatch(wrapped, reference, context: "θ=35° oriented plane")
    }

    func testOrientationSymmetryIsMirrorAcrossY() {
        let alphaDegrees = 2.5
        let configuration = MultibreakPuttConfiguration(
            greenSpeed: greenSpeed,
            initialVelocity: 2.2,
            initialDirectionDegrees: 0,
            holeDistance: 3.5,
            holeDirectionDegrees: 0
        )
        let direct = MultibreakPuttPhysics.simulate(
            configuration: configuration,
            terrain: DualPlaneTerrainField(
                alphaADegrees: alphaDegrees,
                orientationADegrees: 0,
                alphaBDegrees: alphaDegrees,
                orientationBDegrees: 0,
                boundaryY: 100
            )
        )
        let opposite = MultibreakPuttPhysics.simulate(
            configuration: configuration,
            terrain: DualPlaneTerrainField(
                alphaADegrees: alphaDegrees,
                orientationADegrees: 180,
                alphaBDegrees: alphaDegrees,
                orientationBDegrees: 180,
                boundaryY: 100
            )
        )

        XCTAssertEqual(opposite.numberOfSteps, direct.numberOfSteps)
        XCTAssertEqual(opposite.ballHoleIf, direct.ballHoleIf)
        XCTAssertEqual(opposite.ballStopIf, direct.ballStopIf)
        XCTAssertEqual(
            opposite.finalPosition.x,
            -direct.finalPosition.x,
            accuracy: positionTolerance
        )
        XCTAssertEqual(
            opposite.finalPosition.y,
            direct.finalPosition.y,
            accuracy: positionTolerance
        )
        for (index, pair) in zip(direct.trajectory, opposite.trajectory).enumerated() {
            XCTAssertEqual(
                pair.1.position.x,
                -pair.0.position.x,
                accuracy: positionTolerance,
                "mirror traj[\(index)].x"
            )
            XCTAssertEqual(
                pair.1.position.y,
                pair.0.position.y,
                accuracy: positionTolerance,
                "mirror traj[\(index)].y"
            )
        }
    }

    func testCardinalAndArbitraryOrientationsMatchRotatedFlatEngine() {
        let orientations: [Double] = [0, 90, 180, 270, 25, -40]
        let alphaDegrees = 2.0
        for orientation in orientations {
            let configuration = MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: 2.5,
                initialDirectionDegrees: 5,
                holeDistance: 4,
                holeDirectionDegrees: -1
            )
            let terrain = DualPlaneTerrainField(
                alphaADegrees: alphaDegrees,
                orientationADegrees: orientation,
                alphaBDegrees: 0.5,
                orientationBDegrees: 10,
                boundaryY: 100
            )
            let wrapped = MultibreakPuttPhysics.simulate(
                configuration: configuration,
                terrain: terrain
            )
            let reference = simulateFlatInOrientedFrame(
                alphaDegrees: alphaDegrees,
                orientationDegrees: orientation,
                configuration: configuration
            )
            assertResultsMatch(wrapped, reference, context: "θ=\(orientation)°")
        }
    }

    func testLocalSlopeUsesAtanOfGradientMagnitude() {
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 4,
            orientationADegrees: 20,
            alphaBDegrees: 4,
            orientationBDegrees: 20,
            boundaryY: 100
        )
        let slope = terrain.localSlope(at: PuttVector2(x: 0.1, y: 0.2))
        let gradient = terrain.gradient(at: PuttVector2(x: 0.1, y: 0.2))
        XCTAssertEqual(slope.alpha, atan(gradient.magnitude), accuracy: 1e-12)
        XCTAssertEqual(
            slope.descentAzimuth,
            atan2(-gradient.x, -gradient.y),
            accuracy: 1e-12
        )
    }

    func testHeightMapTerrainFieldInterpolatesPrecomputedGradient() throws {
        let cellSize = 0.05
        var values = Array(repeating: 0.0, count: 11 * 11)
        for y in 0..<11 {
            for x in 0..<11 {
                let worldX = Double(x) * cellSize
                let worldY = Double(y) * cellSize
                values[y * 11 + x] = 0.03 * worldX - 0.02 * worldY
            }
        }
        let map = HeightMap(
            cellSize: cellSize,
            originX: 0,
            originY: 0,
            width: 11,
            height: 11,
            values: values,
            measuredMask: Array(repeating: true, count: values.count),
            interpolatedMask: Array(repeating: false, count: values.count)
        )
        let gradient = GradientFieldBuilder.build(from: map)
        let field = HeightMapTerrainField(heightMap: map, gradientField: gradient)
        let sample = field.gradient(at: PuttVector2(x: 0.23, y: 0.17))
        XCTAssertEqual(sample.x, 0.03, accuracy: 1e-6)
        XCTAssertEqual(sample.y, -0.02, accuracy: 1e-6)
    }

    func testBoundaryCrossingVisualizationsAreWritten() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Docs/gate4", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        let cases: [(String, DualPlaneTerrainField, MultibreakPuttConfiguration)] = [
            (
                "boundary-cross-downhill-then-sidehill",
                DualPlaneTerrainField(
                    alphaADegrees: 1.5,
                    orientationADegrees: 0,
                    alphaBDegrees: 3.5,
                    orientationBDegrees: 90,
                    boundaryY: 2.0
                ),
                MultibreakPuttConfiguration(
                    greenSpeed: greenSpeed,
                    initialVelocity: 3.2,
                    initialDirectionDegrees: 2,
                    holeDistance: 4.5,
                    holeDirectionDegrees: 0
                )
            ),
            (
                "boundary-cross-opposite-sideslope",
                DualPlaneTerrainField(
                    alphaADegrees: 2.5,
                    orientationADegrees: 0,
                    alphaBDegrees: 2.5,
                    orientationBDegrees: 180,
                    boundaryY: 1.8
                ),
                MultibreakPuttConfiguration(
                    greenSpeed: greenSpeed,
                    initialVelocity: 3.0,
                    initialDirectionDegrees: -3,
                    holeDistance: 4.0,
                    holeDirectionDegrees: 0
                )
            ),
            (
                "boundary-cross-skewed-break",
                DualPlaneTerrainField(
                    alphaADegrees: 2.0,
                    orientationADegrees: 25,
                    alphaBDegrees: 4.0,
                    orientationBDegrees: -55,
                    boundaryY: 2.2
                ),
                MultibreakPuttConfiguration(
                    greenSpeed: greenSpeed,
                    initialVelocity: 3.4,
                    initialDirectionDegrees: 5,
                    holeDistance: 5.0,
                    holeDirectionDegrees: -2
                )
            )
        ]

        for (name, terrain, configuration) in cases {
            let result = MultibreakPuttPhysics.simulate(
                configuration: configuration,
                terrain: terrain
            )
            XCTAssertGreaterThan(result.trajectory.count, 10, name)
            let crossed = result.trajectory.contains { $0.position.y >= terrain.boundaryY }
                && result.trajectory.contains { $0.position.y < terrain.boundaryY }
            XCTAssertTrue(crossed, "trajectory should cross boundary: \(name)")

            let samples = TrajectoryOverlayRenderer.sampleTerrain(
                terrain,
                originX: -1.5,
                originY: -0.5,
                widthMeters: 3.0,
                heightMeters: 6.0,
                cellSize: 0.05
            )
            let holeBeta = configuration.holeDirectionDegrees * .pi / 180.0
            let request = TrajectoryOverlayRequest(
                terrainSamples: samples,
                originX: -1.5,
                originY: -0.5,
                cellSize: 0.05,
                trajectory: result.trajectory.map(\.position),
                holePosition: PuttVector2(
                    x: configuration.holeDistance * sin(holeBeta),
                    y: configuration.holeDistance * cos(holeBeta)
                ),
                boundaryY: terrain.boundaryY,
                title: name
            )
            let url = docs.appendingPathComponent("\(name).png")
            try TrajectoryOverlayRenderer.writePNG(request: request, to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        }
    }

    private func simulateFlatInOrientedFrame(
        alphaDegrees: Double,
        orientationDegrees: Double,
        configuration: MultibreakPuttConfiguration
    ) -> FlatPuttResult {
        // DualPlaneTerrainField: descentAzimuth = orientation − π/2.
        // 래퍼와 동일한 frameRotation으로 국소(하강=−X) 프레임에 맞춘다.
        let descentAzimuth = orientationDegrees * .pi / 180.0 - .pi / 2.0
        let orientation = MultibreakPuttPhysics.frameRotation(forDescentAzimuth: descentAzimuth)
        let initialBeta = configuration.initialDirectionDegrees * .pi / 180.0
        let holeBeta = configuration.holeDirectionDegrees * .pi / 180.0
        let globalVelocity = PuttVector2(
            x: configuration.initialVelocity * sin(initialBeta),
            y: configuration.initialVelocity * cos(initialBeta)
        )
        let globalHole = PuttVector2(
            x: configuration.holeDistance * sin(holeBeta),
            y: configuration.holeDistance * cos(holeBeta)
        )
        let localVelocity = MultibreakPuttPhysics.rotate(globalVelocity, by: -orientation)
        let localHole = MultibreakPuttPhysics.rotate(globalHole, by: -orientation)
        let localBeta = atan2(localVelocity.x, localVelocity.y) * 180.0 / .pi
        let localHoleBeta = atan2(localHole.x, localHole.y) * 180.0 / .pi
        let localHoleDistance = localHole.magnitude

        let localResult = FlatPuttPhysics.simulate(
            configuration: FlatPuttConfiguration(
                greenSpeed: configuration.greenSpeed,
                slopeDegrees: alphaDegrees,
                initialVelocity: configuration.initialVelocity,
                initialDirectionDegrees: localBeta,
                stopVelocity: configuration.stopVelocity,
                timeFinal: configuration.timeFinal,
                timeDelta: configuration.timeDelta,
                holeDistance: localHoleDistance,
                holeDirectionDegrees: localHoleBeta
            )
        )

        var rotated = localResult
        rotated.finalPosition = MultibreakPuttPhysics.rotate(localResult.finalPosition, by: orientation)
        rotated.finalVelocity = MultibreakPuttPhysics.rotate(localResult.finalVelocity, by: orientation)
        rotated.trajectory = localResult.trajectory.map { sample in
            TrajectorySample(
                position: MultibreakPuttPhysics.rotate(sample.position, by: orientation),
                arcLength: sample.arcLength,
                speed: sample.speed
            )
        }
        return rotated
    }

    private func assertResultsMatch(
        _ actual: FlatPuttResult,
        _ expected: FlatPuttResult,
        context: String
    ) {
        XCTAssertEqual(actual.numberOfSteps, expected.numberOfSteps, context)
        XCTAssertEqual(actual.ballHoleIf, expected.ballHoleIf, context)
        XCTAssertEqual(actual.ballStopIf, expected.ballStopIf, context)
        XCTAssertEqual(actual.ballPassOverHoleIf, expected.ballPassOverHoleIf, context)
        XCTAssertEqual(actual.finalPosition.x, expected.finalPosition.x, accuracy: positionTolerance, context)
        XCTAssertEqual(actual.finalPosition.y, expected.finalPosition.y, accuracy: positionTolerance, context)
        XCTAssertEqual(actual.arcLength, expected.arcLength, accuracy: positionTolerance, context)
        XCTAssertEqual(actual.trajectory.count, expected.trajectory.count, context)
        for (index, pair) in zip(actual.trajectory, expected.trajectory).enumerated() {
            XCTAssertEqual(
                pair.0.position.x,
                pair.1.position.x,
                accuracy: positionTolerance,
                "\(context) traj[\(index)].x"
            )
            XCTAssertEqual(
                pair.0.position.y,
                pair.1.position.y,
                accuracy: positionTolerance,
                "\(context) traj[\(index)].y"
            )
        }
    }
}
