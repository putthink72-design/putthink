import XCTest
@testable import PuttPhysicsKit

final class Gate3ParallelScanTests: XCTestCase {
    func testExactGridCombinationCounts() {
        XCTAssertEqual(configuration(pointCount: 30).combinationCount, 900)
        XCTAssertEqual(configuration(pointCount: 130).combinationCount, 16_900)
    }

    func testSinglePointGridUsesMinimumValues() {
        var configuration = configuration(pointCount: 1)
        configuration.minimumVelocity = 1.75
        configuration.maximumVelocity = 4.0
        configuration.minimumDirectionDegrees = -7
        configuration.maximumDirectionDegrees = 20

        let serial = FlatPuttPhysics.scanExactGridSerial(configuration: configuration)
        let parallel = FlatPuttPhysics.scanExactGridParallel(configuration: configuration)

        XCTAssertEqual(parallel, serial)
        for candidate in serial {
            XCTAssertEqual(candidate.initialVelocity, 1.75)
            XCTAssertEqual(candidate.directionDegrees, -7)
        }
    }

    func testSerialAndParallelThirtyByThirtyAreIdentical() {
        let configuration = configuration(pointCount: 30)

        let serial = FlatPuttPhysics.scanExactGridSerial(configuration: configuration)
        let parallel = FlatPuttPhysics.scanExactGridParallel(configuration: configuration)

        XCTAssertFalse(serial.isEmpty)
        XCTAssertEqual(parallel, serial)
    }

    func testSerialAndParallelOneHundredThirtyByOneHundredThirtyAreIdentical() {
        let configuration = configuration(pointCount: 130)

        let serial = FlatPuttPhysics.scanExactGridSerial(configuration: configuration)
        let parallel = FlatPuttPhysics.scanExactGridParallel(configuration: configuration)

        XCTAssertFalse(serial.isEmpty)
        XCTAssertEqual(parallel, serial)
    }

    func testMultibreakSerialAndParallelAreIdentical() {
        // 지형 경로(다중브레이크)에서도 병렬 탐색이 직렬과 후보·순서까지 일치해야 한다.
        let terrain = DualPlaneTerrainField(
            alphaADegrees: 1.5,
            orientationADegrees: 0,
            alphaBDegrees: 2.5,
            orientationBDegrees: 35,
            boundaryY: 1.5
        )
        let serial = MultibreakPuttPhysics.scanExactGridSerial(
            terrain: terrain,
            greenSpeed: 2.5,
            holeDistance: 3,
            minimumVelocity: 1,
            maximumVelocity: 3,
            velocityPointCount: 40,
            minimumDirectionDegrees: -13,
            maximumDirectionDegrees: 13,
            directionPointCount: 40
        )
        let parallel = MultibreakPuttPhysics.scanExactGridParallel(
            terrain: terrain,
            greenSpeed: 2.5,
            holeDistance: 3,
            minimumVelocity: 1,
            maximumVelocity: 3,
            velocityPointCount: 40,
            minimumDirectionDegrees: -13,
            maximumDirectionDegrees: 13,
            directionPointCount: 40
        )
        XCTAssertFalse(serial.isEmpty)
        XCTAssertEqual(parallel, serial)
    }

    private func configuration(pointCount: Int) -> ExactGridScanConfiguration {
        ExactGridScanConfiguration(
            greenSpeed: 2.5,
            slopeDegrees: 2,
            minimumVelocity: 1,
            maximumVelocity: 3,
            velocityPointCount: pointCount,
            minimumDirectionDegrees: -13,
            maximumDirectionDegrees: 13,
            directionPointCount: pointCount,
            holeDistance: 3,
            holeDirectionDegrees: 0
        )
    }
}
