import ARKit
import PuttPhysicsKit
@preconcurrency import RealityKit
import UIKit
import simd

/// 볼·홀 지면 기준점을 시각적으로 보여주는 AR 마커.
/// ARAnchor에 묶어 카메라가 움직여도 월드 좌표에 고정된다.
enum ARReferenceMarkers {
    /// 규격 홀컵 직경 108mm.
    static let holeCupDiameter: Float = 0.108
    static let ballRadius: Float = 0.0214
    /// 서서 볼 때 AR 볼 마커 알파. 하안에서는 `ballMarkerFloorAlpha`까지 `proximityBlend`로 보간.
    static let ballMarkerStandingAlpha: CGFloat = 0.9
    static let ballMarkerFloorAlpha: CGFloat = 0.5
    static let holeRadius: Float = holeCupDiameter * 0.5

    /// 지면에 눕힌 홀컵 링(Ø108mm). 가운데는 비워 경로가 보인다.
    static func makeHoleCupGroundRing(
        color: UIColor,
        lineWidth: Float = 0.0035,
        lift: Float = 0.003
    ) -> ModelEntity {
        let root = ModelEntity()
        root.name = "holeCupRing"
        let segments = 56
        for index in 0..<segments {
            let a0 = Float(index) / Float(segments) * 2 * .pi
            let a1 = Float(index + 1) / Float(segments) * 2 * .pi
            let p0 = SIMD3<Float>(cos(a0) * holeRadius, lift, sin(a0) * holeRadius)
            let p1 = SIMD3<Float>(cos(a1) * holeRadius, lift, sin(a1) * holeRadius)
            let delta = p1 - p0
            let len = simd_length(delta)
            guard len > 1e-5 else { continue }
            let dir = delta / len
            let seg = makeLineEntity(
                length: len,
                width: lineWidth,
                color: color,
                unlit: true,
                thickness: 0.0012
            )
            seg.orientation = yawRotation(aligningLocalZToHorizontal: dir)
            seg.position = (p0 + p1) * 0.5
            root.addChild(seg)
        }
        return root
    }

    static func makeBallMarkerMaterial(alpha: CGFloat) -> UnlitMaterial {
        var material = UnlitMaterial(color: UIColor(white: 1, alpha: alpha))
        if alpha < 0.99 {
            material.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
        } else {
            material.blending = .opaque
        }
        return material
    }

