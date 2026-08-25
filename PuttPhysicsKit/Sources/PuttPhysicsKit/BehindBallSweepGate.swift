import Foundation
import simd

/// 볼 뒤 사선 LiDAR 구간 — 홀 방향 3–4m, grazing·거리·신뢰도 게이트.
public enum ScanDepthPhase: String, Sendable, Codable, Equatable {
    case behindBallSweep
    case walkCorridor
}

public enum BehindBallSweepGate {
    public static let maxRangeMeters = 4.0
    public static let minRangeMeters = 0.2
    public static let lateralHalfWidthMeters = 2.0
    /// 지면과의 입사각(하향). 너무 얕으면 grazing 편향.
    public static let minElevationDegrees = 18.0
    public static let maxElevationDegrees = 72.0
    public static let requiredAcceptedCells = 14
    public static let minimumDurationSeconds = 2.5
    public static let minimumGoodFrames = 4
    /// 프레임당 이 수 이상 수용되면 good frame.
    public static let goodFrameSampleThreshold = 18

    public struct Sample: Sendable, Equatable {
        public let worldX: Double
        public let worldY: Double
        public let worldZ: Double
        public let confidence: UInt8

        public init(worldX: Double, worldY: Double, worldZ: Double, confidence: UInt8) {
            self.worldX = worldX
            self.worldY = worldY
            self.worldZ = worldZ
            self.confidence = confidence
        }
    }

    public struct Context: Sendable, Equatable {
        public let ballX: Double
        public let ballY: Double
        public let ballZ: Double
        public let cameraX: Double
        public let cameraY: Double
        public let cameraZ: Double
        /// XZ 평면에서 정규화된 카메라 전방(볼→홀 방향 proxy).
        public let forwardX: Double
        public let forwardZ: Double

        public init(
            ballX: Double,
            ballY: Double,
            ballZ: Double,
            cameraX: Double,
            cameraY: Double,
            cameraZ: Double,
            forwardX: Double,
            forwardZ: Double
        ) {
            self.ballX = ballX
            self.ballY = ballY
            self.ballZ = ballZ
            self.cameraX = cameraX
            self.cameraY = cameraY
            self.cameraZ = cameraZ
            self.forwardX = forwardX
            self.forwardZ = forwardZ
        }
    }

    public struct Stats: Codable, Sendable, Equatable {
        public let durationSeconds: Double
        public let processedFrames: Int
        public let acceptedSamples: Int
        public let acceptedCells: Int
        public let goodFrames: Int
        public let qualityMet: Bool

        public init(
            durationSeconds: Double,
            processedFrames: Int,
            acceptedSamples: Int,
            acceptedCells: Int,
            goodFrames: Int,
            qualityMet: Bool
        ) {
            self.durationSeconds = durationSeconds
            self.processedFrames = processedFrames
            self.acceptedSamples = acceptedSamples
            self.acceptedCells = acceptedCells
            self.goodFrames = goodFrames
            self.qualityMet = qualityMet
        }

        public static let empty = Stats(
            durationSeconds: 0,
            processedFrames: 0,
            acceptedSamples: 0,
            acceptedCells: 0,
            goodFrames: 0,
            qualityMet: false
        )
    }

    /// 카메라 −Z를 XZ에 투영해 볼 앞(홀) 방향 proxy.
    public static func forwardDirection(lookX: Double, lookZ: Double) -> (x: Double, z: Double)? {
        let length = hypot(lookX, lookZ)
        guard length > 1e-4 else { return nil }
        return (lookX / length, lookZ / length)
    }

    public static func accepts(sample: Sample, context: Context) -> Bool {
        guard sample.confidence >= 2 else { return false }

        let forwardLen = hypot(context.forwardX, context.forwardZ)
        guard forwardLen > 1e-6 else { return false }
        let fx = context.forwardX / forwardLen
        let fz = context.forwardZ / forwardLen

        let relX = sample.worldX - context.ballX
        let relZ = sample.worldZ - context.ballZ
        let along = relX * fx + relZ * fz
        guard along >= minRangeMeters, along <= maxRangeMeters else { return false }

        let lateral = abs(relX * (-fz) + relZ * fx)
        guard lateral <= lateralHalfWidthMeters else { return false }

        let dx = sample.worldX - context.cameraX
        let dy = sample.worldY - context.cameraY
        let dz = sample.worldZ - context.cameraZ
        let horizontal = hypot(dx, dz)
        guard horizontal > 0.05 else { return false }
        let elevationDeg = atan2(-dy, horizontal) * 180 / .pi
        guard elevationDeg >= minElevationDegrees, elevationDeg <= maxElevationDegrees else { return false }

        guard sample.worldY <= context.ballY + 0.25 else { return false }
        guard sample.worldY >= context.ballY - 0.08 else { return false }
        return true
    }

    public static func qualityMet(stats: Stats) -> Bool {
        stats.acceptedCells >= requiredAcceptedCells
            && stats.durationSeconds >= minimumDurationSeconds
            && stats.goodFrames >= minimumGoodFrames
    }

    public static let fusionCellSize = 0.02

    public static func cellKey(x: Double, z: Double, cellSize: Double = fusionCellSize) -> Int64 {
        let ix = Int32(floor(x / cellSize))
        let iz = Int32(floor(z / cellSize))
        return (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
    }
}
