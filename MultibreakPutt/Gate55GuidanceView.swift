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

/// 바닥 조준 UI 전환 — AR `updateUIView`와 분리해 SwiftUI 재구성·`updateScene` 재호출을 막는다.
final class FloorAddressUIModeBridge {
    var onModeChanged: ((Bool) -> Void)?

    func report(_ isFloor: Bool) {
        if Thread.isMainThread {
            onModeChanged?(isFloor)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onModeChanged?(isFloor)
            }
        }
    }
}

struct Gate55GuidanceView: View {
    @ObservedObject var controller: ARScanSessionController
    /// 스캔 화면과 공유하는 ARView. 있으면 카메라 뷰를 재생성하지 않는다.
    var sessionARView: ARView? = nil
    @Binding var exportError: String?
    var onRequestClearHistory: (() -> Void)? = nil
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
    @State private var floorUIModeBridge = FloorAddressUIModeBridge()
    /// 조준 진입 시 한 번 고정. 기울임으로 safe area가 바뀌어도 하단 블록·OSD 높이가 변하지 않는다.
    @State private var guidanceUILayout: GuidanceUILayoutLock?

    private struct GuidanceUILayoutLock: Equatable {
        var osdCardHeight: CGFloat
        var homeIndicatorPadding: CGFloat
        var panelWidth: CGFloat
        var topContentInset: CGFloat
        /// 진입 시 물리 화면 크기 고정. safe area 변화로 ZStack 자체가 커지는 것을 막는다.
        var screenWidth: CGFloat
        var screenHeight: CGFloat
    }

    /// 새 스캔 + 피커 + spacing.
    private static let guidanceButtonChromeHeight: CGFloat = 92

    var body: some View {
        guidanceRoot
    }

    private var showsBallAimReticle: Bool {
        controller.placementRequest == .reanchorBall || !controller.visualBallLockStatus.isSettled
    }

    private var blocksNonReanchorPlacementUI: Bool {
        guard let request = controller.placementRequest else { return false }
        return request != .reanchorBall
    }

    private var activeGuidanceLayout: GuidanceUILayoutLock {
        guidanceUILayout ?? Self.fallbackGuidanceLayout
    }

    /// onAppear 전 고정값. body·GeometryReader에서 live safe area를 읽지 않는다.
    private static let fallbackGuidanceLayout: GuidanceUILayoutLock = {
        makeGuidanceLayout(
            screenWidth: UIScreen.main.bounds.width,
            screenHeight: UIScreen.main.bounds.height,
            topSafeInset: 47,
            homeIndicator: 34
        )
    }()

    /// 2번 스샷 기준: 하단 ~46%.
    private static let osdLayoutHomeForSizing: CGFloat = 34

    private static func makeGuidanceLayout(
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        topSafeInset: CGFloat,
        homeIndicator: CGFloat
    ) -> GuidanceUILayoutLock {
        let horizontalInset = OSDTopChromeMetrics.floatingCardHorizontalPadding * 2
        let bottomBlockHeight = min(max(screenHeight * 0.46, 360), 460)
        let osdCardHeight = max(
            bottomBlockHeight - guidanceButtonChromeHeight - osdLayoutHomeForSizing,
            260
        )
        return GuidanceUILayoutLock(
            osdCardHeight: osdCardHeight,
            homeIndicatorPadding: max(homeIndicator, 8),
            panelWidth: screenWidth - horizontalInset,
            topContentInset: topSafeInset + OSDTopChromeMetrics.topPadding,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
    }

    private func lockGuidanceUILayoutIfNeeded() {
        guard guidanceUILayout == nil else { return }
        let bounds = UIScreen.main.bounds
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let home = window?.safeAreaInsets.bottom ?? 34
        let topSafe = window?.safeAreaInsets.top ?? 47
        guidanceUILayout = Self.makeGuidanceLayout(
            screenWidth: bounds.width,
            screenHeight: bounds.height,
            topSafeInset: topSafe,
            homeIndicator: home
        )
    }

    private var guidanceRoot: some View {
        let layout = activeGuidanceLayout
        return ZStack(alignment: .bottom) {
            arPanel
                .ignoresSafeArea()

            VStack(spacing: 0) {
                guidanceTopChrome

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 6)
                }

                Spacer(minLength: 0)
            }
            .frame(width: layout.panelWidth, alignment: .top)
            .padding(.top, layout.topContentInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            guidanceBottomArea
                .frame(width: layout.panelWidth)
        }
        .frame(width: layout.screenWidth, height: layout.screenHeight)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            cmNumberPadOverlay
        }
        .onAppear {
            lockGuidanceUILayoutIfNeeded()
            floorUIModeBridge.onModeChanged = { _ in
                // HUD는 UIKit만 전환. SwiftUI 레이아웃은 바꾸지 않는다.
            }
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
        .preferredColorScheme(.dark)
        .onChange(of: controller.completedScan?.id) { _, _ in
            if let scan = controller.completedScan {
                model.bind(scan: scan)
                aimRevision += 1
            }
        }
        .onChange(of: controller.completedScan?.holeDistance) { _, _ in
            if let scan = controller.completedScan {
                model.refreshDisplay(for: scan)
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
                onRequestClearHistory: onRequestClearHistory,
                onAimSettingsChanged: {
                    aimRevision += 1
                }
            )
        }
    }

