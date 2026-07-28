import Foundation
import PuttPhysicsKit
import SceneKit
import UIKit

enum GreenColorMode: String, CaseIterable, Identifiable {
    case elevation
    case slope

    var id: String { rawValue }

    var label: String {
        switch self {
        case .elevation: return "등고"
        case .slope: return "경사"
        }
    }
}

struct GreenDisplayModel {
    var green: GreenHeightmap
    var smoothed: HeightMap
    var gradient: GradientField
    var sceneOriginX: Double
    var sceneOriginZ: Double
    var heightOffset: Double
    var node: SCNNode
    var colorMode: GreenColorMode
}

enum GreenSceneBuilder {
    static let ballRadius = 0.0214

    static func makeDisplayModel(
        from green: GreenHeightmap,
        sigma: Double = 1.5,
        colorMode: GreenColorMode = .elevation
    ) throws -> GreenDisplayModel {
        let heightMap = try worldHeightMap(from: green)
        let smoothed = GaussianSmoother.smooth(heightMap, sigma: sigma)
        let gradient = GradientFieldBuilder.build(from: smoothed)
        let geometry = try makeGeometry(
            heightMap: smoothed,
            gradient: gradient,
            colorMode: colorMode
        )
        let node = SCNNode(geometry: geometry)
        node.name = "greenMesh"
        return GreenDisplayModel(
            green: green,
            smoothed: smoothed,
            gradient: gradient,
            sceneOriginX: smoothed.originX,
            sceneOriginZ: smoothed.originY,
            heightOffset: 0,
            node: node,
            colorMode: colorMode
        )
    }

    static func scenePoint(
        worldX: Double,
        worldY: Double,
        height: Double,
        model: GreenDisplayModel
    ) -> SCNVector3 {
        SCNVector3(
            worldX - model.sceneOriginX,
            height - model.heightOffset + ballRadius,
            worldY - model.sceneOriginZ
        )
    }

    static func worldPoint(scene: SCNVector3, model: GreenDisplayModel) -> (x: Double, y: Double) {
        (
            Double(scene.x) + model.sceneOriginX,
            Double(scene.z) + model.sceneOriginZ
        )
    }

    static func isValidWorldPoint(_ point: PuttVector2, green: GreenHeightmap) -> Bool {
        let column = Int(round((point.x - green.originX) / green.cellSize))
        let row = Int(round((point.y - green.originY) / green.cellSize))
        guard column >= 0, column < green.width, row >= 0, row < green.height else {
            return false
        }
        return !green.isMissing(column: column, row: row)
    }

    static func height(atWorld point: PuttVector2, model: GreenDisplayModel) -> Double {
        let field = HeightMapTerrainField(heightMap: model.smoothed, gradientField: model.gradient)
        return field.height(at: point)
    }

