import PuttPhysicsKit
import SwiftUI

/// 톱니 아이콘으로 여는 통합 설정 — 목업 06·07 + 스캔/조준 전용 항목.
struct AppSettingsSheet: View {
    enum Mode {
        case scan
        case guidance
    }

    let mode: Mode

    @ObservedObject var controller: ARScanSessionController
    var onRequestClearHistory: (() -> Void)?

    @ObservedObject var guidanceModel: Gate55GuidanceModel
    var onAimSettingsChanged: (() -> Void)?

    @AppStorage(ScanFieldSettings.fieldModeKey)
    private var scanFieldModeRaw: String = ScanFieldMode.tuning.rawValue

    @AppStorage(PerformanceSettings.recommendGridKey)
    private var recommendGridRaw: Int = RecommendScanGrid.balanced.rawValue
    @AppStorage(PerformanceSettings.wormFPSKey)
    private var wormFPSRaw: Int = WormAnimFPS.medium.rawValue
    @AppStorage(PerformanceSettings.wormAnimationEnabledKey)
    private var wormAnimationEnabled: Bool = true
    @AppStorage(PerformanceSettings.wormDashesPerEdgeKey)
    private var wormDashesPerEdgeRaw: Int = WormDashesPerEdge.three.rawValue
    @AppStorage(PerformanceSettings.autoThermalKey)
    private var autoThermalThrottle: Bool = true
    @AppStorage(PerformanceSettings.overlayDensityKey)
    private var overlayDensityRaw: String = OverlayDensity.standard.rawValue
    @AppStorage(PerformanceSettings.forceMaxBrightnessKey)
    private var forceMaxBrightness: Bool = false
    @AppStorage(PerformanceSettings.aimCalcDistanceFloorKey)
    private var aimCalcDistanceFloorRaw: Double = AimCalcDistanceFloor.cm30.rawValue

    @Environment(\.dismiss) private var dismiss
    @State private var showClearHistoryConfirmation = false

    private let aimProximityPresets: [AimCalcDistanceFloor] = [.cm10, .cm20, .cm30, .cm40]

