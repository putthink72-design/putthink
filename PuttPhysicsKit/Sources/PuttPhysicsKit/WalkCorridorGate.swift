import Foundation
import simd

/// STEP 3 홀 방향 걷기 스캔 — 라인 리본 커버. 가까운 홀은 볼 뒤에서 지정한다.
public enum WalkCorridorGate {
    /// 볼→진행 방향(카메라 전방 proxy) 기준 라인 리본 반폭.
    public static let lineRibbonHalfWidthMeters = 0.45
    /// 이 거리 안은 짧은 퍼트 씬. 컵을 지나 시간·거리를 채우지 않는다.
    public static let shortPuttMaxDistanceFromBall = 2.5
    /// 긴 퍼트에서만 참고하는 볼↔카메라 수평 거리.
    public static let minWalkDistanceFromBall = 1.5
    public static let minimumDurationSeconds = 2.0
    public static let requiredRibbonCells = 20
    public static let minimumGoodFrames = 3
    public static let goodFrameSampleThreshold = 24
    /// 걷기 중 너무 먼 depth는 리본 카운트에서 제외(grazing).
    public static let maxCountDepthMeters = 4.5
    public static let minElevationDegrees = 12.0
    public static let maxElevationDegrees = 78.0

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

        public var distanceFromBallXZ: Double {
            hypot(cameraX - ballX, cameraZ - ballZ)
        }
    }

    public struct Stats: Codable, Sendable, Equatable {
        public let durationSeconds: Double
        public let processedFrames: Int
        public let ribbonSamples: Int
        public let ribbonCells: Int
        public let goodFrames: Int
        public let maxDistanceFromBall: Double
        public let inBandFrameCount: Int
        public let qualityMet: Bool

        public init(
            durationSeconds: Double,
            processedFrames: Int,
            ribbonSamples: Int,
            ribbonCells: Int,
            goodFrames: Int,
            maxDistanceFromBall: Double,
            inBandFrameCount: Int,
            qualityMet: Bool
        ) {
            self.durationSeconds = durationSeconds
            self.processedFrames = processedFrames
            self.ribbonSamples = ribbonSamples
            self.ribbonCells = ribbonCells
            self.goodFrames = goodFrames
            self.maxDistanceFromBall = maxDistanceFromBall
            self.inBandFrameCount = inBandFrameCount
            self.qualityMet = qualityMet
        }

        public static let empty = Stats(
            durationSeconds: 0,
            processedFrames: 0,
            ribbonSamples: 0,
            ribbonCells: 0,
            goodFrames: 0,
            maxDistanceFromBall: 0,
            inBandFrameCount: 0,
            qualityMet: false
        )

        public var inBandRatio: Double {
            guard processedFrames > 0 else { return 0 }
            return Double(inBandFrameCount) / Double(processedFrames)
        }
    }

    /// 라인 리본 안 + 입사각·거리 OK — 품질 카운트용 (융합은 전체 유지).
    public static func countsTowardRibbon(sample: Sample, context: Context) -> Bool {
        guard sample.confidence >= 2 else { return false }
        let forwardLen = hypot(context.forwardX, context.forwardZ)
        guard forwardLen > 1e-6 else { return false }
        let fx = context.forwardX / forwardLen
        let fz = context.forwardZ / forwardLen

        let relX = sample.worldX - context.ballX
        let relZ = sample.worldZ - context.ballZ
        let along = relX * fx + relZ * fz
        guard along >= -0.3 else { return false }

        let lateral = abs(relX * (-fz) + relZ * fx)
        guard lateral <= lineRibbonHalfWidthMeters else { return false }

        let dx = sample.worldX - context.cameraX
        let dy = sample.worldY - context.cameraY
        let dz = sample.worldZ - context.cameraZ
        let horizontal = hypot(dx, dz)
        guard horizontal > 0.08, horizontal <= maxCountDepthMeters else { return false }
        let elevationDeg = atan2(-dy, horizontal) * 180 / .pi
        guard elevationDeg >= minElevationDegrees, elevationDeg <= maxElevationDegrees else { return false }

        guard sample.worldY <= context.ballY + 0.28 else { return false }
        guard sample.worldY >= context.ballY - 0.10 else { return false }
        return true
    }

    public static func qualityMet(stats: Stats) -> Bool {
        guard stats.ribbonCells >= requiredRibbonCells
            && stats.goodFrames >= minimumGoodFrames else { return false }
        // 볼 근처(짧은 홀): 라인만 비추면 지정. 2초·1.5m를 위해 컵을 지나지 않음.
        if stats.maxDistanceFromBall < shortPuttMaxDistanceFromBall {
            return true
        }
        return stats.durationSeconds >= minimumDurationSeconds
    }

    public static func progress(stats: Stats) -> Double {
        let c = min(1, Double(stats.ribbonCells) / Double(requiredRibbonCells))
        let f = min(1, Double(stats.goodFrames) / Double(minimumGoodFrames))
        if stats.maxDistanceFromBall < shortPuttMaxDistanceFromBall {
            return min(1, (c + f) / 2)
        }
        let d = min(1, stats.maxDistanceFromBall / minWalkDistanceFromBall)
        let t = min(1, stats.durationSeconds / minimumDurationSeconds)
        return min(1, (d + t + c + f) / 4)
    }

    public static func cellKey(x: Double, z: Double, cellSize: Double = 0.02) -> Int64 {
        let ix = Int32(floor(x / cellSize))
        let iz = Int32(floor(z / cellSize))
        return (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
    }
}
