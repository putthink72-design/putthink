import ARKit
import PuttPhysicsKit
import RealityKit
import SwiftUI
import UIKit

/// 결과 화면 그린 표면 시각화 모드.
enum GreenSurfaceVizMode: String, CaseIterable, Identifiable {
    case contours
    case gridFlow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contours: return "등고선"
        case .gridFlow: return "격자·흐름"
        }
    }

    var symbolName: String {
        switch self {
        case .contours: return "waveform.path"
        case .gridFlow: return "square.grid.3x3"
        }
    }

    var hint: String {
        switch self {
        case .contours:
            return "등고: 고도(파랑↓ · 빨강↑)"
        case .gridFlow:
            return "격자 각 변마다 지렁이 방향·속도(기복) · 점선 흐름"
        }
    }
}

/// X 좌우 편차 부호 — 키패드 마이너스 대신 탭으로 선택.
private enum MeasuredXLateral: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: return "←"
        case .center: return "·"
        case .right: return "→"
        }
    }

    func signedMagnitude(_ magnitude: Double) -> Double {
        switch self {
        case .left: return -abs(magnitude)
        case .center: return 0
        case .right: return abs(magnitude)
        }
    }
}

/// Y 직선 편차 부호 — ↓ 짧음 · 정확 · ↑ 김.
private enum MeasuredYAlong: String, CaseIterable, Identifiable {
    case short
    case onLine
    case long

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return "↓"
        case .onLine: return "·"
        case .long: return "↑"
        }
    }

    func adjustedHoleDistance(holeDistance: Double, centimeters: Int) -> Double {
        let meters = Double(max(centimeters, 0)) / 100.0
        switch self {
        case .short: return holeDistance - meters
        case .onLine: return holeDistance
        case .long: return holeDistance + meters
        }
    }
}

/// 현장 퍼팅 후 주관적 경로 일치도 (궤적 자동 추적 없음).
private enum FieldPuttPathMatch: String, CaseIterable, Identifiable {
    case similar
    case fair
    case different

    var id: String { rawValue }

    var label: String {
        switch self {
        case .similar: return "경로 유사"
        case .fair: return "대체로"
        case .different: return "다름"
        }
    }
}

/// 현장 퍼팅 cm 입력 대상.
private enum FieldCmPadTarget {
    case x
    case y
}

struct Gate55GuidanceView: View {
    @ObservedObject var controller: ARScanSessionController
    @StateObject private var model = Gate55GuidanceModel()
    @State private var showDiagnostics = false
    @State private var runID = ""
    @State private var measuredXLateral: MeasuredXLateral = .center
    @State private var measuredStopXcm = ""
    @State private var measuredYAlong: MeasuredYAlong = .onLine
    @State private var measuredStopYcm = ""
    @State private var fieldHoleIn = false
    @State private var fieldPathMatch: FieldPuttPathMatch = .similar
    @State private var recordMessage: String?
    @State private var aimRevision = 0
    @State private var greenVizMode: GreenSurfaceVizMode = .contours
    @State private var showPerformanceSettings = false
    @State private var osdScrollAnchor: String?
    @State private var activeCmPad: FieldCmPadTarget?
    @State private var cmPadMounted = false
    @State private var floorAddressMode = false

    var body: some View {
        guidanceRoot
    }

    private var guidanceRoot: some View {
        ZStack(alignment: .top) {
            arPanel
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !floorAddressMode {
                    guidanceTopChrome
                        .padding(.horizontal, OSDTopChromeMetrics.horizontalPadding)
                        .padding(.top, OSDTopChromeMetrics.topPadding)
                }

                Spacer(minLength: 0)

                if floorAddressMode {
                    floorAddressBottomOSD
                } else {
                    guidanceBottomStack
                }
            }
        }
        .overlay(alignment: .bottom) {
            cmNumberPadOverlay
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cmPadMounted = true
            OSDDoneTextField.prewarmAccessoryBar()
            if runID.isEmpty {
                runID = defaultRunID()
            }
            model.computeMode = .recommend
            if let scan = controller.completedScan {
                model.bind(scan: scan)
                aimRevision += 1
            }
        }
        .onChange(of: controller.completedScan?.id) { _, _ in
            if let scan = controller.completedScan {
                model.bind(scan: scan)
                aimRevision += 1
            }
        }
        .onChange(of: controller.completedScan?.holeDistance) { _, _ in
            if let scan = controller.completedScan {
                model.bind(scan: scan)
                aimRevision += 1
            }
        }
        .onChange(of: model.aimBetaDegrees) { _, _ in
            aimRevision += 1
        }
        .onChange(of: model.hasAimLine) { _, _ in
            aimRevision += 1
        }
        .onChange(of: greenVizMode) { _, _ in
            aimRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: PerformanceSettings.didChangeNotification)) { _ in
            aimRevision += 1
            if model.computeMode == .recommend {
                model.recompute()
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            if let scan = controller.completedScan {
                Gate1DiagnosticsSheet(scan: scan, onDismiss: { showDiagnostics = false })
            }
        }
        .sheet(isPresented: $showPerformanceSettings) {
            AppSettingsSheet(
                mode: .guidance,
                controller: controller,
                guidanceModel: model,
                onAimSettingsChanged: {
                    aimRevision += 1
                }
            )
        }
    }

    private var floorAddressBottomOSD: some View {
        guidanceBottomOSD
            .osdKeyboardAdaptive()
            .padding(.horizontal, OSDTopChromeMetrics.floatingCardHorizontalPadding)
            .padding(.bottom, guidanceBottomPadding)
    }

    @ViewBuilder
    private var arPanel: some View {
        ZStack(alignment: .topLeading) {
            Gate55ARAimView(
                controller: controller,
                scan: controller.completedScan,
                betaDegrees: model.aimBetaDegrees,
                visible: model.hasAimLine,
                revision: aimRevision,
                trajectorySamples: trajectorySamplesForAR,
                greenVizMode: greenVizMode,
                floorAddressMode: $floorAddressMode
            )
            .id("gate55-guidance-ar")

            if controller.placementRequest == .reanchorHole {
                OSDAmberReticle(dashedRing: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private var trajectorySamplesForAR: [TrajectorySample] {
        model.recommendation?.trajectory
            ?? model.forwardResult?.trajectory
            ?? []
    }

    private var guidanceTopChrome: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                OSDStatusPill(
                    isHealthy: controller.guidanceTrackingOK && !controller.trackingLimited,
                    title: "조준 중",
                    subtitle: statusSubtitle
                )

                Spacer(minLength: 4)

                OSDGearButton { showPerformanceSettings = true }
            }

            if let banner = model.thermalLevel.statusBanner {
                Text(banner)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OSDPalette.accentInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(OSDPalette.accent.opacity(0.9), in: Capsule())
            }
        }
    }

    private var statusSubtitle: String? {
        var parts: [String] = []
        if let scan = controller.completedScan {
            parts.append(String(format: "볼→홀 %.1fm", scan.holeDistance))
            parts.append(scan.driftCorrected ? "왕복" : "편도")
        }
        if !controller.guidanceTrackingOK || controller.trackingLimited {
            parts.append("limited")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var guidanceBottomStack: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                Button(action: controller.reset) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .bold))
                        Text("새 스캔")
                            .font(.system(size: 15, weight: .heavy))
                    }
                    .foregroundStyle(OSDPalette.accentInk)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background {
                        LinearGradient(
                            colors: [OSDPalette.accent, Color(red: 229 / 255, green: 150 / 255, blue: 15 / 255)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: OSDPalette.accent.opacity(0.55), radius: 10, y: 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 80, minHeight: 44)
                .contentShape(Rectangle())
            }
            HStack {
                Spacer(minLength: 0)
                GreenVizModePicker(selection: $greenVizMode)
            }
            guidanceBottomOSD
        }
        .osdKeyboardAdaptive()
        .padding(.horizontal, OSDTopChromeMetrics.floatingCardHorizontalPadding)
        .padding(.bottom, guidanceBottomPadding)
    }

    private var guidanceBottomPadding: CGFloat {
        let base = OSDTopChromeMetrics.floatingCardBottomPadding
        if activeCmPad != nil {
            return base + OSDInlineNumberPad.height
        }
        return base
    }

    @ViewBuilder
    private var cmNumberPadOverlay: some View {
        if cmPadMounted {
            OSDInlineNumberPad(
                onDigit: appendCmDigit,
                onDelete: deleteCmDigit,
                onDone: { activeCmPad = nil }
            )
            .opacity(activeCmPad == nil ? 0 : 1)
            .allowsHitTesting(activeCmPad != nil)
            .animation(nil, value: activeCmPad)
            .padding(.horizontal, OSDTopChromeMetrics.floatingCardHorizontalPadding)
            .padding(.bottom, OSDTopChromeMetrics.floatingCardBottomPadding)
        }
    }

    private var guidanceBottomOSD: some View {
        OSDFloatingScrollCard(maxHeight: 320, scrollToID: osdScrollAnchor) {
            VStack(alignment: .leading, spacing: 14) {
                if model.isComputing {
                    ProgressView("계산 중…")
                        .tint(OSDPalette.accent)
                } else {
                    recommendationSection
                    OSDSectionDivider()
                    speedCorridorSection
                }

                OSDSectionDivider()
                advancedPanelContent
            }
        }
    }

    @ViewBuilder
    private var recommendationSection: some View {
        if let rec = model.recommendation, rec.primary != nil {
            OSDAimReadout(
                horizontalDistance: rec.horizontalDistance,
                flatEquivalentDistance: rec.flatEquivalentDistance,
                distanceAdjustment: rec.distanceAdjustment,
                elevationDelta: rec.elevationDelta,
                directionDegrees: rec.directionDegrees,
                strokeGuidance: rec.strokeGuidance,
                detailLines: [
                    String(format: "v0 %.2f m/s · β %+.1f°", rec.initialVelocity, rec.directionDegrees),
                    String(
                        format: "정지 (%.2f, %.2f) · 오버런 %.2fm",
                        rec.stopPosition.x,
                        rec.stopPosition.y,
                        rec.overrunDistance
                    )
                ]
            )

            if abs(rec.elevationDelta) < 0.025, abs(rec.directionDegrees) > 8 {
                Text("평탄한 면인데 |β|가 큽니다. 라이다 노이즈 가능성 — 볼·홀을 다시 지정하거나 조명을 바꿔 재스캔하세요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.accent.opacity(0.9))
            }
        } else {
            Text("후보 없음 — 그린스피드나 볼·홀 배치를 확인하세요.")
                .font(.system(size: 13))
                .foregroundStyle(OSDPalette.accent)
        }
    }

    @ViewBuilder
    private var advancedPanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("게이트 5.5 조준")
                    .font(.headline)
                Spacer()
                Button("진단") { showDiagnostics = true }
                    .font(.caption)
                    .foregroundStyle(OSDPalette.accent)
            }

            Text(greenVizMode.hint)
                .font(.caption2)
                .foregroundStyle(OSDPalette.textTertiary)

            if let scan = controller.completedScan {
                Text(scanStatusText(scan))
                    .font(.caption2)
                    .foregroundStyle(OSDPalette.textSecondary)
            }

            if let message = controller.placementMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(OSDPalette.textSecondary)
            }

            OSDSectionDivider()
            fieldPuttSection

            if let recordMessage {
                Text(recordMessage)
                    .font(.caption2)
                    .foregroundStyle(OSDPalette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 4)
    }

    private func scanStatusText(_ scan: CompletedScan) -> String {
        String(
            format: "기준 AR raycast · 볼→홀 %.2fm · %@",
            scan.holeDistance,
            scan.driftCorrected ? "왕복" : "편도·미보정"
        )
    }

    private var speedCorridorSection: some View {
        OSDSpeedCorridorSection(
            corridorIndex: model.corridorIndex,
            corridorCount: model.corridorCandidateCount,
            overrunDistance: model.recommendation?.overrunDistance,
            isComputing: model.isComputing,
            isApplying: model.isApplyingCorridor,
            statusMessage: model.statusMessage,
            onSelectIndex: { model.selectCorridorIndex($0) }
        )
    }

    private func forwardCard(_ result: Gate55ForwardResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "v0 %.2f · β %+.1f°", result.initialVelocity, result.directionDegrees))
                .font(.headline)
            Text(
                String(
                    format: "정지 (%.2f, %.2f) · 호장 %.2fm",
                    result.stopPosition.x,
                    result.stopPosition.y,
                    result.arcLength
                )
            )
            .font(.caption)
            Text(
                "홀인 \(result.ballHoleIf ? "Y" : "N") · "
                    + "정지 \(result.ballStopIf ? "Y" : "N") · "
                    + "통과 \(result.ballPassOverHoleIf ? "Y" : "N")"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private var fieldPuttSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("현장 퍼팅 기록")
                .font(.subheadline.bold())

            OSDDoneTextField(
                text: $runID,
                placeholder: "run_id (예: h3-putt1)",
                keyboardType: .asciiCapable,
                textAlignment: .natural,
                onBeginEditing: scrollToFieldPuttInputs
            )
            .frame(height: 30)

            Text("실측 cm 정수 (저장 시 m 변환). X=←·→, Y=↓·↑. β는 추천값 자동.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("X")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OSDPalette.textSecondary)
                        .frame(width: 10)

                    Picker("X 부호", selection: $measuredXLateral) {
                        ForEach(MeasuredXLateral.allCases) { lateral in
                            Text(lateral.label).tag(lateral)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: measuredXLateral) { _, lateral in
                        if lateral == .center {
                            measuredStopXcm = ""
                            if activeCmPad == .x { activeCmPad = nil }
                        }
                    }

                    OSDCentimeterInput(
                        digits: $measuredStopXcm,
                        isEnabled: measuredXLateral != .center,
                        isActive: activeCmPad == .x,
                        onActivate: { activateCmPad(.x) }
                    )
                    .frame(width: 60, height: 32)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Text("Y")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OSDPalette.textSecondary)
                        .frame(width: 10)

                    Picker("Y 부호", selection: $measuredYAlong) {
                        ForEach(MeasuredYAlong.allCases) { along in
                            Text(along.label).tag(along)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(fieldHoleIn)
                    .onChange(of: measuredYAlong) { _, along in
                        if along == .onLine {
                            measuredStopYcm = ""
                            if activeCmPad == .y { activeCmPad = nil }
                        }
                    }

                    OSDCentimeterInput(
                        digits: $measuredStopYcm,
                        isEnabled: !fieldHoleIn && measuredYAlong != .onLine,
                        isActive: activeCmPad == .y,
                        onActivate: { activateCmPad(.y) }
                    )
                    .frame(width: 60, height: 32)
                }
                .frame(maxWidth: .infinity)
            }

            Picker("경로 일치", selection: $fieldPathMatch) {
                ForEach(FieldPuttPathMatch.allCases) { match in
                    Text(match.label).tag(match)
                }
            }
            .pickerStyle(.segmented)
            .tint(OSDPalette.accent)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button {
                    fieldHoleIn.toggle()
                    if fieldHoleIn {
                        measuredYAlong = .onLine
                        measuredStopYcm = ""
                        if activeCmPad == .y { activeCmPad = nil }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: fieldHoleIn ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16, weight: .semibold))
                        Text("홀인")
                            .font(.caption)
                    }
                    .foregroundStyle(fieldHoleIn ? OSDPalette.accent : OSDPalette.textSecondary)
                }
                .buttonStyle(.plain)
                Button("퍼팅 1회 저장") {
                    activeCmPad = nil
                    dismissPuttKeyboard()
                    saveFieldPutt()
                }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                    .tint(OSDPalette.accent)
            }
        }
        .id("fieldPutt")
        .padding(.vertical, 4)
    }

    private func saveFieldPutt() {
        guard let scan = controller.completedScan else { return }
        guard let rec = model.recommendation, rec.primary != nil else {
            recordMessage = "추천 결과가 없습니다. 그린스피드·스캔을 확인하세요."
            return
        }
        guard fieldHoleIn || measuredYAlong == .onLine || parsedCentimeters(measuredStopYcm) != nil else {
            recordMessage = "홀인이 아니면 ↓/↑ 와 cm를 입력하세요."
            return
        }

        let mx = measuredXLateral.signedMagnitude(Double(parsedCentimeters(measuredStopXcm) ?? 0) / 100.0)
        let my: Double
        if fieldHoleIn {
            my = scan.holeDistance
        } else {
            my = measuredYAlong.adjustedHoleDistance(
                holeDistance: scan.holeDistance,
                centimeters: parsedCentimeters(measuredStopYcm) ?? 0
            )
        }
        let measured = PuttVector2(x: mx, y: my)

        do {
            try Gate55ExperimentRecorder.appendFieldPuttResult(
                scanID: scan.id,
                pathMode: scan.pathMode.rawValue,
                surfaceSource: scan.surfaceSource,
                holeDistanceM: scan.holeDistance,
                greenSpeedM: model.greenSpeed,
                corridorIndex: model.corridorIndex,
                corridorCount: model.corridorCandidateCount,
                runID: runID,
                requestedV0: rec.initialVelocity,
                requestedBeta: rec.directionDegrees,
                predictedStop: rec.stopPosition,
                recommendation: rec,
                measuredStop: measured,
                executedBeta: rec.directionDegrees,
                holeIn: fieldHoleIn,
                pathMatch: fieldPathMatch.rawValue,
                trackingStateOK: controller.guidanceTrackingOK && !controller.trackingLimited,
                notes: ""
            )
            runID = defaultRunID()
            measuredXLateral = .center
            measuredStopXcm = ""
            measuredYAlong = .onLine
            measuredStopYcm = ""
            fieldHoleIn = false
            activeCmPad = nil
            dismissPuttKeyboard()
            let dir = try Gate55ExperimentRecorder.experimentDirectory(for: scan.id)
            recordMessage = "현장 퍼팅 저장: \(dir.path)/field_putt_results.csv"
        } catch {
            recordMessage = "기록 실패: \(error.localizedDescription)"
        }
    }

    private func parsedCentimeters(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    private func scrollToFieldPuttInputs() {
        osdScrollAnchor = nil
        DispatchQueue.main.async {
            osdScrollAnchor = "fieldPutt"
        }
    }

    private func activateCmPad(_ target: FieldCmPadTarget) {
        dismissPuttKeyboard()
        activeCmPad = target
        scrollToFieldPuttInputs()
    }

    private func appendCmDigit(_ digit: String) {
        switch activeCmPad {
        case .x:
            measuredStopXcm.append(contentsOf: digit.filter(\.isNumber))
        case .y:
            measuredStopYcm.append(contentsOf: digit.filter(\.isNumber))
        case nil:
            break
        }
    }

    private func deleteCmDigit() {
        switch activeCmPad {
        case .x:
            if !measuredStopXcm.isEmpty { measuredStopXcm.removeLast() }
        case .y:
            if !measuredStopYcm.isEmpty { measuredStopYcm.removeLast() }
        case nil:
            break
        }
    }

    private func dismissPuttKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func defaultRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return "run-\(formatter.string(from: Date()))"
    }
}

