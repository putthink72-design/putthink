import ARKit
import PuttPhysicsKit
import UIKit

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

/// Drawn on ARView from DisplayLink — avoids SwiftUI `@Published` during view updates.
final class PlacementRingOverlayView: UIView {
    private static let accentUIColor = UIColor(
        red: 1.0,
        green: 176 / 255,
        blue: 32 / 255,
        alpha: 1
    )

    var ballPoints: [CGPoint] = [] {
        didSet { if oldValue != ballPoints { setNeedsDisplay() } }
    }
    var holePoints: [CGPoint] = [] {
        didSet { if oldValue != holePoints { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        ballPoints = []
        holePoints = []
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        stroke(ballPoints, color: .white, lineWidth: 4, dashed: false, in: ctx)
        stroke(holePoints, color: Self.accentUIColor, lineWidth: 3.5, dashed: true, in: ctx)
    }

    private func stroke(
        _ points: [CGPoint],
        color: UIColor,
        lineWidth: CGFloat,
        dashed: Bool,
        in ctx: CGContext
    ) {
        guard points.count >= 3 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        if dashed {
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(lineWidth + 1.6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: [6, 5])
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if dashed {
            ctx.setLineDash(phase: 0, lengths: [6, 5])
        } else {
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.addPath(path)
        ctx.strokePath()
    }
}
