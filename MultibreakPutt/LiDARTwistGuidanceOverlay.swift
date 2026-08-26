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
        guard let degrees else { return "폰을 \(targetLabel)로 들어 바닥을 비추세요" }
        if degrees < bandMinDegrees {
            return "폰 끝을 조금 더 들어 \(targetLabel)로 (허용 \(bandLabel))"
        }
        if degrees > bandMaxDegrees {
            return "폰을 조금 더 숙여 \(targetLabel)로"
        }
        return "\(Int(degrees.rounded()))° · OK (\(bandLabel))"
    }
}

/// 걷기 스캔 안내 — 안정 파지·피치 밴드·참고 진행. 밴드 안이면 전체 초록 워시.
struct LiDARTwistGuidanceCards: View {
    let guidance: LiDARTwistGuidanceState

    var body: some View {
        VStack(spacing: 8) {
            postureCard
            if let walkProgress = guidance.walkProgress {
                walkProgressRow(
                    progress: walkProgress,
                    distance: guidance.walkDistanceMeters ?? 0,
                    ribbonCells: guidance.walkRibbonCells ?? 0,
                    status: guidance.walkStatusText ?? ""
                )
            }
            pitchCapsule
        }
    }

    private var postureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("스캔 자세")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OSDPalette.textPrimary)
                Spacer()
                Text(guidance.actionText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(guidance.inBand ? OSDPalette.status : OSDPalette.accent)
            }
            Text("좌우로 살짝 틀지 마세요. 흔들리지 않게 잡고, 바닥을 \(ScanPhonePitchGuidance.targetLabel) 사선으로 비추며 걸으세요 (\(ScanPhonePitchGuidance.bandLabel)).")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(OSDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OSDPalette.glassStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
        )
    }

    private func walkProgressRow(
        progress: Double,
        distance: Double,
        ribbonCells: Int,
        status: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("걷기 스캔(참고)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OSDPalette.textPrimary)
                Spacer()
                Text(status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OSDPalette.textSecondary)
            }
            ProgressView(value: min(max(progress, 0), 1))
                .tint(OSDPalette.accent)
            Text(
                String(
                    format: "볼에서 %.1fm · 라인 리본 %d/%d칸 · 언제든 홀 지정 가능",
                    distance,
                    ribbonCells,
                    WalkCorridorGate.requiredRibbonCells
                )
            )
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(OSDPalette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OSDPalette.glassStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
        )
    }

    private var pitchCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: guidance.pitchInBand ? "checkmark.circle.fill" : "arrow.up.and.down")
                .foregroundStyle(guidance.pitchInBand ? OSDPalette.status : Color.orange)
            Text(ScanPhonePitchGuidance.actionHint(degrees: guidance.pitchDegrees))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OSDPalette.textPrimary)
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
