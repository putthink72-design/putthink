import ARKit
import PuttPhysicsKit
import RealityKit
import SwiftUI
import UIKit

struct ScanFlowView: View {
    @StateObject private var controller = ARScanSessionController()
    @StateObject private var guidancePlaceholder = Gate55GuidanceModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var regionCenterX = 0.5
    @State private var regionCenterY = 0.5
    @State private var regionSize = 0.4
    @State private var diagnostics: ScanDiagnostics?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var savedBrightness: CGFloat?
    @State private var showSettings = false
    @State private var exportGeneration = 0
    /// 조준↔스캔 전환 시 ARView를 재생성하지 않기 위한 공유 카메라 뷰.
    @State private var sessionARView: ARView?

    var body: some View {
        ZStack {
            PlacementARView(controller: controller, sessionARView: $sessionARView)
                .ignoresSafeArea()

            if controller.flowState == .complete,
               controller.completedScan != nil {
                Gate55GuidanceView(
                    controller: controller,
                    sessionARView: sessionARView,
                    exportError: $exportError,
                    onRequestClearHistory: clearScanHistory
                )
            } else {
                scanExperienceOverlays
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            applyBrightnessPolicy()
            UIApplication.shared.isIdleTimerDisabled = true
            controller.prewarmSession()
        }
        .onDisappear {
            restoreBrightness()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                applyBrightnessPolicy()
                UIApplication.shared.isIdleTimerDisabled = true
                controller.resumeARSession()
            case .inactive:
                if !PerformanceSettings.forceMaxBrightness {
                    restoreBrightness()
                }
            case .background:
                restoreBrightness()
                UIApplication.shared.isIdleTimerDisabled = false
                controller.pauseARSession()
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PerformanceSettings.didChangeNotification)) { _ in
            applyBrightnessPolicy()
        }
        .onChange(of: controller.completedScan?.id) { _, identifier in
            guard identifier != nil else { return }
            exportCurrentScan()
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsSheet(
                mode: .scan,
                controller: controller,
                guidanceModel: guidancePlaceholder,
                onRequestClearHistory: clearScanHistory
            )
        }
    }

