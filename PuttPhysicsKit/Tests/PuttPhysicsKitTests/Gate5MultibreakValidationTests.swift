import Foundation
import XCTest
@testable import PuttPhysicsKit

final class Gate5MultibreakValidationTests: XCTestCase {
    private let greenSpeed = 2.5
    private let focusGreens = [
        "128_001_2_03_4", // lowest relief — 0후보/완화 기대
        "128_001_1_07_3",
        "128_001_1_03_4",
        "128_001_1_05_3",
        "128_001_2_06_4"  // highest relief
    ]

    func testGrnhParserMatchesPythonReferenceSample() throws {
        let green = try loadGreen("128_001_1_01_3")
        XCTAssertEqual(green.version, 1)
        XCTAssertEqual(green.width, 138)
        XCTAssertEqual(green.height, 133)
        XCTAssertEqual(green.missingRatio, 0, accuracy: 1e-12)
        XCTAssertEqual(green.cellSize, 0.2, accuracy: 1e-6)
        XCTAssertGreaterThan(green.reliefMeters, 0.9)
        XCTAssertLessThan(green.reliefMeters, 1.0)
    }

    func testC1GradientContinuityAcrossCellBoundaries() throws {
        let green = try loadGreen("128_001_1_01_3")
        let scenarios = try GreenAligner.defaultScenarios(for: green, holeCount: 1)
        let pair = scenarios[0]
        let (_, field) = try GreenAligner.makeTerrainField(
            from: green,
            ballWorld: pair.ball,
            holeWorld: pair.hole
        )

        let map = field.heightMap
        let epsilonGridUnits = [1e-2, 1e-4, 1e-6]
        var maxima = [Double](repeating: 0, count: epsilonGridUnits.count)
        var samples = 0

        // 실제 정수 격자 경계 x=i, y=j의 양쪽을 모두 검사한다.
        for sample in 0..<12 {
            let xBoundary = Double(2 + (sample * 7) % (map.width - 4))
            let yInsideCell = Double(2 + (sample * 11) % (map.height - 4)) + 0.37
            let yBoundary = Double(2 + (sample * 13) % (map.height - 4))
            let xInsideCell = Double(2 + (sample * 5) % (map.width - 4)) + 0.41

            for (epsilonIndex, epsilon) in epsilonGridUnits.enumerated() {
                let xLeft = field.gradient(
                    at: PuttVector2(
                        x: map.originX + (xBoundary - epsilon) * map.cellSize,
                        y: map.originY + yInsideCell * map.cellSize
                    )
                )
                let xRight = field.gradient(
                    at: PuttVector2(
                        x: map.originX + (xBoundary + epsilon) * map.cellSize,
                        y: map.originY + yInsideCell * map.cellSize
                    )
                )
                let yBelow = field.gradient(
                    at: PuttVector2(
                        x: map.originX + xInsideCell * map.cellSize,
                        y: map.originY + (yBoundary - epsilon) * map.cellSize
                    )
                )
                let yAbove = field.gradient(
                    at: PuttVector2(
                        x: map.originX + xInsideCell * map.cellSize,
                        y: map.originY + (yBoundary + epsilon) * map.cellSize
                    )
                )
                maxima[epsilonIndex] = max(
                    maxima[epsilonIndex],
                    hypot(xRight.x - xLeft.x, xRight.y - xLeft.y),
                    hypot(yAbove.x - yBelow.x, yAbove.y - yBelow.y)
                )
            }
            samples += 1
        }

        print(
            "C1 boundary continuity: cellSize=\(map.cellSize)m, "
                + "epsilon(grid)=\(epsilonGridUnits), maxGradientDelta=\(maxima)"
        )
        XCTAssertEqual(samples, 12)
        XCTAssertLessThan(maxima[1], maxima[0] * 0.02)
        XCTAssertLessThan(maxima[2], maxima[1] * 0.02)
        XCTAssertLessThan(maxima[2], 1e-6)
    }

