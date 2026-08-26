import Foundation
import simd
import XCTest
@testable import PuttPhysicsKit

final class ScanCoverageTests: XCTestCase {
    func testLowConfidenceRejected() {
        let coverage = ScanCoverage()
        let points = [
            ScanCoveragePoint(worldX: 0.1, worldY: 0.3, worldZ: 1.0, confidence: 0)
        ]
        let snap = coverage.ingest(
            points: points,
            cameraPosition: SIMD3<Float>(0, 1.4, 0),
            timestamp: 1,
            trackingLimited: false
        )
        XCTAssertEqual(snap.observedCellCount, 0)
        XCTAssertEqual(snap.tentativeCellCount, 0)
        XCTAssertEqual(snap.stableCellCount, 0)
    }

    func testCellTransitionsToStableAfterEnoughHits() {
        let coverage = ScanCoverage()
        let point = ScanCoveragePoint(worldX: 0.12, worldY: 0.3, worldZ: 1.05, confidence: 2)
        var last = ScanCoverageSnapshot.empty
        for i in 1...ScanCoverage.observationsForStable {
            last = coverage.ingest(
                points: [point],
                cameraPosition: SIMD3<Float>(0, 1.4, 0),
                timestamp: TimeInterval(i),
                trackingLimited: false
            )
        }
        XCTAssertEqual(last.observedCellCount, 1)
        XCTAssertEqual(last.stableCellCount, 1)
        XCTAssertEqual(last.tentativeCellCount, 0)
        XCTAssertEqual(last.state(worldX: 0.12, worldZ: 1.05), .stable)
        XCTAssertGreaterThanOrEqual(last.newlyStabilizedCount, 1)
    }

    func testTentativeBeforeStableThreshold() {
        let coverage = ScanCoverage()
        let point = ScanCoveragePoint(worldX: -0.2, worldY: 0.3, worldZ: 0.5, confidence: 1)
        let snap = coverage.ingest(
            points: [point],
            cameraPosition: SIMD3<Float>(0, 1.4, 0),
            timestamp: 0.5,
            trackingLimited: false
        )
        XCTAssertEqual(snap.tentativeCellCount, 1)
        XCTAssertEqual(snap.stableCellCount, 0)
        XCTAssertEqual(snap.state(worldX: -0.2, worldZ: 0.5), .tentative)
    }

    func testResetClearsCells() {
        let coverage = ScanCoverage()
        let point = ScanCoveragePoint(worldX: 0, worldY: 0.3, worldZ: 1, confidence: 2)
        _ = coverage.ingest(
            points: [point],
            cameraPosition: .zero,
            timestamp: 1,
            trackingLimited: false
        )
        coverage.reset()
        let snap = coverage.ingest(
            points: [],
            cameraPosition: .zero,
            timestamp: 2,
            trackingLimited: false
        )
        XCTAssertEqual(snap.observedCellCount, 0)
        XCTAssertEqual(snap.stableKeys.count, 0)
    }

    func testQualityTooFastAndTrackingBad() {
        XCTAssertEqual(
            ScanCoverage.evaluateQuality(
                trackingLimited: true,
                speed: 0,
                meanDepth: 1,
                hasSamples: true
            ),
            .trackingBad
        )
        XCTAssertEqual(
            ScanCoverage.evaluateQuality(
                trackingLimited: false,
                speed: ScanCoverage.tooFastMetersPerSecond + 0.1,
                meanDepth: 1,
                hasSamples: true
            ),
            .tooFast
        )
        XCTAssertEqual(
            ScanCoverage.evaluateQuality(
                trackingLimited: false,
                speed: 0.2,
                meanDepth: 0.2,
                hasSamples: true
            ),
            .tooClose
        )
        XCTAssertEqual(
            ScanCoverage.evaluateQuality(
                trackingLimited: false,
                speed: 0.2,
                meanDepth: 4.7,
                hasSamples: true
            ),
            .tooFar
        )
    }

    func testUnprojectFiniteDepth() {
        var intrinsics = matrix_identity_float3x3
        intrinsics[0, 0] = 200
        intrinsics[1, 1] = 200
        intrinsics[2, 0] = 100
        intrinsics[2, 1] = 100
        let cameraToWorld = matrix_identity_float4x4
        let world = ScanCoverage.unproject(
            depthX: 100,
            depthY: 100,
            depthMeters: 1.0,
            intrinsics: intrinsics,
            cameraToWorld: cameraToWorld
        )
        XCTAssertNotNil(world)
        XCTAssertEqual(world!.x, 0, accuracy: 1e-4)
        XCTAssertEqual(world!.y, 0, accuracy: 1e-4)
        XCTAssertEqual(world!.z, -1, accuracy: 1e-4)

        let belowCenter = ScanCoverage.unproject(
            depthX: 100,
            depthY: 120,
            depthMeters: 1.0,
            intrinsics: intrinsics,
            cameraToWorld: cameraToWorld
        )
        XCTAssertNotNil(belowCenter)
        XCTAssertEqual(belowCenter!.x, 0, accuracy: 1e-4)
        XCTAssertEqual(belowCenter!.y, -0.1, accuracy: 1e-4)
        XCTAssertEqual(belowCenter!.z, -1, accuracy: 1e-4)

        let rejected = ScanCoverage.unproject(
            depthX: 100,
            depthY: 100,
            depthMeters: 0.01,
            intrinsics: intrinsics,
            cameraToWorld: cameraToWorld
        )
        XCTAssertNil(rejected)
    }