    private var scanExperienceOverlays: some View {
        ZStack {
            if showsReticle && controller.flowState != .placingHole {
                OSDAmberReticle(dashedRing: controller.flowState != .placingBall)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if !controller.holeGroundRingPoints.isEmpty {
                HoleCupRingOverlay(points: controller.holeGroundRingPoints)
                    .ignoresSafeArea()
            }

            if controller.flowState == .placingBall, !controller.ballGroundRingPoints.isEmpty {
                BallGroundRingOverlay(points: controller.ballGroundRingPoints)
                    .ignoresSafeArea()
            }

            if controller.lidarTwistGuidance?.pitchInBand == true, showsTwistCards {
                ScanPitchInBandWash()
            }

            VStack(spacing: 0) {
                scanTopChrome
                    .padding(.horizontal, OSDTopChromeMetrics.horizontalPadding)
                    .padding(.top, OSDTopChromeMetrics.topPadding)

                if showsCoverageUI {
                    coverageBanner
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                if let twist = controller.lidarTwistGuidance, showsTwistCards {
                    LiDARTwistGuidanceCards(guidance: twist)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                if let message = controller.placementMessage, showsPlacementBanner {
                    Text(message)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                Spacer(minLength: 0)

                Group {
                    if controller.flowState == .idle {
                        idleOnboardCard
                    } else if controller.flowState != .complete {
                        scanBottomPanel
                    }
                }
                .padding(.horizontal, OSDTopChromeMetrics.floatingCardHorizontalPadding)
                .padding(.bottom, OSDTopChromeMetrics.floatingCardBottomPadding)
            }
        }
    }

    /// 스캔 중 placement 배너는 걷기·홀 지정 단계에서 숨김.
    private var showsPlacementBanner: Bool {
        switch controller.flowState {
        case .walkingToHole, .placingHole:
            return false
        default:
            return true
        }
    }

    private var showsTwistCards: Bool {
        switch controller.flowState {
        case .walkingToHole, .placingHole, .processing:
            return true
        case .complete:
            return controller.needsBallReanchor
        default:
            return false
        }
    }

    private var scanTopChrome: some View {
        OSDHeaderBar {
            if showsCoverageUI || controller.flowState != .idle {
                OSDStatusPill(
                    isHealthy: !controller.trackingLimited,
                    title: trackingTitle,
                    subtitle: "메시 \(controller.meshVertexCount.formatted())점"
                )
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        } trailing: {
            OSDGearButton { showSettings = true }
        }
    }

    private var trackingTitle: String {
        switch controller.flowState {
        case .idle:
            return "대기"
        default:
            return "트래킹 스캔 중"
        }
    }

    @ViewBuilder
    private var scanBottomPanel: some View {
        switch controller.flowState {
        case .placingBall:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 1 / 2",
                    title: controller.pendingDetectedBall == nil ? "볼 위치 지정" : "볼 후보 확인",
                    body: ballPlacementBody,
                    button: ballPlacementButtonTitle,
                    action: controller.requestBallPlacement,
                    enabled: controller.meshReady
                ) {
                    if let lock = controller.visualBallLockStatus.shortLabel {
                        Text(lock)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OSDPalette.accent)
                    }
                    if !controller.meshReady {
                        HStack(spacing: 8) {
                            ProgressView().tint(OSDPalette.accent)
                            Text(
                                controller.sceneDepthReady
                                    ? "깊이 준비됨 · 메시 \(controller.meshVertexCount.formatted())점"
                                    : "메시 \(controller.meshVertexCount.formatted()) / \(ARScanSessionController.meshReadyVertexThreshold)점"
                            )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OSDPalette.textSecondary)
                        }
                    }
                    referenceStatusCompact
                }
            }
        case .walkingToHole:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 2 / 2",
                    title: "홀까지 사선 스캔",
                    body: "\(controller.lidarProfile.puttLineScreenHint) 홀이 가까우면 바로 지정해도 됩니다.",
                    button: "홀 도착 · 홀 지정",
                    action: controller.beginHolePlacement,
                    enabled: true
                ) {
                    referenceStatusCompact
                }
            }
        case .placingHole:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 2 / 2",
                    title: "홀을 지정하세요",
                    body: controller.pathMode.requiresBallReanchor
                        ? "십자선을 홀컵 앞 잔디(컵 중심)에 맞춘 뒤 지정하세요. 지정 직후 경로를 계산합니다. 볼로 돌아와 조준하면 흰 볼을 자동 정렬합니다."
                        : "십자선을 홀컵 앞 잔디(컵 중심)에 맞춘 뒤 지정하세요. 지정 직후 경로를 계산·표시하고, 조준 중 흰 볼을 자동 정렬합니다.",
                    button: "홀 지정 · 바로 계산",
                    action: controller.requestHolePlacement
                ) {
                    referenceStatusCompact
                }
            }
        case .processing:
            OSDOnboardCard {
                ProgressView("5cm 높이맵 처리 중…")
                    .font(.system(size: 12))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            OSDOnboardCard {
                stepPanel(
                    step: nil,
                    title: "스캔 실패",
                    body: message,
                    button: "처음부터 다시",
                    action: resetScanSession
                ) {
                    EmptyView()
                }
            }
        default:
            EmptyView()
        }
    }

    private var idleOnboardCard: some View {
        OSDOnboardCard {
            Text("볼·홀 사이 그린을 스캔합니다.\n바닥을 약 40° 사선(허용 30–45°)으로 비추며 홀까지 걸으세요.")
                .font(.system(size: 12.5))
                .foregroundStyle(OSDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            OSDPrimaryButton(
                title: controller.scanPipelineReady ? "스캔 시작" : "LiDAR 준비 중…",
                enabled: controller.scanPipelineReady
            ) {
                controller.startScan()
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var ballPlacementBody: String {
        switch controller.visualBallLockStatus {
        case .candidate:
            return "감지된 후보가 맞으면 확인하세요. 틀리거나 볼이 없으면 십자선을 원하는 지면에 두고 직접 지정하세요."
        case .searching, .waitingForView:
            if controller.ballDetectionPreview != nil {
                return "볼을 찾는 중입니다. 십자선을 볼 중심에 맞추면 지면 링이 따라옵니다."
            }
            return "볼이 있으면 십자선을 중심에 맞추면 후보를 찾습니다. 볼 없이도 십자선 지면을 직접 지정할 수 있습니다."
        case .locked, .aligned:
            return "볼이 지정되었습니다."
        default:
            return "볼이 있으면 십자선을 중심에 맞추면 후보를 찾습니다. 볼 없이도 십자선 지면을 직접 지정할 수 있습니다."
        }
    }

    private var ballPlacementButtonTitle: String {
        guard controller.meshReady else { return "지면 준비 중…" }
        if controller.pendingDetectedBall != nil {
            return "감지 후보로 지정"
        }
        return "십자선 지면 지정"
    }

    @ViewBuilder
    private func stepPanel<Extra: View>(
        step: String?,
        title: String,
        body bodyText: String,
        button buttonTitle: String,
        action: @escaping () -> Void,
        enabled: Bool = true,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OSDStepHeader(step: step, title: title, bodyText: bodyText)
            extra()
            OSDPrimaryButton(title: buttonTitle, enabled: enabled, action: action)
            if controller.trackingLimited {
                Text("천천히 움직이고 잔디의 특징이 보이도록 카메라 방향을 조정하세요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var referenceStatusCompact: some View {
        if controller.ballAnchor != nil || controller.holeAnchor != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let ball = controller.ballAnchor {
                    Text(String(format: "볼 (%.2f, %.2f, %.2f)", ball.worldX, ball.worldY, ball.worldZ))
                        .font(.system(size: 9.5))
                        .foregroundStyle(OSDPalette.textTertiary)
                        .monospacedDigit()
                }
                if let hole = controller.holeAnchor {
                    Text(String(format: "홀 (%.2f, %.2f, %.2f)", hole.worldX, hole.worldY, hole.worldZ))
                        .font(.system(size: 9.5))
                        .foregroundStyle(OSDPalette.textTertiary)
                        .monospacedDigit()
                }
                if let distance = controller.currentHoleDistance {
                    Text(String(format: "볼→홀 %.2fm", distance))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OSDPalette.textSecondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var showsReticle: Bool {
        switch controller.flowState {
        case .placingBall, .placingHole:
            return true
        case .complete:
            return controller.needsBallReanchor
        default:
            return false
        }
    }

    private var showsCoverageUI: Bool {
        switch controller.flowState {
        case .placingBall, .walkingToHole, .placingHole, .processing:
            return true
        case .complete:
            return controller.needsBallReanchor
        default:
            return false
        }
    }

    private var coverageBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCompactCoverage {
                HStack(spacing: 10) {
                    Label("파랑 격자=스캔 중", systemImage: "square.grid.3x3.fill")
                        .foregroundStyle(Color.blue)
                    Label("흰 격자=안정", systemImage: "checkmark.circle")
                        .foregroundStyle(Color.white)
                    Spacer()
                }
                .font(.caption2.weight(.semibold))
            }

            Text(controller.coverageSnapshot.statusLine)
                .font(.caption.monospacedDigit().weight(.semibold))

            if controller.holeAnchor != nil {
                Text(
                    String(
                        format: "홀 뒤 측정 %.0fcm / %.0fcm (경로 계산 %.0fcm까지)",
                        controller.pastHoleMeasuredMeters * 100,
                        PuttScanCorridor.pastHoleMargin * 100,
                        PuttScanCorridor.pastHoleMargin * 100
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(OSDPalette.textSecondary)
            }

            ProgressView(value: controller.coverageSnapshot.stableRatio)
                .tint(OSDPalette.accent)

            if !isCompactCoverage {
                Text(controller.coverageQualityMessage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))

                Text("지정 계산: \(controller.pathMode.label)")
                    .font(.caption2)
                    .foregroundStyle(OSDPalette.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OSDPalette.glassStrong, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
    }

    /// STEP 2/3에서는 안내 카드가 많아 커버리지를 한 줄로 줄임.
    private var isCompactCoverage: Bool {
        switch controller.flowState {
        case .walkingToHole:
            return true
        default:
            return false
        }
    }

    private var selectedRegion: PuttPhysicsKit.NormalizedRegion {
        let half = regionSize / 2
        return PuttPhysicsKit.NormalizedRegion(
            minX: regionCenterX - half,
            maxX: regionCenterX + half,
            minY: regionCenterY - half,
            maxY: regionCenterY + half
        )
    }

    private func applyBrightnessPolicy() {
        if PerformanceSettings.forceMaxBrightness {
            forceMaxBrightness()
        } else {
            restoreBrightness()
        }
    }

    private func forceMaxBrightness() {
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 1.0
    }

    private func restoreBrightness() {
        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
            self.savedBrightness = nil
        }
    }

    private func exportCurrentScan() {
        guard let scan = controller.completedScan else { return }
        exportGeneration += 1
        let generation = exportGeneration
        let region = selectedRegion
        Task.detached(priority: .utility) {
            do {
                let outcome = try ScanExporter.export(scan: scan, region: region)
                await MainActor.run {
                    guard generation == self.exportGeneration else { return }
                    diagnostics = outcome.diagnostics
                    exportURL = outcome.directory
                    exportError = nil
                }
            } catch {
                await MainActor.run {
                    guard generation == self.exportGeneration else { return }
                    exportError = "내보내기 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    private func clearScanHistory() {
        exportGeneration += 1
        do {
            try ScanExporter.clearHistory()
            diagnostics = nil
            exportURL = nil
            exportError = nil
            controller.reset()
        } catch {
            exportError = "기록 초기화 실패: \(error.localizedDescription)"
        }
    }

    private func resetScanSession() {
        controller.reset()
    }
}

// MARK: - AR view with raycast + markers

private struct PlacementARView: UIViewRepresentable {
    @ObservedObject var controller: ARScanSessionController
    @Binding var sessionARView: ARView?

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = controller.session
        view.environment.sceneUnderstanding.options = []
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.renderOptions.insert(.disableGroundingShadows)
        view.renderOptions.insert(.disableCameraGrain)
        view.renderOptions.insert(.disableHDR)
        context.coordinator.arView = view
        DispatchQueue.main.async {
            sessionARView = view
        }
        context.coordinator.attachDisplayLink(controller: controller)
        // 머티리얼 셰이더를 미리 컴파일 — 첫 메시 표시 히칭 제거.
        context.coordinator.brightMesh.prewarmRenderPipelines(in: view)
        // ARView에 session이 붙은 직후 워밍업(onAppear보다 앞서 cold start 단축).
        controller.prewarmSession()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.arView = uiView
        if sessionARView !== uiView {
            sessionARView = uiView
        }
        context.coordinator.controller = controller
        context.coordinator.lineWidthPixels = 2
        uiView.debugOptions.remove(.showSceneUnderstanding)
        let meshAllowed = controller.meshVisualizationAllowed
        if meshAllowed {
            let wasVisible = context.coordinator.meshEnabled && !context.coordinator.meshHidden
            context.coordinator.meshEnabled = true
            context.coordinator.meshHidden = false
            if !wasVisible {
                // 워밍업으로 이미 빌드된 지오메트리를 다음 틱을 기다리지 않고 즉시 공개.
                context.coordinator.revealMeshNow(in: uiView)
            }
        } else if controller.meshWarmupActive {
            // idle: 화면에는 숨기고 지오메트리만 미리 빌드 (스캔 시작 시 즉시 표시).
            context.coordinator.meshEnabled = true
            context.coordinator.meshHidden = true
            context.coordinator.brightMesh.contentHidden = true
        } else {
            // teardown 금지 — 숨김만. (setEnabled false는 워밍업 메시를 버려 깜빡임·소실 유발)
            context.coordinator.meshEnabled = true
            context.coordinator.meshHidden = true
            context.coordinator.brightMesh.contentHidden = true
        }
        if controller.flowState != .complete {
            context.coordinator.syncMarkers(
                in: uiView,
                session: controller.session,
                ball: controller.ballAnchor,
                hole: controller.holeAnchor
            )
        }
        context.coordinator.refreshBallRing(controller: controller, in: uiView)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.detachDisplayLink()
        if let controller = coordinator.controller {
            coordinator.syncMarkers(
                in: uiView,
                session: controller.session,
                ball: nil,
                hole: nil
            )
        }
        coordinator.brightMesh.teardown(in: uiView)
        coordinator.arView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        let brightMesh = BrightMeshVisualizer()
        weak var arView: ARView?
        weak var controller: ARScanSessionController?
        var meshEnabled = false
        var meshHidden = false
        var lineWidthPixels: Float = 2
        private var displayLink: CADisplayLink?
        private var lastMeshTick: CFTimeInterval = 0
        private var burstRateApplied = false
        private var ballAnchorEntity: AnchorEntity?
        private var holeAnchorEntity: AnchorEntity?

        func attachDisplayLink(controller: ARScanSessionController) {
            self.controller = controller
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func detachDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// 스캔 시작 순간 — 워밍업된 지오메트리를 즉시 공개하고 첫 빌드도 바로 스케줄.
        func revealMeshNow(in view: ARView) {
            brightMesh.setEnabled(true, in: view)
            if controller?.meshCoverageSnapshot.observedCellCount == 0 {
                brightMesh.resetCoverageDisplayLock(in: view)
            }
            brightMesh.contentHidden = false
            brightMesh.lineWidthPixels = lineWidthPixels
            brightMesh.burstMode = controller?.meshCaptureBurstActive ?? true
            if let controller {
                brightMesh.coverageSnapshot = controller.meshCoverageSnapshot
            }
            brightMesh.update(in: view)
            lastMeshTick = CACurrentMediaTime()
        }

        @objc private func onDisplayLink(_ link: CADisplayLink) {
            guard meshEnabled, let controller, let view = arView else { return }
            let burst = controller.meshCaptureBurstActive && !meshHidden
            if burst != burstRateApplied {
                link.preferredFrameRateRange = burst
                    ? CAFrameRateRange(minimum: 24, maximum: 45, preferred: 30)
                    : CAFrameRateRange(minimum: 12, maximum: 24, preferred: 18)
                burstRateApplied = burst
            }
            // 숨김 워밍업은 여유 있게, 첫 공개 burst는 촘촘히 갱신.
            let tickInterval: TimeInterval = meshHidden ? 0.08 : (burst ? 0.033 : 0.06)
            guard link.timestamp - lastMeshTick >= tickInterval else { return }
            lastMeshTick = link.timestamp
            brightMesh.setEnabled(true, in: view)
            brightMesh.contentHidden = meshHidden
            brightMesh.lineWidthPixels = lineWidthPixels
            brightMesh.burstMode = burst
            brightMesh.coverageSnapshot = controller.meshCoverageSnapshot
            if let ball = controller.ballAnchor {
                brightMesh.corridorBallXZ = SIMD2(ball.worldX, ball.worldZ)
                brightMesh.corridorBallY = Float(ball.worldY)
            } else {
                brightMesh.corridorBallXZ = nil
                brightMesh.corridorBallY = nil
            }
            if let hole = controller.holeAnchor {
                brightMesh.corridorHoleXZ = SIMD2(hole.worldX, hole.worldZ)
            } else {
                brightMesh.corridorHoleXZ = nil
            }
            brightMesh.update(in: view)
            let showsScanMarkers = controller.flowState != .complete
            syncMarkers(
                in: view,
                session: controller.session,
                ball: showsScanMarkers ? controller.ballAnchor : nil,
                hole: showsScanMarkers ? controller.holeAnchor : nil
            )
            refreshPlacementRings(controller: controller, in: view)
        }

        func refreshPlacementRings(controller: ARScanSessionController, in view: ARView) {
            let frame = view.session.currentFrame
            let viewport = view.bounds.size
            controller.refreshBallGroundRing(frame: frame, viewport: viewport)
            controller.refreshHoleGroundRing(frame: frame, viewport: viewport)
        }

        func refreshBallRing(controller: ARScanSessionController, in view: ARView) {
            refreshPlacementRings(controller: controller, in: view)
        }

        func syncMarkers(
            in view: ARView,
            session _: ARSession,
            ball: ScanPose?,
            hole: ScanPose?
        ) {
            if let ball {
                let world = SIMD3<Float>(Float(ball.worldX), Float(ball.worldY), Float(ball.worldZ))
                ARReferenceMarkers.placeRealityWorldFixed(
                    entityFactory: { ARReferenceMarkers.makeBallEntity() },
                    at: world,
                    in: view,
                    existingEntity: &ballAnchorEntity
                )
            } else {
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &ballAnchorEntity
                )
            }

            if let hole {
                let world = SIMD3<Float>(Float(hole.worldX), Float(hole.worldY), Float(hole.worldZ))
                ARReferenceMarkers.placeRealityWorldFixed(
                    entityFactory: { ARReferenceMarkers.makeHoleEntity() },
                    at: world,
                    in: view,
                    existingEntity: &holeAnchorEntity
                )
            } else {
                ARReferenceMarkers.removeRealityWorldFixed(
                    in: view,
                    existingEntity: &holeAnchorEntity
                )
            }
        }
    }
}
