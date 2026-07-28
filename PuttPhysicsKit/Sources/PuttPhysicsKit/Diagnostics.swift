import Foundation

public struct SigmaNoiseMeasurement: Codable, Sendable, Equatable {
    public let sigma: Double
    public let detrendedStandardDeviationMM: Double

    public init(sigma: Double, detrendedStandardDeviationMM: Double) {
        self.sigma = sigma
        self.detrendedStandardDeviationMM = detrendedStandardDeviationMM
    }
}

public struct RepeatScanRMS: Codable, Sendable, Equatable {
    public let firstScan: String
    public let secondScan: String
    public let commonCellCount: Int
    public let rmsMillimeters: Double

    public init(firstScan: String, secondScan: String, commonCellCount: Int, rmsMillimeters: Double) {
        self.firstScan = firstScan
        self.secondScan = secondScan
        self.commonCellCount = commonCellCount
        self.rmsMillimeters = rmsMillimeters
    }
}

public struct ScanDiagnostics: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let driftMillimeters: Double
    public let emptyCellRatio: Double
    public let limitedTrackingRatio: Double
    public let selectedRegion: NormalizedRegion
    public let noiseStandardDeviationMM: Double
    public let sigmaNoiseMeasurements: [SigmaNoiseMeasurement]
    public let repeatScanRMS: [RepeatScanRMS]
    /// `roundTrip` / `oneWay`. 구버전 로그에는 없을 수 있음.
    public let pathMode: String?
    /// `temporal_scene_depth` / `arkit_mesh_fallback` 등.
    public let surfaceSource: String?

    public init(
        generatedAt: Date,
        driftMillimeters: Double,
        emptyCellRatio: Double,
        limitedTrackingRatio: Double,
        selectedRegion: NormalizedRegion,
        noiseStandardDeviationMM: Double,
        sigmaNoiseMeasurements: [SigmaNoiseMeasurement],
        repeatScanRMS: [RepeatScanRMS],
        pathMode: String? = nil,
        surfaceSource: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.driftMillimeters = driftMillimeters
        self.emptyCellRatio = emptyCellRatio
        self.limitedTrackingRatio = limitedTrackingRatio
        self.selectedRegion = selectedRegion
        self.noiseStandardDeviationMM = noiseStandardDeviationMM
        self.sigmaNoiseMeasurements = sigmaNoiseMeasurements
        self.repeatScanRMS = repeatScanRMS
        self.pathMode = pathMode
        self.surfaceSource = surfaceSource
    }
}

public struct SurfacePlaneFit: Codable, Sendable, Equatable {
    /// 로컬 X축 방향 기울기 (%, 100*tanθ 근사)
    public let slopeAlongXPercent: Double
    public let slopeAlongYPercent: Double
    /// 두 축 합성 기울기 (%)
    public let overallSlopePercent: Double
    /// 최소자승 평면을 뺀 잔차 표준편차. 순수 노이즈+미세 언듈레이션 지표.
    public let residualStdMillimeters: Double
    public let sampleCount: Int

    public init(
        slopeAlongXPercent: Double,
        slopeAlongYPercent: Double,
        overallSlopePercent: Double,
        residualStdMillimeters: Double,
        sampleCount: Int
    ) {
        self.slopeAlongXPercent = slopeAlongXPercent
        self.slopeAlongYPercent = slopeAlongYPercent
        self.overallSlopePercent = overallSlopePercent
        self.residualStdMillimeters = residualStdMillimeters
        self.sampleCount = sampleCount
    }

    public static let empty = SurfacePlaneFit(
        slopeAlongXPercent: .nan,
        slopeAlongYPercent: .nan,
        overallSlopePercent: .nan,
        residualStdMillimeters: .nan,
        sampleCount: 0
    )
}