// MARK: - Surface viz mode picker

private struct GreenVizModePicker: View {
    @Binding var selection: GreenSurfaceVizMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GreenSurfaceVizMode.allCases) { mode in
                let selected = selection == mode
                Button {
                    guard selection != mode else { return }
                    selection = mode
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(selected ? OSDPalette.accentInk : OSDPalette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selected ? OSDPalette.accent : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(OSDPalette.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
    }
}

// MARK: - Direction compass

struct DirectionCompass: View {
    let degrees: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            // 0° = 볼→홀 (위쪽)
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 1, height: 36)
            // SwiftUI 양의 각 = 시계방향 = 골프 +β(화면·진행방향 우측)와 동일
            AimArrow()
                .fill(Color.green)
                .rotationEffect(.degrees(degrees))
            HStack {
                Text("좌−")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("우+")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .offset(y: -2)
            Text(String(format: "%+.1f°", degrees))
                .font(.system(size: 9, weight: .semibold))
                .offset(y: 22)
        }
    }
}

private struct AimArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: cx, y: rect.height * 0.12))
        path.addLine(to: CGPoint(x: cx - rect.width * 0.14, y: rect.height * 0.42))
        path.addLine(to: CGPoint(x: cx - rect.width * 0.05, y: rect.height * 0.42))
        path.addLine(to: CGPoint(x: cx - rect.width * 0.05, y: rect.height * 0.62))
        path.addLine(to: CGPoint(x: cx + rect.width * 0.05, y: rect.height * 0.62))
        path.addLine(to: CGPoint(x: cx + rect.width * 0.05, y: rect.height * 0.42))
        path.addLine(to: CGPoint(x: cx + rect.width * 0.14, y: rect.height * 0.42))
        path.closeSubpath()
        return path
    }
}

// MARK: - Floor address world-locked HUD (화면 투영, 폰 방향 무관)

final class FloorAddressWorldHUDView: UIView {
    private let holeLayer = CAShapeLayer()
    private let aimLayer = CAShapeLayer()
    private let betaLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false

        for layer in [holeLayer, aimLayer] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }
        holeLayer.strokeColor = UIColor(red: 1, green: 176 / 255, blue: 32 / 255, alpha: 1).cgColor
        holeLayer.lineWidth = 4
        aimLayer.strokeColor = UIColor.white.cgColor
        aimLayer.lineWidth = 5
        aimLayer.shadowColor = UIColor.white.cgColor
        aimLayer.shadowOpacity = 0.45
        aimLayer.shadowRadius = 8
        aimLayer.shadowOffset = .zero

        betaLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        betaLabel.textColor = UIColor(red: 1, green: 176 / 255, blue: 32 / 255, alpha: 1)
        betaLabel.textAlignment = .center
        addSubview(betaLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(holeLine: (CGPoint, CGPoint)?, aimLine: (CGPoint, CGPoint)?, betaText: String?, isVisible: Bool) {
        isHidden = !isVisible
        if let holeLine {
            let path = UIBezierPath()
            path.move(to: holeLine.0)
            path.addLine(to: holeLine.1)
            holeLayer.path = path.cgPath
            holeLayer.isHidden = false
        } else {
            holeLayer.isHidden = true
        }

        if let aimLine {
            let path = UIBezierPath()
            path.move(to: aimLine.0)
            path.addLine(to: aimLine.1)
            aimLayer.path = path.cgPath
            aimLayer.isHidden = false
        } else {
            aimLayer.isHidden = true
        }

        betaLabel.text = betaText
        betaLabel.isHidden = betaText == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        holeLayer.frame = bounds
        aimLayer.frame = bounds
        betaLabel.sizeToFit()
        betaLabel.center = CGPoint(x: bounds.midX, y: bounds.maxY - 48)
    }
}

// MARK: - AR aiming line (볼 지면 앵커 기준)