    private var guidanceBottomArea: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                Button(action: beginNewScan) {
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
            HStack(alignment: .center, spacing: 8) {
                if !controller.visualBallLockStatus.isSettled {
                    visualBallLockMiniChip
                }
                Spacer(minLength: 8)
                GreenVizModePicker(selection: $greenVizMode)
            }
            guidanceBottomOSD
        }
        .padding(
            .bottom,
            activeGuidanceLayout.homeIndicatorPadding
                + (activeCmPad != nil ? OSDInlineNumberPad.height : 0)
        )
    }

    @ViewBuilder
    private var arPanel: some View {
        ZStack(alignment: .topLeading) {
            if let sessionARView {
                Gate55GuidanceSceneBinder(
                    arView: sessionARView,
                    controller: controller,
                    scan: controller.completedScan,
                    betaDegrees: model.aimBetaDegrees,
                    visible: model.hasAimLine,
                    revision: aimRevision,
                    trajectorySamples: trajectorySamplesForAR,
                    greenVizMode: greenVizMode,
                    floorAddressMode: floorAddressMode,
                    floorUIModeBridge: floorUIModeBridge
                )
            } else {
                Gate55ARAimView(
                    controller: controller,
                    scan: controller.completedScan,
                    betaDegrees: model.aimBetaDegrees,
                    visible: model.hasAimLine,
                    revision: aimRevision,
                    trajectorySamples: trajectorySamplesForAR,
                    greenVizMode: greenVizMode,
                    floorAddressMode: floorAddressMode,
                    floorUIModeBridge: floorUIModeBridge
                )
                .id("gate55-guidance-ar")
            }

            if showsBallAimReticle {
                // 배치 raycast(centerGroundPose)는 화면 중앙 광축. 십자선도 동일 위치여야 한다.
                OSDAmberReticle(dashedRing: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if !controller.ballGroundRingPoints.isEmpty {
                BallGroundRingOverlay(points: controller.ballGroundRingPoints)
                    .ignoresSafeArea()
            }

            if !controller.holeGroundRingPoints.isEmpty, !floorAddressMode {
                HoleCupRingOverlay(points: controller.holeGroundRingPoints)
                    .ignoresSafeArea()
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
                    .fixedSize()
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

    private func beginNewScan() {
        controller.reset()
    }

    private var statusSubtitle: String? {
        var parts: [String] = []
        if let scan = controller.completedScan {
            parts.append(String(format: "볼→홀 %.1fm", scan.holeDistance))
            parts.append(scan.pathMode.label)
        }
        if !controller.guidanceTrackingOK || controller.trackingLimited {
            parts.append("limited")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        OSDFloatingScrollCard(
            fixedHeight: activeGuidanceLayout.osdCardHeight,
            scrollToID: osdScrollAnchor
        ) {
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

    private var miniBallLockLabel: String {
        if controller.placementRequest == .reanchorBall {
            return "십자선 확정"
        }
        switch controller.visualBallLockStatus {
        case .waitingForView:
            return "실볼 대기"
        case .searching:
            return "실볼 감지"
        case .candidate:
            return "후보 확인"
        default:
            return controller.visualBallLockStatus.shortLabel ?? "실볼"
        }
    }

    private var visualBallLockMiniChip: some View {
        Button(action: controller.requestBallReanchor) {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        controller.placementRequest == .reanchorBall
                            ? OSDPalette.accent
                            : Color.orange.opacity(0.95)
                    )
                    .frame(width: 6, height: 6)
                Text(miniBallLockLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(OSDPalette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(OSDPalette.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(blocksNonReanchorPlacementUI)
        .accessibilityLabel(miniBallLockLabel)
    }

    @ViewBuilder
    private var recommendationSection: some View {
        if let rec = model.recommendation, rec.primary != nil {
            let displayDistance = controller.completedScan?.holeDistance ?? rec.horizontalDistance
            OSDAimReadout(
                horizontalDistance: displayDistance,
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

            if !rec.searchTier.isHoleInVerified {
                Text(rec.searchTier.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            if abs(rec.elevationDelta) < 0.025, abs(rec.directionDegrees) > 8,
               rec.searchTier.isHoleInVerified {
                Text("평탄한 면인데 |β|가 큽니다. 라이다 노이즈 가능성 — 볼·홀을 다시 지정하거나 조명을 바꿔 재스캔하세요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.accent.opacity(0.9))
            }
        } else if !model.isComputing, model.recommendation?.searchTier == .noPath
            || (model.recommendation != nil && model.recommendation?.primary == nil) {
            VStack(alignment: .leading, spacing: 8) {
                Text("홀인 경로를 찾지 못했습니다.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OSDPalette.accent)
                Text("스캔을 다시 하면 더 정확한 지형으로 안내할 수 있습니다. 추정 직선은 표시하지 않습니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(OSDPalette.textSecondary)
                Button(action: beginNewScan) {
                    Text("스캔 다시하기")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(OSDPalette.accent)
            }
        } else {
            Text("추천 계산 중이거나 스캔·그린스피드를 확인하세요.")
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

            HStack(spacing: 8) {
                Button(controller.placementRequest == .reanchorBall ? "십자선 위치 확정" : "볼 다시 맞추기") {
                    controller.requestBallReanchor()
                }
                .font(.caption.weight(.semibold))
                .disabled(blocksNonReanchorPlacementUI)
                Button("홀 재지정") {
                    controller.requestHoleReanchor()
                }
                .font(.caption.weight(.semibold))
                .disabled(controller.placementRequest != nil)
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
        let base = String(
            format: "기준 AR raycast · 볼→홀 %.2fm · %@ · %@ · %@",
            scan.holeDistance,
            scan.pathMode.label,
            scan.driftCorrected ? "드리프트보정" : "드리프트미보정",
            scan.lidarProfile.productName
        )
        if controller.pastHoleMeasuredMeters > 0 {
            return base + String(
                format: " · 홀 뒤 %.0fcm/%.0fcm",
                controller.pastHoleMeasuredMeters * 100,
                PuttScanCorridor.pastHoleMargin * 100
            )
        }
        return base
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
    /// OSD 카드와 겹치지 않게 하단을 비운다. SwiftUI 레이아웃은 바꾸지 않는다.
    var bottomReservedHeight: CGFloat = 0

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
        holeLayer.strokeColor = UIColor(red: 1, green: 176 / 255, blue: 32 / 255, alpha: 0.5).cgColor
        holeLayer.lineWidth = 4
        aimLayer.strokeColor = UIColor(white: 1, alpha: 0.9).cgColor
        aimLayer.lineWidth = 5
        aimLayer.shadowColor = UIColor.white.cgColor
        aimLayer.shadowOpacity = 0.08
        aimLayer.shadowRadius = 8
        aimLayer.shadowOffset = .zero
        clipsToBounds = true
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
        _ = betaText
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        holeLayer.frame = bounds
        aimLayer.frame = bounds
    }

    func drawingBounds(in viewBounds: CGRect) -> CGRect {
        let safeBottom = max(bottomReservedHeight, safeAreaInsets.bottom + 8)
        return viewBounds.inset(by: UIEdgeInsets(top: 8, left: 8, bottom: safeBottom, right: 8))
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
    let floorAddressMode: Bool
    let floorUIModeBridge: FloorAddressUIModeBridge

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
        context.coordinator.onFloorAddressModeChanged = { [bridge = floorUIModeBridge] enabled in
            bridge.report(enabled)
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        uiView.environment.sceneUnderstanding.options = []
        uiView.debugOptions.remove(.showSceneUnderstanding)
        context.coordinator.scanController = controller
        context.coordinator.floorHUDView?.frame = uiView.bounds
        if let hud = context.coordinator.floorHUDView {
            uiView.bringSubviewToFront(hud)
        }
        context.coordinator.updateScene(
            in: uiView,
            scan: scan,
            betaDegrees: betaDegrees,
            visible: visible,
            trajectory: trajectorySamples,
            greenVizMode: greenVizMode
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.updateScene(
            in: uiView,
            scan: nil,
            betaDegrees: 0,
            visible: false
        )
        coordinator.cleanup()
        coordinator.floorHUDView?.removeFromSuperview()
        coordinator.floorHUDView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        private var ballAnchorEntity: AnchorEntity?
        private var holeAnchorEntity: AnchorEntity?
        private var lockedBallPose: ScanPose?
        private var lockedHolePose: ScanPose?
        private var lockedScanTransform: ScanCoordinateTransform?
        /// 조준·경로·등고 — 볼 ARAnchor 아래 (편도 후 session 재구성에도 볼과 동일 좌표계).
        private var overlayRoot: Entity?
        private var zeroLineEntity: ModelEntity?
        private var aimEntity: ModelEntity?
        private var trajectoryRoot: Entity?
        private var contourRoot: Entity?
        private var contourScanID: String?
        private var contourStyleVersionApplied = 0
        private static let contourStyleVersion = 14
        private static let contourLineWidthPixels: Float = 2
        /// 2px 환산값이 너무 얇을 때(근접·뷰포트 미준비) 최소 월드 폭.
        private static let contourLineWidthWorldMin: Float = 0.0036
        private var gridFlowRoot: Entity?
        private var wormDashRoot: Entity?
        private var gridFlowScanID: String?
        private var gridFlowStyleVersionApplied = 0
        private static let gridFlowStyleVersion = 17
        private static let gridLineWidthPixels: Float = 2
        private var gridFlowWormWidthApplied: Float = 0
        private var lastVizMode: GreenSurfaceVizMode?
        private var overlayScanID: String?
        private var lastAimBeta: Double = .nan
        private var lastAimLength: Float = 0
        private var lastAimWidth: Float = 0
        private var lastAimLift: Float = 0
        private var lastAimAlpha: CGFloat = 1
        private var lastPathLift: Float = 0
        private var lastPathAlpha: CGFloat = 1
        private var lastAppliedWidthScale: Float = -1
        private var lastAppliedPathAlpha: CGFloat = -1
        private var lastAppliedAimAlpha: CGFloat = -1
        private var lastAppliedBallAlpha: CGFloat = -1
        /// 근접 하안에서 카메라 높이 노이즈로 선 굵기·알파가 매 프레임 튀지 않게 한다.
        private var smoothedProximityHeight: Float = 0
        private var lastFloorAddressMode = false
        private var lastReportedFloorHUD = false
        private var lastARHiddenForFloorHUD = false
        private var smoothedFloorAddressHUD = false
        private var lastFloorHeightAboveBall: Float = 0.8
        private var lastFloorBallDistance: Float = 1.2
        private var smoothedCamBallDistance: Float = 1.2
        private static let floorAddressHUDEnabled = false

        private static let standingPathWidth: Float = 0.028
        private static let standingAimWidth: Float = 0.010
        private static let floorPathWidthScale: Float = 0.38
        /// 서서 볼 때 경로·조준선 알파. 하안에서 `proximityLineAlpha`로 0.5까지 보간.
        private static let standingLineAlpha: CGFloat = 0.9

        private var lastZeroWidth: Float = 0
        private var lastZeroHoleDistance: Double = .nan
        private var lastTrajectoryRevision: Int = -1
        var onFloorAddressModeChanged: ((Bool) -> Void)?
        weak var scanController: ARScanSessionController?
        weak var floorHUDView: FloorAddressWorldHUDView?
        weak var sceneARView: ARView?
        private weak var hudARView: ARView?
        private var hudDisplayLink: CADisplayLink?
        private var hudSceneState: FloorHUDSceneState?
        private struct TerrainVizContext {
            var scan: CompletedScan
            var mode: GreenSurfaceVizMode
            var wormWidth: Float
        }
        private struct CachedSceneParams {
            var scan: CompletedScan
            var betaDegrees: Double
            var visible: Bool
            var trajectory: [TrajectorySample]
            var greenVizMode: GreenSurfaceVizMode
        }
        private var terrainVizContext: TerrainVizContext?
        private var cachedSceneParams: CachedSceneParams?
        private var lastTerrainVizRetry: TimeInterval = 0
        private var cachedHoleDirection: CGPoint?
        private var cachedAimDirection: CGPoint?
        private var hudLockedHoleLine: (CGPoint, CGPoint)?
        private var hudLockedAimLine: (CGPoint, CGPoint)?
        private var smoothedHUDAnchor: CGPoint?
        private var smoothedHoleUnit: CGPoint?
        private var smoothedAimUnit: CGPoint?
        private var smoothedBetaDegrees: Double?
        private var hudLockedHoleUnit: CGPoint?
        private var hudLockedAimUnit: CGPoint?
        private var hudLockCameraForwardXZ: SIMD2<Float>?
        private var hudLockCameraPosition: SIMD3<Float>?
        private var hudSettleStartedAt: TimeInterval?

        private static let hudAnchorSmoothAlpha: CGFloat = 0.10
        private static let hudDirectionSmoothAlpha: CGFloat = 0.12
        private static let hudBetaSmoothAlpha: Double = 0.10
        private static let hudAnchorDeadZone: CGFloat = 3.0
        private static let hudDirectionDotDeadZone: CGFloat = 0.99992
        /// 정착 후 이 각도 이상 폰을 돌려야 선을 다시 따라간다.
        private static let hudUnlockYawDegrees: Float = 5.0
        /// 요가 작아도 옆으로 이동하면 화면 고정 선이 홀에서 떨어진다.
        private static let hudUnlockTranslationMeters: Float = 0.08
        private static let hudSettleSeconds: TimeInterval = 0.45
        private static let hudSettleMaxDeltaDegrees: Float = 0.45

        private struct FloorHUDSceneState {
            var ballWorld: SIMD3<Float>
            var holeWorld: SIMD3<Float>
            var betaDegrees: Double
            var lift: Float
            var transform: ScanCoordinateTransform
            var holeDistance: Double
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
            dash.orientation = ARReferenceMarkers.yawRotation(aligningLocalZToHorizontal: horizontal)
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
            sceneARView = view
            guard let scan else {
                terrainVizContext = nil
                aimEntity?.isEnabled = false
                clearContours()
                clearGridFlow()
                clearTrajectory()
                clearOverlayRoot()
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &ballAnchorEntity
                )
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &holeAnchorEntity
                )
                lockedBallPose = nil
                lockedHolePose = nil
                lockedScanTransform = nil
                lastAimBeta = .nan
                lastZeroHoleDistance = .nan
                lastTrajectoryRevision = -1
                lastAimWidth = 0
                lastAimLift = 0
                lastAimAlpha = 1
                lastPathLift = 0
                lastPathAlpha = 1
                lastVizMode = nil
                smoothedFloorAddressHUD = false
                lastARHiddenForFloorHUD = false
                stopFloorHUDDisplayLink()
                hideFloorHUD()
                lastReportedFloorHUD = false
                smoothedProximityHeight = 0
                return
            }

            cachedSceneParams = CachedSceneParams(
                scan: scan,
                betaDegrees: betaDegrees,
                visible: visible,
                trajectory: trajectory,
                greenVizMode: greenVizMode
            )

            if overlayScanID != scan.id {
                clearContours()
                clearGridFlow()
                clearTrajectory()
                clearOverlayRoot()
                zeroLineEntity = nil
                aimEntity = nil
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &ballAnchorEntity
                )
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &holeAnchorEntity
                )
                lockedBallPose = nil
                lockedHolePose = nil
                lockedScanTransform = nil
                overlayScanID = scan.id
                lastAimBeta = .nan
                lastZeroHoleDistance = .nan
                lastTrajectoryRevision = -1
                lastAimWidth = 0
                lastAimLift = 0
                lastAimAlpha = 1
                lastPathLift = 0
                lastPathAlpha = 1
                lastVizMode = nil
                smoothedProximityHeight = 0
            }

            if shouldReplaceGuidancePose(lockedBallPose, with: scan.ballAnchor),
               scanController?.guidanceLiveBallPose == nil {
                let incomingBall = SIMD3<Float>(
                    Float(scan.ballAnchor.worldX),
                    Float(scan.ballAnchor.worldY),
                    Float(scan.ballAnchor.worldZ)
                )
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
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &ballAnchorEntity
                )
                ARReferenceMarkers.placeRealityWorldFixed(
                    entityFactory: { ARReferenceMarkers.makeBallEntity() },
                    at: incomingBall,
                    in: view,
                    existingEntity: &ballAnchorEntity
                )
                lockedBallPose = scan.ballAnchor
                lockedScanTransform = scan.scanTransform
            }
            if shouldReplaceGuidancePose(lockedHolePose, with: scan.holeAnchor) {
                let incomingHole = SIMD3<Float>(
                    Float(scan.holeAnchor.worldX),
                    Float(scan.holeAnchor.worldY),
                    Float(scan.holeAnchor.worldZ)
                )
                clearContours()
                clearGridFlow()
                lastVizMode = nil
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &holeAnchorEntity
                )
                ARReferenceMarkers.placeRealityWorldFixed(
                    entityFactory: { ARReferenceMarkers.makeHoleEntity() },
                    at: incomingHole,
                    in: view,
                    existingEntity: &holeAnchorEntity
                )
                lockedHolePose = scan.holeAnchor
            }

            guard let ballEntity = ballAnchorEntity else { return }
            let overlays = ensureOverlayRoot(under: ballEntity)
            let renderBall = lockedBallPose ?? scan.ballAnchor
            let renderHole = lockedHolePose ?? scan.holeAnchor
            let ballWorld = SIMD3<Float>(
                Float(renderBall.worldX),
                Float(renderBall.worldY),
                Float(renderBall.worldZ)
            )
            let holeWorld = SIMD3<Float>(
                Float(renderHole.worldX),
                Float(renderHole.worldY),
                Float(renderHole.worldZ)
            )
            let transform = lockedScanTransform ?? scan.scanTransform

            // 고정 월드 굵기 — 거리 따라 화면폭을 바꾸면 근접 시 굵어지고 매 프레임 흔들림
            let contourLift: Float = 0.006
            let wormWidth: Float = 0.012
            let address = cameraAddressContext(
                ballWorld: ballWorld,
                holeWorld: holeWorld,
                in: view
            )
            _ = address.isFloorAddressHUD
            if smoothedCamBallDistance <= 0 {
                smoothedCamBallDistance = stabilizedCamBallDistance(address.distance)
            } else {
                let target = stabilizedCamBallDistance(address.distance)
                let alpha: Float = address.distance < target ? 0.10 : 0.18
                smoothedCamBallDistance += (target - smoothedCamBallDistance) * alpha
            }

            let pathLift: Float = 0.008
            let aimLift: Float = 0.010
            let pathWidth = Self.standingPathWidth
            let aimWidth = Self.standingAimWidth

            if Self.floorAddressHUDEnabled {
                reportFloorAddressHUD(address)
            } else if smoothedFloorAddressHUD || lastReportedFloorHUD {
                smoothedFloorAddressHUD = false
                lastReportedFloorHUD = false
            }
            if visible {
                hudSceneState = FloorHUDSceneState(
                    ballWorld: ballWorld,
                    holeWorld: holeWorld,
                    betaDegrees: betaDegrees,
                    lift: pathLift,
                    transform: transform,
                    holeDistance: scan.holeDistance
                )
                hudARView = view
                startFloorHUDDisplayLinkIfNeeded()
                if Self.floorAddressHUDEnabled {
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
                    hideFloorHUD()
                }
            } else {
                stopFloorHUDDisplayLink()
                hideFloorHUD()
            }

            let arHiddenForHUD = Self.floorAddressHUDEnabled && smoothedFloorAddressHUD
            let arVisibilityChanged = lastARHiddenForFloorHUD != arHiddenForHUD
            lastARHiddenForFloorHUD = arHiddenForHUD
            applyFloorHUDOverlayVisibility(hidden: arHiddenForHUD)
            if arHiddenForHUD {
                if arVisibilityChanged {
                    stopWormFlowAnimation()
                }
                lastFloorAddressMode = address.isFloorAddressHUD
                return
            }

            if greenVizMode == .gridFlow, PerformanceSettings.wormAnimationEnabled {
                startWormFlowAnimation()
            }

            zeroLineEntity?.isEnabled = true
            aimEntity?.isEnabled = visible
            trajectoryRoot?.isEnabled = visible

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

            let zeroNeedsRebuild = zeroLineEntity == nil
                || abs(lastZeroHoleDistance - scan.holeDistance) > 1e-4
                || abs(lastPathLift - pathLift) > 0.0015
                || abs(lastZeroWidth - pathWidth * 0.35) > 0.0008
                || arVisibilityChanged
            if zeroNeedsRebuild {
                let zeroWidth = max(pathWidth * 0.35, 0.003)
                placeBallLocalSegment(
                    toLocalX: 0,
                    toLocalY: scan.holeDistance,
                    lift: pathLift,
                    width: zeroWidth,
                    thickness: 0.002,
                    color: UIColor(red: 1.0, green: 176 / 255, blue: 32 / 255, alpha: 0.5),
                    transform: transform,
                    parent: overlays,
                    entity: &zeroLineEntity
                )
                lastZeroHoleDistance = scan.holeDistance
                lastPathLift = pathLift
                lastZeroWidth = zeroWidth
            }

            guard visible else {
                aimEntity?.isEnabled = false
                clearTrajectory()
                lastTrajectoryRevision = -1
                return
            }

            let trajSig = trajectorySignature(
                trajectory,
                pathWidth: pathWidth * proximityLineWidthScale(heightAboveBall: address.heightAboveBall),
                lift: pathLift
            )
            var trajectoryRebuilt = false
            if trajSig != lastTrajectoryRevision {
                let pathWidthScale = proximityLineWidthScale(heightAboveBall: address.heightAboveBall)
                updateTrajectory(
                    samples: trajectory,
                    scan: scan,
                    displayTransform: transform,
                    lift: pathLift,
                    pathWidth: pathWidth * pathWidthScale,
                    pathAlpha: proximityLineAlpha(base: Self.standingLineAlpha, heightAboveBall: address.heightAboveBall),
                    parent: overlays
                )
                lastTrajectoryRevision = trajSig
                lastAppliedWidthScale = pathWidthScale
                lastAppliedPathAlpha = proximityLineAlpha(base: Self.standingLineAlpha, heightAboveBall: address.heightAboveBall)
                lastAppliedBallAlpha = -1
                trajectoryRebuilt = true
            }

            let proximityT = proximityBlend(heightAboveBall: address.heightAboveBall)
            let standingLength = max(1.0, min(scan.holeDistance * 0.45, 2.2))
            let addressLength = max(1.5, min(scan.holeDistance * 0.82, 5.0))
            let length = standingLength + (addressLength - standingLength) * Double(1 - proximityT)
            if trajectoryRebuilt
                || aimEntity == nil
                || abs(lastAimBeta - betaDegrees) > 0.05
                || abs(lastAimLength - Float(length)) > 0.10
                || abs(lastAimWidth - aimWidth) > 0.0008
                || abs(lastAimLift - aimLift) > 0.0015
                || arVisibilityChanged {
                let beta = betaDegrees * .pi / 180
                placeBallLocalSegment(
                    toLocalX: sin(beta) * length,
                    toLocalY: cos(beta) * length,
                    lift: aimLift,
                    width: aimWidth,
                    thickness: 0.0025,
                    color: UIColor(white: 1, alpha: 0.9),
                    transform: transform,
                    parent: overlays,
                    entity: &aimEntity
                )
                lastAimBeta = betaDegrees
                lastAimLength = Float(length)
                lastAimWidth = aimWidth
                lastAimLift = aimLift
                lastAppliedWidthScale = -1
                lastAppliedAimAlpha = -1
                lastAppliedBallAlpha = -1
            }
            lastFloorAddressMode = address.isFloorAddressHUD
        }

        private func reportFloorAddressHUD(_ address: CameraAddressContext) {
            guard Self.floorAddressHUDEnabled else { return }
            lastFloorHeightAboveBall = address.heightAboveBall
            lastFloorBallDistance = address.distance
            if address.isFloorAddressHUD {
                smoothedFloorAddressHUD = true
            } else if address.heightAboveBall > 0.42 || address.distance > 1.40 {
                smoothedFloorAddressHUD = false
            }
            // SwiftUI 레이아웃은 건드리지 않는다. HUD 전환으로 OSD가 커지며 잘리던 원인.
            lastReportedFloorHUD = smoothedFloorAddressHUD
        }

        /// timestamp·실볼 미세 정렬은 무시. 일어선 뒤 감지가 8cm만 어긋나도 다시 심으면 AR이 계속 흐른다.
        private func shouldReplaceGuidancePose(_ locked: ScanPose?, with incoming: ScanPose) -> Bool {
            guard let locked else { return true }
            let dx = locked.worldX - incoming.worldX
            let dy = locked.worldY - incoming.worldY
            let dz = locked.worldZ - incoming.worldZ
            return (dx * dx + dz * dz) > 0.25 * 0.25 || abs(dy) > 0.12
        }

        private func applyFloorHUDOverlayVisibility(hidden: Bool) {
            overlayRoot?.isEnabled = !hidden
            zeroLineEntity?.isEnabled = !hidden
            aimEntity?.isEnabled = !hidden
            trajectoryRoot?.isEnabled = !hidden
            contourRoot?.isEnabled = !hidden
            gridFlowRoot?.isEnabled = !hidden
            setWorldAnchorChildrenEnabled(ballAnchorEntity, enabled: !hidden)
            setWorldAnchorChildrenEnabled(holeAnchorEntity, enabled: !hidden)
        }

        private func setWorldAnchorChildrenEnabled(_ anchor: AnchorEntity?, enabled: Bool) {
            guard let anchor else { return }
            for child in anchor.children {
                child.isEnabled = enabled
            }
        }

        /// DisplayLink 경로에서도 경로만 숨기거나 복구한다. 앵커 재배치는 하지 않는다.
        private func syncFloorHUDARVisibility() {
            let hidden = smoothedFloorAddressHUD
            lastARHiddenForFloorHUD = hidden
            applyFloorHUDOverlayVisibility(hidden: hidden)
        }

        /// limited 추적 중 바닥 HUD에 들어갔다 나오면 ARAnchor가 어긋날 수 있어 스캔 좌표로 재배치.
        private func replantGuidanceMarkersFromScan(
            scan: CompletedScan,
            view: ARView
        ) {
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
            ARReferenceMarkers.replaceRealityWorldFixed(
                entityFactory: { ARReferenceMarkers.makeBallEntity() },
                at: ballWorld,
                in: view,
                existingEntity: &ballAnchorEntity
            )
            ARReferenceMarkers.replaceRealityWorldFixed(
                entityFactory: { ARReferenceMarkers.makeHoleEntity() },
                at: holeWorld,
                in: view,
                existingEntity: &holeAnchorEntity
            )
            lockedBallPose = scan.ballAnchor
            lockedHolePose = scan.holeAnchor
            lockedScanTransform = scan.scanTransform
            clearOverlayRoot()
            clearContours()
            clearGridFlow()
            clearTrajectory()
            lastZeroHoleDistance = .nan
            lastAimBeta = .nan
            lastTrajectoryRevision = -1
            lastVizMode = nil
            lastAimWidth = 0
            lastAimLift = 0
            lastAimAlpha = 1
            lastPathLift = 0
            lastPathAlpha = 1
        }

        private func startFloorHUDDisplayLinkIfNeeded() {
            guard hudDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(refreshFloorHUDTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
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
            cachedHoleDirection = nil
            cachedAimDirection = nil
            hudLockedHoleUnit = nil
            hudLockedAimUnit = nil
            hudLockedHoleLine = nil
            hudLockedAimLine = nil
            hudLockCameraForwardXZ = nil
            hudLockCameraPosition = nil
            hudSettleStartedAt = nil
        }

        private func beginFloorHUDSmoothingSession() {
            hudLockedHoleLine = nil
            hudLockedAimLine = nil
        }

        @objc private func refreshFloorHUDTick() {
            guard let view = sceneARView else { return }
            if !Self.floorAddressHUDEnabled {
                hideFloorHUD()
                if let cached = cachedSceneParams {
                    let ball = lockedBallPose ?? cached.scan.ballAnchor
                    let hole = lockedHolePose ?? cached.scan.holeAnchor
                    applyProximityLineAppearance(
                        ballWorld: SIMD3(
                            Float(ball.worldX),
                            Float(ball.worldY),
                            Float(ball.worldZ)
                        ),
                        holeWorld: SIMD3(
                            Float(hole.worldX),
                            Float(hole.worldY),
                            Float(hole.worldZ)
                        ),
                        in: view
                    )
                }
                return
            }
            guard let hudView = hudARView, let state = hudSceneState else { return }
            let address = cameraAddressContext(
                ballWorld: state.ballWorld,
                holeWorld: state.holeWorld,
                in: hudView
            )
            let wasFloorHUD = smoothedFloorAddressHUD
            reportFloorAddressHUD(address)
            syncFloorHUDARVisibility()

            if smoothedFloorAddressHUD, !wasFloorHUD {
                hudLockedHoleLine = nil
                hudLockedAimLine = nil
                refreshFloorHUD(showLines: true)
                stopWormFlowAnimation()
            } else if !smoothedFloorAddressHUD, wasFloorHUD {
                resetFloorHUDSmoothing()
                refreshFloorHUD(showLines: false)
                applyFloorHUDOverlayVisibility(hidden: false)
                if terrainVizContext?.mode == .gridFlow, PerformanceSettings.wormAnimationEnabled {
                    startWormFlowAnimation()
                }
            } else {
                refreshFloorHUD(showLines: smoothedFloorAddressHUD)
            }
            if !smoothedFloorAddressHUD {
                refreshTerrainVizIfNeeded(in: view)
            }
        }

        private func hideFloorHUD() {
            floorHUDView?.update(holeLine: nil, aimLine: nil, betaText: nil, isVisible: false)
        }

        private func refreshFloorHUD(showLines: Bool, preferFastDirections _: Bool = false) {
            guard let view = hudARView,
                  let state = hudSceneState,
                  let hud = floorHUDView else { return }

            hud.bottomReservedHeight = Self.hudBottomReservedHeight(for: view.bounds.height)
            let bounds = hud.drawingBounds(in: view.bounds)
            guard bounds.width > 1, bounds.height > 1 else { return }

            guard let frame = view.session.currentFrame else {
                hud.update(holeLine: nil, aimLine: nil, betaText: nil, isVisible: showLines)
                return
            }

            if showLines {
                if hudLockedHoleLine == nil || hudLockedAimLine == nil {
                    let captured = captureWorldLockedHUDLines(
                        state: state,
                        in: view,
                        frame: frame,
                        bounds: bounds
                    )
                    if let hole = captured.hole { hudLockedHoleLine = hole }
                    if let aim = captured.aim { hudLockedAimLine = aim }
                }
                hud.update(
                    holeLine: hudLockedHoleLine,
                    aimLine: hudLockedAimLine,
                    betaText: nil,
                    isVisible: hudLockedHoleLine != nil || hudLockedAimLine != nil
                )
                return
            }

            hud.update(holeLine: nil, aimLine: nil, betaText: nil, isVisible: false)
        }

        private static func hudBottomReservedHeight(for viewHeight: CGFloat) -> CGFloat {
            min(max(viewHeight * 0.40, 240), 400)
        }

        private func captureWorldLockedHUDLines(
            state: FloorHUDSceneState,
            in view: ARView,
            frame: ARFrame,
            bounds: CGRect
        ) -> (hole: (CGPoint, CGPoint)?, aim: (CGPoint, CGPoint)?) {
            let orientation = viewportOrientation(for: view)
            guard let holeDir = horizontalWorldDirection(from: state.transform, localX: 0, localY: 1) else {
                return (nil, nil)
            }
            let beta = state.betaDegrees * .pi / 180
            guard let aimDir = horizontalWorldDirection(
                from: state.transform,
                localX: sin(beta),
                localY: cos(beta)
            ) else { return (nil, nil) }

            let origin = SIMD3<Float>(state.ballWorld.x, state.ballWorld.y + state.lift, state.ballWorld.z)
            let holeHoriz = SIMD3<Float>(
                state.holeWorld.x - state.ballWorld.x,
                0,
                state.holeWorld.z - state.ballWorld.z
            )
            let holeLen = max(simd_length(holeHoriz), 0.5)
            let aimLen = max(1.0, min(Float(state.holeDistance) * 0.82, 5.0))

            guard let holeOrigin = projectWorldPoint(origin, in: view, frame: frame, orientation: orientation),
                  let holeEnd = projectWorldPoint(origin + holeDir * holeLen, in: view, frame: frame, orientation: orientation),
                  let aimEnd = projectWorldPoint(origin + aimDir * aimLen, in: view, frame: frame, orientation: orientation) else {
                return (nil, nil)
            }

            return (
                clipSegmentThroughPoints(from: holeOrigin, to: holeEnd, bounds: bounds),
                clipSegmentThroughPoints(from: holeOrigin, to: aimEnd, bounds: bounds)
            )
        }

        private func projectWorldPoint(
            _ world: SIMD3<Float>,
            in view: ARView,
            frame: ARFrame,
            orientation: UIInterfaceOrientation
        ) -> CGPoint? {
            if let projected = view.project(world) {
                return projected
            }
            let projected = frame.camera.projectPoint(
                world,
                orientation: orientation,
                viewportSize: view.bounds.size
            )
            guard projected.x.isFinite, projected.y.isFinite else { return nil }
            return projected
        }

        private func clipSegmentThroughPoints(
            from origin: CGPoint,
            to end: CGPoint,
            bounds: CGRect
        ) -> (CGPoint, CGPoint) {
            let dx = end.x - origin.x
            let dy = end.y - origin.y
            let len = hypot(dx, dy)
            guard len > 1 else { return (origin, end) }
            let unit = CGPoint(x: dx / len, y: dy / len)
            return clipLineThroughAnchor(anchor: origin, unitDirection: unit, bounds: bounds)
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

        /// 카메라 yaw 변화 — 정착 락 해제에만 사용.
        private func cameraForwardXZ(_ transform: simd_float4x4) -> SIMD2<Float>? {
            var xz = SIMD2<Float>(-transform.columns.2.x, -transform.columns.2.z)
            let len = simd_length(xz)
            guard len > 1e-4 else { return nil }
            xz /= len
            return xz
        }

        private func cameraPosition(_ transform: simd_float4x4) -> SIMD3<Float> {
            SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        private func shouldUnlockHUD(cameraTransform: simd_float4x4) -> Bool {
            guard let locked = hudLockCameraForwardXZ,
                  let current = cameraForwardXZ(cameraTransform) else { return true }
            let dot = max(-1, min(1, simd_dot(locked, current)))
            let yaw = acos(dot) * 180 / Float.pi
            if yaw >= Self.hudUnlockYawDegrees { return true }
            if let lockedPos = hudLockCameraPosition {
                let moved = simd_length(cameraPosition(cameraTransform) - lockedPos)
                if moved >= Self.hudUnlockTranslationMeters { return true }
            }
            return false
        }

        private func updateHUDSettleLock(
            holeUnit: CGPoint,
            aimUnit: CGPoint,
            rawHole: CGPoint,
            cameraTransform: simd_float4x4
        ) {
            let nHole = normalizeHUDDirection(holeUnit)
            let nRaw = normalizeHUDDirection(rawHole)
            let dot = Float(nHole.x * nRaw.x + nHole.y * nRaw.y)
            let delta = acos(max(-1, min(1, dot))) * 180 / Float.pi
            let now = CACurrentMediaTime()
            if delta <= Self.hudSettleMaxDeltaDegrees {
                if hudSettleStartedAt == nil {
                    hudSettleStartedAt = now
                } else if now - (hudSettleStartedAt ?? now) >= Self.hudSettleSeconds {
                    hudLockedHoleUnit = holeUnit
                    hudLockedAimUnit = aimUnit
                    hudLockCameraForwardXZ = cameraForwardXZ(cameraTransform)
                    hudLockCameraPosition = cameraPosition(cameraTransform)
                }
            } else {
                hudSettleStartedAt = nil
            }
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
            let now = CACurrentMediaTime()
            guard now - lastTerrainVizRetry >= 0.25 else { return }
            lastTerrainVizRetry = now
            let renderBall = lockedBallPose ?? ctx.scan.ballAnchor
            let ballWorld = SIMD3<Float>(
                Float(renderBall.worldX),
                Float(renderBall.worldY),
                Float(renderBall.worldZ)
            )
            updateTerrainViz(
                mode: ctx.mode,
                for: ctx.scan,
                lift: 0.006,
                transform: lockedScanTransform ?? ctx.scan.scanTransform,
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
            let distance = max(simd_length(camPos - ballWorld), Float(PerformanceSettings.aimCalcDistanceFloor))
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

        /// 높이맵 로컬 → 현재 볼 앵커 로컬. 재지정 볼과 스캔 볼이 달라도 등고가 그린에 남는다.
        private func heightmapLocalPoint(
            localX: Double,
            localY: Double,
            lift: Float,
            scan: CompletedScan
        ) -> SIMD3<Float> {
            let rotated = ballLocalPoint(
                localX: localX,
                localY: localY,
                lift: lift,
                transform: scan.terrainTransform
            )
            let origin = scan.terrainTransform.origin
            let parent = scan.ballAnchor
            return SIMD3(
                rotated.x + Float(origin.worldX - parent.worldX),
                rotated.y + Float(origin.worldY - parent.worldY),
                rotated.z + Float(origin.worldZ - parent.worldZ)
            )
        }

        private func stabilizedCamBallDistance(_ raw: Float) -> Float {
            max(raw, Float(PerformanceSettings.aimCalcDistanceFloor))
        }

        /// 0 = 하안(약 22cm), 1 = 선 자세(약 72cm).
        private func proximityBlend(heightAboveBall: Float) -> Float {
            let floorHeight: Float = 0.22
            let standingHeight: Float = 0.72
            let t = (heightAboveBall - floorHeight) / (standingHeight - floorHeight)
            return max(0, min(1, t))
        }

        /// 카메라가 볼에 가까울수록(낮을수록) 경로선을 얇게 — 근접 시 원근으로 굵어 보이는 것 완화.
        private func proximityLineWidthScale(heightAboveBall: Float) -> Float {
            let t = proximityBlend(heightAboveBall: heightAboveBall)
            let raw = Self.floorPathWidthScale + t * (1 - Self.floorPathWidthScale)
            return (raw * 10).rounded() / 10
        }

        /// 지면과 가까울수록 투명. 서서 볼 때 기본 알파, 하안에서 최대 50%.
        private func proximityLineAlpha(base: CGFloat, heightAboveBall: Float) -> CGFloat {
            let t = CGFloat(proximityBlend(heightAboveBall: heightAboveBall))
            let floorAlpha: CGFloat = 0.5
            let raw = floorAlpha + (base - floorAlpha) * t
            return (raw * 10).rounded() / 10
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
            let isFloorHUD = heightAboveBall < 0.40 && distance < 1.35

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

        /// 메시를 다시 만들지 않고 로컬 X(굵기)와 알파만 바꾼다. 하안 근접 끊김 방지.
        private func applyProximityLineAppearance(
            ballWorld: SIMD3<Float>,
            holeWorld: SIMD3<Float>,
            in view: ARView
        ) {
            let address = cameraAddressContext(
                ballWorld: ballWorld,
                holeWorld: holeWorld,
                in: view
            )
            let rawHeight = address.heightAboveBall
            if smoothedProximityHeight <= 0 {
                smoothedProximityHeight = rawHeight
            } else {
                smoothedProximityHeight += (rawHeight - smoothedProximityHeight) * 0.14
            }
            let height = smoothedProximityHeight
            let widthScale = proximityLineWidthScale(heightAboveBall: height)
            let pathAlpha = proximityLineAlpha(base: Self.standingLineAlpha, heightAboveBall: height)
            let aimAlpha = proximityLineAlpha(base: Self.standingLineAlpha, heightAboveBall: height)
            let ballAlpha = proximityLineAlpha(
                base: ARReferenceMarkers.ballMarkerStandingAlpha,
                heightAboveBall: height
            )
            let widthChanged = abs(widthScale - lastAppliedWidthScale) >= 0.03
            let pathAlphaChanged = abs(pathAlpha - lastAppliedPathAlpha) >= 0.03
            let aimAlphaChanged = abs(aimAlpha - lastAppliedAimAlpha) >= 0.03
            let ballAlphaChanged = abs(ballAlpha - lastAppliedBallAlpha) >= 0.03
            guard widthChanged || pathAlphaChanged || aimAlphaChanged || ballAlphaChanged else { return }
            let widthAxis = SIMD3<Float>(widthScale, 1, 1)
            if widthChanged {
                lastAppliedWidthScale = widthScale
                // 곡선 리본은 엔티티 X축 스케일로 폭을 줄이면 접선 방향과 어긋나 뒤틀린다.
                rebuildTrajectoryRibbon(
                    widthScale: widthScale,
                    pathAlpha: pathAlpha
                )
                applyLineScale(aimEntity, scale: widthAxis)
            } else if pathAlphaChanged {
                lastAppliedPathAlpha = pathAlpha
                applyLineAlpha(
                    trajectoryRoot,
                    red: 1,
                    green: 0.15,
                    blue: 0.12,
                    alpha: pathAlpha
                )
            }
            if aimAlphaChanged {
                lastAppliedAimAlpha = aimAlpha
                applyLineAlpha(aimEntity, red: 1, green: 1, blue: 1, alpha: aimAlpha)
            }
            if ballAlphaChanged {
                lastAppliedBallAlpha = ballAlpha
                applyBallMarkerAlpha(ballAlpha)
            }
        }

        /// 근접 시 경로 폭: 메시 생성 시 반영. `scale.x`는 곡선 리본 폭 방향과 맞지 않아 뒤틀림.
        private func rebuildTrajectoryRibbon(
            widthScale: Float,
            pathAlpha: CGFloat
        ) {
            guard let cached = cachedSceneParams,
                  let ballEntity = ballAnchorEntity else { return }
            let overlays = ensureOverlayRoot(under: ballEntity)
            let transform = lockedScanTransform ?? cached.scan.scanTransform
            let effectiveWidth = Self.standingPathWidth * widthScale
            updateTrajectory(
                samples: cached.trajectory,
                scan: cached.scan,
                displayTransform: transform,
                lift: lastPathLift,
                pathWidth: effectiveWidth,
                pathAlpha: pathAlpha,
                parent: overlays
            )
            lastTrajectoryRevision = trajectorySignature(
                cached.trajectory,
                pathWidth: effectiveWidth,
                lift: lastPathLift
            )
            lastAppliedPathAlpha = pathAlpha
        }

        private func ballMarkerEntity() -> ModelEntity? {
            ballAnchorEntity?
                .children
                .first { $0.name == "ballMarker" } as? ModelEntity
        }

        private func applyBallMarkerAlpha(_ alpha: CGFloat) {
            guard let ball = ballMarkerEntity() else { return }
            ball.model?.materials = [ARReferenceMarkers.makeBallMarkerMaterial(alpha: alpha)]
        }

        private func applyLineScale(_ entity: Entity?, scale: SIMD3<Float>) {
            guard let entity else { return }
            if let model = entity as? ModelEntity {
                model.scale = scale
            }
            for child in entity.children {
                applyLineScale(child, scale: scale)
            }
        }

        private func applyLineAlpha(
            _ entity: Entity?,
            red: CGFloat,
            green: CGFloat,
            blue: CGFloat,
            alpha: CGFloat
        ) {
            guard let entity else { return }
            if let model = entity as? ModelEntity {
                var material = UnlitMaterial(
                    color: UIColor(red: red, green: green, blue: blue, alpha: alpha)
                )
                if alpha < 0.99 {
                    material.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
                } else {
                    material.blending = .opaque
                }
                model.model?.materials = [material]
            }
            for child in entity.children {
                applyLineAlpha(child, red: red, green: green, blue: blue, alpha: alpha)
            }
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
            model.orientation = ARReferenceMarkers.yawRotation(aligningLocalZToHorizontal: dir)
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
            // transform: 조준선용. 등고 배치는 scan.terrainTransform 사용.
            _ = transform
            let density = PerformanceSettings.effectiveOverlayDensity
            let corridorMargins = PuttScanCorridor.margins(for: scan.fieldMode)
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
                // 격자는 ±3m 프레임, 등고는 퍼트 라인 근처 실측만 — 외삽·플랭크 평행선이
                // 노란 경로선 오른쪽으로 밀려 보이는 현상을 줄인다.
                corridorHalfWidth: min(corridorMargins.displayHalfWidth, 1.5),
                holeDistance: scan.holeDistance,
                corridorMargin: corridorMargins.displayPastHoleMargin,
                requireKnownCell: true,
                requireMeasuredCell: true,
                smoothIterations: thermal >= .serious ? 2 : 4,
                maxSegmentLength: thermal >= .serious ? 0.028 : 0.018
            )
            var polylines = ContourLineBuilder.build(map: scan.result.smoothed, configuration: config)
            if polylines.isEmpty {
                // 실측이 너무 성기면 보간 셀까지 허용하되, 전역 외삽(false)은 쓰지 않는다.
                let fallback = ContourBuildConfiguration(
                    intervalMeters: config.intervalMeters,
                    maxLevels: config.maxLevels,
                    corridorHalfWidth: config.corridorHalfWidth,
                    holeDistance: config.holeDistance,
                    corridorMargin: config.corridorMargin,
                    requireKnownCell: true,
                    requireMeasuredCell: false,
                    smoothIterations: config.smoothIterations,
                    maxSegmentLength: config.maxSegmentLength
                )
                polylines = ContourLineBuilder.build(map: scan.result.smoothed, configuration: fallback)
            }
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
            // 높이맵 좌표계. 볼 재지정 후 부모는 새 볼이므로 heightmapLocalPoint로 원점 차이를 보정한다.

            for line in polylines {
                guard added < density.contourMaxPolylines else { break }
                guard line.points.count >= 3 else { continue }

                let minAbsX = ContourLineBuilder.minAbsLateral(line)
                // 퍼트 라인에서 너무 먼 플랭크-only 등고는 시인성만 해치고 “오른쪽 치우침”처럼 보인다.
                guard minAbsX <= 1.35 else { continue }

                // 높이맵 상대고도: 높을수록 큰 값(worldY − 볼). 정규화 1=최고→빨강, 0=최저→파랑
                // (GreenSimulator elevationColor · ScanExporter heatColor와 동일 방향)
                let normalized = (line.level - minLevel) / levelSpan
                let contourColor = Self.contourColor(normalizedElevation: normalized)

                var localPoints: [SIMD3<Float>] = []
                localPoints.reserveCapacity(line.points.count)
                for point in line.points {
                    let pointLift = lift + Float(point.height - ballHeight) * undulationScale
                    localPoints.append(
                        heightmapLocalPoint(
                            localX: point.x,
                            localY: point.y,
                            lift: pointLift,
                            scan: scan
                        )
                    )
                }

                var length: Float = 0
                for i in 1..<localPoints.count {
                    length += simd_distance(localPoints[i - 1], localPoints[i])
                }
                // 라인 근처 짧은 횡단 등고는 살리고, 먼 긴 평행선만 길이로 거르지 않도록 완화.
                let minLength: Float = minAbsX < 0.55 ? 0.10 : 0.22
                guard length > minLength else { continue }

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
                        seg.orientation = ARReferenceMarkers.yawRotation(aligningLocalZToHorizontal: dir)
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
            let corridorMargins = PuttScanCorridor.margins(for: scan.fieldMode)
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

            _ = transform
            let thermal = ThermalPerformance.level
            let map = scan.result.smoothed
            guard map.width > 1, map.height > 1 else { return }

            // 표시만 ±1.5m(전체 3m). ±3m(6m)는 선·웜 엔티티가 과도해 발열/다운 유발.
            let halfW = min(corridorMargins.displayHalfWidth, 1.5)
            let physicsHoleDistance = hypot(
                scan.terrainHoleAnchor.worldX - scan.terrainTransform.origin.worldX,
                scan.terrainHoleAnchor.worldZ - scan.terrainTransform.origin.worldZ
            )
            let yMin = -0.2
            let yMax = physicsHoleDistance + corridorMargins.displayPastHoleMargin
            let spacing = max(0.20, min(0.32, physicsHoleDistance / 10.0)) * density.gridSpacingScale
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
                    world: heightmapLocalPoint(localX: localX, localY: localY, lift: pointLift, scan: scan)
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
                let p0 = heightmapLocalPoint(
                    localX: ordered.first!.localX,
                    localY: ordered.first!.localY,
                    lift: lift + Float(ordered.first!.height - minH) * undulationScale + wormLiftExtra,
                    scan: scan
                )
                let p1 = heightmapLocalPoint(
                    localX: ordered.last!.localX,
                    localY: ordered.last!.localY,
                    lift: lift + Float(ordered.last!.height - minH) * undulationScale + wormLiftExtra,
                    scan: scan
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
                seg.orientation = ARReferenceMarkers.yawRotation(aligningLocalZToHorizontal: dir)
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
            scan: CompletedScan,
            displayTransform: ScanCoordinateTransform,
            lift: Float,
            pathWidth: Float,
            pathAlpha: CGFloat,
            parent: Entity
        ) {
            clearTrajectory()
            guard samples.count >= 2 else { return }

            let physicsTransform = scan.terrainTransform
            var localPoints: [PuttVector2] = [PuttVector2(x: 0, y: 0)]
            for sample in samples {
                let p = sample.position
                if hypot(p.x, p.y) < 1e-4 { continue }
                let world = physicsTransform.worldXZ(localX: p.x, localY: p.y)
                let display = displayTransform.localFromWorld(
                    worldX: world.worldX,
                    worldZ: world.worldZ
                )
                localPoints.append(display)
            }
            guard localPoints.count >= 2 else { return }

            let holeLocal = PuttVector2(x: 0, y: scan.holeDistance)
            let nearestHole = localPoints.map {
                hypot($0.x - holeLocal.x, $0.y - holeLocal.y)
            }.min() ?? .infinity
            if nearestHole > 0.15 {
                localPoints.append(holeLocal)
            }

            let pathPositions = localPoints.map {
                ballLocalPoint(
                    localX: $0.x,
                    localY: $0.y,
                    lift: lift,
                    transform: displayTransform
                )
            }

            let root = Entity()
            root.name = "trajectory"
            let pathColor = UIColor(red: 1, green: 0.15, blue: 0.12, alpha: pathAlpha)
            if let ribbon = ARReferenceMarkers.makePolylineRibbon(
                points: pathPositions,
                width: pathWidth,
                color: pathColor
            ) {
                root.addChild(ribbon)
            }
            parent.addChild(root)
            trajectoryRoot = root
        }
    }
}

/// 조준 AR 씬을 공유 `ARView`에 그린다. 카메라 뷰 재생성 없이 씬만 갱신.
struct Gate55GuidanceSceneBinder: UIViewRepresentable {
    let arView: ARView
    @ObservedObject var controller: ARScanSessionController
    let scan: CompletedScan?
    let betaDegrees: Double
    let visible: Bool
    let revision: Int
    var trajectorySamples: [TrajectorySample] = []
    var greenVizMode: GreenSurfaceVizMode = .contours
    let floorAddressMode: Bool
    let floorUIModeBridge: FloorAddressUIModeBridge

    func makeUIView(context: Context) -> UIView {
        let placeholder = UIView(frame: .zero)
        placeholder.isUserInteractionEnabled = false
        placeholder.backgroundColor = .clear
        attachFloorHUDIfNeeded(context: context)
        context.coordinator.onFloorAddressModeChanged = { [bridge = floorUIModeBridge] enabled in
            bridge.report(enabled)
        }
        return placeholder
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.scanController = controller
        context.coordinator.sceneARView = arView
        attachFloorHUDIfNeeded(context: context)
        context.coordinator.floorHUDView?.frame = arView.bounds
        if let hud = context.coordinator.floorHUDView {
            arView.bringSubviewToFront(hud)
        }
        context.coordinator.updateScene(
            in: arView,
            scan: scan,
            betaDegrees: betaDegrees,
            visible: visible,
            trajectory: trajectorySamples,
            greenVizMode: greenVizMode
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Gate55ARAimView.Coordinator) {
        if let arView = coordinator.sceneARView {
            coordinator.updateScene(
                in: arView,
                scan: nil,
                betaDegrees: 0,
                visible: false
            )
        }
        coordinator.cleanup()
        coordinator.floorHUDView?.removeFromSuperview()
        coordinator.floorHUDView = nil
        coordinator.sceneARView = nil
    }

    func makeCoordinator() -> Gate55ARAimView.Coordinator {
        Gate55ARAimView.Coordinator()
    }

    private func attachFloorHUDIfNeeded(context: Context) {
        guard context.coordinator.floorHUDView == nil else { return }
        let hud = FloorAddressWorldHUDView(frame: arView.bounds)
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hud.isUserInteractionEnabled = false
        arView.addSubview(hud)
        context.coordinator.floorHUDView = hud
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
                            Text("볼홀지정계산 — 드리프트 미보정")
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