    func testUnprojectAllowsFiveMeterLiDARRange() {
        var intrinsics = matrix_identity_float3x3
        intrinsics[0, 0] = 200
        intrinsics[1, 1] = 200
        intrinsics[2, 0] = 100
        intrinsics[2, 1] = 100
        let cameraToWorld = matrix_identity_float4x4
        XCTAssertNotNil(
            ScanCoverage.unproject(
                depthX: 100,
                depthY: 100,
                depthMeters: 4.0,
                intrinsics: intrinsics,
                cameraToWorld: cameraToWorld
            )
        )
        XCTAssertNil(
            ScanCoverage.unproject(
                depthX: 100,
                depthY: 100,
                depthMeters: 5.5,
                intrinsics: intrinsics,
                cameraToWorld: cameraToWorld
            )
        )
    }

    func testCoverageDoesNotAffectIsolationContract() {
        // 문서화용: ScanCoverage는 순수 관측 상태만 반환하며 Terrain/앵커 타입을 참조하지 않는다.
        let snap = ScanCoverageSnapshot.empty
        XCTAssertEqual(snap.stableRatio, 0)
        XCTAssertEqual(snap.state(worldX: 0, worldZ: 0), .unseen)
    }

    func testSameFrameMultiplePixelsCountAsOneHit() {
        let coverage = ScanCoverage()
        let points = (0..<20).map { i in
            ScanCoveragePoint(
                worldX: 0.01 + Float(i) * 0.001,
                worldY: 0.3,
                worldZ: 1.01,
                confidence: 2
            )
        }
        let snap = coverage.ingest(
            points: points,
            cameraPosition: SIMD3<Float>(0, 1.4, 0),
            timestamp: 1,
            trackingLimited: false
        )
        XCTAssertEqual(snap.observedCellCount, 1)
        XCTAssertEqual(snap.tentativeCellCount, 1)
        XCTAssertEqual(snap.stableCellCount, 0)
        XCTAssertEqual(snap.state(worldX: 0.01, worldZ: 1.01), .tentative)
    }

    func testStableRequiresIndependentFrames() {
        let coverage = ScanCoverage()
        let point = ScanCoveragePoint(worldX: 0.2, worldY: 0.3, worldZ: 0.8, confidence: 2)
        // 같은 timestamp로 여러 번 넣어도 1회만.
        _ = coverage.ingest(
            points: [point, point, point],
            cameraPosition: .zero,
            timestamp: 5,
            trackingLimited: false
        )
        _ = coverage.ingest(
            points: [point],
            cameraPosition: .zero,
            timestamp: 5,
            trackingLimited: false
        )
        var snap = coverage.ingest(
            points: [point],
            cameraPosition: .zero,
            timestamp: 6,
            trackingLimited: false
        )
        XCTAssertEqual(snap.stableCellCount, 0)
        snap = coverage.ingest(
            points: [point],
            cameraPosition: .zero,
            timestamp: 7,
            trackingLimited: false
        )
        XCTAssertEqual(snap.stableCellCount, 1)
    }

    func testTrackingLimitedDoesNotAddOrMoveCells() {
        let coverage = ScanCoverage()
        let first = ScanCoveragePoint(worldX: 0.1, worldY: 0.3, worldZ: 1.0, confidence: 2)
        let drifted = ScanCoveragePoint(worldX: 1.5, worldY: 0.3, worldZ: 2.0, confidence: 2)
        var snap = coverage.ingest(
            points: [first],
            cameraPosition: SIMD3<Float>(0, 1.4, 0),
            timestamp: 1,
            trackingLimited: false
        )
        XCTAssertEqual(snap.observedCellCount, 1)
        snap = coverage.ingest(
            points: [drifted],
            cameraPosition: SIMD3<Float>(0.4, 1.4, 0.3),
            timestamp: 2,
            trackingLimited: true
        )
        XCTAssertEqual(snap.observedCellCount, 1)
        XCTAssertEqual(snap.quality, .trackingBad)
        XCTAssertEqual(snap.state(worldX: 0.1, worldZ: 1.0), .tentative)
        XCTAssertEqual(snap.state(worldX: 1.5, worldZ: 2.0), .unseen)
    }
}
