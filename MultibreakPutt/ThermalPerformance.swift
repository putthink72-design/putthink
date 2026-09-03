import Foundation
import UIKit

// MARK: - User-facing performance presets

/// 추천 슈팅 격자 (N×N).
enum RecommendScanGrid: Int, CaseIterable, Identifiable {
    case fine = 130
    case balanced = 90
    case light = 45

    var id: Int { rawValue }

    var label: String { "\(rawValue)×\(rawValue)" }

    var subtitle: String {
        switch self {
        case .fine: return "최고 정밀 · 발열·대기 큼"
        case .balanced: return "권장 · 정밀/발열 균형"
        case .light: return "빠른 계산 · 야외·고온용"
        }
    }
}

/// 지렁이 애니메이션 FPS.
enum WormAnimFPS: Int, CaseIterable, Identifiable {
    case high = 30
    case medium = 15
    case low = 12

    var id: Int { rawValue }

    var label: String { "\(rawValue) fps" }

    var subtitle: String {
        switch self {
        case .high: return "가장 부드러움 · GPU 부하↑"
        case .medium: return "권장"
        case .low: return "발열 감소"
        }
    }
}

/// 격자 한 변에 붙는 지렁이(대시) 개수.
enum WormDashesPerEdge: Int, CaseIterable, Identifiable {
    case three = 3
    case four = 4
    case five = 5
    case six = 6
    case seven = 7
    case eight = 8
    case nine = 9

    var id: Int { rawValue }

    var label: String { "\(rawValue)" }

    var subtitle: String {
        switch self {
        case .three: return "가벼움 · 권장"
        case .four, .five: return "흐름이 더 잘 보임"
        case .six, .seven: return "촘촘 · GPU 부하↑"
        case .eight, .nine: return "최대 밀도 · 발열 주의"
        }
    }
}

/// AR 조준선 근접 안정화 — 계산용 카메라-공 거리 하한(m).
enum AimCalcDistanceFloor: Double, CaseIterable, Identifiable {
    case cm10 = 0.10
    case cm20 = 0.20
    case cm25 = 0.25
    case cm30 = 0.30
    case cm40 = 0.40
    case cm50 = 0.50

    var id: Double { rawValue }

    var label: String {
        String(format: "%.0fcm", rawValue * 100)
    }

    var subtitle: String {
        switch self {
        case .cm10: return "매우 가까이에서만 선을 내림"
        case .cm20: return "아주 가까이에서만 선을 내림"
        case .cm25: return "약간 여유"
        case .cm30: return "권장 · 근접 시 선을 볼 아래로"
        case .cm40, .cm50: return "더 일찍부터 선을 지면 쪽으로"
        }
    }
}

/// AR 등고/격자 밀도.
enum OverlayDensity: String, CaseIterable, Identifiable {
    case standard
    case sparse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "촘촘"
        case .sparse: return "듬성"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "선·등고를 더 많이 표시"
        case .sparse: return "선·등고 수↓ · 토글·야외·발열에 유리"
        }
    }

    var gridSpacingScale: Double {
        switch self {
        case .standard: return 1.0
        case .sparse: return 1.45
        }
    }

    var contourMaxPolylines: Int {
        switch self {
        case .standard: return 48
        case .sparse: return 22
        }
    }

    var contourIntervalMeters: Double {
        switch self {
        case .standard: return 0.010
        case .sparse: return 0.016
        }
    }
}

/// @AppStorage / UserDefaults 키 + 실효값 계산.
enum PerformanceSettings {
    static let recommendGridKey = "perf.recommendScanGrid"
    static let wormFPSKey = "perf.wormAnimFPS"
    static let wormAnimationEnabledKey = "perf.wormAnimationEnabled"
    static let wormDashesPerEdgeKey = "perf.wormDashesPerEdge"
    static let autoThermalKey = "perf.autoThermalThrottle"
    static let overlayDensityKey = "perf.overlayDensity"
    static let forceMaxBrightnessKey = "perf.forceMaxBrightness"
    static let aimCalcDistanceFloorKey = "perf.aimCalcDistanceFloor"
    static let didChangeNotification = Notification.Name("PerformanceSettings.didChange")

    static var recommendGrid: RecommendScanGrid {
        let raw = UserDefaults.standard.object(forKey: recommendGridKey) as? Int
            ?? RecommendScanGrid.light.rawValue
        return RecommendScanGrid(rawValue: raw) ?? .light
    }

