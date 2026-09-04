import Foundation
import PuttPhysicsKit
import UIKit

struct ExportOutcome {
    let directory: URL
    let diagnostics: ScanDiagnostics
}

private struct ScanArchive: Codable {
    let id: String
    let startedAt: Date
    let trackingEvents: [TrackingEvent]
    let result: TerrainPipelineResult
    let diagnostics: ScanDiagnostics
}

enum ScanExporter {
    static func export(scan: CompletedScan, region: NormalizedRegion) throws -> ExportOutcome {
        let root = try exportRoot()
        let directory = root.appendingPathComponent(scan.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let historicalMaps = loadRecentMaps(from: root, excluding: scan.id, limit: 2)
        let repeatRMS = RepeatScanComparator.compare(
            namedMaps: historicalMaps + [(scan.id, scan.result.smoothed)]
        )
        let sigmaMeasurements = HeightMapNoiseEstimator.sigmaSweep(
            correctedMap: scan.result.corrected,
            region: region
        )
        let diagnostics = ScanDiagnostics(
            generatedAt: Date(),
            driftMillimeters: scan.result.driftMeters * 1_000,
            emptyCellRatio: scan.result.corrected.emptyCellRatio,
            limitedTrackingRatio: scan.limitedTrackingRatio,
            selectedRegion: region,
            noiseStandardDeviationMM: HeightMapNoiseEstimator.detrendedStandardDeviation(
                map: scan.result.smoothed,
                region: region
            ) * 1_000,
            sigmaNoiseMeasurements: sigmaMeasurements,
            repeatScanRMS: repeatRMS,
            pathMode: scan.pathMode.rawValue,
            surfaceSource: scan.surfaceSource,
            lidarMachineIdentifier: scan.lidarProfile.machineIdentifier,
            lidarLayout: scan.lidarProfile.layout.rawValue,
            behindBallSweepDurationSeconds: scan.behindBallSweepStats.durationSeconds,
            behindBallSweepAcceptedCells: scan.behindBallSweepStats.acceptedCells,
            behindBallSweepQualityMet: scan.behindBallSweepStats.qualityMet,
            walkCorridorDurationSeconds: scan.walkCorridorStats.durationSeconds,
            walkCorridorRibbonCells: scan.walkCorridorStats.ribbonCells,
            walkCorridorMaxDistanceMeters: scan.walkCorridorStats.maxDistanceFromBall,
            walkCorridorQualityMet: scan.walkCorridorStats.qualityMet,
            walkCorridorInBandRatio: scan.walkCorridorStats.inBandRatio
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        try encoder.encode(scan.result.uncorrected)
            .write(to: directory.appendingPathComponent("heightmap-before-drift.json"), options: .atomic)
        try encoder.encode(scan.result.corrected)
            .write(to: directory.appendingPathComponent("heightmap-after-drift.json"), options: .atomic)
        try encoder.encode(scan.result.smoothed)
            .write(to: directory.appendingPathComponent("heightmap-smoothed.json"), options: .atomic)
        try encoder.encode(scan.result.gradient)
            .write(to: directory.appendingPathComponent("gradient-field.json"), options: .atomic)
        try encoder.encode(diagnostics)
            .write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        try encoder.encode(scan.trackingEvents)
            .write(to: directory.appendingPathComponent("tracking-events.json"), options: .atomic)

        try heightMapCSV(scan.result.uncorrected)
            .write(to: directory.appendingPathComponent("heightmap-before-drift.csv"), atomically: true, encoding: .utf8)
        try heightMapCSV(scan.result.corrected)
            .write(to: directory.appendingPathComponent("heightmap-after-drift.csv"), atomically: true, encoding: .utf8)
        try heightMapCSV(scan.result.smoothed)
            .write(to: directory.appendingPathComponent("heightmap-smoothed.csv"), atomically: true, encoding: .utf8)
        try gradientCSV(scan.result.gradient, map: scan.result.smoothed)
            .write(to: directory.appendingPathComponent("gradient-field.csv"), atomically: true, encoding: .utf8)
        try sigmaCSV(sigmaMeasurements)
            .write(to: directory.appendingPathComponent("sigma-noise-comparison.csv"), atomically: true, encoding: .utf8)
        try repeatRMSCSV(repeatRMS)
            .write(to: directory.appendingPathComponent("repeat-scan-rms.csv"), atomically: true, encoding: .utf8)

        let planeFit = HeightMapNoiseEstimator.planeFit(map: scan.result.smoothed, region: region)
        try surfaceDetrendCSV(planeFit, source: scan.surfaceSource, vertexCount: scan.surfaceVertexCount)
            .write(to: directory.appendingPathComponent("surface-detrend.csv"), atomically: true, encoding: .utf8)

        try writeHeatmap(scan.result.corrected, to: directory.appendingPathComponent("heatmap-before-smoothing.png"))
        try writeHeatmap(scan.result.smoothed, to: directory.appendingPathComponent("heatmap-after-smoothing.png"))

        let archive = ScanArchive(
            id: scan.id,
            startedAt: scan.startedAt,
            trackingEvents: scan.trackingEvents,
            result: scan.result,
            diagnostics: diagnostics
        )
        try encoder.encode(archive)
            .write(to: directory.appendingPathComponent("scan-archive.json"), options: .atomic)

        try writeReferenceAnchorsCSV(scan)
            .write(
                to: directory.appendingPathComponent("reference-anchors.csv"),
                atomically: true,
                encoding: .utf8
            )
        try Gate55ExperimentRecorder.writeReferenceMetadata(scan: scan)

        return ExportOutcome(directory: directory, diagnostics: diagnostics)
    }

    static func exportRoot() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent("scanparScans", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func clearHistory() throws {
        let root = try exportRoot()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func loadRecentMaps(
        from root: URL,
        excluding identifier: String,
        limit: Int
    ) -> [(name: String, map: HeightMap)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }
        let maps: [(name: String, map: HeightMap)] = urls
            .filter { $0.lastPathComponent != identifier }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .prefix(limit)
            .compactMap { directory -> (name: String, map: HeightMap)? in
                let url = directory.appendingPathComponent("heightmap-smoothed.json")
                guard let data = try? Data(contentsOf: url),
                      let map = try? JSONDecoder().decode(HeightMap.self, from: data) else {
                    return nil
                }
                return (name: directory.lastPathComponent, map: map)
            }
        return Array(maps.reversed())
    }

    private static func heightMapCSV(_ map: HeightMap) -> String {
        var output = "grid_x,grid_y,local_x_m,local_y_m,height_m,measured,interpolated\n"
        for y in 0..<map.height {
            for x in 0..<map.width {
                let index = map.index(x: x, y: y)
                let coordinate = map.worldCoordinate(x: x, y: y)
                output += "\(x),\(y),\(coordinate.x),\(coordinate.y),\(map.values[index]),"
                output += "\(map.measuredMask[index]),\(map.interpolatedMask[index])\n"
            }
        }
        return output
    }

    private static func gradientCSV(_ field: GradientField, map: HeightMap) -> String {
        var output = "grid_x,grid_y,local_x_m,local_y_m,dh_dx,dh_dy\n"
        for y in 0..<field.height {
            for x in 0..<field.width {
                let index = y * field.width + x
                let coordinate = map.worldCoordinate(x: x, y: y)
                output += "\(x),\(y),\(coordinate.x),\(coordinate.y),\(field.dx[index]),\(field.dy[index])\n"
            }
        }
        return output
    }

    private static func sigmaCSV(_ measurements: [SigmaNoiseMeasurement]) -> String {
        "sigma_cells,detrended_noise_std_mm\n"
            + measurements.map { "\($0.sigma),\($0.detrendedStandardDeviationMM)" }.joined(separator: "\n")
            + "\n"
    }

    private static func repeatRMSCSV(_ measurements: [RepeatScanRMS]) -> String {
        "first_scan,second_scan,common_cell_count,rms_mm\n"
            + measurements.map {
                "\($0.firstScan),\($0.secondScan),\($0.commonCellCount),\($0.rmsMillimeters)"
            }.joined(separator: "\n")
            + "\n"
    }

    private static func surfaceDetrendCSV(
        _ fit: SurfacePlaneFit,
        source: String,
        vertexCount: Int
    ) -> String {
        var csv = "field,value\n"
        csv += "surface_source,\(source)\n"
        csv += "surface_vertex_count,\(vertexCount)\n"
        csv += "plane_slope_x_pct,\(fit.slopeAlongXPercent)\n"
        csv += "plane_slope_y_pct,\(fit.slopeAlongYPercent)\n"
        csv += "plane_slope_overall_pct,\(fit.overallSlopePercent)\n"
        csv += "detrended_residual_std_mm,\(fit.residualStdMillimeters)\n"
        csv += "plane_fit_sample_count,\(fit.sampleCount)\n"
        return csv
    }

    private static func writeHeatmap(_ map: HeightMap, to url: URL) throws {
        let scale = max(1, min(8, 1_024 / max(map.width, map.height)))
        let size = CGSize(width: map.width * scale, height: map.height * scale)
        let minimum = map.values.min() ?? 0
        let maximum = map.values.max() ?? minimum
        let range = max(maximum - minimum, 1e-9)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            for y in 0..<map.height {
                for x in 0..<map.width {
                    let index = map.index(x: x, y: y)
                    let normalized = (map.values[index] - minimum) / range
                    cg.setFillColor(heatColor(normalized).cgColor)
                    cg.fill(
                        CGRect(
                            x: x * scale,
                            y: (map.height - y - 1) * scale,
                            width: scale,
                            height: scale
                        )
                    )
                }
            }
        }
        guard let data = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func heatColor(_ value: Double) -> UIColor {
        let value = min(max(value, 0), 1)
        let hue = CGFloat((1 - value) * 0.66)
        return UIColor(hue: hue, saturation: 0.9, brightness: 0.95, alpha: 1)
    }

    private static func writeReferenceAnchorsCSV(_ scan: CompletedScan) -> String {
        var csv = "field,value\n"
        csv += "reference_method,\(scan.referenceMethod)\n"
        csv += "path_mode,\(scan.pathMode.rawValue)\n"
        csv += "drift_corrected,\(scan.driftCorrected ? "Y" : "N")\n"
        csv += "surface_source,\(scan.surfaceSource)\n"
        csv += "surface_vertex_count,\(scan.surfaceVertexCount)\n"
        csv += "hole_distance_m,\(scan.holeDistance)\n"
        csv += "ball_x,\(scan.ballAnchor.worldX)\n"
        csv += "ball_y,\(scan.ballAnchor.worldY)\n"
        csv += "ball_z,\(scan.ballAnchor.worldZ)\n"
        csv += "ball_tracking_ok,\(scan.ballPlacementTrackingOK ? "Y" : "N")\n"
        csv += "hole_x,\(scan.holeAnchor.worldX)\n"
        csv += "hole_y,\(scan.holeAnchor.worldY)\n"
        csv += "hole_z,\(scan.holeAnchor.worldZ)\n"
        csv += "hole_tracking_ok,\(scan.holePlacementTrackingOK ? "Y" : "N")\n"
        csv += "camera_start_y,\(scan.cameraStartPose.worldY)\n"
        csv += "camera_return_y,\(scan.cameraReturnPose.worldY)\n"
        csv += "drift_m,\(scan.result.driftMeters)\n"
        return csv
    }
}
