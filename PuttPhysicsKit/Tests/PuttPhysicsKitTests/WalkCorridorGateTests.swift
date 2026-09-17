import XCTest
@testable import PuttPhysicsKit

final class WalkCorridorGateTests: XCTestCase {
    private func context(
        ball: (x: Double, y: Double, z: Double) = (0, 0.3, 0),
        camera: (x: Double, y: Double, z: Double) = (0.4, 1.1, 2.0),
        forward: (x: Double, z: Double) = (0, 1)
    ) -> WalkCorridorGate.Context {
        WalkCorridorGate.Context(
            ballX: ball.x, ballY: ball.y, ballZ: ball.z,
            cameraX: camera.x, cameraY: camera.y, cameraZ: camera.z,
            forwardX: forward.x, forwardZ: forward.z
        )
    }

    func testCountsPointOnLineRibbon() {
        let ctx = context()
        let sample = WalkCorridorGate.Sample(worldX: 0.05, worldY: 0.31, worldZ: 1.5, confidence: 2)
        XCTAssertTrue(WalkCorridorGate.countsTowardRibbon(sample: sample, context: ctx))
    }

    func testRejectsFarOffLine() {
        let ctx = context()
        let sample = WalkCorridorGate.Sample(worldX: 1.5, worldY: 0.31, worldZ: 1.5, confidence: 2)
        XCTAssertFalse(WalkCorridorGate.countsTowardRibbon(sample: sample, context: ctx))
    }

    func testQualityMetAllowsShortPuttWithoutWalkingPastHole() {
        let fromAddress = WalkCorridorGate.Stats(
            durationSeconds: 0.4,
            processedFrames: 8,
            ribbonSamples: 200,
            ribbonCells: 22,
            goodFrames: 4,
            maxDistanceFromBall: 0.8,
            inBandFrameCount: 6,
            qualityMet: false
        )
        XCTAssertTrue(WalkCorridorGate.qualityMet(stats: fromAddress))

        let aroundTwoMeters = WalkCorridorGate.Stats(
            durationSeconds: 0.5,
            processedFrames: 8,
            ribbonSamples: 200,
            ribbonCells: 22,
            goodFrames: 4,
            maxDistanceFromBall: 2.0,
            inBandFrameCount: 6,
            qualityMet: false
        )
        XCTAssertTrue(WalkCorridorGate.qualityMet(stats: aroundTwoMeters))

        let thinRibbon = WalkCorridorGate.Stats(
            durationSeconds: 3,
            processedFrames: 12,
            ribbonSamples: 10,
            ribbonCells: 5,
            goodFrames: 1,
            maxDistanceFromBall: 0.8,
            inBandFrameCount: 8,
            qualityMet: false
        )
        XCTAssertFalse(WalkCorridorGate.qualityMet(stats: thinRibbon))
    }

    func testQualityMetLongWalkStillNeedsDuration() {
        let rushed = WalkCorridorGate.Stats(
            durationSeconds: 0.4,
            processedFrames: 4,
            ribbonSamples: 200,
            ribbonCells: 22,
            goodFrames: 4,
            maxDistanceFromBall: 4.0,
            inBandFrameCount: 3,
            qualityMet: false
        )
        XCTAssertFalse(WalkCorridorGate.qualityMet(stats: rushed))

        let walked = WalkCorridorGate.Stats(
            durationSeconds: 2.2,
            processedFrames: 12,
            ribbonSamples: 400,
            ribbonCells: 22,
            goodFrames: 4,
            maxDistanceFromBall: 4.0,
            inBandFrameCount: 8,
            qualityMet: false
        )
        XCTAssertTrue(WalkCorridorGate.qualityMet(stats: walked))
    }
}
