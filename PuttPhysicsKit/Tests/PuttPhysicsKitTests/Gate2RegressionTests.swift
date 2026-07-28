import Foundation
import XCTest
@testable import PuttPhysicsKit

final class Gate2RegressionTests: XCTestCase {
    private struct TrajectoryReference {
        let caseID: String
        let greenSpeed: Double
        let slopeDegrees: Double
        let initialVelocity: Double
        let initialDirectionDegrees: Double
        let holeDistance: Double
        let holeDirectionDegrees: Double
        let stopVelocity: Double
        let timeFinal: Double
        let timeDelta: Double
        let numberOfSteps: Int
        let ballHoleIf: Int
        let ballStopIf: Int
        let ballPassOverHoleIf: Int
        let arcLength: Double
        let finalPosition: PuttVector2
        let finalVelocity: PuttVector2
        let ballSpeedForHole: Double
    }

    private struct CheckpointReference {
        let caseID: String
        let stepIndex: Int
        let position: PuttVector2
        let arcLength: Double
        let speed: Double
    }

    private struct GridReference {
        let scanID: String
        let greenSpeed: Double
        let slopeDegrees: Double
        let holeDistance: Double
        let holeDirectionDegrees: Double
        let minimumVelocity: Double
        let maximumVelocity: Double
        let numberOfVelocityScans: Int
        let minimumDirectionDegrees: Double
        let maximumDirectionDegrees: Double
        let numberOfDirectionScans: Int
        let initialVelocity: Double
        let directionDegrees: Double
        let arcLength: Double
        let finalPosition: PuttVector2
        let finalVelocity: PuttVector2
        let ballSpeedForHole: Double
        let numberOfSteps: Int
    }

    func testReferenceCoverageMeetsGate2Requirements() throws {
        let references = try trajectoryReferences()
        XCTAssertEqual(references.count, 69)
        XCTAssertGreaterThanOrEqual(
            Double(references.filter {
                $0.slopeDegrees != 0 && $0.initialDirectionDegrees != 0
            }.count) / Double(references.count),
            0.5
        )
        XCTAssertEqual(references.filter { $0.ballHoleIf == 1 }.count, 12)
        XCTAssertEqual(references.filter { $0.ballPassOverHoleIf == 1 }.count, 2)
        XCTAssertEqual(references.filter { $0.ballStopIf == 1 }.count, 64)
        XCTAssertEqual(references.filter {
            $0.ballStopIf == 0 && $0.ballHoleIf == 0
        }.count, 5)
    }

    func testAll69FlatTrajectoriesMatchReference() throws {
        for reference in try trajectoryReferences() {
            let actual = FlatPuttPhysics.simulate(
                configuration: configuration(for: reference)
            )
            let context = reference.caseID

            XCTAssertEqual(actual.numberOfSteps, reference.numberOfSteps, context)
            XCTAssertEqual(actual.ballHoleIf, reference.ballHoleIf, context)
            XCTAssertEqual(actual.ballStopIf, reference.ballStopIf, context)
            XCTAssertEqual(actual.ballPassOverHoleIf, reference.ballPassOverHoleIf, context)
            XCTAssertEqual(actual.finalPosition.x, reference.finalPosition.x, accuracy: 0.001, context)
            XCTAssertEqual(actual.finalPosition.y, reference.finalPosition.y, accuracy: 0.001, context)
            XCTAssertEqual(actual.finalVelocity.x, reference.finalVelocity.x, accuracy: 1e-9, context)
            XCTAssertEqual(actual.finalVelocity.y, reference.finalVelocity.y, accuracy: 1e-9, context)
            XCTAssertEqual(actual.ballSpeedForHole, reference.ballSpeedForHole, accuracy: 1e-9, context)

            let denominator = max(abs(reference.arcLength), 1e-12)
            XCTAssertLessThan(abs(actual.arcLength - reference.arcLength) / denominator, 0.001, context)
        }
    }

