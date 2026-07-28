import Foundation
import PuttPhysicsKit

/// 게이트 6 섀도 관측 CSV. 실제 볼·홀 앵커에는 쓰지 않는다.
enum Gate6ExperimentRecorder {
    static func sessionDirectory(for sessionID: String) throws -> URL {
        let root = try ScanExporter.exportRoot()
        let directory = root
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("gate6", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func appendAttempt(
        sessionID: String,
        kind: Gate6TargetKind,
        attemptID: String,
        rgbCandidates: Int,
        depthAccepted: Bool,
        falsePositiveRejected: Int,
        auto: Gate6DetectionResult?,
        manualWorldX: Double?,
        manualWorldY: Double?,
        manualWorldZ: Double?,
        outcome: String
    ) throws {
        let filename = kind == .ball ? "ball_attempts.csv" : "hole_attempts.csv"
        let url = try sessionDirectory(for: sessionID).appendingPathComponent(filename)
        try ensureHeader(
            url,
            header: "attempt_id,rgb_candidates,depth_accepted,false_positive_rejected,auto_nx,auto_ny,auto_score,auto_world_x,auto_world_y,auto_world_z,depth_verdict,depth_delta_m,manual_world_x,manual_world_y,manual_world_z,delta_m,outcome"
        )
        let delta: String
        if let auto,
           let ax = auto.worldX, let ay = auto.worldY, let az = auto.worldZ,
           let mx = manualWorldX, let my = manualWorldY, let mz = manualWorldZ
        {
            delta = format(hypot(ax - mx, hypot(ay - my, az - mz)))
        } else {
            delta = ""
        }
        try appendRow(
            url,
            fields: [
                attemptID,
                "\(rgbCandidates)",
                depthAccepted ? "Y" : "N",
                "\(falsePositiveRejected)",
                auto.map { format($0.candidate.normalizedX) } ?? "",
                auto.map { format($0.candidate.normalizedY) } ?? "",
                auto.map { format($0.candidate.score) } ?? "",
                auto.flatMap { $0.worldX.map(format) } ?? "",
                auto.flatMap { $0.worldY.map(format) } ?? "",
                auto.flatMap { $0.worldZ.map(format) } ?? "",
                auto?.depth.verdict.rawValue ?? "",
                auto.flatMap { $0.depth.deltaMeters.map(format) } ?? "",
                manualWorldX.map(format) ?? "",
                manualWorldY.map(format) ?? "",
                manualWorldZ.map(format) ?? "",
                delta,
                outcome
            ]
        )
    }

    static func writeSummary(
        sessionID: String,
        ballAttempts: Int,
        ballDepthHits: Int,
        holeAttempts: Int,
        holeDepthHits: Int,
        totalRGBRejectedByDepth: Int
    ) throws {
        let url = try sessionDirectory(for: sessionID).appendingPathComponent("summary.json")
        let payload: [String: Any] = [
            "mode": "shadow",
            "note": "Auto detections are never applied to ballAnchor/holeAnchor.",
            "ball_attempts": ballAttempts,
            "ball_depth_accepted": ballDepthHits,
            "hole_attempts": holeAttempts,
            "hole_depth_accepted": holeDepthHits,
            "rgb_false_positives_rejected_by_depth": totalRGBRejectedByDepth
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

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
}
