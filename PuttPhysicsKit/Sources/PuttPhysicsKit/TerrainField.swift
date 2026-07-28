import Foundation

public struct LocalSlope: Sendable, Equatable {
    public var alpha: Double
    public var descentAzimuth: Double

    public init(alpha: Double, descentAzimuth: Double) {
        self.alpha = alpha
        self.descentAzimuth = descentAzimuth
    }
}

/// 스무딩된 높이맵과 사전계산 ∇H 필드를 조회하는 지형 인터페이스.
public protocol TerrainField: Sendable {
    func height(at point: PuttVector2) -> Double
    func gradient(at point: PuttVector2) -> PuttVector2
    func localSlope(at point: PuttVector2) -> LocalSlope
}

public extension TerrainField {
    func localSlope(at point: PuttVector2) -> LocalSlope {
        let gradient = gradient(at: point)
        let magnitude = gradient.magnitude
        return LocalSlope(
            alpha: atan(magnitude),
            descentAzimuth: atan2(-gradient.x, -gradient.y)
        )
    }
}

public enum BilinearSampler {
    public static func sample(
        width: Int,
        height: Int,
        originX: Double,
        originY: Double,
        cellSize: Double,
        value: (Int, Int) -> Double,
        at point: PuttVector2
    ) -> Double {
        precondition(width > 0 && height > 0)
        precondition(cellSize > 0)

        let gx = (point.x - originX) / cellSize
        let gy = (point.y - originY) / cellSize
        let x0 = Int(floor(gx))
        let y0 = Int(floor(gy))
        let x1 = x0 + 1
        let y1 = y0 + 1
        let tx = gx - Double(x0)
        let ty = gy - Double(y0)

        let v00 = value(clamp(x0, 0, width - 1), clamp(y0, 0, height - 1))
        let v10 = value(clamp(x1, 0, width - 1), clamp(y0, 0, height - 1))
        let v01 = value(clamp(x0, 0, width - 1), clamp(y1, 0, height - 1))
        let v11 = value(clamp(x1, 0, width - 1), clamp(y1, 0, height - 1))

        let v0 = v00 * (1 - tx) + v10 * tx
        let v1 = v01 * (1 - tx) + v11 * tx
        return v0 * (1 - ty) + v1 * ty
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

/// 게이트 1 결과(스무딩 H + 사전계산 ∇H)를 런타임 조회에 연결한다.
public struct HeightMapTerrainField: TerrainField, Sendable, Equatable {
    public var heightMap: HeightMap
    public var gradientField: GradientField

    public init(heightMap: HeightMap, gradientField: GradientField) {
        precondition(heightMap.width == gradientField.width)
        precondition(heightMap.height == gradientField.height)
        self.heightMap = heightMap
        self.gradientField = gradientField
    }

    public func height(at point: PuttVector2) -> Double {
        BilinearSampler.sample(
            width: heightMap.width,
            height: heightMap.height,
            originX: heightMap.originX,
            originY: heightMap.originY,
            cellSize: heightMap.cellSize,
            value: { x, y in heightMap.value(x: x, y: y) },
            at: point
        )
    }

    public func gradient(at point: PuttVector2) -> PuttVector2 {
        let dx = BilinearSampler.sample(
            width: gradientField.width,
            height: gradientField.height,
            originX: heightMap.originX,
            originY: heightMap.originY,
            cellSize: heightMap.cellSize,
            value: { x, y in gradientField.gradient(x: x, y: y).dx },
            at: point
        )
        let dy = BilinearSampler.sample(
            width: gradientField.width,
            height: gradientField.height,
            originX: heightMap.originX,
            originY: heightMap.originY,
            cellSize: heightMap.cellSize,
            value: { x, y in gradientField.gradient(x: x, y: y).dy },
            at: point
        )
        return PuttVector2(x: dx, y: dy)
    }
}

/// 직선 경계로 접합한 이중평면 합성 지형.
///
/// `orientationDegrees`는 원본 평면엔진 축(하강 = −X)으로부터의 방위각이다.
/// 0°이면 게이트 2 상수 α 엔진과 동일 축이 되고, 180°이면 X축 거울상이다.
public struct DualPlaneTerrainField: TerrainField, Sendable, Equatable {
    public var alphaA: Double
    public var orientationADegrees: Double
    public var alphaB: Double
    public var orientationBDegrees: Double
    public var boundaryY: Double

    public init(
        alphaADegrees: Double,
        orientationADegrees: Double,
        alphaBDegrees: Double,
        orientationBDegrees: Double,
        boundaryY: Double
    ) {
        self.alphaA = alphaADegrees * .pi / 180.0
        self.orientationADegrees = orientationADegrees
        self.alphaB = alphaBDegrees * .pi / 180.0
        self.orientationBDegrees = orientationBDegrees
        self.boundaryY = boundaryY
    }

    public func height(at point: PuttVector2) -> Double {
        if point.y < boundaryY {
            return heightOnPlane(point: point, alpha: alphaA, orientationDegrees: orientationADegrees)
        }
        let atBoundary = PuttVector2(x: point.x, y: boundaryY)
        let heightA = heightOnPlane(
            point: atBoundary,
            alpha: alphaA,
            orientationDegrees: orientationADegrees
        )
        let heightB = heightOnPlane(
            point: atBoundary,
            alpha: alphaB,
            orientationDegrees: orientationBDegrees
        )
        return heightOnPlane(
            point: point,
            alpha: alphaB,
            orientationDegrees: orientationBDegrees
        ) - heightB + heightA
    }

    public func gradient(at point: PuttVector2) -> PuttVector2 {
        let alpha = point.y < boundaryY ? alphaA : alphaB
        let orientation = point.y < boundaryY ? orientationADegrees : orientationBDegrees
        return Self.gradientOnPlane(alpha: alpha, orientationDegrees: orientation)
    }

    public func localSlope(at point: PuttVector2) -> LocalSlope {
        let alpha = point.y < boundaryY ? alphaA : alphaB
        let orientation = (point.y < boundaryY ? orientationADegrees : orientationBDegrees) * .pi / 180.0
        return LocalSlope(
            alpha: alpha,
            descentAzimuth: orientation - .pi / 2.0
        )
    }

    /// 원본 엔진 축(하강 −X)을 `orientationDegrees`만큼 돌린 평면의 ∇H.
    public static func gradientOnPlane(
        alpha: Double,
        orientationDegrees: Double
    ) -> PuttVector2 {
        let orientation = orientationDegrees * .pi / 180.0
        let descentAzimuth = orientation - .pi / 2.0
        let magnitude = tan(alpha)
        return PuttVector2(
            x: -magnitude * sin(descentAzimuth),
            y: -magnitude * cos(descentAzimuth)
        )
    }

    private func heightOnPlane(
        point: PuttVector2,
        alpha: Double,
        orientationDegrees: Double
    ) -> Double {
        let gradient = Self.gradientOnPlane(alpha: alpha, orientationDegrees: orientationDegrees)
        return gradient.x * point.x + gradient.y * point.y
    }
}