    static func makeBallNode() -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(ballRadius))
        sphere.firstMaterial?.diffuse.contents = UIColor.white
        sphere.firstMaterial?.emission.contents = UIColor(white: 0.15, alpha: 1)
        let node = SCNNode(geometry: sphere)
        node.name = "ball"
        return node
    }

    static func makeHoleNode() -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.054, height: 0.01)
        cylinder.firstMaterial?.diffuse.contents = UIColor.black
        let node = SCNNode(geometry: cylinder)
        node.name = "hole"
        return node
    }

    static func makeTrajectoryNode(
        worldPoints: [PuttVector2],
        model: GreenDisplayModel,
        color: UIColor
    ) -> SCNNode {
        guard worldPoints.count >= 2 else { return SCNNode() }
        var vertices: [SCNVector3] = worldPoints.map { point in
            let height = height(atWorld: point, model: model)
            return SCNVector3(
                point.x - model.sceneOriginX,
                height - model.heightOffset + 0.01,
                point.y - model.sceneOriginZ
            )
        }
        let source = SCNGeometrySource(vertices: vertices)
        var indices: [Int32] = []
        for index in 0..<(vertices.count - 1) {
            indices.append(Int32(index))
            indices.append(Int32(index + 1))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.emission.contents = color
        geometry.firstMaterial?.isDoubleSided = true
        let node = SCNNode(geometry: geometry)
        node.name = "trajectory"
        return node
    }

    /// 경사(기울기) 크기 기반 히트맵 (완만=녹색 → 급경사=빨강).
    static func heatColor(normalized: Double) -> SIMD4<Float> {
        let t = Float(min(max(normalized, 0), 1))
        return SIMD4(
            0.15 + 0.75 * t,
            0.55 - 0.25 * t,
            0.35 * (1 - t),
            1
        )
    }

    /// 고도(등고) 기반 컬러: 낮음 → 높음
    /// 파랑 → 하늘색 → 연두 → 초록 → 주황 → 빨강 (스크린골프식 등고 팔레트).
    static func elevationColor(normalized: Double) -> SIMD4<Float> {
        let stops: [(Double, SIMD3<Float>)] = [
            (0.00, SIMD3(0.10, 0.30, 0.85)), // 파랑 (가장 낮음)
            (0.20, SIMD3(0.25, 0.65, 0.95)), // 하늘색
            (0.40, SIMD3(0.55, 0.85, 0.45)), // 연두
            (0.60, SIMD3(0.20, 0.65, 0.25)), // 초록
            (0.80, SIMD3(0.95, 0.60, 0.15)), // 주황
            (1.00, SIMD3(0.85, 0.15, 0.12))  // 빨강 (가장 높음)
        ]
        let t = min(max(normalized, 0), 1)
        for index in 0..<(stops.count - 1) {
            let (lo, loColor) = stops[index]
            let (hi, hiColor) = stops[index + 1]
            if t <= hi {
                let span = hi - lo
                let f = span > 0 ? Float((t - lo) / span) : 0
                let rgb = loColor + (hiColor - loColor) * f
                return SIMD4(rgb.x, rgb.y, rgb.z, 1)
            }
        }
        let last = stops[stops.count - 1].1
        return SIMD4(last.x, last.y, last.z, 1)
    }

    private static func worldHeightMap(from green: GreenHeightmap) throws -> HeightMap {
        var values = Array(repeating: 0.0, count: green.cellCount)
        var measured = Array(repeating: false, count: green.cellCount)
        var interpolated = Array(repeating: false, count: green.cellCount)
        var minimum = Double.greatestFiniteMagnitude
        for row in 0..<green.height {
            for column in 0..<green.width {
                let index = row * green.width + column
                if let height = green.heightMeters(column: column, row: row) {
                    values[index] = height
                    measured[index] = true
                    minimum = min(minimum, height)
                }
            }
        }
        guard minimum.isFinite else { throw GreenHeightmapError.emptyValidCells }
        for index in values.indices where measured[index] {
            values[index] -= minimum
        }
        // 결측은 이웃 보간 대신 최저면으로 채우고 measured=false 유지 → 메시에서 제외
        for index in values.indices where !measured[index] {
            values[index] = 0
            interpolated[index] = true
        }
        return HeightMap(
            cellSize: green.cellSize,
            originX: green.originX,
            originY: green.originY,
            width: green.width,
            height: green.height,
            values: values,
            measuredMask: measured,
            interpolatedMask: interpolated
        )
    }

    private static func makeGeometry(
        heightMap: HeightMap,
        gradient: GradientField,
        colorMode: GreenColorMode
    ) throws -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        var indices: [Int32] = []
        var vertexIndex = Array(repeating: Int32(-1), count: heightMap.cellCount)

        var maxAlpha = 1e-6
        var minHeight = Double.greatestFiniteMagnitude
        var maxHeight = -Double.greatestFiniteMagnitude
        for row in 0..<heightMap.height {
            for column in 0..<heightMap.width {
                let index = heightMap.index(x: column, y: row)
                guard heightMap.measuredMask[index] else { continue }
                let g = gradient.gradient(x: column, y: row)
                maxAlpha = max(maxAlpha, atan(hypot(g.dx, g.dy)))
                minHeight = min(minHeight, heightMap.values[index])
                maxHeight = max(maxHeight, heightMap.values[index])
            }
        }
        let heightSpan = max(maxHeight - minHeight, 1e-6)

        for row in 0..<heightMap.height {
            for column in 0..<heightMap.width {
                let index = heightMap.index(x: column, y: row)
                guard heightMap.measuredMask[index] else { continue }
                let world = heightMap.worldCoordinate(x: column, y: row)
                vertexIndex[index] = Int32(vertices.count)
                vertices.append(
                    SCNVector3(
                        world.x - heightMap.originX,
                        heightMap.values[index],
                        world.y - heightMap.originY
                    )
                )
                let g = gradient.gradient(x: column, y: row)
                let alpha = atan(hypot(g.dx, g.dy))
                switch colorMode {
                case .slope:
                    colors.append(heatColor(normalized: alpha / maxAlpha))
                case .elevation:
                    let normalizedHeight = (heightMap.values[index] - minHeight) / heightSpan
                    colors.append(elevationColor(normalized: normalizedHeight))
                }
            }
        }

        for row in 0..<(heightMap.height - 1) {
            for column in 0..<(heightMap.width - 1) {
                let i00 = heightMap.index(x: column, y: row)
                let i10 = heightMap.index(x: column + 1, y: row)
                let i01 = heightMap.index(x: column, y: row + 1)
                let i11 = heightMap.index(x: column + 1, y: row + 1)
                let v00 = vertexIndex[i00]
                let v10 = vertexIndex[i10]
                let v01 = vertexIndex[i01]
                let v11 = vertexIndex[i11]
                guard v00 >= 0, v10 >= 0, v01 >= 0, v11 >= 0 else { continue }
                indices.append(contentsOf: [v00, v10, v11, v00, v11, v01])
            }
        }

        guard !vertices.isEmpty, !indices.isEmpty else {
            throw GreenHeightmapError.emptyValidCells
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.lightingModel = .blinn
        return geometry
    }
}

extension GreenAlignment {
    func world(local: PuttVector2) -> PuttVector2 {
        PuttVector2(
            x: ballWorld.x + local.x * rightX + local.y * forwardX,
            y: ballWorld.y + local.x * rightY + local.y * forwardY
        )
    }
}
