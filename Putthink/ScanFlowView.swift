import ARKit
import PuttPhysicsKit
@preconcurrency import RealityKit
import SwiftUI
import UIKit

struct ScanFlowView: View {
    @StateObject private var controller = ARScanSessionController()
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var freeRuns: FreeRunsStore
    @EnvironmentObject private var auth: AuthSessionStore
    @EnvironmentObject private var language: AppLanguageStore
    @EnvironmentObject private var devMode: DevModeStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var regionCenterX = 0.5
    @State private var regionCenterY = 0.5
    @State private var regionSize = 0.4
    @State private var diagnostics: ScanDiagnostics?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var savedBrightness: CGFloat?
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
                    showSettings: $showSettings
                )
            } else {
                scanExperienceOverlays
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            AppSettingsSheet()
                .environmentObject(subscriptions)
                .environmentObject(freeRuns)
                .environmentObject(language)
                .environmentObject(auth)
                .environmentObject(devMode)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(22)
                .presentationContentInteraction(.scrolls)
        }
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
        .onChange(of: controller.completedScan?.id) { _, identifier in
            guard identifier != nil else { return }
            exportCurrentScan()
        }
    }

    private var scanExperienceOverlays: some View {
        ZStack {
            if showsReticle && controller.flowState != .placingHole {
                OSDAmberReticle(dashedRing: controller.flowState != .placingBall)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if controller.lidarTwistGuidance?.pitchInBand == true {
                ScanPitchInBandWash()
            }

            VStack(spacing: 0) {
                scanTopChrome
                    .padding(.horizontal, OSDTopChromeMetrics.horizontalPadding)
                    .padding(.top, OSDTopChromeMetrics.topPadding)

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

    private var scanTopChrome: some View {
        OSDHeaderBar {
            if let twist = controller.lidarTwistGuidance {
                ScanPitchGuidancePill(guidance: twist)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 8) {
                OSDGearButton { showSettings = true }
                // Temporary: remove before App Store review.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        devMode.isDevMode.toggle()
                    }
                } label: {
                    Text(devMode.isDevMode ? L10n.devModeOn : L10n.prodModeOn)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(devMode.isDevMode ? OSDPalette.accentInk : OSDPalette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(devMode.isDevMode ? OSDPalette.accent : Color.white.opacity(0.12))
                        )
                        .overlay(
                            Capsule().strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(devMode.isDevMode ? L10n.devModeOn : L10n.prodModeOn)
            }
        }
    }

    @ViewBuilder
    private var scanBottomPanel: some View {
        switch controller.flowState {
        case .placingBall:
            OSDOnboardCard {
                stepPanel(
                    step: L10n.step1Label,
                    title: controller.pendingDetectedBall == nil ? L10n.step1Title : L10n.step1TitleConfirm,
                    body: ballPlacementBody,
                    button: ballPlacementButtonTitle,
                    action: controller.requestBallPlacement,
                    enabled: controller.meshReady
                ) {
                    if let lock = localizedBallLockLabel {
                        Text(lock)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OSDPalette.accent)
                    }
                    if !controller.meshReady {
                        HStack(spacing: 8) {
                            ProgressView().tint(OSDPalette.accent)
                            Text(
                                controller.sceneDepthReady
                                    ? L10n.depthReady(meshPoints: controller.meshVertexCount)
                                    : L10n.meshProgress(
                                        current: controller.meshVertexCount,
                                        threshold: ARScanSessionController.meshReadyVertexThreshold
                                    )
                            )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OSDPalette.textSecondary)
                        }
                    }
                }
            }
        case .walkingToHole:
            OSDOnboardCard {
                stepPanel(
                    step: L10n.step2Label,
                    title: L10n.step2Title,
                    body: L10n.step2Body,
                    button: L10n.arriveMarkHole,
                    action: controller.beginHolePlacement,
                    enabled: true
                ) {
                    EmptyView()
                }
            }
        case .placingHole:
            OSDOnboardCard {
                stepPanel(
                    step: L10n.step3Label,
                    title: L10n.step3Title,
                    body: L10n.step3Body,
                    button: L10n.markHoleCalculate,
                    action: controller.requestHolePlacement
                ) {
                    EmptyView()
                }
            }
        case .processing:
            OSDOnboardCard {
                ProgressView(L10n.processingHeightMap)
                    .font(.system(size: 12))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            OSDOnboardCard {
                stepPanel(
                    step: nil,
                    title: L10n.scanFailed,
                    body: L10n.localizedFailure(message),
                    button: L10n.startOver,
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
            Text(L10n.scanIdleHint)
                .font(.system(size: 12.5))
                .foregroundStyle(OSDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            if let accessNote = scanAccessNote {
                Text(accessNote)
                    .font(.system(size: 12))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            OSDPrimaryButton(
                title: controller.scanPipelineReady ? L10n.scanStart : L10n.lidarPreparing,
                enabled: controller.scanPipelineReady
            ) {
                if subscriptions.canStartGreenScan(freeRuns: freeRuns, devMode: devMode) {
                    controller.startScan()
                } else {
                    showSettings = true
                }
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var scanAccessNote: String? {
        if SubscriptionStore.temporarilyUnlockScanStart { return nil }
        if subscriptions.hasProAccess(devMode: devMode) { return nil }
        if freeRuns.balance > 0 {
            return L10n.settingsFreeRunsRemaining(freeRuns.balance)
        }
        return L10n.settingsNeedsSubscription
    }

    private var ballPlacementBody: String { L10n.step1Body }

    private var ballPlacementButtonTitle: String {
        guard controller.meshReady else { return L10n.groundPreparing }
        return L10n.placeBall
    }

    private var localizedBallLockLabel: String? {
        switch controller.visualBallLockStatus {
        case .idle:
            return nil
        case .waitingForView:
            return L10n.lockOnScreen
        case .searching:
            return L10n.lockDetecting
        case .candidate:
            return L10n.lockNeedsConfirm
        case .aligned:
            return L10n.lockMatched
        case .locked:
            return L10n.lockAligned
        }
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
                Text(L10n.trackingTip)
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    exportError = L10n.exportFailed(error.localizedDescription)
                }
            }
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
        // 실제 커버리지 리본 MeshResource까지 사전 컴파일 — 첫 스캔 격자 물결 히칭 제거.
        context.coordinator.brightMesh.prewarmRenderPipelines(in: view)
        // ARView에 session이 붙은 직후 워밍업(onAppear보다 앞서 cold start 단축).
        controller.prewarmSession()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.arView = uiView
        if sessionARView !== uiView {
            // Binding publish during updateUIView triggers the same SwiftUI warning.
            DispatchQueue.main.async {
                sessionARView = uiView
            }
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
        // Ring @Published updates run on DisplayLink only — never inside updateUIView.
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

    @MainActor
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
        private weak var ringOverlay: PlacementRingOverlayView?

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
            ringOverlay?.removeFromSuperview()
            ringOverlay = nil
        }

        private func ensureRingOverlay(in view: ARView) -> PlacementRingOverlayView {
            if let ringOverlay { return ringOverlay }
            let overlay = PlacementRingOverlayView(frame: view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(overlay)
            ringOverlay = overlay
            return overlay
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
                if let ball = controller.ballAnchor {
                    brightMesh.corridorBallXZ = SIMD2(ball.worldX, ball.worldZ)
                    brightMesh.corridorBallY = Float(ball.worldY)
                }
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
            let overlay = ensureRingOverlay(in: view)
            overlay.frame = view.bounds
            view.bringSubviewToFront(overlay)
            let frame = view.session.currentFrame
            let viewport = view.bounds.size
            overlay.ballPoints = controller.projectedBallGroundRing(frame: frame, viewport: viewport)
            overlay.holePoints = controller.projectedHoleGroundRing(frame: frame, viewport: viewport)
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
