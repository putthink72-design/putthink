import SwiftUI

/// 볼 뒤 사선 — 선택 단계. 긴 퍼트용 참고 게이지.
struct BehindBallSweepCards: View {
    let guidance: BehindBallSweepGuidanceState

    var body: some View {
        VStack(spacing: 8) {
            forwardHint
            progressCard
            pitchCapsule
        }
    }

    private var forwardHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("선택 · 볼 뒤 3–4초")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OSDPalette.textPrimary)
            Text("긴 퍼트에서만 권장. 홀 방향 바닥을 천천히 훑고, 짧게면 바로 걷기로 넘어가세요.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OSDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OSDPalette.glassStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
        )
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("근거리(참고)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OSDPalette.textPrimary)
                Spacer()
                Text(guidance.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(guidance.canContinue ? OSDPalette.status : OSDPalette.accent)
            }

            ProgressView(value: guidance.progress)
                .tint(guidance.canContinue ? OSDPalette.status : OSDPalette.accent)

            Text("수용 \(guidance.acceptedCells)/\(guidance.requiredCells)칸 · \(String(format: "%.1f", guidance.durationSeconds))초")
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
            Image(systemName: guidance.pitchOK ? "checkmark.circle.fill" : "arrow.down.to.line")
                .foregroundStyle(guidance.pitchOK ? OSDPalette.status : Color.orange)
            Text(guidance.pitchOK
                  ? "바닥을 비스듬히 비추는 중 · OK"
                  : "폰을 세워두지 말고 바닥을 향해 살짝 숙이세요")
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

struct BehindBallSweepGuidanceState: Equatable {
    var progress: Double
    var acceptedCells: Int
    var requiredCells: Int
    var durationSeconds: Double
    var pitchOK: Bool
    var canContinue: Bool
    var statusText: String
}
