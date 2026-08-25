import SwiftUI
import PuttPhysicsKit

/// 걷기 스캔 안내 — 틀기 게이지·전체 초록 워시 없음. 안정 파지·바닥 각도·참고 진행만.
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
            Text("좌우로 살짝 틀지 마세요. 흔들리지 않게 잡고, 바닥을 약 30° 사선으로 비추며 걸으세요.")
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
            Image(systemName: guidance.pitchLookingAtGround ? "checkmark.circle.fill" : "arrow.down.to.line")
                .foregroundStyle(guidance.pitchLookingAtGround ? OSDPalette.status : Color.orange)
            Text(guidance.pitchLookingAtGround
                  ? "약 30° 사선으로 바닥 비추는 중 · OK"
                  : "폰을 세워두지 말고 바닥을 약 30°로 숙이세요")
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

struct LiDARTwistGuidanceState: Equatable {
    var bandMinX: Double
    var bandMaxX: Double
    var markerNormalizedX: Double?
    var inBand: Bool
    var actionText: String
    var statusText: String
    var pitchLookingAtGround: Bool
    var walkProgress: Double?
    var walkDistanceMeters: Double?
    var walkRibbonCells: Int?
    var walkCanArrive: Bool?
    var walkStatusText: String?
}