struct Gate55ARAimView: UIViewRepresentable {
    @ObservedObject var controller: ARScanSessionController
    let scan: CompletedScan?
    let betaDegrees: Double
    let visible: Bool
    let revision: Int
    var trajectorySamples: [TrajectorySample] = []
    var greenVizMode: GreenSurfaceVizMode = .contours
    @Binding var floorAddressMode: Bool

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = controller.session
        view.environment.sceneUnderstanding.options = []
        view.debugOptions.remove(.showSceneUnderstanding)
        view.renderOptions.insert(.disableMotionBlur)
        let hud = FloorAddressWorldHUDView(frame: view.bounds)
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hud)
        context.coordinator.floorHUDView = hud
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        uiView.environment.sceneUnderstanding.options = []
        uiView.debugOptions.remove(.showSceneUnderstanding)
        context.coordinator.floorHUDView?.frame = uiView.bounds
        if let hud = context.coordinator.floorHUDView {
            uiView.bringSubviewToFront(hud)
        }
        context.coordinator.onFloorAddressModeChanged = { newValue in
            if floorAddressMode != newValue {
                floorAddressMode = newValue
            }
        }
        context.coordinator.updateScene(
            in: uiView,
            scan: scan,
            betaDegrees: betaDegrees,
            visible: visible,
            trajectory: trajectorySamples,
            greenVizMode: greenVizMode
        )
        if controller.placementRequest == .reanchorHole {
            let coordinator = context.coordinator
            let sessionController = controller
            DispatchQueue.main.async {
                coordinator.performReanchorRaycast(in: uiView, controller: sessionController)
            }
        }
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        private var ballAnchorEntity: AnchorEntity?
        private var holeAnchorEntity: AnchorEntity?
        private var ballARAnchor: ARAnchor?
        private var holeARAnchor: ARAnchor?
        private var lockedBallPose: ScanPose?
        private var lockedHolePose: ScanPose?
        /// 조준·경로·등고 — 볼 ARAnchor 아래 (편도 후 session 재구성에도 볼과 동일 좌표계).
        private var overlayRoot: Entity?
        private var zeroLineEntity: ModelEntity?
        private var aimEntity: ModelEntity?
        private var trajectoryRoot: Entity?
        private var contourRoot: Entity?
        private var contourScanID: String?
        private var contourStyleVersionApplied = 0
        private static let contourStyleVersion = 11
        private static let contourLineWidthPixels: Float = 2
        /// 2px 환산값이 너무 얇을 때(근접·뷰포트 미준비) 최소 월드 폭.
        private static let contourLineWidthWorldMin: Float = 0.0036
        private var gridFlowRoot: Entity?
        private var wormDashRoot: Entity?
        private var gridFlowScanID: String?
        private var gridFlowStyleVersionApplied = 0
        private static let gridFlowStyleVersion = 15
        private static let gridLineWidthPixels: Float = 2
        private var gridFlowWormWidthApplied: Float = 0
        private var lastVizMode: GreenSurfaceVizMode?
        private var overlayScanID: String?
        private var handlingReanchor = false
        private var lastAimBeta: Double = .nan
        private var lastAimLength: Float = 0
        private var lastAimWidth: Float = 0
        private var lastAimLift: Float = 0
        private var lastPathLift: Float = 0
        private var lastAddressMode = false
        private var lastFloorAddressMode = false
        private var lastReportedFloorHUD = false
        private var lastARHiddenForFloorHUD = false
        private var smoothedFloorAddressHUD = false
        private var lastFloorHeightAboveBall: Float = 0.8
        private var lastFloorBallDistance: Float = 1.2
        private var smoothedCamBallDistance: Float = 1.2
        private var lastZeroHoleDistance: Double = .nan
        private var lastTrajectoryRevision: Int = -1
        var onFloorAddressModeChanged: ((Bool) -> Void)?
        weak var floorHUDView: FloorAddressWorldHUDView?
        private weak var hudARView: ARView?
        private var hudDisplayLink: CADisplayLink?
        private var hudSceneState: FloorHUDSceneState?
        private struct TerrainVizContext {
            var scan: CompletedScan
            var mode: GreenSurfaceVizMode
            var wormWidth: Float
        }
        private var terrainVizContext: TerrainVizContext?
        private var cachedHoleDirection: CGPoint?
        private var cachedAimDirection: CGPoint?
        private var smoothedHUDAnchor: CGPoint?
        private var smoothedHoleUnit: CGPoint?
        private var smoothedAimUnit: CGPoint?
        private var smoothedBetaDegrees: Double?
        private var lastHUDCameraTransform: simd_float4x4?

        private static let hudAnchorSmoothAlpha: CGFloat = 0.14
        private static let hudDirectionSmoothAlpha: CGFloat = 0.22
        private static let hudBetaSmoothAlpha: Double = 0.12
        private static let hudAnchorDeadZone: CGFloat = 2.0
        private static let hudDirectionDotDeadZone: CGFloat = 0.99985
        /// 프레임당 이 각도 이상 회전하면 AR처럼 즉시 추적 (스무딩 생략).
        private static let hudRotationThresholdDegrees: Float = 0.35

        private struct FloorHUDSceneState {
            var ballWorld: SIMD3<Float>
            var holeWorld: SIMD3<Float>
            var betaDegrees: Double
            var lift: Float
            var transform: ScanCoordinateTransform
        }

        private struct CameraAddressContext {
            var distance: Float
            var heightAboveBall: Float
            var alongPuttAxis: Float
            var isAddressPosition: Bool
            var isFloorAddressHUD: Bool
        }

        /// 격자 한 변 단위 지렁이 — 변당 대시 3개.
        private struct WormFlowLine {
            var p0: SIMD3<Float>
            var p1: SIMD3<Float>
            var totalLength: Float
            var slopeMagnitude: Double
            var dashLength: Float
            var period: Float
            var dashes: [ModelEntity]
        }

        private var wormFlowLines: [WormFlowLine] = []
        private var flowDisplayLink: CADisplayLink?
        private var lastFlowTimestamp: CFTimeInterval = 0
        private var flowTime: Float = 0
        private var wormPoseAccum: Float = 0
        /// 틱마다 일부만 갱신 — 전량 transform은 jetsam/워치독 유발.
        private var wormAnimCursor = 0
        private var gridFlowThermalApplied: ThermalPerformance.Level?
        private var contourThermalApplied: ThermalPerformance.Level?
        private var gridFlowDensityApplied: OverlayDensity?
        private var contourDensityApplied: OverlayDensity?
        private var gridFlowWormEnabledApplied: Bool?
        private var gridFlowDashesPerEdgeApplied: Int?

        /// DisplayLink 1회에 움직일 최대 줄 수.
        private static let wormAnimBudgetPerTick = 24
        /// 이 경사 미만 변은 지렁이 생략(평평한 격자).
        private static let minWormSlope = 0.018

        func cleanup() {
            stopWormFlowAnimation()
            stopFloorHUDDisplayLink()
            resetFloorHUDSmoothing()
            wormFlowLines.removeAll()
            if let wormDashRoot {
                wormDashRoot.removeFromParent()
            }
            wormDashRoot = nil
        }

        private func stopWormFlowAnimation() {
            flowDisplayLink?.invalidate()
            flowDisplayLink = nil
            lastFlowTimestamp = 0
            wormPoseAccum = 0
            wormAnimCursor = 0
        }

        private func startWormFlowAnimation() {
            let fps = PerformanceSettings.effectiveWormFPS
            if fps <= 0 {
                stopWormFlowAnimation()
                return
            }
            if let existing = flowDisplayLink {
                existing.preferredFrameRateRange = CAFrameRateRange(
                    minimum: max(3, fps - 1),
                    maximum: fps,
                    preferred: fps
                )
                return
            }
            guard !wormFlowLines.isEmpty else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleWormFlowTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: max(3, fps - 1),
                maximum: fps,
                preferred: fps
            )
            link.add(to: .main, forMode: .common)
            flowDisplayLink = link
        }

        @objc private func handleWormFlowTick(_ link: CADisplayLink) {
            let fps = PerformanceSettings.effectiveWormFPS
            if fps <= 0 {
                stopWormFlowAnimation()
                return
            }
            let now = link.timestamp
            let dt: Float
            if lastFlowTimestamp > 0 {
                dt = Float(min(now - lastFlowTimestamp, 0.12))
            } else {
                dt = 1.0 / fps
            }
            lastFlowTimestamp = now
            flowTime += dt
            wormPoseAccum += dt
            let interval = 1.0 / fps
            guard wormPoseAccum >= interval else { return }
            wormPoseAccum = 0
            tickWormFlowDashes()
        }

        private func tickWormFlowDashes() {
            let lines = wormFlowLines
            guard !lines.isEmpty else { return }
            let budget = min(Self.wormAnimBudgetPerTick, lines.count)
            let start = wormAnimCursor
            for offset in 0..<budget {
                let lineIndex = (start + offset) % lines.count
                let line = lines[lineIndex]
                guard line.totalLength > 0.04, !line.dashes.isEmpty else { continue }
                let speed = Float(0.022 + min(line.slopeMagnitude, 0.15) * 0.5)
                let travel = flowTime * speed
                let wrap = max(line.totalLength, line.period * Float(line.dashes.count))
                for (dashIndex, dash) in line.dashes.enumerated() {
                    var s = travel + Float(dashIndex) * line.period
                    s = s.truncatingRemainder(dividingBy: wrap)
                    if s < 0 { s += wrap }
                    placeDash(dash, on: line, at: s)
                }
            }
            wormAnimCursor = (start + budget) % lines.count
        }

        private func placeDash(_ dash: ModelEntity, on line: WormFlowLine, at arc: Float) {
            let len = line.totalLength
            guard len > 1e-4 else {
                dash.isEnabled = false
                return
            }
            let u = min(max(arc / len, 0), 1)
            let a = line.p0
            let b = line.p1
            let delta = b - a
            let horizontal = SIMD3<Float>(delta.x, 0, delta.z)
            let hLen = simd_length(horizontal)
            guard hLen > 1e-4 else {
                dash.isEnabled = false
                return
            }
            // 대시 중심이 변 끝에서 잘리지 않게
            let half = min(line.dashLength * 0.5, len * 0.45)
            let clampedU = min(max(u, half / len), 1 - half / len)
            dash.isEnabled = true
            dash.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: horizontal / hLen)
            dash.position = a + (b - a) * clampedU
        }

        func updateScene(
            in view: ARView,
            scan: CompletedScan?,
            betaDegrees: Double,
            visible: Bool,
            trajectory: [TrajectorySample] = [],
            greenVizMode: GreenSurfaceVizMode = .contours
        ) {
            let session = view.session
            guard let scan else {
                terrainVizContext = nil
                aimEntity?.isEnabled = false
                clearContours()
                clearGridFlow()
                clearTrajectory()
                clearOverlayRoot()
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &ballAnchorEntity,
                    existingARAnchor: &ballARAnchor
                )
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &holeAnchorEntity,
                    existingARAnchor: &holeARAnchor
                )
                lockedBallPose = nil
                lockedHolePose = nil
                lastAimBeta = .nan
                lastZeroHoleDistance = .nan
                lastTrajectoryRevision = -1
                lastAimWidth = 0
                lastAimLift = 0
                lastPathLift = 0
                lastVizMode = nil
                smoothedFloorAddressHUD = false
                lastARHiddenForFloorHUD = false
                stopFloorHUDDisplayLink()
                hideFloorHUD()
                if lastReportedFloorHUD {
                    lastReportedFloorHUD = false
                    onFloorAddressModeChanged?(false)
                }
                return
            }

            if overlayScanID != scan.id {
                clearContours()
                clearGridFlow()
                clearTrajectory()
                clearOverlayRoot()
                zeroLineEntity = nil
                aimEntity = nil
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &ballAnchorEntity,
                    existingARAnchor: &ballARAnchor
                )
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &holeAnchorEntity,
                    existingARAnchor: &holeARAnchor
                )
                lockedBallPose = nil
                lockedHolePose = nil
                overlayScanID = scan.id
                lastAimBeta = .nan
                lastZeroHoleDistance = .nan
                lastTrajectoryRevision = -1
                lastAimWidth = 0
                lastAimLift = 0
                lastPathLift = 0
                lastVizMode = nil
            }

            let ballWorld = SIMD3<Float>(
                Float(scan.ballAnchor.worldX),
                Float(scan.ballAnchor.worldY),
                Float(scan.ballAnchor.worldZ)
            )
            let holeWorld = SIMD3<Float>(
                Float(scan.holeAnchor.worldX),
                Float(scan.holeAnchor.worldY),
                Float(scan.holeAnchor.worldZ)
            )

            if lockedBallPose != scan.ballAnchor {
                clearContours()
                clearGridFlow()
                clearTrajectory()
                clearOverlayRoot()
                zeroLineEntity = nil
                aimEntity = nil
                lastZeroHoleDistance = .nan
                lastAimBeta = .nan
                lastTrajectoryRevision = -1
                lastVizMode = nil
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &ballAnchorEntity,
                    existingARAnchor: &ballARAnchor
                )
                ARReferenceMarkers.placeWorldLocked(
                    named: "trueputt.ball",
                    entityFactory: { ARReferenceMarkers.makeBallEntity() },
                    at: ballWorld,
                    session: session,
                    in: view,
                    existingEntity: &ballAnchorEntity,
                    existingARAnchor: &ballARAnchor
                )
                lockedBallPose = scan.ballAnchor
            }
            if lockedHolePose != scan.holeAnchor {
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &holeAnchorEntity,
                    existingARAnchor: &holeARAnchor
                )
                ARReferenceMarkers.placeWorldLocked(
                    named: "trueputt.hole",
                    entityFactory: { ARReferenceMarkers.makeHoleEntity() },
                    at: holeWorld,
                    session: session,
                    in: view,
                    existingEntity: &holeAnchorEntity,
                    existingARAnchor: &holeARAnchor
                )
                lockedHolePose = scan.holeAnchor
            }

            guard let ballEntity = ballAnchorEntity else { return }
            let overlays = ensureOverlayRoot(under: ballEntity)
            let transform = scan.scanTransform

            // 고정 월드 굵기 — 거리 따라 화면폭을 바꾸면 근접 시 굵어지고 매 프레임 흔들림
            let contourLift: Float = 0.006
            let wormWidth: Float = 0.012
            let address = cameraAddressContext(
                ballWorld: ballWorld,
                holeWorld: holeWorld,
                in: view
            )
            let addressModeChanged = lastAddressMode != address.isAddressPosition
            let floorModeChanged = lastFloorAddressMode != address.isFloorAddressHUD
            if smoothedCamBallDistance <= 0 {
                smoothedCamBallDistance = address.distance
            } else {
                smoothedCamBallDistance += (address.distance - smoothedCamBallDistance) * 0.18
            }

            let pathLift: Float
            let aimLift: Float
            var pathWidth: Float = 0.014
            var aimWidth: Float = 0.010
            if address.isAddressPosition {
                pathLift = 0.057
                aimLift = 0.066
                pathWidth = 0.020
                aimWidth = 0.014
            } else {
                let floorMeters = Float(PerformanceSettings.aimCalcDistanceFloor)
                let proximityT = max(
                    0,
                    min(1, (floorMeters - smoothedCamBallDistance) / max(floorMeters, 0.05))
                )
                pathLift = ((0.018 - proximityT * 0.014) / 0.003).rounded() * 0.003
                aimLift = ((0.022 - proximityT * 0.018) / 0.003).rounded() * 0.003
            }

            reportFloorAddressHUD(address)
            if visible {
                hudSceneState = FloorHUDSceneState(
                    ballWorld: ballWorld,
                    holeWorld: holeWorld,
                    betaDegrees: betaDegrees,
                    lift: pathLift,
                    transform: transform
                )
                hudARView = view
                startFloorHUDDisplayLinkIfNeeded()
                refreshFloorHUD(
                    showLines: smoothedFloorAddressHUD,
                    preferFastDirections: smoothedFloorAddressHUD
                )
                if !smoothedFloorAddressHUD {
                    seedFloorHUDDirectionCache(
                        in: view,
                        ballWorld: ballWorld,
                        lift: pathLift,
                        transform: transform,
                        betaDegrees: betaDegrees
                    )
                }
            } else {
                stopFloorHUDDisplayLink()
                hideFloorHUD()
            }

            let arHiddenForHUD = smoothedFloorAddressHUD
            let arVisibilityChanged = lastARHiddenForFloorHUD != arHiddenForHUD
            lastARHiddenForFloorHUD = arHiddenForHUD
            overlayRoot?.isEnabled = !arHiddenForHUD
            ballAnchorEntity?.isEnabled = !arHiddenForHUD
            holeAnchorEntity?.isEnabled = !arHiddenForHUD
            if arHiddenForHUD {
                zeroLineEntity?.isEnabled = false
                aimEntity?.isEnabled = false
                trajectoryRoot?.isEnabled = false
                clearContours()
                clearGridFlow()
                lastAddressMode = address.isAddressPosition
                lastFloorAddressMode = address.isFloorAddressHUD
                return
            }

            if arVisibilityChanged && !arHiddenForHUD {
                clearContours()
                clearGridFlow()
                lastVizMode = nil
            }

            zeroLineEntity?.isEnabled = true
            aimEntity?.isEnabled = visible
            trajectoryRoot?.isEnabled = visible
            if arVisibilityChanged {
                lastTrajectoryRevision = -1
            }

            if address.isFloorAddressHUD {
                clearContours()
                clearGridFlow()
            } else {
                terrainVizContext = TerrainVizContext(
                    scan: scan,
                    mode: greenVizMode,
                    wormWidth: wormWidth
                )
                updateTerrainViz(
                    mode: greenVizMode,
                    for: scan,
                    lift: contourLift,
                    transform: transform,
                    parent: overlays,
                    wormWidth: wormWidth,
                    in: view,
                    ballWorld: ballWorld
                )
            }

            let zeroNeedsRebuild = zeroLineEntity == nil
                || abs(lastZeroHoleDistance - scan.holeDistance) > 1e-4
                || abs(lastPathLift - pathLift) > 0.0015
                || addressModeChanged
                || arVisibilityChanged
            if zeroNeedsRebuild {
                let zeroWidth = address.isAddressPosition
                    ? max(pathWidth * 0.55, 0.008)
                    : max(pathWidth * 0.35, 0.004)
                placeBallLocalSegment(
                    toLocalX: 0,
                    toLocalY: scan.holeDistance,
                    lift: pathLift,
                    width: zeroWidth,
                    thickness: 0.002,
                    color: UIColor(red: 1.0, green: 176 / 255, blue: 32 / 255, alpha: 1),
                    transform: transform,
                    parent: overlays,
                    entity: &zeroLineEntity
                )
                lastZeroHoleDistance = scan.holeDistance
                lastPathLift = pathLift
            }

            guard visible else {
                aimEntity?.isEnabled = false
                clearTrajectory()
                lastTrajectoryRevision = -1
                return
            }

            let trajSig = trajectorySignature(trajectory, pathWidth: pathWidth, lift: pathLift)
            var trajectoryRebuilt = false
            if trajSig != lastTrajectoryRevision {
                updateTrajectory(
                    samples: trajectory,
                    transform: transform,
                    lift: pathLift,
                    pathWidth: pathWidth,
                    parent: overlays
                )
                lastTrajectoryRevision = trajSig
                trajectoryRebuilt = true
            }

            let length: Double
            if address.isAddressPosition {
                length = max(1.5, min(scan.holeDistance * 0.82, 5.0))
            } else {
                length = max(1.0, min(scan.holeDistance * 0.45, 2.2))
            }
            if trajectoryRebuilt
                || aimEntity == nil
                || abs(lastAimBeta - betaDegrees) > 0.05
                || abs(lastAimLength - Float(length)) > 1e-3
                || abs(lastAimLift - aimLift) > 0.0015
                || addressModeChanged
                || floorModeChanged
                || arVisibilityChanged {
                let beta = betaDegrees * .pi / 180
                placeBallLocalSegment(
                    toLocalX: sin(beta) * length,
                    toLocalY: cos(beta) * length,
                    lift: aimLift,
                    width: aimWidth,
                    thickness: 0.0025,
                    color: UIColor(white: 1, alpha: 1),
                    transform: transform,
                    parent: overlays,
                    entity: &aimEntity
                )
                lastAimBeta = betaDegrees
                lastAimLength = Float(length)
                lastAimWidth = aimWidth
                lastAimLift = aimLift
            }
            lastAddressMode = address.isAddressPosition
            lastFloorAddressMode = address.isFloorAddressHUD
        }

        private func reportFloorAddressHUD(_ address: CameraAddressContext) {
            lastFloorHeightAboveBall = address.heightAboveBall
            lastFloorBallDistance = address.distance
            if address.isFloorAddressHUD {
                smoothedFloorAddressHUD = true
            } else if lastFloorHeightAboveBall > 0.42 || lastFloorBallDistance > 1.40 {
                smoothedFloorAddressHUD = false
            }
            guard smoothedFloorAddressHUD != lastReportedFloorHUD else { return }
            lastReportedFloorHUD = smoothedFloorAddressHUD
            onFloorAddressModeChanged?(smoothedFloorAddressHUD)
        }

        private func startFloorHUDDisplayLinkIfNeeded() {
            guard hudDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(refreshFloorHUDTick))
            link.add(to: .main, forMode: .common)
            hudDisplayLink = link
        }

        private func stopFloorHUDDisplayLink() {
            hudDisplayLink?.invalidate()
            hudDisplayLink = nil
            hudARView = nil
            hudSceneState = nil
            resetFloorHUDSmoothing()
        }

        private func resetFloorHUDSmoothing() {
            smoothedHUDAnchor = nil
            smoothedHoleUnit = nil
            smoothedAimUnit = nil
            smoothedBetaDegrees = nil
            lastHUDCameraTransform = nil
            cachedHoleDirection = nil
            cachedAimDirection = nil
        }

        private func beginFloorHUDSmoothingSession() {
            smoothedHUDAnchor = nil
            smoothedHoleUnit = nil
            smoothedAimUnit = nil
            smoothedBetaDegrees = nil
            lastHUDCameraTransform = nil
        }

        @objc private func refreshFloorHUDTick() {
            guard let view = hudARView, let state = hudSceneState else { return }
            let address = cameraAddressContext(
                ballWorld: state.ballWorld,
                holeWorld: state.holeWorld,
                in: view
            )
            let wasFloorHUD = smoothedFloorAddressHUD
            reportFloorAddressHUD(address)
            if smoothedFloorAddressHUD, !wasFloorHUD {
                beginFloorHUDSmoothingSession()
                refreshFloorHUD(showLines: true, preferFastDirections: true)
            } else if !smoothedFloorAddressHUD, wasFloorHUD {
                resetFloorHUDSmoothing()
                refreshFloorHUD(showLines: false)
            } else {
                refreshFloorHUD(showLines: smoothedFloorAddressHUD)
            }
            refreshTerrainVizIfNeeded(in: view)
        }

        private func hideFloorHUD() {
            floorHUDView?.update(holeLine: nil, aimLine: nil, betaText: nil, isVisible: false)
        }

        private func refreshFloorHUD(showLines: Bool, preferFastDirections: Bool = false) {
            guard let view = hudARView,
                  let state = hudSceneState,
                  let hud = floorHUDView else { return }

            let bounds = view.bounds.insetBy(dx: 8, dy: 8)
            guard bounds.width > 1, bounds.height > 1 else { return }

            guard let holeDir = horizontalWorldDirection(from: state.transform, localX: 0, localY: 1) else {
                return
            }
            let beta = state.betaDegrees * .pi / 180
            guard let aimDir = horizontalWorldDirection(
                from: state.transform,
                localX: sin(beta),
                localY: cos(beta)
            ) else { return }

            let origin = SIMD3<Float>(
                state.ballWorld.x,
                state.ballWorld.y + state.lift,
                state.ballWorld.z
            )
            let orientation = viewportOrientation(for: view)

            guard let frame = view.session.currentFrame else {
                if showLines {
                    let betaText = formatSmoothedBeta(state.betaDegrees, immediate: false)
                    hud.update(holeLine: nil, aimLine: nil, betaText: betaText, isVisible: true)
                }
                return
            }

            let cameraTransform = frame.camera.transform
            let rotating = isHUDCameraRotating(current: cameraTransform)
            lastHUDCameraTransform = cameraTransform

            let rawHoleUnit = resolveScreenDirection(
                origin: origin,
                directionWorld: holeDir,
                in: view,
                frame: frame,
                orientation: orientation,
                cached: cachedHoleDirection,
                preferFast: preferFastDirections && !rotating
            )
            let rawAimUnit = resolveScreenDirection(
                origin: origin,
                directionWorld: aimDir,
                in: view,
                frame: frame,
                orientation: orientation,
                cached: cachedAimDirection,
                preferFast: preferFastDirections && !rotating
            )
            let rawAnchor = hudAnchor(
                in: view,
                ballWorld: state.ballWorld,
                lift: state.lift,
                bounds: bounds,
                frame: frame,
                orientation: orientation
            )

            cachedHoleDirection = rawHoleUnit
            cachedAimDirection = rawAimUnit

            let holeUnit: CGPoint
            let aimUnit: CGPoint
            let anchor: CGPoint
            let betaText: String

            if showLines {
                if rotating {
                    holeUnit = rawHoleUnit
                    aimUnit = rawAimUnit
                    smoothedHoleUnit = rawHoleUnit
                    smoothedAimUnit = rawAimUnit
                    anchor = rawAnchor
                    smoothedHUDAnchor = rawAnchor
                    betaText = formatSmoothedBeta(state.betaDegrees, immediate: true)
                } else {
                    holeUnit = smoothUnitDirection(
                        smoothedHoleUnit,
                        toward: rawHoleUnit,
                        alpha: Self.hudDirectionSmoothAlpha
                    )
                    aimUnit = smoothUnitDirection(
                        smoothedAimUnit,
                        toward: rawAimUnit,
                        alpha: Self.hudDirectionSmoothAlpha
                    )
                    smoothedHoleUnit = holeUnit
                    smoothedAimUnit = aimUnit
                    anchor = smoothHUDAnchor(
                        smoothedHUDAnchor,
                        toward: rawAnchor,
                        alpha: Self.hudAnchorSmoothAlpha
                    )
                    smoothedHUDAnchor = anchor
                    betaText = formatSmoothedBeta(state.betaDegrees, immediate: false)
                }
            } else {
                holeUnit = rawHoleUnit
                aimUnit = rawAimUnit
                anchor = rawAnchor
                betaText = String(format: "%+.1f°", state.betaDegrees)
            }

            hud.update(
                holeLine: clipLineThroughAnchor(anchor: anchor, unitDirection: holeUnit, bounds: bounds),
                aimLine: clipLineThroughAnchor(anchor: anchor, unitDirection: aimUnit, bounds: bounds),
                betaText: betaText,
                isVisible: showLines
            )
        }

        private func formatSmoothedBeta(_ betaDegrees: Double, immediate: Bool) -> String {
            if immediate {
                smoothedBetaDegrees = betaDegrees
                return String(format: "%+.1f°", betaDegrees)
            }
            if let previous = smoothedBetaDegrees {
                let next = previous + (betaDegrees - previous) * Self.hudBetaSmoothAlpha
                smoothedBetaDegrees = next
                return String(format: "%+.1f°", next)
            }
            smoothedBetaDegrees = betaDegrees
            return String(format: "%+.1f°", betaDegrees)
        }

        /// 카메라 yaw 변화 — 폰 회전 시 HUD가 AR 선과 같이 즉시 따라가게 한다.
        private func isHUDCameraRotating(current: simd_float4x4) -> Bool {
            guard let previous = lastHUDCameraTransform else { return false }
            let curForward = -SIMD3<Float>(
                current.columns.2.x,
                current.columns.2.y,
                current.columns.2.z
            )
            let prevForward = -SIMD3<Float>(
                previous.columns.2.x,
                previous.columns.2.y,
                previous.columns.2.z
            )
            var curXZ = SIMD2<Float>(curForward.x, curForward.z)
            var prevXZ = SIMD2<Float>(prevForward.x, prevForward.z)
            let curLen = simd_length(curXZ)
            let prevLen = simd_length(prevXZ)
            guard curLen > 1e-4, prevLen > 1e-4 else { return false }
            curXZ /= curLen
            prevXZ /= prevLen
            let dot = max(-1, min(1, simd_dot(curXZ, prevXZ)))
            let deltaDegrees = acos(dot) * 180 / Float.pi
            return deltaDegrees >= Self.hudRotationThresholdDegrees
        }

        private func smoothHUDAnchor(
            _ current: CGPoint?,
            toward target: CGPoint,
            alpha: CGFloat
        ) -> CGPoint {
            guard let current else { return target }
            let dx = target.x - current.x
            let dy = target.y - current.y
            if hypot(dx, dy) < Self.hudAnchorDeadZone {
                return current
            }
            return CGPoint(x: current.x + dx * alpha, y: current.y + dy * alpha)
        }

        private func smoothUnitDirection(
            _ current: CGPoint?,
            toward target: CGPoint,
            alpha: CGFloat
        ) -> CGPoint {
            let normalizedTarget = normalizeHUDDirection(target)
            guard let current else { return normalizedTarget }
            let normalizedCurrent = normalizeHUDDirection(current)
            let dot = normalizedCurrent.x * normalizedTarget.x
                + normalizedCurrent.y * normalizedTarget.y
            if dot >= Self.hudDirectionDotDeadZone {
                return normalizedCurrent
            }
            let blended = CGPoint(
                x: normalizedCurrent.x + (normalizedTarget.x - normalizedCurrent.x) * alpha,
                y: normalizedCurrent.y + (normalizedTarget.y - normalizedCurrent.y) * alpha
            )
            return normalizeHUDDirection(blended)
        }

        private func normalizeHUDDirection(_ point: CGPoint) -> CGPoint {
            let len = hypot(point.x, point.y)
            guard len > 0.001 else { return CGPoint(x: 0, y: -1) }
            return CGPoint(x: point.x / len, y: point.y / len)
        }

        private func viewportOrientation(for view: UIView) -> UIInterfaceOrientation {
            if let scene = view.window?.windowScene {
                return scene.interfaceOrientation
            }
            return view.bounds.width > view.bounds.height ? .landscapeRight : .portrait
        }

        /// 투영 1회 시도 후 viewMatrix 폴백 — nil 없이 즉시 반환.
        private func resolveScreenDirection(
            origin: SIMD3<Float>,
            directionWorld: SIMD3<Float>,
            in view: ARView,
            frame: ARFrame,
            orientation: UIInterfaceOrientation,
            cached: CGPoint?,
            preferFast: Bool = false
        ) -> CGPoint {
            if preferFast {
                if let cached { return cached }
                return viewMatrixScreenDirection(directionWorld, frame: frame, orientation: orientation)
            }
            if let projected = quickProjectedDirection(
                origin: origin,
                directionWorld: directionWorld,
                in: view,
                frame: frame,
                orientation: orientation
            ) {
                return projected
            }
            if let cached {
                return cached
            }
            return viewMatrixScreenDirection(directionWorld, frame: frame, orientation: orientation)
        }

        private func seedFloorHUDDirectionCache(
            in view: ARView,
            ballWorld: SIMD3<Float>,
            lift: Float,
            transform: ScanCoordinateTransform,
            betaDegrees: Double
        ) {
            guard let frame = view.session.currentFrame,
                  let holeDir = horizontalWorldDirection(from: transform, localX: 0, localY: 1) else { return }
            let beta = betaDegrees * .pi / 180
            guard let aimDir = horizontalWorldDirection(
                from: transform,
                localX: sin(beta),
                localY: cos(beta)
            ) else { return }
            let origin = SIMD3<Float>(ballWorld.x, ballWorld.y + lift, ballWorld.z)
            let orientation = viewportOrientation(for: view)
            cachedHoleDirection = resolveScreenDirection(
                origin: origin,
                directionWorld: holeDir,
                in: view,
                frame: frame,
                orientation: orientation,
                cached: cachedHoleDirection,
                preferFast: false
            )
            cachedAimDirection = resolveScreenDirection(
                origin: origin,
                directionWorld: aimDir,
                in: view,
                frame: frame,
                orientation: orientation,
                cached: cachedAimDirection,
                preferFast: false
            )
        }

        private func quickProjectedDirection(
            origin: SIMD3<Float>,
            directionWorld: SIMD3<Float>,
            in view: ARView,
            frame: ARFrame,
            orientation: UIInterfaceOrientation
        ) -> CGPoint? {
            let viewport = view.bounds.size
            guard viewport.width > 1, viewport.height > 1 else { return nil }

            func project(_ world: SIMD3<Float>) -> CGPoint? {
                if let p = view.project(world) { return p }
                let p = frame.camera.projectPoint(world, orientation: orientation, viewportSize: viewport)
                guard p.x.isFinite, p.y.isFinite else { return nil }
                return p
            }

            func unit(from p0: CGPoint, to p1: CGPoint) -> CGPoint? {
                let dx = p1.x - p0.x
                let dy = p1.y - p0.y
                let len = hypot(dx, dy)
                guard len > 2 else { return nil }
                return CGPoint(x: dx / len, y: dy / len)
            }

            let pairs: [(Float, Float)] = [(0.25, 0.75), (0.4, 1.2), (0.15, 0.45)]
            for (near, far) in pairs {
                guard let p0 = project(origin + directionWorld * near),
                      let p1 = project(origin + directionWorld * far),
                      let u = unit(from: p0, to: p1) else { continue }
                return u
            }
            if let p0 = project(origin),
               let p1 = project(origin + directionWorld * 1.0),
               let u = unit(from: p0, to: p1) {
                return u
            }
            return nil
        }

        private func viewMatrixScreenDirection(
            _ directionWorld: SIMD3<Float>,
            frame: ARFrame,
            orientation: UIInterfaceOrientation
        ) -> CGPoint {
            let viewMatrix = frame.camera.viewMatrix(for: orientation)
            let dir = simd_normalize(directionWorld)
            let cam = viewMatrix * SIMD4<Float>(dir.x, dir.y, dir.z, 0)
            var ux = CGFloat(cam.x)
            var uy = CGFloat(-cam.y)
            var len = hypot(ux, uy)
            if len < 0.03 {
                let t = frame.camera.transform
                let right = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)
                let up = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
                ux = CGFloat(simd_dot(dir, right))
                uy = CGFloat(-simd_dot(dir, up))
                len = hypot(ux, uy)
            }
            if len < 0.001 {
                return CGPoint(x: 0, y: -1)
            }
            return CGPoint(x: ux / len, y: uy / len)
        }

        private func hudAnchor(
            in view: ARView,
            ballWorld: SIMD3<Float>,
            lift: Float,
            bounds: CGRect,
            frame: ARFrame,
            orientation: UIInterfaceOrientation
        ) -> CGPoint {
            let origin = SIMD3<Float>(ballWorld.x, ballWorld.y + lift, ballWorld.z)
            let expanded = bounds.insetBy(dx: -60, dy: -60)
            if let projected = view.project(origin), expanded.contains(projected) {
                return projected
            }
            let projected = frame.camera.projectPoint(
                origin,
                orientation: orientation,
                viewportSize: view.bounds.size
            )
            if projected.x.isFinite, projected.y.isFinite, expanded.contains(projected) {
                return projected
            }
            return CGPoint(x: bounds.midX, y: bounds.maxY * 0.72)
        }

        private func clipLineThroughAnchor(
            anchor: CGPoint,
            unitDirection: CGPoint,
            bounds: CGRect
        ) -> (CGPoint, CGPoint) {
            var ts: [CGFloat] = []
            if abs(unitDirection.x) > 1e-6 {
                ts.append((bounds.minX - anchor.x) / unitDirection.x)
                ts.append((bounds.maxX - anchor.x) / unitDirection.x)
            }
            if abs(unitDirection.y) > 1e-6 {
                ts.append((bounds.minY - anchor.y) / unitDirection.y)
                ts.append((bounds.maxY - anchor.y) / unitDirection.y)
            }
            let tMin = ts.min() ?? 0
            let tMax = ts.max() ?? 0
            return (
                CGPoint(x: anchor.x + tMin * unitDirection.x, y: anchor.y + tMin * unitDirection.y),
                CGPoint(x: anchor.x + tMax * unitDirection.x, y: anchor.y + tMax * unitDirection.y)
            )
        }

        private func horizontalWorldDirection(
            from transform: ScanCoordinateTransform,
            localX: Double,
            localY: Double
        ) -> SIMD3<Float>? {
            var wx = Float(localX * transform.rightX + localY * transform.forwardX)
            var wz = Float(localX * transform.rightZ + localY * transform.forwardZ)
            let len = hypot(wx, wz)
            guard len > 1e-4 else { return nil }
            wx /= len
            wz /= len
            return SIMD3(wx, 0, wz)
        }

        private func ensureOverlayRoot(under ball: AnchorEntity) -> Entity {
            if let overlayRoot, overlayRoot.parent === ball {
                return overlayRoot
            }
            overlayRoot?.removeFromParent()
            // 오버레이 재생성 시 자식(등고·격자) 참조만 남고 씬에서 분리될 수 있음 — 캐시 무효화.
            clearContours()
            clearGridFlow()
            let root = Entity()
            root.name = "puttOverlays"
            ball.addChild(root)
            overlayRoot = root
            return root
        }

        private func isTerrainOverlayAttached(_ root: Entity?, to parent: Entity) -> Bool {
            guard let root else { return false }
            return root.parent === parent
        }

        private func isContourVizReady(parent: Entity, scanID: String, in view: ARView) -> Bool {
            guard view.session.currentFrame != nil,
                  contourScanID == scanID,
                  isTerrainOverlayAttached(contourRoot, to: parent),
                  let root = contourRoot,
                  !root.children.isEmpty,
                  contourStyleVersionApplied == Self.contourStyleVersion else {
                return false
            }
            return true
        }

        private func isGridVizReady(parent: Entity, scanID: String, in view: ARView) -> Bool {
            guard view.session.currentFrame != nil,
                  gridFlowScanID == scanID,
                  isTerrainOverlayAttached(gridFlowRoot, to: parent),
                  let root = gridFlowRoot,
                  !root.children.isEmpty,
                  gridFlowStyleVersionApplied == Self.gridFlowStyleVersion else {
                return false
            }
            return true
        }

        /// SwiftUI `updateUIView`만으로는 첫 AR 프레임·레이아웃 후 재빌드가 안 될 수 있음 — DisplayLink에서 보완.
        private func refreshTerrainVizIfNeeded(in view: ARView) {
            guard !smoothedFloorAddressHUD,
                  let ctx = terrainVizContext,
                  let ballEntity = ballAnchorEntity else { return }
            let overlays = ensureOverlayRoot(under: ballEntity)
            let ready: Bool
            switch ctx.mode {
            case .contours:
                ready = isContourVizReady(parent: overlays, scanID: ctx.scan.id, in: view)
            case .gridFlow:
                ready = isGridVizReady(parent: overlays, scanID: ctx.scan.id, in: view)
            }
            guard !ready else { return }
            let ballWorld = SIMD3<Float>(
                Float(ctx.scan.ballAnchor.worldX),
                Float(ctx.scan.ballAnchor.worldY),
                Float(ctx.scan.ballAnchor.worldZ)
            )
            updateTerrainViz(
                mode: ctx.mode,
                for: ctx.scan,
                lift: 0.006,
                transform: ctx.scan.scanTransform,
                parent: overlays,
                wormWidth: ctx.wormWidth,
                in: view,
                ballWorld: ballWorld
            )
        }

        private func clearOverlayRoot() {
            stopWormFlowAnimation()
            wormFlowLines = []
            wormDashRoot = nil
            overlayRoot?.removeFromParent()
            overlayRoot = nil
            zeroLineEntity = nil
            aimEntity = nil
            trajectoryRoot = nil
            contourRoot = nil
            gridFlowRoot = nil
            flowTime = 0
        }

        private func updateTerrainViz(
            mode: GreenSurfaceVizMode,
            for scan: CompletedScan,
            lift: Float,
            transform: ScanCoordinateTransform,
            parent: Entity,
            wormWidth: Float,
            in view: ARView,
            ballWorld: SIMD3<Float>
        ) {
            if lastVizMode != mode {
                clearContours()
                clearGridFlow()
                lastVizMode = mode
            }
            switch mode {
            case .contours:
                clearGridFlow()
                updateContours(
                    for: scan,
                    lift: lift,
                    transform: transform,
                    parent: parent,
                    in: view,
                    ballWorld: ballWorld
                )
            case .gridFlow:
                clearContours()
                updateGridFlow(
                    for: scan,
                    lift: lift,
                    transform: transform,
                    parent: parent,
                    wormWidth: wormWidth,
                    in: view,
                    ballWorld: ballWorld
                )
            }
        }

        /// 화면 2px에 해당하는 월드 리본 폭 (카메라·볼 거리 기준).
        private func terrainLineWidthWorld(
            in view: ARView,
            ballWorld: SIMD3<Float>,
            pixels: Float
        ) -> Float {
            guard let frame = view.session.currentFrame else { return 0.004 }
            let cam = frame.camera.transform.columns.3
            let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
            let distance = max(simd_length(camPos - ballWorld), 0.35)
            let viewport = view.bounds.size
            let orientation: UIInterfaceOrientation
            if let scene = view.window?.windowScene {
                orientation = scene.interfaceOrientation
            } else {
                orientation = viewport.width > viewport.height ? .landscapeRight : .portrait
            }
            let projection = frame.camera.projectionMatrix(
                for: orientation,
                viewportSize: viewport,
                zNear: 0.001,
                zFar: 1000
            )
            return ARReferenceMarkers.worldWidth(
                forScreenPixels: pixels,
                distanceMeters: distance,
                viewportPixelHeight: Float(max(viewport.height, 1)),
                projectionYScale: projection.columns.1.y
            )
        }

        /// 볼 ARAnchor 로컬 좌표 (scanTransform 로컬 x/y → 볼 기준 오프셋).
        private func ballLocalPoint(
            localX: Double,
            localY: Double,
            lift: Float,
            transform: ScanCoordinateTransform
        ) -> SIMD3<Float> {
            SIMD3(
                Float(localX * transform.rightX + localY * transform.forwardX),
                lift,
                Float(localX * transform.rightZ + localY * transform.forwardZ)
            )
        }

        private func cameraAddressContext(
            ballWorld: SIMD3<Float>,
            holeWorld: SIMD3<Float>,
            in view: ARView
        ) -> CameraAddressContext {
            guard let frame = view.session.currentFrame else {
                return CameraAddressContext(
                    distance: 1.0,
                    heightAboveBall: 0.8,
                    alongPuttAxis: 0,
                    isAddressPosition: false,
                    isFloorAddressHUD: false
                )
            }
            let cam = frame.camera.transform.columns.3
            let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
            let toCam = camPos - ballWorld
            let distance = simd_length(toCam)
            let heightAboveBall = toCam.y

            let holeDelta = holeWorld - ballWorld
            var forward = SIMD2<Float>(holeDelta.x, holeDelta.z)
            let forwardLen = simd_length(forward)
            if forwardLen > 1e-4 {
                forward /= forwardLen
            } else {
                forward = SIMD2(0, 1)
            }
            let along = simd_dot(SIMD2(toCam.x, toCam.z), forward)
            let isAddress = along < -0.08 || heightAboveBall < 0.38
            let isFloorHUD = heightAboveBall < 0.36 && distance < 1.30

            return CameraAddressContext(
                distance: distance,
                heightAboveBall: heightAboveBall,
                alongPuttAxis: along,
                isAddressPosition: isAddress,
                isFloorAddressHUD: isFloorHUD
            )
        }

        private func trajectorySignature(
            _ samples: [TrajectorySample],
            pathWidth: Float,
            lift: Float
        ) -> Int {
            guard let first = samples.first, let last = samples.last else { return 0 }
            var hasher = Hasher()
            hasher.combine(samples.count)
            hasher.combine(first.position.x)
            hasher.combine(first.position.y)
            hasher.combine(last.position.x)
            hasher.combine(last.position.y)
            hasher.combine(Int((pathWidth * 10_000).rounded()))
            hasher.combine(Int((lift * 10_000).rounded()))
            return hasher.finalize()
        }

        /// 볼 앵커 자식으로 세그먼트 배치 — 왕복/편도 모두 볼·홀과 동일 좌표계.
        private func placeBallLocalSegment(
            toLocalX: Double,
            toLocalY: Double,
            lift: Float,
            width: Float,
            thickness: Float,
            color: UIColor,
            transform: ScanCoordinateTransform,
            parent: Entity,
            entity: inout ModelEntity?
        ) {
            var from = ballLocalPoint(localX: 0, localY: 0, lift: lift, transform: transform)
            let to = ballLocalPoint(localX: toLocalX, localY: toLocalY, lift: lift, transform: transform)
            let delta = to - from
            let horizontal = SIMD3<Float>(delta.x, 0, delta.z)
            let len = simd_length(horizontal)
            guard len > 1e-4 else { return }
            let dir = horizontal / len
            from -= dir * 0.012
            let adjustedLen = len + 0.012
            let mid = from + dir * (adjustedLen * 0.5)

            entity?.removeFromParent()
            let model = ARReferenceMarkers.makeLineEntity(
                length: adjustedLen,
                width: width,
                color: color,
                unlit: true,
                thickness: thickness
            )
            model.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: dir)
            model.position = mid
            parent.addChild(model)
            entity = model
        }

        private func updateContours(
            for scan: CompletedScan,
            lift: Float,
            transform: ScanCoordinateTransform,
            parent: Entity,
            in view: ARView,
            ballWorld: SIMD3<Float>
        ) {
            let density = PerformanceSettings.effectiveOverlayDensity
            let arFrameReady = view.session.currentFrame != nil
            if arFrameReady,
               contourScanID == scan.id,
               isTerrainOverlayAttached(contourRoot, to: parent),
               let cached = contourRoot,
               !cached.children.isEmpty,
               contourStyleVersionApplied == Self.contourStyleVersion,
               contourThermalApplied == ThermalPerformance.level,
               contourDensityApplied == density {
                return
            }
            clearContours()

            let thermal = ThermalPerformance.level
            let map = scan.result.smoothed
            let config = ContourBuildConfiguration(
                intervalMeters: density.contourIntervalMeters,
                maxLevels: min(24, density.contourMaxPolylines),
                corridorHalfWidth: 1.8,
                holeDistance: scan.holeDistance,
                corridorMargin: 0.7,
                requireKnownCell: false,
                smoothIterations: thermal >= .serious ? 2 : 4,
                maxSegmentLength: thermal >= .serious ? 0.028 : 0.018
            )
            var polylines = ContourLineBuilder.build(map: scan.result.smoothed, configuration: config)
            if polylines.isEmpty {
                polylines = ContourLineBuilder.build(map: scan.result.corrected, configuration: config)
            }
            guard !polylines.isEmpty else { return }

            let levels = polylines.map(\.level)
            let minLevel = levels.min() ?? 0
            let maxLevel = levels.max() ?? 0
            let levelSpan = max(maxLevel - minLevel, 1e-9)
            let ballHeight = sampleHeight(map, localX: 0, localY: 0) ?? minLevel
            let undulationScale = Float(min(1.2, 0.10 / max(maxLevel - minLevel, 1e-6)))

            let root = Entity()
            root.name = "contours"
            let lineWidth = max(
                terrainLineWidthWorld(
                    in: view,
                    ballWorld: ballWorld,
                    pixels: Self.contourLineWidthPixels
                ),
                Self.contourLineWidthWorldMin
            )
            var added = 0

            for line in polylines {
                guard added < density.contourMaxPolylines else { break }
                guard line.points.count >= 3 else { continue }

                // 높이맵 상대고도: 높을수록 큰 값(worldY − 볼). 정규화 1=최고→빨강, 0=최저→파랑
                // (GreenSimulator elevationColor · ScanExporter heatColor와 동일 방향)
                let normalized = (line.level - minLevel) / levelSpan
                let contourColor = Self.contourColor(normalizedElevation: normalized)

                var localPoints: [SIMD3<Float>] = []
                localPoints.reserveCapacity(line.points.count)
                for point in line.points {
                    let pointLift = lift + Float(point.height - ballHeight) * undulationScale
                    localPoints.append(
                        ballLocalPoint(
                            localX: point.x,
                            localY: point.y,
                            lift: pointLift,
                            transform: transform
                        )
                    )
                }

                var length: Float = 0
                for i in 1..<localPoints.count {
                    length += simd_distance(localPoints[i - 1], localPoints[i])
                }
                guard length > 0.25 else { continue }

                if let ribbon = ARReferenceMarkers.makePolylineRibbon(
                    points: localPoints,
                    width: lineWidth,
                    color: contourColor
                ) {
                    root.addChild(ribbon)
                    added += 1
                } else {
                    var segAdded = false
                    for index in 0..<(localPoints.count - 1) {
                        let a = localPoints[index]
                        let b = localPoints[index + 1]
                        let delta = b - a
                        let horizontal = SIMD3<Float>(delta.x, 0, delta.z)
                        let len = simd_length(horizontal)
                        guard len > 0.004 else { continue }
                        let dir = horizontal / len
                        let seg = ARReferenceMarkers.makeLineEntity(
                            length: len,
                            width: lineWidth,
                            color: contourColor,
                            unlit: true,
                            thickness: 0.0016
                        )
                        seg.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: dir)
                        seg.position = (a + b) * 0.5
                        root.addChild(seg)
                        segAdded = true
                    }
                    if segAdded { added += 1 }
                }
            }

            guard added > 0 else { return }
            parent.addChild(root)
            contourRoot = root
            contourScanID = scan.id
            contourStyleVersionApplied = Self.contourStyleVersion
            contourThermalApplied = thermal
            contourDensityApplied = density
        }

        /// normalizedElevation: 0=최저(파랑) … 1=최고(빨강). GreenSimulator `elevationColor`와 동일 방향.
        private static func contourColor(normalizedElevation: Double) -> UIColor {
            let t = min(max(normalizedElevation, 0), 1)
            // 낮음 → 높음: 파랑 · 하늘 · 초록 · 연두 · 노랑 · 주황 · 빨강
            let stops: [(Double, UIColor)] = [
                (0.00, UIColor(red: 0.15, green: 0.35, blue: 0.95, alpha: 1)),
                (0.17, UIColor(red: 0.20, green: 0.78, blue: 0.92, alpha: 1)),
                (0.33, UIColor(red: 0.12, green: 0.72, blue: 0.28, alpha: 1)),
                (0.50, UIColor(red: 0.55, green: 0.90, blue: 0.22, alpha: 1)),
                (0.67, UIColor(red: 1.00, green: 0.86, blue: 0.12, alpha: 1)),
                (0.83, UIColor(red: 1.00, green: 0.48, blue: 0.08, alpha: 1)),
                (1.00, UIColor(red: 0.92, green: 0.18, blue: 0.14, alpha: 1))
            ]
            for index in 0..<(stops.count - 1) {
                let (lo, loColor) = stops[index]
                let (hi, hiColor) = stops[index + 1]
                if t <= hi {
                    let span = hi - lo
                    let f = span > 0 ? Float((t - lo) / span) : 0
                    return lerpUIColor(loColor, hiColor, f)
                }
            }
            return stops.last!.1
        }

        private static func lerpUIColor(_ a: UIColor, _ b: UIColor, _ t: Float) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let u = CGFloat(min(max(t, 0), 1))
            return UIColor(
                red: ar + (br - ar) * u,
                green: ag + (bg - ag) * u,
                blue: ab + (bb - ab) * u,
                alpha: aa + (ba - aa) * u
            )
        }

        private func clearContours() {
            contourRoot?.removeFromParent()
            contourRoot = nil
            contourScanID = nil
            contourThermalApplied = nil
            contourDensityApplied = nil
        }

        private func clearGridFlow() {
            stopWormFlowAnimation()
            wormFlowLines = []
            wormDashRoot?.removeFromParent()
            wormDashRoot = nil
            gridFlowRoot?.removeFromParent()
            gridFlowRoot = nil
            gridFlowScanID = nil
            gridFlowThermalApplied = nil
            gridFlowDensityApplied = nil
            gridFlowWormEnabledApplied = nil
            gridFlowDashesPerEdgeApplied = nil
            flowTime = 0
            wormAnimCursor = 0
        }

        private func updateGridFlow(
            for scan: CompletedScan,
            lift: Float,
            transform: ScanCoordinateTransform,
            parent: Entity,
            wormWidth: Float,
            in view: ARView,
            ballWorld: SIMD3<Float>
        ) {
            let density = PerformanceSettings.effectiveOverlayDensity
            let wormsOn = PerformanceSettings.wormAnimationEnabled
            let dashesPerEdge = PerformanceSettings.wormDashesPerEdge.rawValue
            let arFrameReady = view.session.currentFrame != nil
            if arFrameReady,
               gridFlowScanID == scan.id,
               isTerrainOverlayAttached(gridFlowRoot, to: parent),
               let cached = gridFlowRoot,
               !cached.children.isEmpty,
               gridFlowStyleVersionApplied == Self.gridFlowStyleVersion,
               gridFlowThermalApplied == ThermalPerformance.level,
               gridFlowDensityApplied == density,
               gridFlowWormEnabledApplied == wormsOn,
               gridFlowDashesPerEdgeApplied == dashesPerEdge {
                // 카메라 거리(픽셀폭) 변화로는 재생성하지 않음 — 야외 토글/발열 주요 원인
                startWormFlowAnimation()
                return
            }
            clearGridFlow()

            let thermal = ThermalPerformance.level
            let map = scan.result.smoothed
            guard map.width > 1, map.height > 1 else { return }

            let halfW = 1.35
            let yMin = -0.2
            let yMax = scan.holeDistance + 0.45
            let spacing = max(0.20, min(0.32, scan.holeDistance / 10.0)) * density.gridSpacingScale
            let sampleStep = spacing * (density == .sparse || thermal >= .serious ? 0.75 : 0.55)

            var minH = Double.infinity
            var maxH = -Double.infinity
            var x = -halfW
            while x <= halfW + 1e-9 {
                var y = yMin
                while y <= yMax + 1e-9 {
                    if let h = sampleHeight(map, localX: x, localY: y) {
                        minH = min(minH, h)
                        maxH = max(maxH, h)
                    }
                    y += spacing
                }
                x += spacing
            }
            guard minH.isFinite, maxH.isFinite else { return }
            let span = max(maxH - minH, 1e-6)
            let undulationScale = Float(min(1.2, 0.10 / span))

            let root = Entity()
            root.name = "gridFlow"
            let dashRoot = Entity()
            dashRoot.name = "wormDashes"
            root.addChild(dashRoot)

            let gridColor = UIColor(white: 1.0, alpha: 1)
            let gridWidth = terrainLineWidthWorld(
                in: view,
                ballWorld: ballWorld,
                pixels: Self.gridLineWidthPixels
            )
            let wormLiftExtra: Float = 0.0038
            let thickWorm = max(wormWidth, gridWidth * 3.5)
            let dashLength: Float = 0.048
            let gapLength: Float = 0.028
            let period = dashLength + gapLength
            var gridLines = 0

            struct GridSample {
                var localX: Double
                var localY: Double
                var height: Double
                var world: SIMD3<Float>
            }

            struct WormCandidate {
                var p0: SIMD3<Float>
                var p1: SIMD3<Float>
                var totalLength: Float
                var slopeMagnitude: Double
                var color: UIColor
            }

            var wormCandidates: [WormCandidate] = []
            let wormsWanted = PerformanceSettings.wormAnimationEnabled
                && PerformanceSettings.effectiveWormFPS > 0

            func makeSample(localX: Double, localY: Double) -> GridSample? {
                guard let h = sampleHeight(map, localX: localX, localY: localY) else { return nil }
                let pointLift = lift + Float(h - minH) * undulationScale
                return GridSample(
                    localX: localX,
                    localY: localY,
                    height: h,
                    world: ballLocalPoint(localX: localX, localY: localY, lift: pointLift, transform: transform)
                )
            }

            /// 격자 한 변 — 경사 임계 통과 시 후보 등록.
            func registerFlowEdge(
                _ samples: [GridSample],
                tangentX: Double,
                tangentY: Double
            ) {
                guard wormsWanted, samples.count >= 2 else { return }
                let first = samples.first!
                let last = samples.last!
                let edgeLen = max(
                    hypot(last.localX - first.localX, last.localY - first.localY),
                    1e-4
                )
                let heightSlope = abs(last.height - first.height) / edgeLen

                let mid = samples[samples.count / 2]
                var projected = 0.0
                if let g = gridScaleGradient(
                    map: map,
                    localX: mid.localX,
                    localY: mid.localY,
                    sampleDelta: spacing
                ) {
                    projected = abs((-g.dx) * tangentX + (-g.dy) * tangentY)
                }
                let slopeMag = max(heightSlope, projected)
                guard slopeMag >= Self.minWormSlope else { return }

                let forward = last.height <= first.height
                let ordered = forward ? samples : Array(samples.reversed())
                let p0 = ballLocalPoint(
                    localX: ordered.first!.localX,
                    localY: ordered.first!.localY,
                    lift: lift + Float(ordered.first!.height - minH) * undulationScale + wormLiftExtra,
                    transform: transform
                )
                let p1 = ballLocalPoint(
                    localX: ordered.last!.localX,
                    localY: ordered.last!.localY,
                    lift: lift + Float(ordered.last!.height - minH) * undulationScale + wormLiftExtra,
                    transform: transform
                )
                let total = simd_distance(p0, p1)
                guard total > 0.06 else { return }

                wormCandidates.append(
                    WormCandidate(
                        p0: p0,
                        p1: p1,
                        totalLength: total,
                        slopeMagnitude: slopeMag,
                        color: Self.flowColor(slopeMagnitude: slopeMag)
                    )
                )
            }

            // 세로 격자 (x = const) — 선은 통짜, 지렁이는 셀 변마다
            x = -halfW
            while x <= halfW + 1e-9 {
                var samples: [GridSample] = []
                var y = yMin
                while y <= yMax + 1e-9 {
                    if let s = makeSample(localX: x, localY: y) {
                        samples.append(s)
                    }
                    y += sampleStep
                }
                if appendPolyline(samples.map(\.world), width: gridWidth, color: gridColor, to: root) {
                    gridLines += 1
                }
                if wormsWanted {
                    var edgeY = yMin
                    while edgeY + spacing * 0.25 < yMax {
                        let edgeEnd = min(edgeY + spacing, yMax)
                        var unique: [GridSample] = []
                        if let a = makeSample(localX: x, localY: edgeY) { unique.append(a) }
                        let midY = (edgeY + edgeEnd) * 0.5
                        if let m = makeSample(localX: x, localY: midY) { unique.append(m) }
                        if let b = makeSample(localX: x, localY: edgeEnd) { unique.append(b) }
                        registerFlowEdge(unique, tangentX: 0, tangentY: 1)
                        edgeY += spacing
                    }
                }
                x += spacing
                if gridLines > (thermal >= .serious ? 14 : 18) { break }
            }

            // 가로 격자 (y = const)
            var y = yMin
            var horiz = 0
            while y <= yMax + 1e-9 {
                var samples: [GridSample] = []
                x = -halfW
                while x <= halfW + 1e-9 {
                    if let s = makeSample(localX: x, localY: y) {
                        samples.append(s)
                    }
                    x += sampleStep
                }
                if appendPolyline(samples.map(\.world), width: gridWidth, color: gridColor, to: root) {
                    horiz += 1
                }
                if wormsWanted {
                    var edgeX = -halfW
                    while edgeX + spacing * 0.25 < halfW {
                        let edgeEnd = min(edgeX + spacing, halfW)
                        var unique: [GridSample] = []
                        if let a = makeSample(localX: edgeX, localY: y) { unique.append(a) }
                        let midX = (edgeX + edgeEnd) * 0.5
                        if let m = makeSample(localX: midX, localY: y) { unique.append(m) }
                        if let b = makeSample(localX: edgeEnd, localY: y) { unique.append(b) }
                        registerFlowEdge(unique, tangentX: 1, tangentY: 0)
                        edgeX += spacing
                    }
                }
                y += spacing
                if horiz > (thermal >= .serious ? 12 : 16) { break }
            }

            guard gridLines + horiz > 0 else { return }

            // 경사 임계 통과한 모든 변 — 변당 설정 개수 대시 (공유 메시)
            var builtFlowLines: [WormFlowLine] = []
            if wormsWanted, !wormCandidates.isEmpty {
                let wormMesh = MeshResource.generateBox(
                    size: [thickWorm, max(thickWorm * 0.4, 0.0012), dashLength],
                    cornerRadius: min(thickWorm, max(thickWorm * 0.4, 0.0012)) * 0.35
                )
                builtFlowLines.reserveCapacity(wormCandidates.count)
                for candidate in wormCandidates {
                    var material = UnlitMaterial(color: candidate.color)
                    material.blending = .opaque
                    var dashes: [ModelEntity] = []
                    dashes.reserveCapacity(dashesPerEdge)
                    for _ in 0..<dashesPerEdge {
                        let dash = ModelEntity(mesh: wormMesh, materials: [material])
                        dashRoot.addChild(dash)
                        dashes.append(dash)
                    }
                    builtFlowLines.append(
                        WormFlowLine(
                            p0: candidate.p0,
                            p1: candidate.p1,
                            totalLength: candidate.totalLength,
                            slopeMagnitude: candidate.slopeMagnitude,
                            dashLength: dashLength,
                            period: period,
                            dashes: dashes
                        )
                    )
                }
            }

            parent.addChild(root)
            gridFlowRoot = root
            wormDashRoot = dashRoot
            wormFlowLines = builtFlowLines
            gridFlowScanID = scan.id
            gridFlowStyleVersionApplied = Self.gridFlowStyleVersion
            gridFlowWormWidthApplied = wormWidth
            gridFlowThermalApplied = thermal
            gridFlowDensityApplied = density
            gridFlowWormEnabledApplied = PerformanceSettings.wormAnimationEnabled
            gridFlowDashesPerEdgeApplied = dashesPerEdge
            flowTime = 0
            wormAnimCursor = 0
            tickWormFlowDashes()
            startWormFlowAnimation()
        }

        /// 표시 격자 간격과 같은 스케일로 고도 차분 → 격자 기복과 일치하는 흐름.
        private func gridScaleGradient(
            map: HeightMap,
            localX: Double,
            localY: Double,
            sampleDelta: Double
        ) -> (dx: Double, dy: Double)? {
            let d = max(sampleDelta * 0.55, map.cellSize * 2)
            guard let hL = sampleHeight(map, localX: localX - d, localY: localY),
                  let hR = sampleHeight(map, localX: localX + d, localY: localY),
                  let hD = sampleHeight(map, localX: localX, localY: localY - d),
                  let hU = sampleHeight(map, localX: localX, localY: localY + d)
            else { return nil }
            return ((hR - hL) / (2 * d), (hU - hD) / (2 * d))
        }

        private func appendPolyline(
            _ points: [SIMD3<Float>],
            width: Float,
            color: UIColor,
            to root: Entity,
            minLength: Float = 0.08
        ) -> Bool {
            guard points.count >= 2 else { return false }
            var length: Float = 0
            for i in 1..<points.count {
                length += simd_distance(points[i - 1], points[i])
            }
            guard length > minLength else { return false }

            if let ribbon = ARReferenceMarkers.makePolylineRibbon(
                points: points,
                width: width,
                color: color
            ) {
                root.addChild(ribbon)
                return true
            }

            var added = false
            for index in 0..<(points.count - 1) {
                let a = points[index]
                let b = points[index + 1]
                let delta = b - a
                let horizontal = SIMD3<Float>(delta.x, 0, delta.z)
                let len = simd_length(horizontal)
                guard len > 0.004 else { continue }
                let dir = horizontal / len
                let seg = ARReferenceMarkers.makeLineEntity(
                    length: len,
                    width: width,
                    color: color,
                    unlit: true,
                    thickness: max(width * 0.35, 0.0008)
                )
                seg.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: dir)
                seg.position = (a + b) * 0.5
                root.addChild(seg)
                added = true
            }
            return added
        }

        private func sampleHeight(_ map: HeightMap, localX: Double, localY: Double) -> Double? {
            let fx = (localX - map.originX) / map.cellSize
            let fy = (localY - map.originY) / map.cellSize
            let x0 = Int(floor(fx))
            let y0 = Int(floor(fy))
            let x1 = x0 + 1
            let y1 = y0 + 1
            guard map.contains(x: x0, y: y0) else { return nil }
            if !map.contains(x: x1, y: y0) || !map.contains(x: x0, y: y1) || !map.contains(x: x1, y: y1) {
                return map.value(x: x0, y: y0)
            }
            let tx = fx - Double(x0)
            let ty = fy - Double(y0)
            let v00 = map.value(x: x0, y: y0)
            let v10 = map.value(x: x1, y: y0)
            let v01 = map.value(x: x0, y: y1)
            let v11 = map.value(x: x1, y: y1)
            let a = v00 * (1 - tx) + v10 * tx
            let b = v01 * (1 - tx) + v11 * tx
            return a * (1 - ty) + b * ty
        }

        /// 경사 세기: 완만=청록 → 급=호박색 (격자 스케일 % 기준)
        private static func flowColor(slopeMagnitude: Double) -> UIColor {
            let t = min(max((slopeMagnitude - 0.010) / 0.09, 0), 1)
            let stops: [(Double, UIColor)] = [
                (0.00, UIColor(red: 0.15, green: 0.92, blue: 0.98, alpha: 1)),
                (0.35, UIColor(red: 0.35, green: 0.96, blue: 0.45, alpha: 1)),
                (0.65, UIColor(red: 1.00, green: 0.84, blue: 0.18, alpha: 1)),
                (1.00, UIColor(red: 1.00, green: 0.42, blue: 0.10, alpha: 1))
            ]
            for index in 0..<(stops.count - 1) {
                let (lo, loColor) = stops[index]
                let (hi, hiColor) = stops[index + 1]
                if t <= hi {
                    let span = hi - lo
                    let f = span > 0 ? Float((t - lo) / span) : 0
                    return lerpUIColor(loColor, hiColor, f)
                }
            }
            return stops.last!.1
        }

        private func clearTrajectory() {
            trajectoryRoot?.removeFromParent()
            trajectoryRoot = nil
        }

        private func updateTrajectory(
            samples: [TrajectorySample],
            transform: ScanCoordinateTransform,
            lift: Float,
            pathWidth: Float,
            parent: Entity
        ) {
            clearTrajectory()
            guard samples.count >= 2 else { return }

            var localPoints: [PuttVector2] = [PuttVector2(x: 0, y: 0)]
            for sample in samples {
                let p = sample.position
                if hypot(p.x, p.y) < 1e-4 { continue }
                localPoints.append(p)
            }
            guard localPoints.count >= 2 else { return }

            let root = Entity()
            root.name = "trajectory"
            let pathColor = UIColor(red: 1, green: 0.15, blue: 0.12, alpha: 0.8)
            let step = max(1, localPoints.count / 80)
            var index = 0
            while index < localPoints.count - 1 {
                let a = localPoints[index]
                let b = localPoints[min(index + step, localPoints.count - 1)]
                let from = ballLocalPoint(localX: a.x, localY: a.y, lift: lift, transform: transform)
                let to = ballLocalPoint(localX: b.x, localY: b.y, lift: lift, transform: transform)
                let delta = to - from
                let len = simd_length(SIMD3(delta.x, 0, delta.z))
                if len > 1e-4 {
                    let dir = SIMD3(delta.x, 0, delta.z) / len
                    let seg = ARReferenceMarkers.makeLineEntity(
                        length: len,
                        width: pathWidth,
                        color: pathColor,
                        unlit: true,
                        thickness: 0.0025
                    )
                    seg.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: dir)
                    seg.position = (from + to) * 0.5
                    root.addChild(seg)
                }
                index += step
            }
            parent.addChild(root)
            trajectoryRoot = root
        }

        func performReanchorRaycast(in view: ARView, controller: ARScanSessionController) {
            guard !handlingReanchor else { return }
            handlingReanchor = true
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard view.bounds.width > 1 else {
                handlingReanchor = false
                return
            }
            let results = view.raycast(from: center, allowing: .estimatedPlane, alignment: .any)
                + view.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any)
            if let hit = results.first {
                let t = hit.worldTransform.columns.3
                let timestamp = view.session.currentFrame?.timestamp ?? Date().timeIntervalSince1970
                controller.applyRaycastHit(
                    worldX: Double(t.x),
                    worldY: Double(t.y),
                    worldZ: Double(t.z),
                    timestamp: timestamp
                )
            } else {
                controller.reportRaycastFailure("홀 재앵커: 지면을 찾지 못했습니다.")
            }
            handlingReanchor = false
        }
    }
}