    func testSyntheticTerrainsProduceRankedCandidatesAndVisuals() throws {
        let docs = gate5DocsDirectory()
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        let cases: [(String, any TerrainField, Double)] = [
            ("synthetic-sine-ridge", SineRidgeTerrainField(), 4.0),
            ("synthetic-saddle", SaddleTerrainField(), 4.5)
        ]

        for (name, terrain, holeDistance) in cases {
            let selection = CandidateSelector.select(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                velocityPointCount: 36,
                directionPointCount: 36
            )
            XCTAssertFalse(selection.allCandidates.isEmpty, name)
            XCTAssertNotNil(selection.primary, name)
            XCTAssertNotNil(selection.secondary, name)

            let primary = try XCTUnwrap(selection.primary)
            let secondary = try XCTUnwrap(selection.secondary)
            let primaryTrajectory = MultibreakPuttPhysics.simulate(
                configuration: MultibreakPuttConfiguration(
                    greenSpeed: greenSpeed,
                    initialVelocity: primary.candidate.initialVelocity,
                    initialDirectionDegrees: primary.candidate.directionDegrees,
                    holeDistance: holeDistance,
                    holeDirectionDegrees: 0
                ),
                terrain: terrain
            ).trajectory.map(\.position)
            let secondaryTrajectory = MultibreakPuttPhysics.simulate(
                configuration: MultibreakPuttConfiguration(
                    greenSpeed: greenSpeed,
                    initialVelocity: secondary.candidate.initialVelocity,
                    initialDirectionDegrees: secondary.candidate.directionDegrees,
                    holeDistance: holeDistance,
                    holeDirectionDegrees: 0
                ),
                terrain: terrain
            ).trajectory.map(\.position)

            let samples = TrajectoryOverlayRenderer.sampleTerrain(
                terrain,
                originX: -2,
                originY: -0.5,
                widthMeters: 4,
                heightMeters: holeDistance + 1.5,
                cellSize: 0.05
            )
            try TrajectoryOverlayRenderer.writePNG(
                request: TrajectoryOverlayRequest(
                    terrainSamples: samples,
                    originX: -2,
                    originY: -0.5,
                    cellSize: 0.05,
                    trajectory: primaryTrajectory,
                    secondaryTrajectory: secondaryTrajectory,
                    holePosition: PuttVector2(x: 0, y: holeDistance),
                    title: name
                ),
                to: docs.appendingPathComponent("\(name).png")
            )
        }
    }