    func testAll345TrajectoryCheckpointsMatchReference() throws {
        let configurations = Dictionary(
            uniqueKeysWithValues: try trajectoryReferences().map {
                ($0.caseID, configuration(for: $0))
            }
        )
        var results: [String: FlatPuttResult] = [:]
        for (caseID, configuration) in configurations {
            results[caseID] = FlatPuttPhysics.simulate(configuration: configuration)
        }

        let checkpoints = try checkpointReferences()
        XCTAssertEqual(checkpoints.count, 345)
        for checkpoint in checkpoints {
            let result = try XCTUnwrap(results[checkpoint.caseID], checkpoint.caseID)
            XCTAssertLessThan(checkpoint.stepIndex, result.trajectory.count, checkpoint.caseID)
            let actual = result.trajectory[checkpoint.stepIndex]
            let context = "\(checkpoint.caseID) step \(checkpoint.stepIndex)"
            XCTAssertEqual(actual.position.x, checkpoint.position.x, accuracy: 1e-9, context)
            XCTAssertEqual(actual.position.y, checkpoint.position.y, accuracy: 1e-9, context)
            XCTAssertEqual(actual.arcLength, checkpoint.arcLength, accuracy: 1e-9, context)
            XCTAssertEqual(actual.speed, checkpoint.speed, accuracy: 1e-9, context)
        }
    }

    func testAllFourGridScansMatchReferenceCandidateSets() throws {
        let grouped = Dictionary(grouping: try gridReferences(), by: \.scanID)
        XCTAssertEqual(Set(grouped.keys), Set(["S1", "S2", "S3", "S4"]))
        XCTAssertEqual(grouped.values.reduce(0) { $0 + $1.count }, 319)

        for scanID in ["S1", "S2", "S3", "S4"] {
            let expected = try XCTUnwrap(grouped[scanID], scanID)
            let first = try XCTUnwrap(expected.first, scanID)
            let actual = FlatPuttPhysics.scanInitialConditions(
                configuration: InitialConditionScanConfiguration(
                    greenSpeed: first.greenSpeed,
                    slopeDegrees: first.slopeDegrees,
                    minimumVelocity: first.minimumVelocity,
                    maximumVelocity: first.maximumVelocity,
                    numberOfVelocityScans: first.numberOfVelocityScans,
                    minimumDirectionDegrees: first.minimumDirectionDegrees,
                    maximumDirectionDegrees: first.maximumDirectionDegrees,
                    numberOfDirectionScans: first.numberOfDirectionScans,
                    holeDistance: first.holeDistance,
                    holeDirectionDegrees: first.holeDirectionDegrees
                )
            )

            XCTAssertEqual(actual.count, expected.count, "\(scanID) candidate count")
            guard actual.count == expected.count else { continue }
            for (candidate, reference) in zip(actual, expected) {
                let context = "\(scanID) v=\(reference.initialVelocity), beta=\(reference.directionDegrees)"
                XCTAssertEqual(candidate.initialVelocity, reference.initialVelocity, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.directionDegrees, reference.directionDegrees, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.result.ballHoleIf, 1, context)
                XCTAssertEqual(candidate.result.numberOfSteps, reference.numberOfSteps, context)
                XCTAssertEqual(candidate.result.arcLength, reference.arcLength, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.result.finalPosition.x, reference.finalPosition.x, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.result.finalPosition.y, reference.finalPosition.y, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.result.finalVelocity.x, reference.finalVelocity.x, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.result.finalVelocity.y, reference.finalVelocity.y, accuracy: 1e-9, context)
                XCTAssertEqual(candidate.result.ballSpeedForHole, reference.ballSpeedForHole, accuracy: 1e-9, context)
            }
        }
    }