// MARK: - Gate 1 diagnostics sheet (기존 요약 보존)

private struct Gate1DiagnosticsSheet: View {
    let scan: CompletedScan
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("스캔 ID: \(scan.id)")
                            .font(.caption)
                        Text("기준 방식: \(scan.referenceMethod)")
                        Text("경로: \(scan.pathMode.label) · 드리프트보정 \(scan.driftCorrected ? "Y" : "N")")
                        Text("표면: \(scan.surfaceSource) · \(scan.surfaceVertexCount.formatted())점")
                        Text(String(format: "홀 거리 %.2f m", scan.holeDistance))
                        Text(String(format: "드리프트 %.2f mm", scan.result.driftMeters * 1_000))
                        if !scan.driftCorrected {
                            Text("편도 스캔 — 드리프트 미보정")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(String(format: "limited %.1f%%", scan.limitedTrackingRatio * 100))
                        Text(String(format: "빈 셀 %.1f%%", scan.result.corrected.emptyCellRatio * 100))
                        Text(
                            String(
                                format: "볼앵커 (%.2f, %.2f, %.2f) track=%@",
                                scan.ballAnchor.worldX,
                                scan.ballAnchor.worldY,
                                scan.ballAnchor.worldZ,
                                scan.ballPlacementTrackingOK ? "OK" : "limited"
                            )
                        )
                        .font(.caption2)
                        Text(
                            String(
                                format: "홀앵커 (%.2f, %.2f, %.2f) track=%@",
                                scan.holeAnchor.worldX,
                                scan.holeAnchor.worldY,
                                scan.holeAnchor.worldZ,
                                scan.holePlacementTrackingOK ? "OK" : "limited"
                            )
                        )
                        .font(.caption2)
                        Text(
                            String(
                                format: "카메라시작Y %.2f · 복귀Y %.2f",
                                scan.cameraStartPose.worldY,
                                scan.cameraReturnPose.worldY
                            )
                        )
                        .font(.caption2)
                    }
                    .padding()
                }

                Button("닫기", action: onDismiss)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 16)
            }
            .navigationTitle("게이트 1 진단")
        }
    }
}