    init(
        mode: Mode,
        controller: ARScanSessionController,
        guidanceModel: Gate55GuidanceModel,
        onRequestClearHistory: (() -> Void)? = nil,
        onAimSettingsChanged: (() -> Void)? = nil
    ) {
        self.mode = mode
        self._controller = ObservedObject(wrappedValue: controller)
        self._guidanceModel = ObservedObject(wrappedValue: guidanceModel)
        self.onRequestClearHistory = onRequestClearHistory
        self.onAimSettingsChanged = onAimSettingsChanged
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OSDSettingsSectionGroup(title: "필드 스캔") {
                        fieldScanModeContent
                    }

                    OSDSettingsSectionGroup(title: "스캔 옵션") {
                        scanOptionsContent
                    }

                    OSDSettingsSectionGroup(title: "조준 보정") {
                        aimCalibrationContent
                    }

                    OSDSettingsSectionGroup(title: "퍼팅 경로 계산") {
                        pathCalculationContent
                    }

                    OSDSettingsSectionGroup(title: "격자 · 지렁이") {
                        gridWormContent
                    }

                    OSDSettingsSectionGroup(title: "AR 오버레이 밀도") {
                        overlayDensityContent
                    }

                    OSDSettingsSectionGroup(title: "시스템") {
                        systemContent
                    }

                    if mode == .scan {
                        clearHistorySection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
            }
            .background(OSDPalette.glassStrong.ignoresSafeArea())
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        PerformanceSettings.notifyDidChange()
                        dismiss()
                    }
                    .foregroundStyle(OSDPalette.accent)
                }
            }
            .preferredColorScheme(.dark)
            .alert("저장된 스캔 기록을 초기화할까요?", isPresented: $showClearHistoryConfirmation) {
                Button("취소", role: .cancel) {}
                Button("모두 삭제", role: .destructive) {
                    onRequestClearHistory?()
                }
            } message: {
                Text("실내 측정값을 포함한 모든 진단 파일이 삭제되며, 최근 3회 RMS는 다음 스캔부터 새로 계산됩니다.")
            }
        }
        .onChange(of: recommendGridRaw) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: wormFPSRaw) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: wormAnimationEnabled) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: wormDashesPerEdgeRaw) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: autoThermalThrottle) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: overlayDensityRaw) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: forceMaxBrightness) { _, _ in PerformanceSettings.notifyDidChange() }
        .onChange(of: aimCalcDistanceFloorRaw) { _, _ in
            PerformanceSettings.notifyDidChange()
            onAimSettingsChanged?()
        }
        .onChange(of: scanFieldModeRaw) { _, _ in
            ScanFieldSettings.notifyDidChange()
            DispatchQueue.main.async {
                controller.applyPathModeForFieldMode()
            }
        }
    }

    // MARK: - Scan

    private var fieldScanModeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            OSDSegmentedRow(
                options: ScanFieldMode.allCases,
                label: \.label,
                selection: Binding(
                    get: { ScanFieldMode(rawValue: scanFieldModeRaw) ?? .tuning },
                    set: { scanFieldModeRaw = $0.rawValue }
                )
            )
            fieldHelp((ScanFieldMode(rawValue: scanFieldModeRaw) ?? .tuning).settingsDetail)
            if mode == .guidance {
                fieldHelp("다음 스캔부터 적용됩니다. 이미 완료된 스캔의 높이맵은 바뀌지 않습니다.")
            }
        }
    }

    private var scanOptionsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .scan {
                OSDSettingsToggleRow(
                    title: "재측정(왕복 고정)",
                    isOn: $controller.gate1RetestLockRoundTrip
                )
                if controller.gate1RetestLockRoundTrip {
                    fieldHelp("게이트1 전체 스택 재측정 모드 — 편도 회차는 시작할 수 없습니다. path_mode=roundTrip만 기록됩니다.")
                }
            }

            Text("스캔 경로")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OSDPalette.textSecondary)
            if (ScanFieldMode(rawValue: scanFieldModeRaw) ?? .tuning) == .competition {
                OSDSettingsKVRow(title: "경로", value: "편도 · 홀 지정 직후 계산")
                fieldHelp("경기 모드는 편도로 고정됩니다.")
            } else {
                OSDSettingsKVRow(title: "경로", value: "왕복 · 드리프트 보정")
                fieldHelp("튜닝 모드는 왕복으로 고정됩니다. 홀 지정 후 볼로 돌아와 스캔을 종료하세요.")
            }

            Text(String(format: "스무딩 σ: %.2f셀", controller.sigma))
                .font(.system(size: 12))
                .foregroundStyle(OSDPalette.textPrimary)
            Slider(value: $controller.sigma, in: 0.5...3, step: 0.25)
                .tint(OSDPalette.accent)
            if mode == .guidance {
                fieldHelp("다음 스캔부터 적용됩니다.")
            }
        }
    }

    // MARK: - Aim calibration (항상 표시)

    private var aimCalibrationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("조준 근접 하한")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OSDPalette.textSecondary)
            OSDPillRow(
                labels: aimProximityPresets.map(\.label),
                selectedIndex: selectedAimProximityIndex
            ) { index in
                aimCalcDistanceFloorRaw = aimProximityPresets[index].rawValue
            }
            fieldHelp("무릎 높이 근접 촬영 시 AR 선 흔들림 완화용입니다. 바닥·볼 뒤 배치는 화면 조준 HUD를 사용하세요.")

            Text("그린스피드")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OSDPalette.textSecondary)
                .padding(.top, 4)
            OSDGreenSpeedStepper(
                value: guidanceModel.greenSpeed,
                onDecrement: { guidanceModel.nudgeGreenSpeed(-0.1) },
                onIncrement: { guidanceModel.nudgeGreenSpeed(0.1) },
                canDecrement: !guidanceModel.isComputing && guidanceModel.greenSpeed > 1.5,
                canIncrement: !guidanceModel.isComputing && guidanceModel.greenSpeed < 4.0
            )
            OSDPillRow(
                labels: Gate55GuidanceModel.greenSpeedPresets.map { String(format: "%.1f", $0) },
                selectedIndex: selectedGreenSpeedPresetIndex
            ) { index in
                guidanceModel.setGreenSpeed(Gate55GuidanceModel.greenSpeedPresets[index])
            }
        }
    }

    // MARK: - Shared performance

    private var pathCalculationContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            OSDSegmentedRow(
                options: RecommendScanGrid.allCases,
                label: { grid in
                    switch grid {
                    case .fine: return "130×130"
                    case .balanced: return "90×90"
                    case .light: return "45×45"
                    }
                },
                selection: Binding(
                    get: { RecommendScanGrid(rawValue: recommendGridRaw) ?? .balanced },
                    set: { recommendGridRaw = $0.rawValue }
                )
            )
            fieldHelp("숫자가 클수록 β·속도 후보가 촘촘해지지만 CPU 발열과 대기시간이 늘어납니다. 야외·고온에서는 45×45를 권장합니다.")
            OSDSettingsKVRow(
                title: "실효 격자",
                value: "\(PerformanceSettings.effectiveRecommendPointCount)×\(PerformanceSettings.effectiveRecommendPointCount)"
            )
        }
    }

    private var wormDashesPerEdge: Binding<WormDashesPerEdge> {
        Binding(
            get: { WormDashesPerEdge(rawValue: wormDashesPerEdgeRaw) ?? .three },
            set: { wormDashesPerEdgeRaw = $0.rawValue }
        )
    }

    private var gridWormContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            OSDSettingsToggleRow(title: "지렁이 애니메이션", isOn: $wormAnimationEnabled)
            OSDSegmentedRow(
                options: WormAnimFPS.allCases,
                label: { fps in "\(fps.rawValue) fps" },
                selection: Binding(
                    get: { WormAnimFPS(rawValue: wormFPSRaw) ?? .medium },
                    set: { wormFPSRaw = $0.rawValue }
                )
            )
            .disabled(!wormAnimationEnabled)
            OSDSettingsKVRow(
                title: "실효 FPS",
                value: {
                    let fps = PerformanceSettings.effectiveWormFPS
                    return fps <= 0 ? "정지" : String(format: "%.0f", fps)
                }()
            )
            OSDSettingsMenuRow(
                title: "변당 지렁이",
                options: WormDashesPerEdge.allCases,
                optionLabel: { "\($0.rawValue)개" },
                selection: wormDashesPerEdge,
                disabled: !wormAnimationEnabled
            )
            fieldHelp("경사가 있는 격자 변에는 모두 지렁이가 붙습니다. 많을수록 GPU 부하가 커집니다.")
        }
    }

    private var overlayDensityContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            OSDSegmentedRow(
                options: OverlayDensity.allCases,
                label: { density in
                    switch density {
                    case .sparse: return "절제"
                    case .standard: return "풍성"
                    }
                },
                selection: Binding(
                    get: { OverlayDensity(rawValue: overlayDensityRaw) ?? .standard },
                    set: { overlayDensityRaw = $0.rawValue }
                )
            )
            fieldHelp("풍성은 화면에 그리는 선·등고선 개수만 늘립니다. LiDAR 높이맵 해상도는 바뀌지 않습니다.")
        }
    }

    private var systemContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            OSDSettingsToggleRow(title: "자동 발열 조절", isOn: $autoThermalThrottle)
            OSDSettingsToggleRow(title: "화면 최대 밝기 강제", isOn: $forceMaxBrightness)
            OSDSettingsKVRow(title: "현재 기기 열 상태", value: thermalLabel, valueColor: thermalColor)
            fieldHelp("설정을 닫은 뒤 등고/격자를 다시 전환하면 새 밀도가 반영됩니다.")
        }
    }

    private var clearHistorySection: some View {
        VStack(spacing: 10) {
            Button(role: .destructive) {
                showClearHistoryConfirmation = true
            } label: {
                Label("저장된 스캔 기록 초기화", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private var selectedAimProximityIndex: Int {
        let current = aimCalcDistanceFloorRaw
        if let index = aimProximityPresets.firstIndex(where: { abs($0.rawValue - current) < 0.01 }) {
            return index
        }
        return aimProximityPresets.enumerated().min(by: {
            abs($0.element.rawValue - current) < abs($1.element.rawValue - current)
        })?.offset ?? 2
    }

    private var selectedGreenSpeedPresetIndex: Int {
        Gate55GuidanceModel.greenSpeedPresets.enumerated().min(by: {
            abs($0.element - guidanceModel.greenSpeed) < abs($1.element - guidanceModel.greenSpeed)
        })?.offset ?? 2
    }

    private func fieldHelp(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.8))
            .foregroundStyle(OSDPalette.textTertiary)
            .lineSpacing(2)
    }

    private var thermalLabel: String {
        switch ThermalPerformance.level {
        case .nominal: return "정상"
        case .fair: return "따뜻함"
        case .serious: return "고온"
        case .critical: return "과열"
        }
    }

    private var thermalColor: Color {
        switch ThermalPerformance.level {
        case .nominal: return OSDPalette.textSecondary
        case .fair: return OSDPalette.accent
        case .serious, .critical: return .red
        }
    }
}