    func testPurePhysicsFunctionsHaveKnownNeutralSlopeValues() {
        let acceleration = FlatPuttPhysics.computeAcceleration(
            vx: 0,
            vy: 2,
            alpha: 0,
            greenSpeed: 2.5
        )
        XCTAssertEqual(acceleration.ax, 0, accuracy: 1e-12)
        XCTAssertLessThan(acceleration.ay, 0)

        let result = FlatPuttPhysics.checkHoleCapture(
            position: PuttVector2(x: 0, y: 3),
            velocity: PuttVector2(x: 0, y: 0.5),
            holePosition: PuttVector2(x: 0, y: 3),
            alpha: 0,
            beta: 0
        )
        XCTAssertEqual(result, .captured)
    }

    private func configuration(for reference: TrajectoryReference) -> FlatPuttConfiguration {
        FlatPuttConfiguration(
            greenSpeed: reference.greenSpeed,
            slopeDegrees: reference.slopeDegrees,
            initialVelocity: reference.initialVelocity,
            initialDirectionDegrees: reference.initialDirectionDegrees,
            stopVelocity: reference.stopVelocity,
            timeFinal: reference.timeFinal,
            timeDelta: reference.timeDelta,
            holeDistance: reference.holeDistance,
            holeDirectionDegrees: reference.holeDirectionDegrees
        )
    }

    private func trajectoryReferences() throws -> [TrajectoryReference] {
        try csvRows(named: "regression_reference_trajectories").map { row in
            TrajectoryReference(
                caseID: row[0],
                greenSpeed: try double(row[2]),
                slopeDegrees: try double(row[3]),
                initialVelocity: try double(row[4]),
                initialDirectionDegrees: try double(row[5]),
                holeDistance: try double(row[6]),
                holeDirectionDegrees: try double(row[7]),
                stopVelocity: try double(row[8]),
                timeFinal: try double(row[9]),
                timeDelta: try double(row[10]),
                numberOfSteps: try integer(row[11]),
                ballHoleIf: try integer(row[12]),
                ballStopIf: try integer(row[13]),
                ballPassOverHoleIf: try integer(row[14]),
                arcLength: try double(row[15]),
                finalPosition: PuttVector2(x: try double(row[16]), y: try double(row[17])),
                finalVelocity: PuttVector2(x: try double(row[18]), y: try double(row[19])),
                ballSpeedForHole: try double(row[20])
            )
        }
    }

    private func checkpointReferences() throws -> [CheckpointReference] {
        try csvRows(named: "regression_reference_checkpoints").map { row in
            CheckpointReference(
                caseID: row[0],
                stepIndex: try integer(row[3]),
                position: PuttVector2(x: try double(row[4]), y: try double(row[5])),
                arcLength: try double(row[6]),
                speed: try double(row[7])
            )
        }
    }

    private func gridReferences() throws -> [GridReference] {
        try csvRows(named: "regression_reference_gridscan").map { row in
            GridReference(
                scanID: row[0],
                greenSpeed: try double(row[1]),
                slopeDegrees: try double(row[2]),
                holeDistance: try double(row[3]),
                holeDirectionDegrees: try double(row[4]),
                minimumVelocity: try double(row[5]),
                maximumVelocity: try double(row[6]),
                numberOfVelocityScans: try integer(row[7]),
                minimumDirectionDegrees: try double(row[8]),
                maximumDirectionDegrees: try double(row[9]),
                numberOfDirectionScans: try integer(row[10]),
                initialVelocity: try double(row[11]),
                directionDegrees: try double(row[12]),
                arcLength: try double(row[13]),
                finalPosition: PuttVector2(x: try double(row[14]), y: try double(row[15])),
                finalVelocity: PuttVector2(x: try double(row[16]), y: try double(row[17])),
                ballSpeedForHole: try double(row[18]),
                numberOfSteps: try integer(row[19])
            )
        }
    }

    private func csvRows(named name: String) throws -> [[String]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "csv"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private func double(_ value: String) throws -> Double {
        try XCTUnwrap(Double(value), value)
    }

    private func integer(_ value: String) throws -> Int {
        try XCTUnwrap(Int(value), value)
    }
}
