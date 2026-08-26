import Foundation
import simd

/// iPhone Pro LiDAR 배치. 보정은 카메라 이미지 +X(화면 오른쪽) 기준.
public enum LiDARSensorLayout: String, Sendable, Codable, Equatable {
    /// 12–16 Pro: 뒷면 왼쪽 범프. 화면에서는 오른쪽.
    case cameraBumpLeftBack
    /// 17 Pro: 뒷면 플레이트 오른쪽 LiDAR. 화면에서는 왼쪽.
    case plateauRightBack
    case unknown
}

public struct LiDARDeviceProfile: Sendable, Equatable, Codable {
    public var machineIdentifier: String
    public var productName: String
    public var layout: LiDARSensorLayout
    /// 카메라 이미지 +X(화면 오른쪽) 기준, 메인 카메라 대비 LiDAR(m).
    public var lidarFromCameraImageRightMeters: Double
    /// 편도 융합 보존 경로를 LiDAR가 보는 쪽으로 더 민다.
    public var fusionPathBiasMeters: Double
    /// 화면 정규화 X에서 LiDAR 권장 구역 (0=왼쪽, 1=오른쪽).
    public var targetScreenBandMinX: Double
    public var targetScreenBandMaxX: Double

    public init(
        machineIdentifier: String,
        productName: String,
        layout: LiDARSensorLayout,
        lidarFromCameraImageRightMeters: Double,
        fusionPathBiasMeters: Double,
        targetScreenBandMinX: Double,
        targetScreenBandMaxX: Double
    ) {
        self.machineIdentifier = machineIdentifier
        self.productName = productName
        self.layout = layout
        self.lidarFromCameraImageRightMeters = lidarFromCameraImageRightMeters
        self.fusionPathBiasMeters = fusionPathBiasMeters
        self.targetScreenBandMinX = targetScreenBandMinX
        self.targetScreenBandMaxX = targetScreenBandMaxX
    }

    public static func resolve(machineIdentifier: String = DeviceMachineIdentifier.current()) -> LiDARDeviceProfile {
        let parsed = parse(machineIdentifier)
        switch parsed.layout {
        case .plateauRightBack:
            let offset = parsed.isMax ? 0.068 : 0.055
            return LiDARDeviceProfile(
                machineIdentifier: machineIdentifier,
                productName: parsed.productName,
                layout: .plateauRightBack,
                lidarFromCameraImageRightMeters: -offset,
                // 보존 경로를 옆으로 밀면 등고/지형이 퍼트 라인 한쪽으로 치우침 → 0.
                fusionPathBiasMeters: 0,
                // UI는 넓은 허용 — 틀기보다 안정 파지 우선.
                targetScreenBandMinX: 0.10,
                targetScreenBandMaxX: 0.88
            )
        case .cameraBumpLeftBack:
            return LiDARDeviceProfile(
                machineIdentifier: machineIdentifier,
                productName: parsed.productName,
                layout: .cameraBumpLeftBack,
                lidarFromCameraImageRightMeters: 0.012,
                fusionPathBiasMeters: 0,
                targetScreenBandMinX: 0.12,
                targetScreenBandMaxX: 0.90
            )
        case .unknown:
            return LiDARDeviceProfile(
                machineIdentifier: machineIdentifier,
                productName: parsed.productName,
                layout: .unknown,
                lidarFromCameraImageRightMeters: 0,
                fusionPathBiasMeters: 0,
                targetScreenBandMinX: 0.10,
                targetScreenBandMaxX: 0.90
            )
        }
    }

    /// 볼→홀 직교 복도는 기종과 무관하게 라인 중심 6m.
    /// 융합 prune 끝점은 카메라 위치(편향 없음). LiDAR 오프셋 기록만 유지.
    public func pathEndXZ(
        cameraXZ: SIMD2<Double>,
        cameraRightXZ: SIMD2<Double>
    ) -> SIMD2<Double> {
        _ = cameraRightXZ
        _ = lidarFromCameraImageRightMeters
        _ = fusionPathBiasMeters
        return cameraXZ
    }

    public var targetScreenBandCenterX: Double {
        (targetScreenBandMinX + targetScreenBandMaxX) * 0.5
    }

    /// 화면 마커 X(0…1)가 권장 구역에 있는지.
    public func isInTargetBand(normalizedX: Double) -> Bool {
        normalizedX >= targetScreenBandMinX && normalizedX <= targetScreenBandMaxX
    }

    /// 마커가 목표보다 왼쪽이면 음수(왼쪽으로 과다), 오른쪽이면 양수.
    public func twistError(normalizedX: Double) -> Double {
        normalizedX - targetScreenBandCenterX
    }

    public func twistActionLabel(normalizedX: Double?) -> String {
        guard let normalizedX else { return "볼·홀이 화면에 보이게 하세요" }
        if isInTargetBand(normalizedX: normalizedX) { return "안정 유지" }
        // 넓은 밴드 밖 = 거의 화면 밖. 미세 틀기 유도하지 않음.
        return normalizedX < targetScreenBandMinX ? "볼·홀이 화면 왼쪽 밖" : "볼·홀이 화면 오른쪽 밖"
    }

    /// 화면을 보며 스캔할 때 — 항상 사선(~40°, 허용 30–45°), 틀기보다 안정 파지.
    public var puttLineScreenHint: String {
        "폰을 안정적으로 잡고 바닥을 약 40° 사선(허용 30–45°)으로 비추며 걸으세요. 멀리 보이다가 가까워지도록 유지하고, 좌우로 살짝 틀지 않아도 됩니다."
    }

    private struct Parsed {
        var productName: String
        var layout: LiDARSensorLayout
        var isMax: Bool
    }

    private static func parse(_ identifier: String) -> Parsed {
        let parts = identifier.split(separator: ",")
        guard identifier.hasPrefix("iPhone"),
              parts.count == 2,
              let family = Int(parts[0].dropFirst("iPhone".count)),
              let model = Int(parts[1])
        else {
            return Parsed(productName: identifier, layout: .unknown, isMax: false)
        }

        // 17 Pro / Pro Max
        if family == 18 && (model == 1 || model == 2) {
            return Parsed(
                productName: model == 2 ? "iPhone 17 Pro Max" : "iPhone 17 Pro",
                layout: .plateauRightBack,
                isMax: model == 2
            )
        }
        // 12 Pro … 16 Pro (LiDAR 범프)
        let bump: [(family: Int, model: Int, name: String, isMax: Bool)] = [
            (13, 3, "iPhone 12 Pro", false),
            (13, 4, "iPhone 12 Pro Max", true),
            (14, 2, "iPhone 13 Pro", false),
            (14, 3, "iPhone 13 Pro Max", true),
            (15, 2, "iPhone 14 Pro", false),
            (15, 3, "iPhone 14 Pro Max", true),
            (16, 1, "iPhone 15 Pro", false),
            (16, 2, "iPhone 15 Pro Max", true),
            (17, 1, "iPhone 16 Pro", false),
            (17, 2, "iPhone 16 Pro Max", true)
        ]
        if let match = bump.first(where: { $0.family == family && $0.model == model }) {
            return Parsed(productName: match.name, layout: .cameraBumpLeftBack, isMax: match.isMax)
        }
        return Parsed(productName: identifier, layout: .unknown, isMax: false)
    }
}

public enum DeviceMachineIdentifier {
    public static func current() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { chars in
                String(cString: chars)
            }
        }
    }
}
