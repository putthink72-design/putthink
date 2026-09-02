import ARKit
import PuttPhysicsKit
import SwiftUI

/// 바닥면 XZ 원을 카메라에 투영해 사선 시 타원으로 그린다.
enum GroundCircleProjector {
    static let segmentCount = 48

    static func screenPoints(
        worldX: Double,
        worldY: Double,
        worldZ: Double,
        radiusMeters: Double,
        camera: ARCamera,
        viewport: CGSize,
        orientation: UIInterfaceOrientation
    ) -> [CGPoint]? {
        var points: [CGPoint] = []
        points.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let angle = Double(index) / Double(segmentCount) * 2 * .pi
            let wx = worldX + cos(angle) * radiusMeters
            let wz = worldZ + sin(angle) * radiusMeters
            let world = SIMD3<Float>(Float(wx), Float(worldY), Float(wz))
            let cam = camera.transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
            guard cam.z < -0.05 else { continue }
            let projected = camera.projectPoint(
                world,
                orientation: orientation,
                viewportSize: viewport
            )
            guard projected.x.isFinite, projected.y.isFinite else { continue }
            points.append(CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)))
        }
        return points.count >= 8 ? points : nil
    }
}

enum BallGroundRingProjector {
    static func screenPoints(
        worldX: Double,
        worldY: Double,
        worldZ: Double,
        camera: ARCamera,
        viewport: CGSize,
        orientation: UIInterfaceOrientation
    ) -> [CGPoint]? {
        GroundCircleProjector.screenPoints(
            worldX: worldX,
            worldY: worldY,
            worldZ: worldZ,
            radiusMeters: GolfBallVisualLock.radiusMeters,
            camera: camera,
            viewport: viewport,
            orientation: orientation
        )
    }
}

struct BallGroundRingOverlay: View {
    let points: [CGPoint]

    var body: some View {
        GroundCircleStrokeOverlay(
            points: points,
            color: .white,
            lineWidth: 4
        )
    }
}

/// 홀컵 지정·재지정 — 규격 108mm(Ø) 노란 링.
struct HoleCupRingOverlay: View {
    let points: [CGPoint]

    var body: some View {
        GroundCircleStrokeOverlay(
            points: points,
            color: OSDPalette.accent,
            lineWidth: 3.5,
            dashed: true
        )
    }
}

private struct GroundCircleStrokeOverlay: View {
    let points: [CGPoint]
    let color: Color
    var lineWidth: CGFloat = 3
    var dashed: Bool = false

    var body: some View {
        Canvas { context, _ in
            guard points.count >= 3 else { return }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            var style = StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            )
            if dashed {
                style.dash = [6, 5]
            }
            if dashed {
                context.stroke(
                    path,
                    with: .color(.black.opacity(0.45)),
                    style: StrokeStyle(lineWidth: lineWidth + 1.6, lineCap: .round, lineJoin: .round, dash: [6, 5])
                )
            }
            context.stroke(path, with: .color(color), style: style)
        }
        .allowsHitTesting(false)
    }
}
