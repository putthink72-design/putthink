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
        // 야외: 흰 단선은 잔디·하이라이트에 묻힌다. 십자선과 같이 검정 외곽+앰버.
        stroke(
            ballPoints,
            color: Self.accentUIColor,
            lineWidth: 5,
            outlineWidth: 2.4,
            dashed: false,
            in: ctx
        )
        stroke(
            holePoints,
            color: Self.accentUIColor,
            lineWidth: 5.5,
            outlineWidth: 2.8,
            dashed: true,
            // 긴 막대 점선. round cap으로 개별 점선 끝이 동그랗게(캡슐).
            // 갭은 선 굵기보다 커야 실선처럼 붙지 않는다.
            dashPattern: [16, 12],
            in: ctx
        )
    }

    private func stroke(
        _ points: [CGPoint],
        color: UIColor,
        lineWidth: CGFloat,
        outlineWidth: CGFloat,
        dashed: Bool,
        dashPattern: [CGFloat] = [6, 5],
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

        // 점선도 round — 개별 막대 끝이 동그란 캡슐 모양.
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if dashed {
            ctx.setLineDash(phase: 0, lengths: dashPattern)
        } else {
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // 외곽(야외 대비) → 흰 중간선(잔디 위 분리) → 앰버 본선.
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(lineWidth + outlineWidth)
        ctx.addPath(path)
        ctx.strokePath()

        if dashed {
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(lineWidth + 1.0)
            ctx.addPath(path)
            ctx.strokePath()
        }

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path)
        ctx.strokePath()
    }
}
