import SwiftUI

/// 발열·성능 관련 사용자 설정.
struct PerformanceSettingsView: View {
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

    @Environment(\.dismiss) private var dismiss

    private var recommendGrid: Binding<RecommendScanGrid> {
        Binding(
            get: { RecommendScanGrid(rawValue: recommendGridRaw) ?? .balanced },
            set: { recommendGridRaw = $0.rawValue }
        )
    }

    private var wormFPS: Binding<WormAnimFPS> {
        Binding(
            get: { WormAnimFPS(rawValue: wormFPSRaw) ?? .medium },
            set: { wormFPSRaw = $0.rawValue }
        )
    }

    private var wormDashesPerEdge: Binding<WormDashesPerEdge> {
        Binding(
            get: { WormDashesPerEdge(rawValue: wormDashesPerEdgeRaw) ?? .three },
            set: { wormDashesPerEdgeRaw = $0.rawValue }
        )
    }

    private var overlayDensity: Binding<OverlayDensity> {
        Binding(
            get: { OverlayDensity(rawValue: overlayDensityRaw) ?? .standard },
            set: { overlayDensityRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("추천 슈팅 격자", selection: recommendGrid) {
                        ForEach(RecommendScanGrid.allCases) { grid in
                            Text(grid.label).tag(grid)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text((RecommendScanGrid(rawValue: recommendGridRaw) ?? .balanced).subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("실효 격자") {
                        Text("\(PerformanceSettings.effectiveRecommendPointCount)×\(PerformanceSettings.effectiveRecommendPointCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("퍼팅 경로 계산")
                } footer: {
                    Text("숫자가 클수록 β·속도 후보가 촘촘해지지만 CPU 발열과 대기 시간이 늘어납니다. 야외·고온에서는 45×45를 권장합니다.")
                }

                Section {
                    Toggle("지렁이 애니메이션", isOn: $wormAnimationEnabled)

                    Picker("지렁이 FPS", selection: wormFPS) {
                        ForEach(WormAnimFPS.allCases) { fps in
                            Text(fps.label).tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!wormAnimationEnabled)

                    Text((WormAnimFPS(rawValue: wormFPSRaw) ?? .medium).subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("실효 FPS") {
                        let fps = PerformanceSettings.effectiveWormFPS
                        Text(fps <= 0 ? "정지" : String(format: "%.0f", fps))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Picker("변당 지렁이", selection: wormDashesPerEdge) {
                        ForEach(WormDashesPerEdge.allCases) { count in
                            Text("\(count.rawValue)개").tag(count)
                        }
                    }
                    .disabled(!wormAnimationEnabled)

                    Text((WormDashesPerEdge(rawValue: wormDashesPerEdgeRaw) ?? .three).subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("격자·지렁이")
                } footer: {
                    Text("경사가 있는 격자 변에는 모두 지렁이가 붙습니다. 변당 3~9개. 많을수록 GPU 부하가 커집니다.")
                }

                Section {
                    Picker("등고/격자 밀도", selection: overlayDensity) {
                        ForEach(OverlayDensity.allCases) { density in
                            Text(density.label).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text((OverlayDensity(rawValue: overlayDensityRaw) ?? .standard).subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("AR 오버레이 밀도")
                } footer: {
                    Text("듬성은 화면에 그리는 선·등고 개수만 줄입니다. LiDAR·높이맵 해상도는 바꾸지 않습니다.")
                }

                Section {
                    Toggle("자동 발열 조절", isOn: $autoThermalThrottle)
                    Toggle("화면 최대 밝기 강제", isOn: $forceMaxBrightness)
                } header: {
                    Text("시스템")
                } footer: {
                    Text("자동 발열 조절: 기기 온도가 오를 때 위 설정보다 더 낮은 쪽으로만 제한합니다.\n최대 밝기 강제: 야외 시인성용이며 발열·배터리를 키웁니다. 기본은 꺼짐입니다.")
                }

                Section {
                    LabeledContent("현재 기기 열 상태") {
                        Text(thermalLabel)
                            .foregroundStyle(thermalColor)
                    }
                } footer: {
                    Text("이 화면을 닫은 뒤 조준에서 등고/격자를 다시 전환하면 새 설정이 반영됩니다.")
                }
            }
            .navigationTitle("성능·발열")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        PerformanceSettings.notifyDidChange()
                        dismiss()
                    }
                }
            }
            .onChange(of: recommendGridRaw) { _, _ in PerformanceSettings.notifyDidChange() }
            .onChange(of: wormFPSRaw) { _, _ in PerformanceSettings.notifyDidChange() }
            .onChange(of: wormAnimationEnabled) { _, _ in PerformanceSettings.notifyDidChange() }
            .onChange(of: wormDashesPerEdgeRaw) { _, _ in PerformanceSettings.notifyDidChange() }
            .onChange(of: autoThermalThrottle) { _, _ in PerformanceSettings.notifyDidChange() }
            .onChange(of: overlayDensityRaw) { _, _ in PerformanceSettings.notifyDidChange() }
            .onChange(of: forceMaxBrightness) { _, _ in PerformanceSettings.notifyDidChange() }
        }
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
        case .nominal: return .secondary
        case .fair: return .orange
        case .serious, .critical: return .red
        }
    }
}
