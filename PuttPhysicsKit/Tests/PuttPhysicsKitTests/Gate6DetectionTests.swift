import Foundation
import XCTest
@testable import PuttPhysicsKit

final class Gate6DetectionTests: XCTestCase {
    func testBallProtrusionAccepted() {
        let depth = makeDepthMap(width: 64, height: 64) { x, y, w, h in
            let cx = Double(w) * 0.5
            let cy = Double(h) * 0.5
            let dist = hypot(Double(x) - cx, Double(y) - cy)
            // 카메라 거리: 중심이 2.5cm 더 가까움 (돌출)
            return dist < 4 ? 1.48 : 1.50
        }
        let candidate = Gate6ImageCandidate(
            kind: .ball,
            normalizedX: 0.5,
            normalizedY: 0.5,
            radiusNorm: 0.06,
            score: 0.9
        )
        let result = Gate6Detection.crossCheckDepth(kind: .ball, depth: depth, candidate: candidate)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertLessThan(result.deltaMeters ?? 0, 0)
    }

    func testHoleDepressionAccepted() {
        let depth = makeDepthMap(width: 64, height: 64) { x, y, w, h in
            let cx = Double(w) * 0.5
            let cy = Double(h) * 0.5
            let dist = hypot(Double(x) - cx, Double(y) - cy)
            // 함몰: 중심이 3cm 더 멀음
            return dist < 5 ? 1.53 : 1.50
        }
        let candidate = Gate6ImageCandidate(
            kind: .hole,
            normalizedX: 0.5,
            normalizedY: 0.5,
            radiusNorm: 0.08,
            score: 0.85
        )
        let result = Gate6Detection.crossCheckDepth(kind: .hole, depth: depth, candidate: candidate)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertGreaterThan(result.deltaMeters ?? 0, 0)
    }

    func testFlatShadowRejectedAsFlat() {
        // 그림자: RGB는 어두워도 depth는 평탄
        let depth = makeDepthMap(width: 48, height: 48) { _, _, _, _ in 1.50 }
        let candidate = Gate6ImageCandidate(
            kind: .hole,
            normalizedX: 0.5,
            normalizedY: 0.5,
            radiusNorm: 0.08,
            score: 0.95
        )
        let result = Gate6Detection.crossCheckDepth(kind: .hole, depth: depth, candidate: candidate)
        XCTAssertEqual(result.verdict, .rejectedFlat)
    }

    func testBallOnDepressionRejectedWrongSign() {
        let depth = makeDepthMap(width: 48, height: 48) { x, y, w, h in
            let dist = hypot(Double(x) - Double(w) * 0.5, Double(y) - Double(h) * 0.5)
            return dist < 4 ? 1.54 : 1.50
        }
        let candidate = Gate6ImageCandidate(
            kind: .ball,
            normalizedX: 0.5,
            normalizedY: 0.5,
            radiusNorm: 0.06,
            score: 0.8
        )
        let result = Gate6Detection.crossCheckDepth(kind: .ball, depth: depth, candidate: candidate)
        XCTAssertEqual(result.verdict, .rejectedWrongSign)
    }

    func testSelectBestFiltersFalsePositives() {
        let depth = makeDepthMap(width: 80, height: 80) { x, y, w, h in
            let dist = hypot(Double(x) - Double(w) * 0.4, Double(y) - Double(h) * 0.4)
            return dist < 4 ? 1.48 : 1.50
        }
        let trueBall = Gate6ImageCandidate(
            kind: .ball, normalizedX: 0.4, normalizedY: 0.4, radiusNorm: 0.05, score: 0.7
        )
        let shadow = Gate6ImageCandidate(
            kind: .ball, normalizedX: 0.7, normalizedY: 0.7, radiusNorm: 0.05, score: 0.95
        )
        let (best, rejected, rgbCount) = Gate6Detection.selectBest(
            kind: .ball,
            candidates: [shadow, trueBall],
            depth: depth
        )
        XCTAssertEqual(rgbCount, 2)
        XCTAssertEqual(rejected, 1, "평탄 그림자 후보는 깊이에서 기각")
        XCTAssertEqual(try XCTUnwrap(best).candidate.normalizedX, 0.4, accuracy: 1e-9)
        XCTAssertTrue(try XCTUnwrap(best).depth.accepted)
    }

    func testBrightBallOnWoodLikeBackground() {
        // 나무바닥(~110) 위 흰 공(~220)
        var luma = [UInt8](repeating: 110, count: 80 * 80)
        for y in 36...44 {
            for x in 36...44 {
                luma[y * 80 + x] = 220
            }
        }
        let candidates = Gate6Detection.extractBrightBallCandidates(
            luma: luma,
            width: 80,
            height: 80,
            minAbsoluteLuma: 150
        )
        XCTAssertFalse(candidates.isEmpty, "나무색 배경의 흰 공을 RGB에서 찾아야 함")
        XCTAssertEqual(candidates.first?.normalizedX ?? 0, 0.5, accuracy: 0.12)
    }

    func testDepthFilterRatioOnShadowBatch() {
        // 오탐 10개(평탄) + 진양성 1개 → 깊이 필터가 오탐을 걸러낸 비율 보고용
        let depth = makeDepthMap(width: 64, height: 64) { x, y, w, h in
            let dist = hypot(Double(x) - Double(w) * 0.3, Double(y) - Double(h) * 0.3)
            return dist < 4 ? 1.48 : 1.50
        }
        var candidates: [Gate6ImageCandidate] = [
            Gate6ImageCandidate(kind: .ball, normalizedX: 0.3, normalizedY: 0.3, radiusNorm: 0.05, score: 0.8)
        ]
        for i in 0..<10 {
            candidates.append(
                Gate6ImageCandidate(
                    kind: .ball,
                    normalizedX: 0.55 + Double(i) * 0.03,
                    normalizedY: 0.55,
                    radiusNorm: 0.05,
                    score: 0.9
                )
            )
        }
        let (best, rejected, rgbCount) = Gate6Detection.selectBest(
            kind: .ball,
            candidates: candidates,
            depth: depth
        )
        XCTAssertEqual(rgbCount, 11)
        XCTAssertEqual(rejected, 10)
        XCTAssertNotNil(best)
        let filterRatio = Double(rejected) / Double(rgbCount - 1)
        XCTAssertEqual(filterRatio, 1.0, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeDepthMap(
        width: Int,
        height: Int,
        value: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Float
    ) -> Gate6DepthMap {
        var meters = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                meters[y * width + x] = value(x, y, width, height)
            }
        }
        return Gate6DepthMap(width: width, height: height, meters: meters)
    }
}