public enum HeightMapNoiseEstimator {
    /// 선택 영역에 최소자승 평면을 맞춰 기울기와 잔차(노이즈)를 분리한다.
    /// 잔차는 그린의 미세 언듈레이션 + 센서 노이즈를 나타낸다.
    public static func planeFit(
        map: HeightMap,
        region: NormalizedRegion
    ) -> SurfacePlaneFit {
        let x0 = min(max(Int(floor(region.minX * Double(map.width - 1))), 0), map.width - 1)
        let x1 = min(max(Int(ceil(region.maxX * Double(map.width - 1))), x0), map.width - 1)
        let y0 = min(max(Int(floor(region.minY * Double(map.height - 1))), 0), map.height - 1)
        let y1 = min(max(Int(ceil(region.maxY * Double(map.height - 1))), y0), map.height - 1)

        var samples: [(x: Double, y: Double, z: Double)] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let index = map.index(x: x, y: y)
                guard map.measuredMask[index] else { continue }
                samples.append((Double(x) * map.cellSize, Double(y) * map.cellSize, map.values[index]))
            }
        }
        guard samples.count >= 3 else { return .empty }

        var matrix = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
        for sample in samples {
            let terms = [sample.x, sample.y, 1.0]
            for row in 0..<3 {
                for column in 0..<3 {
                    matrix[row][column] += terms[row] * terms[column]
                }
                matrix[row][3] += terms[row] * sample.z
            }
        }
        guard let coefficients = solve3x3(matrix) else { return .empty }
        let residuals = samples.map {
            $0.z - (coefficients[0] * $0.x + coefficients[1] * $0.y + coefficients[2])
        }
        let mean = residuals.reduce(0, +) / Double(residuals.count)
        let variance = residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(max(residuals.count - 1, 1))
        let slopeX = coefficients[0] * 100
        let slopeY = coefficients[1] * 100
        return SurfacePlaneFit(
            slopeAlongXPercent: slopeX,
            slopeAlongYPercent: slopeY,
            overallSlopePercent: sqrt(slopeX * slopeX + slopeY * slopeY),
            residualStdMillimeters: sqrt(variance) * 1_000,
            sampleCount: samples.count
        )
    }

    public static func detrendedStandardDeviation(
        map: HeightMap,
        region: NormalizedRegion
    ) -> Double {
        let x0 = min(max(Int(floor(region.minX * Double(map.width - 1))), 0), map.width - 1)
        let x1 = min(max(Int(ceil(region.maxX * Double(map.width - 1))), x0), map.width - 1)
        let y0 = min(max(Int(floor(region.minY * Double(map.height - 1))), 0), map.height - 1)
        let y1 = min(max(Int(ceil(region.maxY * Double(map.height - 1))), y0), map.height - 1)

        var samples: [(x: Double, y: Double, z: Double)] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let index = map.index(x: x, y: y)
                guard map.measuredMask[index] else { continue }
                samples.append((Double(x) * map.cellSize, Double(y) * map.cellSize, map.values[index]))
            }
        }
        guard samples.count >= 3 else { return .nan }

        var matrix = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
        for sample in samples {
            let terms = [sample.x, sample.y, 1.0]
            for row in 0..<3 {
                for column in 0..<3 {
                    matrix[row][column] += terms[row] * terms[column]
                }
                matrix[row][3] += terms[row] * sample.z
            }
        }
        guard let coefficients = solve3x3(matrix) else { return .nan }
        let residuals = samples.map {
            $0.z - (coefficients[0] * $0.x + coefficients[1] * $0.y + coefficients[2])
        }
        let mean = residuals.reduce(0, +) / Double(residuals.count)
        let variance = residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(max(residuals.count - 1, 1))
        return sqrt(variance)
    }

    public static func sigmaSweep(
        correctedMap: HeightMap,
        region: NormalizedRegion,
        sigmas: [Double] = [0.75, 1.5, 2.25]
    ) -> [SigmaNoiseMeasurement] {
        sigmas.map { sigma in
            let smoothed = GaussianSmoother.smooth(correctedMap, sigma: sigma)
            let standardDeviation = detrendedStandardDeviation(map: smoothed, region: region)
            return SigmaNoiseMeasurement(
                sigma: sigma,
                detrendedStandardDeviationMM: standardDeviation * 1_000
            )
        }
    }

    private static func solve3x3(_ augmented: [[Double]]) -> [Double]? {
        var matrix = augmented
        for pivot in 0..<3 {
            var bestRow = pivot
            for row in (pivot + 1)..<3 where abs(matrix[row][pivot]) > abs(matrix[bestRow][pivot]) {
                bestRow = row
            }
            guard abs(matrix[bestRow][pivot]) > 1e-12 else { return nil }
            if bestRow != pivot {
                matrix.swapAt(bestRow, pivot)
            }
            let divisor = matrix[pivot][pivot]
            for column in pivot..<4 {
                matrix[pivot][column] /= divisor
            }
            for row in 0..<3 where row != pivot {
                let factor = matrix[row][pivot]
                for column in pivot..<4 {
                    matrix[row][column] -= factor * matrix[pivot][column]
                }
            }
        }
        return matrix.map { $0[3] }
    }
}

public enum RepeatScanComparator {
    public static func compare(
        namedMaps: [(name: String, map: HeightMap)]
    ) -> [RepeatScanRMS] {
        guard namedMaps.count >= 2 else { return [] }
        var output: [RepeatScanRMS] = []
        for first in 0..<(namedMaps.count - 1) {
            for second in (first + 1)..<namedMaps.count {
                output.append(compare(namedMaps[first], namedMaps[second]))
            }
        }
        return output
    }

    private static func compare(
        _ first: (name: String, map: HeightMap),
        _ second: (name: String, map: HeightMap)
    ) -> RepeatScanRMS {
        let firstCells = measuredCells(first.map)
        let secondCells = measuredCells(second.map)
        let commonKeys = Set(firstCells.keys).intersection(secondCells.keys)
        let squaredError = commonKeys.reduce(0.0) { partial, key in
            let difference = firstCells[key]! - secondCells[key]!
            return partial + difference * difference
        }
        let rms = commonKeys.isEmpty ? .nan : sqrt(squaredError / Double(commonKeys.count)) * 1_000
        return RepeatScanRMS(
            firstScan: first.name,
            secondScan: second.name,
            commonCellCount: commonKeys.count,
            rmsMillimeters: rms
        )
    }

    private struct CellKey: Hashable {
        let x: Int
        let y: Int
    }

    private static func measuredCells(_ map: HeightMap) -> [CellKey: Double] {
        var cells: [CellKey: Double] = [:]
        for y in 0..<map.height {
            for x in 0..<map.width {
                let index = map.index(x: x, y: y)
                guard map.measuredMask[index] else { continue }
                let coordinate = map.worldCoordinate(x: x, y: y)
                let key = CellKey(
                    x: Int(round(coordinate.x / 0.05)),
                    y: Int(round(coordinate.y / 0.05))
                )
                cells[key] = map.values[index]
            }
        }
        return cells
    }
}
