import Foundation

/// 게이트 5 합성 지형 (a) 사인파 능선형 이중브레이크.
public struct SineRidgeTerrainField: TerrainField, Sendable, Equatable {
    public var amplitude: Double
    public var wavelength: Double
    public var baseSlope: Double

    public init(amplitude: Double = 0.04, wavelength: Double = 2.5, baseSlopeDegrees: Double = 1.0) {
        self.amplitude = amplitude
        self.wavelength = wavelength
        self.baseSlope = baseSlopeDegrees * .pi / 180.0
    }

    public func height(at point: PuttVector2) -> Double {
        let k = 2.0 * .pi / wavelength
        return -tan(baseSlope) * point.x
            + amplitude * sin(k * point.y)
            + 0.5 * amplitude * sin(1.5 * k * point.x + 0.3)
    }

    public func gradient(at point: PuttVector2) -> PuttVector2 {
        let k = 2.0 * .pi / wavelength
        return PuttVector2(
            x: -tan(baseSlope) + 0.5 * amplitude * 1.5 * k * cos(1.5 * k * point.x + 0.3),
            y: amplitude * k * cos(k * point.y)
        )
    }
}

/// 게이트 5 합성 지형 (b) 대각 안장형.
public struct SaddleTerrainField: TerrainField, Sendable, Equatable {
    public var curvature: Double
    public var rotationDegrees: Double

    public init(curvature: Double = 0.008, rotationDegrees: Double = 35) {
        self.curvature = curvature
        self.rotationDegrees = rotationDegrees
    }

    public func height(at point: PuttVector2) -> Double {
        let rotated = rotate(point, by: -rotationDegrees * .pi / 180.0)
        return curvature * (rotated.x * rotated.x - rotated.y * rotated.y)
    }

    public func gradient(at point: PuttVector2) -> PuttVector2 {
        let angle = -rotationDegrees * .pi / 180.0
        let rotated = rotate(point, by: angle)
        let local = PuttVector2(x: 2.0 * curvature * rotated.x, y: -2.0 * curvature * rotated.y)
        return rotate(local, by: -angle)
    }

    private func rotate(_ vector: PuttVector2, by radians: Double) -> PuttVector2 {
        let cosine = cos(radians)
        let sine = sin(radians)
        return PuttVector2(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine
        )
    }
}
