import ARKit
import PuttPhysicsKit
import RealityKit
import SwiftUI
import UIKit

struct ScanFlowView: View {
    @StateObject private var controller = ARScanSessionController()
    @Environment(\.scenePhase) private var scenePhase
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
                    exportError: $exportError
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

            if !controller.holeGroundRingPoints.isEmpty {
                HoleCupRingOverlay(points: controller.holeGroundRingPoints)
                    .ignoresSafeArea()
            }

            if controller.flowState == .placingBall, !controller.ballGroundRingPoints.isEmpty {
                BallGroundRingOverlay(points: controller.ballGroundRingPoints)
                    .ignoresSafeArea()
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
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private var scanBottomPanel: some View {
        switch controller.flowState {
        case .placingBall:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 1 / 3",
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
                }
            }
        case .walkingToHole:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 2 / 3",
                    title: "홀까지 사선 스캔",
                    body: "그린을 약 40°(추천 30°–40°) 내외로 비추며 흰색매시가 생성되도록 걸으세요. 홀이 가까우면 바로 홀을 지정해도 됩니다.",
                    button: "홀 도착 · 홀 지정",
                    action: controller.beginHolePlacement,
                    enabled: true
                ) {
                    EmptyView()
                }
            }
        case .placingHole:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 3 / 3",
                    title: "홀을 지정하세요",
                    body: "화면 중앙의 홀컵 사이즈 원을 홀의 중심에 맞춘 뒤 지정하세요. 지정 직후 퍼팅경로가 계산됩니다.",
                    button: "홀지정 · 퍼팅경로 계산",
                    action: controller.requestHolePlacement
                ) {
                    EmptyView()
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
            Text("볼과 홀을 지정하고 그린을 스캔하면 홀인경로와 퍼팅방향을 안내합니다.")
                .font(.system(size: 12.5))
                .foregroundStyle(OSDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            OSDPrimaryButton(
                title: controller.scanPipelineReady ? "그린 스캔 시작" : "LiDAR 준비 중…",
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
        "십자선 중심에 볼을 맞추면 자동으로 볼을 찾습니다. 볼 없이도 십자선 지면을 직접 지정할 수 있습니다."
    }

    private var ballPlacementButtonTitle: String {
        guard controller.meshReady else { return "지면 준비 중…" }
        return "볼 지정"
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
                    exportError = "내보내기 실패: \(error.localizedDescription)"
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
