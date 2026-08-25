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

    func testQualityMetRequiresWalkDistanceAndRibbon() {
        let ok = WalkCorridorGate.Stats(
            durationSeconds: 3,
            processedFrames: 12,
            ribbonSamples: 400,
            ribbonCells: 22,
            goodFrames: 4,
            maxDistanceFromBall: 2.0,
            inBandFrameCount: 8,
            qualityMet: false
        )
        XCTAssertTrue(WalkCorridorGate.qualityMet(stats: ok))

        let shortWalk = WalkCorridorGate.Stats(
            durationSeconds: 3,
            processedFrames: 12,
            ribbonSamples: 400,
            ribbonCells: 22,
            goodFrames: 4,
            maxDistanceFromBall: 0.8,
            inBandFrameCount: 8,
            qualityMet: false
        )
        XCTAssertFalse(WalkCorridorGate.qualityMet(stats: shortWalk))
    }
}
