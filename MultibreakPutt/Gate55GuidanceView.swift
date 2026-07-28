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

struct Gate55GuidanceView: View {
    @ObservedObject var controller: ARScanSessionController
    @StateObject private var model = Gate55GuidanceModel()
    @State private var showDiagnostics = false
    @State private var runID = ""
    @State private var executedBetaText = ""
    @State private var measuredStopX = ""
    @State private var measuredStopY = ""
    @State private var rampHeightCM = "10"
    @State private var measuredV0 = ""
    @State private var recordMessage: String?
    @State private var aimRevision = 0
    @State private var greenVizMode: GreenSurfaceVizMode = .contours
    @State private var showPerformanceSettings = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                arPanel(height: geo.size.height * 0.5)
                infoPanel
                    .frame(height: geo.size.height * 0.5)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if runID.isEmpty {
                runID = defaultRunID()
            }
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
            PerformanceSettingsView()
        }
    }

    @ViewBuilder
    private func arPanel(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Gate55ARAimView(
                controller: controller,
                scan: controller.completedScan,
                betaDegrees: model.aimBetaDegrees,
                visible: model.hasAimLine,
                revision: aimRevision,
                trajectorySamples: trajectorySamplesForAR,
                greenVizMode: greenVizMode
            )
            .frame(height: height)

            if controller.placementRequest == .reanchorHole {
                CenterReticleOverlay()
                    .allowsHitTesting(false)
            }

            arChromeOverlay(height: height)
        }
        .frame(height: height)
    }

    private var trajectorySamplesForAR: [TrajectorySample] {
        model.recommendation?.trajectory
            ?? model.forwardResult?.trajectory
            ?? []
    }

    @ViewBuilder
    private func arChromeOverlay(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                arStatusStack
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                GreenVizModePicker(selection: $greenVizMode)
            }
            .padding(10)

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            Text(greenVizMode.hint)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var arStatusStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            trackingBadge
            if let banner = model.thermalLevel.statusBanner {
                Text(banner)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.9), in: Capsule())
            }
            if let scan = controller.completedScan {
                Text(scanStatusText(scan))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            if let message = controller.placementMessage {
                Text(message)
                    .font(.caption2)
                    .padding(6)
                    .background(.blue.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func scanStatusText(_ scan: CompletedScan) -> String {
        String(
            format: "기준 AR raycast · 볼→홀 %.2fm · %@",
            scan.holeDistance,
            scan.driftCorrected ? "왕복" : "편도·미보정"
        )
    }

    private var trackingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.trackingLimited ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(controller.trackingDescription)
                .font(.caption.weight(.semibold))
            if !controller.guidanceTrackingOK {
                Text("· 조준중 limited")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("게이트 5.5 조준")
                        .font(.headline)
                    Spacer()
                    Button {
                        showPerformanceSettings = true
                    } label: {
                        Image(systemName: "thermometer.medium")
                    }
                    .font(.caption)
                    .accessibilityLabel("성능·발열 설정")
                    Button("진단") { showDiagnostics = true }
                        .font(.caption)
                    Button("새 스캔", action: controller.reset)
                        .font(.caption)
                }

                Picker("모드", selection: $model.computeMode) {
                    ForEach(Gate55ComputeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.computeMode) { _, _ in model.recompute() }

                HStack {
                    Text(String(format: "스 %.1f", model.greenSpeed))
                        .font(.caption)
                        .frame(width: 48, alignment: .leading)
                    Slider(value: $model.greenSpeed, in: 1.5...4.0, step: 0.1)
                    Button("재계산") { model.recompute() }
                        .buttonStyle(.bordered)
                }

                if model.computeMode == .forward {
                    HStack {
                        labeledNumber("v0", value: $model.manualV0)
                        labeledNumber("β°", value: $model.manualBeta)
                        Button("실행") { model.recompute() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let rec = model.recommendation, rec.primary != nil,
                   abs(rec.elevationDelta) < 0.025, abs(rec.directionDegrees) > 8 {
                    Text("평탄한 면인데 |β|가 큽니다. 라이다 노이즈 가능성 — 볼·홀을 다시 지정하거나 조명을 바꿔 재스캔하세요.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("AR 우측 상단에서 등고선 / 격자·흐름을 전환 · 회색 0° · 녹색 경로 · 흰 조준")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if model.isComputing {
                    ProgressView("계산 중…")
                } else if model.computeMode == .recommend {
                    recommendationCard
                } else if let forward = model.forwardResult {
                    forwardCard(forward)
                }

                Divider()
                experimentSection

                Button("홀 재앵커링 (중앙 조준)") {
                    controller.requestHoleReanchor()
                }
                .buttonStyle(.bordered)
                .font(.caption)

                if let recordMessage {
                    Text(recordMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var recommendationCard: some View {
        if let rec = model.recommendation, rec.primary != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "실거리 %.1fm", rec.horizontalDistance))
                            .font(.subheadline)
                        Text("평지환산거리")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f m", rec.flatEquivalentDistance))
                            .font(.title.bold())
                    }
                    Spacer()
                    DirectionCompass(degrees: rec.directionDegrees)
                        .frame(width: 56, height: 56)
                }

                Text(adjustmentText(rec.distanceAdjustment))
                    .font(.subheadline.weight(.medium))
                Text(elevationText(rec.elevationDelta))
                    .font(.subheadline)
                Text(rec.strokeGuidance)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)

                Divider()

                Text(
                    String(
                        format: "v0 %.2f m/s · β %+.1f°",
                        rec.initialVelocity,
                        rec.directionDegrees
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    String(
                        format: "정지위치 (%.2f, %.2f) · +%.2fm",
                        rec.stopPosition.x,
                        rec.stopPosition.y,
                        rec.overrunDistance
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text("후보 없음 — 그린스피드나 볼·홀 배치를 확인하세요.")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
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

    private var experimentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("실험 기록")
                .font(.subheadline.bold())

            TextField("run_id", text: $runID)
                .textInputAutocapitalization(.never)
                .font(.caption)

            HStack {
                TextField("실행 β(영상)", text: $executedBetaText)
                    .keyboardType(.decimalPad)
                    .font(.caption)
                TextField("실측정지 X", text: $measuredStopX)
                    .keyboardType(.decimalPad)
                    .font(.caption)
                TextField("실측정지 Y", text: $measuredStopY)
                    .keyboardType(.decimalPad)
                    .font(.caption)
            }

            HStack {
                TextField("램프 cm", text: $rampHeightCM)
                    .keyboardType(.decimalPad)
                    .font(.caption)
                TextField("실측 v0", text: $measuredV0)
                    .keyboardType(.decimalPad)
                    .font(.caption)
            }

            HStack {
                Button("조준 스냅샷") { saveAimSnapshot() }
                Button("실내 결과") { saveIndoorResult() }
                Button("램프 캘리브") { saveRampCalibration() }
            }
            .buttonStyle(.bordered)
            .font(.caption)

            Button("경사 스팟체크 샘플 1점") { saveSlopeSpotSample() }
                .buttonStyle(.bordered)
                .font(.caption)
        }
    }

    private func labeledNumber(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption2)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(2))
            )
            .keyboardType(.decimalPad)
            .font(.caption)
            .frame(width: 64)
        }
    }

    private func saveAimSnapshot() {
        guard let scan = controller.completedScan else { return }
        let v0: Double
        let beta: Double
        if model.computeMode == .recommend, let rec = model.recommendation, rec.primary != nil {
            v0 = rec.initialVelocity
            beta = rec.directionDegrees
        } else {
            v0 = model.manualV0
            beta = model.manualBeta
        }
        do {
            try Gate55ExperimentRecorder.writeAimSnapshot(
                scanID: scan.id,
                runID: runID,
                requestedV0: v0,
                requestedBeta: beta,
                trackingStateOK: controller.guidanceTrackingOK && !controller.trackingLimited,
                recommendation: model.recommendation
            )
            if let executed = Double(executedBetaText) {
                try Gate55ExperimentRecorder.appendOverheadTrackingMeta(
                    scanID: scan.id,
                    runID: runID + "-exec",
                    requestedV0: v0,
                    requestedBeta: beta,
                    executedBeta: executed,
                    trackingStateOK: controller.guidanceTrackingOK
                )
            }
            let dir = try Gate55ExperimentRecorder.experimentDirectory(for: scan.id)
            recordMessage = "저장: \(dir.path)"
        } catch {
            recordMessage = "기록 실패: \(error.localizedDescription)"
        }
    }

    private func saveIndoorResult() {
        guard let scan = controller.completedScan else { return }
        let predicted: PuttVector2
        let v0: Double
        let beta: Double
        if let rec = model.recommendation, rec.primary != nil {
            predicted = rec.stopPosition
            v0 = rec.initialVelocity
            beta = rec.directionDegrees
        } else if let forward = model.forwardResult {
            predicted = forward.stopPosition
            v0 = forward.initialVelocity
            beta = forward.directionDegrees
        } else {
            recordMessage = "예측 결과가 없습니다."
            return
        }
        guard let mx = Double(measuredStopX), let my = Double(measuredStopY) else {
            recordMessage = "실측 정지좌표를 입력하세요."
            return
        }
        do {
            try Gate55ExperimentRecorder.appendIndoorRunResult(
                scanID: scan.id,
                runID: runID,
                v0: v0,
                beta: beta,
                predictedStop: predicted,
                measuredStop: PuttVector2(x: mx, y: my)
            )
            let dir = try Gate55ExperimentRecorder.experimentDirectory(for: scan.id)
            recordMessage = "실내 결과 저장: \(dir.path)"
        } catch {
            recordMessage = "기록 실패: \(error.localizedDescription)"
        }
    }

    private func saveRampCalibration() {
        guard let scan = controller.completedScan else { return }
        guard let height = Double(rampHeightCM), let v0 = Double(measuredV0) else {
            recordMessage = "램프 높이와 실측 v0를 입력하세요."
            return
        }
        do {
            try Gate55ExperimentRecorder.appendRampCalibration(
                scanID: scan.id,
                runID: runID,
                rampHeightCM: height,
                ballID: "ball-1",
                measuredV0: v0,
                notes: ""
            )
            recordMessage = "램프 캘리브 저장 완료"
        } catch {
            recordMessage = "기록 실패: \(error.localizedDescription)"
        }
    }

    /// 볼 위치 국소 경사를 높이맵에서 조회해 스팟체크 CSV에 한 줄 남긴다.
    /// measured_* 칸은 현장에서 경사계 값으로 덮어쓸 수 있도록 동일 값으로 시드한다.
    private func saveSlopeSpotSample() {
        guard let scan = controller.completedScan,
              let context = model.context else { return }
        let point = PuttVector2(x: 0, y: context.holeDistance * 0.5)
        let slope = context.field.localSlope(at: point)
        let deg = slope.alpha * 180 / .pi
        let az = slope.descentAzimuth * 180 / .pi
        do {
            try Gate55ExperimentRecorder.appendSlopeSpotcheck(
                scanID: scan.id,
                runID: runID,
                pointID: "midpath",
                x: point.x,
                y: point.y,
                measuredSlopeDeg: deg,
                measuredAzimuthDeg: az,
                heightmapSlopeDeg: deg,
                heightmapAzimuthDeg: az
            )
            // 빈 실내 지형 템플릿도 함께 확보
            try Gate55ExperimentRecorder.writeIndoorTerrain(
                scanID: scan.id,
                points: [
                    (0, 0, context.field.height(at: .zero)),
                    (0, context.holeDistance * 0.5, context.field.height(at: point)),
                    (0, context.holeDistance, context.field.height(at: context.holeLocal))
                ]
            )
            recordMessage = "스팟체크·실내지형 템플릿 저장 완료"
        } catch {
            recordMessage = "기록 실패: \(error.localizedDescription)"
        }
    }

    private func defaultRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return "run-\(formatter.string(from: Date()))"
    }

    private func adjustmentText(_ value: Double) -> String {
        let direction = value >= 0 ? "오르막 보정" : "내리막 보정"
        return String(format: "(%+.1f m %@)", value, direction)
    }

    private func elevationText(_ value: Double) -> String {
        if abs(value) < 0.005 {
            return "볼과 홀이 같은 높이"
        }
        return value > 0
            ? String(format: "홀이 볼보다 %.2f m 높음", value)
            : String(format: "홀이 볼보다 %.2f m 낮음", abs(value))
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
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule().fill(Color.white)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
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

private struct CenterReticleOverlay: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.orange.opacity(0.95), lineWidth: 2)
                .frame(width: 44, height: 44)
            Rectangle().fill(Color.orange).frame(width: 2, height: 28)
            Rectangle().fill(Color.orange).frame(width: 28, height: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = controller.session
        // 조준 단계: LiDAR 메시 재구성·occlusion 불필요. 등고·조준·경로만.
        view.environment.sceneUnderstanding.options = []
        view.debugOptions.remove(.showSceneUnderstanding)
        view.renderOptions.insert(.disableMotionBlur)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        uiView.environment.sceneUnderstanding.options = []
        uiView.debugOptions.remove(.showSceneUnderstanding)
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
        private static let contourStyleVersion = 7
        private var gridFlowRoot: Entity?
        private var wormDashRoot: Entity?
        private var gridFlowScanID: String?
        private var gridFlowStyleVersionApplied = 0
        private static let gridFlowStyleVersion = 12
        private var gridFlowWormWidthApplied: Float = 0
        private var lastVizMode: GreenSurfaceVizMode?
        private var overlayScanID: String?
        private var handlingReanchor = false
        private var lastAimBeta: Double = .nan
        private var lastAimLength: Float = 0
        private var lastAimWidth: Float = 0
        private var lastZeroHoleDistance: Double = .nan
        private var lastTrajectoryRevision: Int = -1

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
                lastVizMode = nil
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

            // 초록 경로(불투명 80%) · 흰 조준은 좌우 4px만 가늘게
            let contourLift: Float = 0.006
            let pathLift: Float = 0.018
            let aimLift: Float = 0.022
            let pathPixels: Float = 12
            let aimPixels: Float = pathPixels - 4
            let pathWidth = lineScreenSpaceWidth(pixels: pathPixels, in: view, near: ballWorld)
            let aimWidth = lineScreenSpaceWidth(pixels: aimPixels, in: view, near: ballWorld)
            // 지렁이: 격자보다 확실히 굵게 (화면 ~9px, 야외 시인성)
            let wormWidth = lineScreenSpaceWidth(pixels: 9.0, in: view, near: ballWorld)

            updateTerrainViz(
                mode: greenVizMode,
                for: scan,
                lift: contourLift,
                transform: transform,
                parent: overlays,
                wormWidth: wormWidth
            )

            if zeroLineEntity == nil || abs(lastZeroHoleDistance - scan.holeDistance) > 1e-4 {
                placeBallLocalSegment(
                    toLocalX: 0,
                    toLocalY: scan.holeDistance,
                    lift: pathLift,
                    width: max(pathWidth * 0.35, 0.004),
                    thickness: 0.002,
                    color: UIColor(white: 0.55, alpha: 0.75),
                    transform: transform,
                    parent: overlays,
                    entity: &zeroLineEntity
                )
                lastZeroHoleDistance = scan.holeDistance
            }

            guard visible else {
                aimEntity?.isEnabled = false
                clearTrajectory()
                lastTrajectoryRevision = -1
                return
            }

            let trajSig = trajectorySignature(trajectory, pathWidth: pathWidth)
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

            let length = max(1.0, min(scan.holeDistance * 0.45, 2.2))
            if trajectoryRebuilt
                || aimEntity == nil
                || abs(lastAimBeta - betaDegrees) > 0.05
                || abs(lastAimLength - Float(length)) > 1e-3
                || abs(lastAimWidth - aimWidth) > 0.0008 {
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
            }
        }

        private func ensureOverlayRoot(under ball: AnchorEntity) -> Entity {
            if let overlayRoot, overlayRoot.parent === ball {
                return overlayRoot
            }
            overlayRoot?.removeFromParent()
            let root = Entity()
            root.name = "puttOverlays"
            ball.addChild(root)
            overlayRoot = root
            return root
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
            wormWidth: Float
        ) {
            if lastVizMode != mode {
                clearContours()
                clearGridFlow()
                lastVizMode = mode
            }
            switch mode {
            case .contours:
                clearGridFlow()
                updateContours(for: scan, lift: lift, transform: transform, parent: parent)
            case .gridFlow:
                clearContours()
                updateGridFlow(
                    for: scan,
                    lift: lift,
                    transform: transform,
                    parent: parent,
                    wormWidth: wormWidth
                )
            }
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

        private func lineScreenSpaceWidth(
            pixels: Float,
            in view: ARView,
            near point: SIMD3<Float>
        ) -> Float {
            guard let frame = view.session.currentFrame else {
                return max(pixels * 0.001, 0.004)
            }
            let cam = frame.camera.transform.columns.3
            let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
            let distance = simd_length(point - camPos)
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let projection = frame.camera.projectionMatrix(
                for: orientation,
                viewportSize: view.bounds.size,
                zNear: 0.01,
                zFar: 100
            )
            let projectionYScale = max(abs(projection[1][1]), 0.001)
            let viewportPixelHeight = max(Float(view.bounds.height * view.contentScaleFactor), 1)
            return ARReferenceMarkers.worldWidth(
                forScreenPixels: pixels,
                distanceMeters: distance,
                viewportPixelHeight: viewportPixelHeight,
                projectionYScale: projectionYScale
            )
        }

        private func trajectorySignature(_ samples: [TrajectorySample], pathWidth: Float) -> Int {
            guard let first = samples.first, let last = samples.last else { return 0 }
            var hasher = Hasher()
            hasher.combine(samples.count)
            hasher.combine(first.position.x)
            hasher.combine(first.position.y)
            hasher.combine(last.position.x)
            hasher.combine(last.position.y)
            hasher.combine(Int((pathWidth * 10_000).rounded()))
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
            parent: Entity
        ) {
            let density = PerformanceSettings.effectiveOverlayDensity
            if contourScanID == scan.id,
               contourRoot != nil,
               contourStyleVersionApplied == Self.contourStyleVersion,
               contourThermalApplied == ThermalPerformance.level,
               contourDensityApplied == density {
                return
            }
            clearContours()

            let thermal = ThermalPerformance.level
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

            let root = Entity()
            root.name = "contours"
            let lineWidth: Float = 0.0036
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
                    localPoints.append(
                        ballLocalPoint(
                            localX: point.x,
                            localY: point.y,
                            lift: lift,
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
                    }
                    added += 1
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
                (0.00, UIColor(red: 0.15, green: 0.35, blue: 0.95, alpha: 0.95)),
                (0.17, UIColor(red: 0.20, green: 0.78, blue: 0.92, alpha: 0.95)),
                (0.33, UIColor(red: 0.12, green: 0.72, blue: 0.28, alpha: 0.95)),
                (0.50, UIColor(red: 0.55, green: 0.90, blue: 0.22, alpha: 0.95)),
                (0.67, UIColor(red: 1.00, green: 0.86, blue: 0.12, alpha: 0.95)),
                (0.83, UIColor(red: 1.00, green: 0.48, blue: 0.08, alpha: 0.95)),
                (1.00, UIColor(red: 0.92, green: 0.18, blue: 0.14, alpha: 0.95))
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
            wormWidth: Float
        ) {
            let density = PerformanceSettings.effectiveOverlayDensity
            let wormsOn = PerformanceSettings.wormAnimationEnabled
            let dashesPerEdge = PerformanceSettings.wormDashesPerEdge.rawValue
            if gridFlowScanID == scan.id,
               gridFlowRoot != nil,
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

            let gridColor = UIColor(white: 1.0, alpha: 0.28)
            let gridWidth: Float = 0.0024
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
                (0.00, UIColor(red: 0.15, green: 0.92, blue: 0.98, alpha: 0.98)),
                (0.35, UIColor(red: 0.35, green: 0.96, blue: 0.45, alpha: 0.98)),
                (0.65, UIColor(red: 1.00, green: 0.84, blue: 0.18, alpha: 0.98)),
                (1.00, UIColor(red: 1.00, green: 0.42, blue: 0.10, alpha: 0.98))
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
            let pathColor = UIColor(red: 0.15, green: 0.95, blue: 0.35, alpha: 0.8)
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
            .navigationTitle("게이트 1 진단")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onDismiss)
                }
            }
        }
    }
}