    static func makeBallEntity() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: ballRadius)
        let entity = ModelEntity(
            mesh: mesh,
            materials: [makeBallMarkerMaterial(alpha: ballMarkerStandingAlpha)]
        )
        entity.position = SIMD3(0, ballRadius, 0)
        entity.name = "ballMarker"
        return entity
    }

    static func makeHoleEntity() -> ModelEntity {
        let root = ModelEntity()
        root.name = "holeMarker"

        let cupRing = makeHoleCupGroundRing(
            color: UIColor(white: 0.95, alpha: 1),
            lineWidth: 0.004
        )
        root.addChild(cupRing)

        let poleMesh = MeshResource.generateBox(size: [0.012, 0.45, 0.012])
        let pole = ModelEntity(
            mesh: poleMesh,
            materials: [UnlitMaterial(color: .white)]
        )
        pole.position = SIMD3(0, 0.225, 0)
        root.addChild(pole)

        let flagMesh = MeshResource.generateBox(size: [0.12, 0.08, 0.004])
        let flag = ModelEntity(
            mesh: flagMesh,
            materials: [UnlitMaterial(color: .systemRed)]
        )
        flag.position = SIMD3(0.06, 0.40, 0)
        root.addChild(flag)

        return root
    }

    static func makeLineEntity(
        length: Float,
        width: Float = 0.03,
        color: UIColor,
        unlit: Bool = false,
        thickness: Float = 0.008
    ) -> ModelEntity {
        let mesh = MeshResource.generateBox(
            size: [width, thickness, length],
            cornerRadius: min(thickness, width) * 0.35
        )
        if unlit {
            var material = UnlitMaterial(color: color)
            var alpha: CGFloat = 1
            if !color.getRed(nil, green: nil, blue: nil, alpha: &alpha) {
                color.getWhite(nil, alpha: &alpha)
            }
            if alpha < 0.99 {
                material.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
            } else {
                material.blending = .opaque
            }
            return ModelEntity(mesh: mesh, materials: [material])
        }
        var material = SimpleMaterial()
        material.color = .init(tint: color)
        material.roughness = 0.25
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// 바닥 선용. `simd_quatf(from:to:)`는 방향이 ±Z에 가까우면 축이 불안정해 상자가 세워진다.
    static func yawRotation(aligningLocalZToHorizontal dir: SIMD3<Float>) -> simd_quatf {
        var flat = SIMD3<Float>(dir.x, 0, dir.z)
        let len = simd_length(flat)
        guard len > 1e-6 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        flat /= len
        return simd_quatf(angle: atan2(flat.x, flat.z), axis: SIMD3(0, 1, 0))
    }

    /// 화면 픽셀 두께를 월드 미터로.
    static func worldWidth(
        forScreenPixels pixels: Float,
        distanceMeters: Float,
        viewportPixelHeight: Float,
        projectionYScale: Float
    ) -> Float {
        let distance = max(distanceMeters, 0.12)
        let viewport = max(viewportPixelHeight, 1)
        let yScale = max(abs(projectionYScale), 0.001)
        let metersPerPixel = (2 * distance) / (yScale * viewport)
        return max(pixels * metersPerPixel, 0.002)
    }

    static func makePolylineRibbon(
        points: [SIMD3<Float>],
        width: Float,
        color: UIColor
    ) -> ModelEntity? {
        guard points.count >= 2, width > 0 else { return nil }

        let halfW = width * 0.5
        let halfH = max(width * 0.25, 0.0006)

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(points.count * 4)

        for index in 0..<points.count {
            let prev = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            var tangent = next - prev
            tangent.y = 0
            if simd_length(tangent) < 1e-6 {
                if index + 1 < points.count {
                    tangent = points[index + 1] - points[index]
                    tangent.y = 0
                } else if index > 0 {
                    tangent = points[index] - points[index - 1]
                    tangent.y = 0
                }
            }
            let tLen = simd_length(tangent)
            let t = tLen > 1e-6 ? tangent / tLen : SIMD3<Float>(1, 0, 0)
            var side = simd_cross(SIMD3<Float>(0, 1, 0), t)
            let sLen = simd_length(side)
            side = sLen > 1e-6 ? side / sLen : SIMD3<Float>(1, 0, 0)

            let p = points[index]
            positions.append(p - side * halfW)
            positions.append(p + side * halfW)
            positions.append(p + SIMD3<Float>(0, halfH, 0))
            positions.append(p - SIMD3<Float>(0, halfH, 0))

            if index > 0 {
                let b = UInt32((index - 1) * 4)
                let c = UInt32(index * 4)
                indices.append(contentsOf: [b, b + 1, c, b + 1, c + 1, c])
                indices.append(contentsOf: [b, c, b + 1, b + 1, c, c + 1])
                indices.append(contentsOf: [b + 2, b + 3, c + 2, b + 3, c + 3, c + 2])
                indices.append(contentsOf: [b + 2, c + 2, b + 3, b + 3, c + 2, c + 3])
            }
        }

        var descriptor = MeshDescriptor(name: "contourRibbon")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        return ModelEntity(mesh: mesh, materials: [unlitMaterial(color: color)])
    }

    static func unlitMaterial(color: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        let alpha = Float(color.cgColor.alpha)
        if alpha < 0.99 {
            material.blending = .transparent(opacity: .init(floatLiteral: alpha))
        } else {
            material.blending = .opaque
        }
        return material
    }

    /// 채움 리본 + 더 굵은 어두운 외곽선 — 야외 시인성용.
    static func makePolylineRibbonOutlined(
        points: [SIMD3<Float>],
        width: Float,
        color: UIColor,
        outlineColor: UIColor = .white,
        outlineWidthScale: Float = 1.65
    ) -> Entity? {
        guard points.count >= 2, width > 0 else { return nil }
        let root = Entity()
        root.name = "outlinedRibbon"
        if let outline = makePolylineRibbon(
            points: points,
            width: width * outlineWidthScale,
            color: outlineColor
        ) {
            root.addChild(outline)
        }
        guard let fill = makePolylineRibbon(points: points, width: width, color: color) else {
            return root.children.isEmpty ? nil : root
        }
        root.addChild(fill)
        return root
    }

    /// 단일 세그먼트 + 외곽선.
    static func makeOutlinedLineSegment(
        length: Float,
        width: Float,
        color: UIColor,
        thickness: Float = 0.0016,
        outlineColor: UIColor = .white,
        outlineWidthScale: Float = 1.65
    ) -> Entity {
        let root = Entity()
        let outline = makeLineEntity(
            length: length,
            width: width * outlineWidthScale,
            color: outlineColor,
            unlit: true,
            thickness: thickness * 1.15
        )
        let fill = makeLineEntity(
            length: length,
            width: width,
            color: color,
            unlit: true,
            thickness: thickness
        )
        root.addChild(outline)
        root.addChild(fill)
        return root
    }

    private static func worldTransform(at world: SIMD3<Float>) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(world.x, world.y, world.z, 1)
        return transform
    }

    /// ARKit ARAnchor에 고정 — 지정 위치에 남고 카메라를 따라가지 않는다.
    static func placeWorldLocked(
        named name: String,
        entityFactory: () -> ModelEntity,
        at world: SIMD3<Float>,
        session: ARSession,
        in view: ARView,
        existingEntity: inout AnchorEntity?,
        existingARAnchor: inout ARAnchor?
    ) {
        if existingEntity != nil, existingARAnchor != nil {
            return
        }
        removeWorldLocked(
            session: session,
            in: view,
            existingEntity: &existingEntity,
            existingARAnchor: &existingARAnchor
        )
        let arAnchor = ARAnchor(name: name, transform: worldTransform(at: world))
        session.add(anchor: arAnchor)
        let entity = AnchorEntity(anchor: arAnchor)
        entity.addChild(entityFactory())
        view.scene.addAnchor(entity)
        existingARAnchor = arAnchor
        existingEntity = entity
    }

    static func removeWorldLocked(
        session: ARSession,
        in view: ARView,
        existingEntity: inout AnchorEntity?,
        existingARAnchor: inout ARAnchor?
    ) {
        if let existingEntity {
            view.scene.removeAnchor(existingEntity)
        }
        if let existingARAnchor {
            session.remove(anchor: existingARAnchor)
        }
        existingEntity = nil
        existingARAnchor = nil
    }

    /// ARKit `ARAnchor` 없이 RealityKit 월드 좌표에 고정 — relocalization 시 흐름 방지.
    static func placeRealityWorldFixed(
        entityFactory: () -> ModelEntity,
        at world: SIMD3<Float>,
        in view: ARView,
        existingEntity: inout AnchorEntity?
    ) {
        if existingEntity != nil { return }
        removeRealityWorldFixed(in: view, existingEntity: &existingEntity)
        let anchor = AnchorEntity(world: worldTransform(at: world))
        anchor.addChild(entityFactory())
        view.scene.addAnchor(anchor)
        existingEntity = anchor
    }

    static func moveRealityWorldFixed(
        to world: SIMD3<Float>,
        existingEntity: AnchorEntity?
    ) {
        existingEntity?.transform = Transform(matrix: worldTransform(at: world))
    }

    static func replaceRealityWorldFixed(
        entityFactory: () -> ModelEntity,
        at world: SIMD3<Float>,
        in view: ARView,
        existingEntity: inout AnchorEntity?
    ) {
        removeRealityWorldFixed(in: view, existingEntity: &existingEntity)
        let anchor = AnchorEntity(world: worldTransform(at: world))
        anchor.addChild(entityFactory())
        view.scene.addAnchor(anchor)
        existingEntity = anchor
    }

    static func removeRealityWorldFixed(
        in view: ARView,
        existingEntity: inout AnchorEntity?
    ) {
        if let existingEntity {
            view.scene.removeAnchor(existingEntity)
        }
        existingEntity = nil
    }
}
