import SwiftUI
import PuttPhysicsKit

/// 폰 피치(사용자 정의): 0°=바닥 수평·카메라 직하, 90°=스크린 정면·카메라 수평.
enum ScanPhonePitchGuidance {
    static let targetDegrees = 40.0
    static let bandMinDegrees = 30.0
    static let bandMaxDegrees = 45.0

    static var bandLabel: String {
        "\(Int(bandMinDegrees))–\(Int(bandMaxDegrees))°"
    }

    static var targetLabel: String {
        "약 \(Int(targetDegrees))°"
    }

    static func actionHint(degrees: Double?) -> String {
        guard let degrees else { return L10n.pitchHintNone }
        if degrees < bandMinDegrees {
            return L10n.pitchHintLow
        }
        if degrees > bandMaxDegrees {
            return L10n.pitchHintHigh
        }
        return L10n.pitchHintOK(degrees: Int(degrees.rounded()))
    }
}

/// 걷기 스캔 안내 상태 (피치 배너·워시용).
struct ScanPitchGuidancePill: View {
    let guidance: LiDARTwistGuidanceState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: guidance.pitchInBand ? "checkmark.circle.fill" : "arrow.up.and.down")
                .foregroundStyle(guidance.pitchInBand ? OSDPalette.status : Color.orange)
            Text(ScanPhonePitchGuidance.actionHint(degrees: guidance.pitchDegrees))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OSDPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OSDPalette.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
    }
}

/// 피치 허용 밴드(30–45°)일 때만. 단색 fill — blur/머티리얼 없음(부하 무시 가능).
struct ScanPitchInBandWash: View {
    var body: some View {
        Color.green.opacity(0.14)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct LiDARTwistGuidanceState: Equatable {
    var bandMinX: Double
    var bandMaxX: Double
    var markerNormalizedX: Double?
    var inBand: Bool
    var actionText: String
    var statusText: String
    /// 피치가 스캔 밴드 안이면 true (`pitchInBand`와 동일).
    var pitchLookingAtGround: Bool
    var pitchDegrees: Double?
    var pitchInBand: Bool
    var walkProgress: Double?
    var walkDistanceMeters: Double?
    var walkRibbonCells: Int?
    var walkCanArrive: Bool?
    var walkStatusText: String?
}