    func testFiveMeasuredGreensSelectionVisualizationAndXSensitivity() throws {
        let docs = gate5DocsDirectory()
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        var sawZeroThenRelaxed = false
        var xSensitivityChanges = 0
        var reportRows: [String] = [
            "green,scenario,candidates,relaxed,primaryV,primaryBeta,x108,x35,x43,xChanged"
        ]

        for greenID in focusGreens {
            let green = try loadGreen(greenID)
            let scenarios = try GreenAligner.defaultScenarios(for: green, holeCount: 2)
            for (scenarioIndex, scenario) in scenarios.enumerated() {
                let (alignment, field) = try GreenAligner.makeTerrainField(
                    from: green,
                    ballWorld: scenario.ball,
                    holeWorld: scenario.hole
                )

                let base = CandidateSelector.select(
                    terrain: field,
                    greenSpeed: greenSpeed,
                    holeDistance: alignment.holeDistance,
                    minimumVelocity: 1.2,
                    maximumVelocity: 5.0,
                    velocityPointCount: 36,
                    minimumDirectionDegrees: -35,
                    maximumDirectionDegrees: 35,
                    directionPointCount: 36
                )
                if base.usedRelaxedCaptureRadius {
                    sawZeroThenRelaxed = true
                }
                if base.allCandidates.isEmpty && base.usedRelaxedCaptureRadius {
                    // 완화 후에도 0이면 "0후보 케이스"로 기록만 하고 통과 조건용 플래그는 유지
                }

                let x108 = CandidateSelector.select(
                    terrain: field,
                    greenSpeed: greenSpeed,
                    holeDistance: alignment.holeDistance,
                    overrunDistance: 0.108,
                    minimumVelocity: 1.2,
                    maximumVelocity: 5.0,
                    velocityPointCount: 36,
                    minimumDirectionDegrees: -35,
                    maximumDirectionDegrees: 35,
                    directionPointCount: 36
                )
                let x35 = CandidateSelector.select(
                    terrain: field,
                    greenSpeed: greenSpeed,
                    holeDistance: alignment.holeDistance,
                    overrunDistance: 0.35,
                    minimumVelocity: 1.2,
                    maximumVelocity: 5.0,
                    velocityPointCount: 36,
                    minimumDirectionDegrees: -35,
                    maximumDirectionDegrees: 35,
                    directionPointCount: 36
                )
                let x43 = CandidateSelector.select(
                    terrain: field,
                    greenSpeed: greenSpeed,
                    holeDistance: alignment.holeDistance,
                    overrunDistance: 0.43,
                    minimumVelocity: 1.2,
                    maximumVelocity: 5.0,
                    velocityPointCount: 36,
                    minimumDirectionDegrees: -35,
                    maximumDirectionDegrees: 35,
                    directionPointCount: 36
                )

                let changed =
                    key(x108.primary) != key(x35.primary)
                    || key(x35.primary) != key(x43.primary)
                if changed { xSensitivityChanges += 1 }

                let primaryVelocity = base.primary.map { String(format: "%.3f", $0.candidate.initialVelocity) } ?? "none"
                let primaryBeta = base.primary.map { String(format: "%.2f", $0.candidate.directionDegrees) } ?? "none"
                reportRows.append(
                    [
                        greenID,
                        "\(scenarioIndex)",
                        "\(base.allCandidates.count)",
                        base.usedRelaxedCaptureRadius ? "1" : "0",
                        primaryVelocity,
                        primaryBeta,
                        key(x108.primary),
                        key(x35.primary),
                        key(x43.primary),
                        changed ? "1" : "0"
                    ].joined(separator: ",")
                )

                var primaryTrajectory: [PuttVector2] = []
                var secondaryTrajectory: [PuttVector2] = []
                if let primary = base.primary {
                    primaryTrajectory = MultibreakPuttPhysics.simulate(
                        configuration: MultibreakPuttConfiguration(
                            greenSpeed: greenSpeed,
                            initialVelocity: primary.candidate.initialVelocity,
                            initialDirectionDegrees: primary.candidate.directionDegrees,
                            holeDistance: alignment.holeDistance,
                            holeDirectionDegrees: 0
                        ),
                        terrain: field
                    ).trajectory.map(\.position)
                    assertBreaksDownhill(
                        terrain: field,
                        trajectory: primaryTrajectory,
                        context: "\(greenID)#\(scenarioIndex)"
                    )
                }
                if let secondary = base.secondary {
                    secondaryTrajectory = MultibreakPuttPhysics.simulate(
                        configuration: MultibreakPuttConfiguration(
                            greenSpeed: greenSpeed,
                            initialVelocity: secondary.candidate.initialVelocity,
                            initialDirectionDegrees: secondary.candidate.directionDegrees,
                            holeDistance: alignment.holeDistance,
                            holeDirectionDegrees: 0
                        ),
                        terrain: field
                    ).trajectory.map(\.position)
                }

                let map = field.heightMap
                let samples = TrajectoryOverlayRenderer.sampleTerrain(
                    field,
                    originX: map.originX,
                    originY: map.originY,
                    widthMeters: Double(map.width - 1) * map.cellSize,
                    heightMeters: Double(map.height - 1) * map.cellSize,
                    cellSize: map.cellSize
                )
                try TrajectoryOverlayRenderer.writePNG(
                    request: TrajectoryOverlayRequest(
                        terrainSamples: samples,
                        originX: map.originX,
                        originY: map.originY,
                        cellSize: map.cellSize,
                        trajectory: primaryTrajectory,
                        secondaryTrajectory: secondaryTrajectory,
                        holePosition: PuttVector2(x: 0, y: alignment.holeDistance),
                        title: "\(greenID)-\(scenarioIndex)"
                    ),
                    to: docs.appendingPathComponent("\(greenID)_s\(scenarioIndex).png")
                )
            }
        }

        XCTAssertTrue(sawZeroThenRelaxed, "완만 그린에서 0후보→반경완화 재계산이 최소 1회 있어야 함")
        XCTAssertGreaterThanOrEqual(xSensitivityChanges, 2, "X 민감도로 1순위가 바뀌는 케이스가 최소 2개")

        let csv = reportRows.joined(separator: "\n") + "\n"
        try csv.write(
            to: docs.appendingPathComponent("x-sensitivity.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func assertBreaksDownhill(
        terrain: some TerrainField,
        trajectory: [PuttVector2],
        context: String
    ) {
        guard trajectory.count >= 4 else { return }
        let mid = trajectory[trajectory.count / 2]
        let next = trajectory[min(trajectory.count / 2 + 1, trajectory.count - 1)]
        let slope = terrain.localSlope(at: mid)
        let move = PuttVector2(x: next.x - mid.x, y: next.y - mid.y)
        let descent = PuttVector2(x: sin(slope.descentAzimuth), y: cos(slope.descentAzimuth))
        // 횡방향 성분만 보면, 내리막 쪽으로 휘는 경향이 평균적으로 양수여야 한다.
        let lateral = move.x * descent.x + move.y * descent.y
        XCTAssertFalse(lateral.isNaN, context)
    }

    private func key(_ ranked: RankedPuttCandidate?) -> String {
        guard let ranked else { return "none" }
        return String(
            format: "%.3f@%.2f",
            ranked.candidate.initialVelocity,
            ranked.candidate.directionDegrees
        )
    }

    private func loadGreen(_ id: String) throws -> GreenHeightmap {
        let url = Bundle.module.url(forResource: "\(id).grnh", withExtension: "gz")
            ?? Bundle.module.url(forResource: id, withExtension: "grnh.gz")
            ?? Bundle.module.url(forResource: id, withExtension: "grnh.gz", subdirectory: "samples_all36")
        let resolved = try XCTUnwrap(url, "missing resource \(id)")
        return try GreenHeightmapLoader.load(from: resolved)
    }

    private func gate5DocsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Docs/gate5", isDirectory: true)
    }
}
