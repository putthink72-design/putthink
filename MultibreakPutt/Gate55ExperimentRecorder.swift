import Foundation
import PuttPhysicsKit

enum Gate55ExperimentRecorder {
    // MARK: - Paths

    static func experimentDirectory(for scanID: String) throws -> URL {
        let root = try ScanExporter.exportRoot()
        let directory = root
            .appendingPathComponent(scanID, isDirectory: true)
            .appendingPathComponent("gate55", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Append helpers

    static func appendRampCalibration(
        scanID: String,
        runID: String,
        rampHeightCM: Double,
        ballID: String,
        measuredV0: Double,
        notes: String
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("ramp_calibration.csv")
        try ensureHeader(
            url,
            header: "run_id,ramp_height_cm,ball_id,measured_v0_ms,notes"
        )
        try appendRow(
            url,
            fields: [
                runID,
                format(rampHeightCM),
                ballID,
                format(measuredV0),
                notes
            ]
        )
    }

    static func appendOverheadTrackingMeta(
        scanID: String,
        runID: String,
        requestedV0: Double,
        requestedBeta: Double,
        executedBeta: Double?,
        trackingStateOK: Bool
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("overhead_tracking_\(sanitize(runID)).csv")
        try ensureHeader(
            url,
            header: "run_id,requested_v0,requested_beta_deg,executed_beta_deg,tracking_state_ok,frame_index,t_sec,ball_x_m,ball_y_m"
        )
        // 메타 행 — 프레임 궤적은 오프라인 처리 후 같은 파일에 추가한다.
        try appendRow(
            url,
            fields: [
                runID,
                format(requestedV0),
                format(requestedBeta),
                executedBeta.map(format) ?? "",
                trackingStateOK ? "Y" : "N",
                "",
                "",
                "",
                ""
            ]
        )
    }

    static func appendOverheadFrame(
        scanID: String,
        runID: String,
        frameIndex: Int,
        tSec: Double,
        ballX: Double,
        ballY: Double
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("overhead_tracking_\(sanitize(runID)).csv")
        try ensureHeader(
            url,
            header: "run_id,requested_v0,requested_beta_deg,executed_beta_deg,tracking_state_ok,frame_index,t_sec,ball_x_m,ball_y_m"
        )
        try appendRow(
            url,
            fields: [
                runID,
                "",
                "",
                "",
                "",
                "\(frameIndex)",
                format(tSec),
                format(ballX),
                format(ballY)
            ]
        )
    }

    static func appendSlopeSpotcheck(
        scanID: String,
        runID: String,
        pointID: String,
        x: Double,
        y: Double,
        measuredSlopeDeg: Double,
        measuredAzimuthDeg: Double,
        heightmapSlopeDeg: Double,
        heightmapAzimuthDeg: Double
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("slope_spotcheck_\(sanitize(runID)).csv")
        try ensureHeader(
            url,
            header: "point_id,x_m,y_m,measured_slope_deg,measured_azimuth_deg,heightmap_slope_deg,heightmap_azimuth_deg,diff_deg"
        )
        let diff = measuredSlopeDeg - heightmapSlopeDeg
        try appendRow(
            url,
            fields: [
                pointID,
                format(x),
                format(y),
                format(measuredSlopeDeg),
                format(measuredAzimuthDeg),
                format(heightmapSlopeDeg),
                format(heightmapAzimuthDeg),
                format(diff)
            ]
        )
    }

    static func writeIndoorTerrain(
        scanID: String,
        points: [(x: Double, y: Double, height: Double)]
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("indoor_scaled_terrain.csv")
        var csv = "grid_x_m,grid_y_m,measured_height_m\n"
        for point in points {
            csv += "\(escape(format(point.x))),\(escape(format(point.y))),\(escape(format(point.height)))\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    static func appendIndoorRunResult(
        scanID: String,
        runID: String,
        v0: Double,
        beta: Double,
        predictedStop: PuttVector2,
        measuredStop: PuttVector2
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("indoor_run_results.csv")
        try ensureHeader(
            url,
            header: "run_id,v0_ms,beta_deg,predicted_stop_x,predicted_stop_y,measured_stop_x,measured_stop_y,error_m"
        )
        let error = hypot(
            predictedStop.x - measuredStop.x,
            predictedStop.y - measuredStop.y
        )
        try appendRow(
            url,
            fields: [
                runID,
                format(v0),
                format(beta),
                format(predictedStop.x),
                format(predictedStop.y),
                format(measuredStop.x),
                format(measuredStop.y),
                format(error)
            ]
        )
    }

    /// 스캔 완료 시 볼·홀 지면 기준점 메타데이터를 gate55 폴더에 기록.
    static func writeReferenceMetadata(scan: CompletedScan) throws {
        let url = try experimentDirectory(for: scan.id)
            .appendingPathComponent("reference_anchors.csv")
        let header = "reference_method,path_mode,drift_corrected,hole_distance_m,ball_x,ball_y,ball_z,ball_tracking_ok,hole_x,hole_y,hole_z,hole_tracking_ok,camera_start_y,camera_return_y,drift_m"
        try ensureHeader(url, header: header)
        // 동일 스캔에서 재내보내기 시 덮어쓴다.
        let row = [
            scan.referenceMethod,
            scan.pathMode.rawValue,
            scan.driftCorrected ? "Y" : "N",
            format(scan.holeDistance),
            format(scan.ballAnchor.worldX),
            format(scan.ballAnchor.worldY),
            format(scan.ballAnchor.worldZ),
            scan.ballPlacementTrackingOK ? "Y" : "N",
            format(scan.holeAnchor.worldX),
            format(scan.holeAnchor.worldY),
            format(scan.holeAnchor.worldZ),
            scan.holePlacementTrackingOK ? "Y" : "N",
            format(scan.cameraStartPose.worldY),
            format(scan.cameraReturnPose.worldY),
            format(scan.result.driftMeters)
        ].map(escape).joined(separator: ",")
        try (header + "\n" + row + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 현장 퍼팅 1회 — 추천(스냅샷) + 실측 정지 + 홀인·홀컵 편차를 한 줄로 기록.
    static func appendFieldPuttResult(
        scanID: String,
        pathMode: String,
        surfaceSource: String,
        holeDistanceM: Double,
        greenSpeedM: Double,
        corridorIndex: Int,
        corridorCount: Int,
        runID: String,
        requestedV0: Double,
        requestedBeta: Double,
        predictedStop: PuttVector2,
        recommendation: Gate55Recommendation?,
        measuredStop: PuttVector2,
        executedBeta: Double?,
        holeIn: Bool,
        pathMatch: String,
        trackingStateOK: Bool,
        notes: String
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("field_putt_results.csv")
        try ensureHeader(
            url,
            header: [
                "recorded_at",
                "scan_id",
                "run_id",
                "path_mode",
                "surface_source",
                "hole_distance_m",
                "green_speed_m",
                "corridor_index",
                "corridor_count",
                "requested_v0_ms",
                "requested_beta_deg",
                "executed_beta_deg",
                "predicted_stop_x_m",
                "predicted_stop_y_m",
                "flat_equivalent_m",
                "horizontal_m",
                "elevation_m",
                "overrun_m",
                "measured_stop_x_m",
                "measured_stop_y_m",
                "stop_error_m",
                "lateral_miss_m",
                "along_miss_m",
                "hole_miss_distance_m",
                "hole_in",
                "path_match",
                "tracking_state_ok",
                "notes"
            ].joined(separator: ",")
        )

        let holeY = holeDistanceM
        let lateralMiss = measuredStop.x
        let alongMiss = measuredStop.y - holeY
        let holeMiss = hypot(measuredStop.x, measuredStop.y - holeY)
        let stopError = hypot(
            predictedStop.x - measuredStop.x,
            predictedStop.y - measuredStop.y
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try appendRow(
            url,
            fields: [
                formatter.string(from: Date()),
                scanID,
                runID,
                pathMode,
                surfaceSource,
                format(holeDistanceM),
                format(greenSpeedM),
                "\(corridorIndex)",
                "\(corridorCount)",
                format(requestedV0),
                format(requestedBeta),
                executedBeta.map(format) ?? "",
                format(predictedStop.x),
                format(predictedStop.y),
                format(recommendation?.flatEquivalentDistance ?? 0),
                format(recommendation?.horizontalDistance ?? 0),
                format(recommendation?.elevationDelta ?? 0),
                format(recommendation?.overrunDistance ?? 0),
                format(measuredStop.x),
                format(measuredStop.y),
                format(stopError),
                format(lateralMiss),
                format(alongMiss),
                holeIn ? "0" : format(holeMiss),
                holeIn ? "Y" : "N",
                pathMatch,
                trackingStateOK ? "Y" : "N",
                notes
            ]
        )
    }

    /// 현재 조준 세션의 요청값 스냅샷을 한 줄로 남긴다.
    static func writeAimSnapshot(
        scanID: String,
        runID: String,
        requestedV0: Double,
        requestedBeta: Double,
        trackingStateOK: Bool,
        recommendation: Gate55Recommendation?
    ) throws {
        let url = try experimentDirectory(for: scanID)
            .appendingPathComponent("aim_snapshot.csv")
        try ensureHeader(
            url,
            header: "run_id,requested_v0,requested_beta_deg,tracking_state_ok,flat_m,elevation_m,horizontal_m,stop_x,stop_y"
        )
        try appendRow(
            url,
            fields: [
                runID,
                format(requestedV0),
                format(requestedBeta),
                trackingStateOK ? "Y" : "N",
                format(recommendation?.flatEquivalentDistance ?? 0),
                format(recommendation?.elevationDelta ?? 0),
                format(recommendation?.horizontalDistance ?? 0),
                format(recommendation?.stopPosition.x ?? 0),
                format(recommendation?.stopPosition.y ?? 0)
            ]
        )
        try appendOverheadTrackingMeta(
            scanID: scanID,
            runID: runID,
            requestedV0: requestedV0,
            requestedBeta: requestedBeta,
            executedBeta: nil,
            trackingStateOK: trackingStateOK
        )
    }

    // MARK: - CSV utilities

    private static func ensureHeader(_ url: URL, header: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func appendRow(_ url: URL, fields: [String]) throws {
        let line = fields.map(escape).joined(separator: ",") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }
}