    static var wormFPS: WormAnimFPS {
        let raw = UserDefaults.standard.object(forKey: wormFPSKey) as? Int
            ?? WormAnimFPS.medium.rawValue
        return WormAnimFPS(rawValue: raw) ?? .medium
    }

    static var wormAnimationEnabled: Bool {
        if UserDefaults.standard.object(forKey: wormAnimationEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: wormAnimationEnabledKey)
    }

    static var wormDashesPerEdge: WormDashesPerEdge {
        let raw = UserDefaults.standard.object(forKey: wormDashesPerEdgeKey) as? Int
            ?? WormDashesPerEdge.three.rawValue
        return WormDashesPerEdge(rawValue: raw) ?? .three
    }

    static var autoThermalThrottle: Bool {
        if UserDefaults.standard.object(forKey: autoThermalKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoThermalKey)
    }

    static var overlayDensity: OverlayDensity {
        let raw = UserDefaults.standard.string(forKey: overlayDensityKey)
            ?? OverlayDensity.standard.rawValue
        return OverlayDensity(rawValue: raw) ?? .standard
    }

    /// 화면 최대 밝기 강제. 기본 off (발열·배터리).
    static var forceMaxBrightness: Bool {
        if UserDefaults.standard.object(forKey: forceMaxBrightnessKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: forceMaxBrightnessKey)
    }

    /// 조준선 렌더링용 카메라-공 거리 하한(m). 기본 0.30.
    static var aimCalcDistanceFloor: Double {
        let raw = UserDefaults.standard.object(forKey: aimCalcDistanceFloorKey) as? Double
            ?? AimCalcDistanceFloor.cm30.rawValue
        let clamped = min(max(raw, 0.15), 0.80)
        return clamped
    }

    static var aimCalcDistanceFloorPreset: AimCalcDistanceFloor {
        let value = aimCalcDistanceFloor
        return AimCalcDistanceFloor.allCases.min(by: {
            abs($0.rawValue - value) < abs($1.rawValue - value)
        }) ?? .cm30
    }

    /// 추천 계산에 쓸 N (자동 발열이 켜져 있으면 기기 온도로만 하향).
    static var effectiveRecommendPointCount: Int {
        let user = recommendGrid.rawValue
        guard autoThermalThrottle else { return user }
        return min(user, ThermalPerformance.level.recommendPointCap)
    }

    /// 지렁이 목표 FPS (꺼짐·과열 시 0).
    static var effectiveWormFPS: Float {
        guard wormAnimationEnabled else { return 0 }
        let user = Float(wormFPS.rawValue)
        guard autoThermalThrottle else { return user }
        let cap = ThermalPerformance.level.wormFPSCap
        if cap <= 0 { return 0 }
        return min(user, cap)
    }

    static var effectiveOverlayDensity: OverlayDensity {
        guard autoThermalThrottle else { return overlayDensity }
        if ThermalPerformance.level >= .serious {
            return .sparse
        }
        return overlayDensity
    }

    static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

// MARK: - Device thermal caps (only used when auto throttle is on)

enum ThermalPerformance {
    enum Level: Int, Comparable {
        case nominal
        case fair
        case serious
        case critical

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// 사용자 설정보다 높게는 안 올리고, 이 값으로 상한만 둠.
        var recommendPointCap: Int {
            switch self {
            case .nominal: return 130
            case .fair: return 90
            case .serious: return 45
            case .critical: return 45
            }
        }

        var wormFPSCap: Float {
            switch self {
            case .nominal: return 30
            case .fair: return 15
            case .serious: return 12
            case .critical: return 0
            }
        }

        var statusBanner: String? {
            switch self {
            case .nominal:
                return nil
            case .fair:
                return PerformanceSettings.autoThermalThrottle
                    ? "기기 온도 상승 · 자동으로 부하 제한 중"
                    : "기기 온도 상승"
            case .serious:
                return PerformanceSettings.autoThermalThrottle
                    ? "고온 · 격자·지렁이 자동 축소"
                    : "고온 주의"
            case .critical:
                return PerformanceSettings.autoThermalThrottle
                    ? "과열 위험 · 지렁이 정지·최소 계산"
                    : "과열 위험 · 설정을 낮춰 주세요"
            }
        }
    }

    static var level: Level {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }

    static var thermalStateDidChangeNotification: Notification.Name {
        ProcessInfo.thermalStateDidChangeNotification
    }
}
