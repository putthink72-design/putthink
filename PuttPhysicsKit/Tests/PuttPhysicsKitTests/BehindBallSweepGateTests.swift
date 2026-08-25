import XCTest
@testable import PuttPhysicsKit

final class BehindBallSweepGateTests: XCTestCase {
    private func context(
        ball: (x: Double, y: Double, z: Double) = (0, 0.3, 0),
        camera: (x: Double, y: Double, z: Double) = (0, 1.0, -1.2),
        forward: (x: Double, z: Double) = (0, 1)
    ) -> BehindBallSweepGate.Context {
        BehindBallSweepGate.Context(
            ballX: ball.x, ballY: ball.y, ballZ: ball.z,
            cameraX: camera.x, cameraY: camera.y, cameraZ: camera.z,
            forwardX: forward.x, forwardZ: forward.z
        )
    }

    func testAcceptsPointInForwardCone() {
        let ctx = context(camera: (0, 1.2, -0.3))
        let sample = BehindBallSweepGate.Sample(worldX: 0.1, worldY: 0.31, worldZ: 1.0, confidence: 2)
        XCTAssertTrue(BehindBallSweepGate.accepts(sample: sample, context: ctx))
    }

    func testRejectsLowConfidence() {
        let ctx = context()
        let sample = BehindBallSweepGate.Sample(worldX: 0, worldY: 0.31, worldZ: 2, confidence: 1)
        XCTAssertFalse(BehindBallSweepGate.accepts(sample: sample, context: ctx))
    }

    func testRejectsBehindBall() {
        let ctx = context()
        let sample = BehindBallSweepGate.Sample(worldX: 0, worldY: 0.31, worldZ: -1.0, confidence: 2)
        XCTAssertFalse(BehindBallSweepGate.accepts(sample: sample, context: ctx))
    }

    func testRejectsTooFar() {
        let ctx = context()
        let sample = BehindBallSweepGate.Sample(worldX: 0, worldY: 0.31, worldZ: 5.0, confidence: 2)
        XCTAssertFalse(BehindBallSweepGate.accepts(sample: sample, context: ctx))
    }

    func testRejectsGrazingRay() {
        let ctx = context(camera: (0, 1.0, 1.0))
        // 카메라가 거의 수평으로 멀리 있는 점 → elevation 너무 작음
        let sample = BehindBallSweepGate.Sample(worldX: 0, worldY: 0.31, worldZ: 3.5, confidence: 2)
        XCTAssertFalse(BehindBallSweepGate.accepts(sample: sample, context: ctx))
    }

    func testQualityMetThresholds() {
        let ok = BehindBallSweepGate.Stats(
            durationSeconds: 3,
            processedFrames: 10,
            acceptedSamples: 200,
            acceptedCells: 16,
            goodFrames: 5,
            qualityMet: false
        )
        XCTAssertTrue(BehindBallSweepGate.qualityMet(stats: ok))
        let weak = BehindBallSweepGate.Stats(
            durationSeconds: 3,
            processedFrames: 10,
            acceptedSamples: 50,
            acceptedCells: 8,
            goodFrames: 5,
            qualityMet: false
        )
        XCTAssertFalse(BehindBallSweepGate.qualityMet(stats: weak))
    }
}
