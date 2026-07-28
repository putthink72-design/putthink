import XCTest
@testable import PuttPhysicsKit

final class TemporalSurfaceFusionTests: XCTestCase {
    func testMedianFusionRejectsSingleHeightOutlier() throws {
        let fusion = TemporalSurfaceFusion(cellSize: 0.05)
        let heights = [0.301, 0.302, 0.300, 0.355, 0.299]
        for (index, height) in heights.enumerated() {
            fusion.ingestFrame(
                [.init(worldX: 0.02, worldY: height, worldZ: 1.02, timestamp: Double(index))],
                timestamp: Double(index)
            )
        }

        let vertices = fusion.fusedVertices(
            referenceHeight: 0.30,
            ballX: 0,
            ballZ: 0,
            holeX: 0,
            holeZ: 2
        )
        let vertex = try XCTUnwrap(vertices.first)
        XCTAssertEqual(vertex.worldY, 0.3005, accuracy: 0.002)
    }

    func testRequiresIndependentFrames() {
        let fusion = TemporalSurfaceFusion(cellSize: 0.05)
        fusion.ingestFrame(
            (0..<20).map { _ in
                .init(worldX: 0.01, worldY: 0.30, worldZ: 0.51, timestamp: 1)
            },
            timestamp: 1
        )

        let vertices = fusion.fusedVertices(
            referenceHeight: 0.30,
            ballX: 0,
            ballZ: 0,
            holeX: 0,
            holeZ: 2
        )
        XCTAssertTrue(vertices.isEmpty)
    }

    func testPreservesGradualSlopeInsteadOfFlattening() {
        let fusion = TemporalSurfaceFusion(cellSize: 0.05)
        for frame in 0..<4 {
            var samples: [TemporalSurfaceFusion.Sample] = []
            for row in 0..<20 {
                let z = Double(row) * 0.05
                let height = 0.30 + z * 0.01 + Double(frame - 2) * 0.0005
                samples.append(
                    .init(
                        worldX: 0.01,
                        worldY: height,
                        worldZ: z + 0.01,
                        timestamp: Double(frame)
                    )
                )
            }
            fusion.ingestFrame(samples, timestamp: Double(frame))
        }

        let vertices = fusion.fusedVertices(
            referenceHeight: 0.30,
            ballX: 0,
            ballZ: 0,
            holeX: 0,
            holeZ: 1
        )
        let near = vertices.min { $0.worldZ < $1.worldZ }
        let far = vertices.max { $0.worldZ < $1.worldZ }
        XCTAssertNotNil(near)
        XCTAssertNotNil(far)
        XCTAssertGreaterThan(try! XCTUnwrap(far).worldY - (try! XCTUnwrap(near).worldY), 0.008)
    }

    func testRejectsSingleViewpointWhenCameraProvided() {
        let fusion = TemporalSurfaceFusion(cellSize: 0.05)
        for frame in 0..<5 {
            fusion.ingestFrame(
                [.init(worldX: 0.01, worldY: 0.30, worldZ: 1.01, timestamp: Double(frame))],
                timestamp: Double(frame),
                cameraXZ: SIMD2<Double>(0.0, 0.0) // 같은 위치에서만 관측
            )
        }
        let vertices = fusion.fusedVertices(
            referenceHeight: 0.30,
            ballX: 0,
            ballZ: 0,
            holeX: 0,
            holeZ: 2
        )
        XCTAssertTrue(vertices.isEmpty)
    }

    func testAcceptsMultipleViewpoints() {
        let fusion = TemporalSurfaceFusion(cellSize: 0.05)
        for frame in 0..<5 {
            fusion.ingestFrame(
                [.init(worldX: 0.01, worldY: 0.30, worldZ: 1.01, timestamp: Double(frame))],
                timestamp: Double(frame),
                cameraXZ: SIMD2<Double>(Double(frame) * 0.2, 0.0) // 시점 이동
            )
        }
        let vertices = fusion.fusedVertices(
            referenceHeight: 0.30,
            ballX: 0,
            ballZ: 0,
            holeX: 0,
            holeZ: 2
        )
        XCTAssertEqual(vertices.count, 1)
        XCTAssertEqual(vertices[0].worldY, 0.30, accuracy: 0.001)
    }

    func testDistinctViewpointCountClustersBySeparation() {
        let cameras = [
            SIMD2<Double>(0, 0),
            SIMD2<Double>(0.05, 0), // 첫 위치와 가까움 → 같은 시점
            SIMD2<Double>(0.30, 0)  // 멀리 이동 → 새 시점
        ]
        XCTAssertEqual(
            TemporalSurfaceFusion.distinctViewpointCount(cameras, separation: 0.12),
            2
        )
    }

    func testFiltersWallAndOutsideCorridor() {
        let fusion = TemporalSurfaceFusion(cellSize: 0.05)
        for frame in 0..<4 {
            fusion.ingestFrame(
                [
                    .init(worldX: 0.01, worldY: 0.30, worldZ: 1.01, timestamp: Double(frame)),
                    .init(worldX: 0.01, worldY: 1.50, worldZ: 1.01, timestamp: Double(frame)),
                    .init(worldX: 3.01, worldY: 0.30, worldZ: 1.01, timestamp: Double(frame))
                ],
                timestamp: Double(frame)
            )
        }

        let vertices = fusion.fusedVertices(
            referenceHeight: 0.30,
            ballX: 0,
            ballZ: 0,
            holeX: 0,
            holeZ: 2
        )
        XCTAssertEqual(vertices.count, 1)
        XCTAssertEqual(vertices[0].worldY, 0.30, accuracy: 0.001)
    }
}
