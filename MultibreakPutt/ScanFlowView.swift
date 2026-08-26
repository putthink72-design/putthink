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

    var body: some View {
        Group {
            if controller.flowState == .complete,
               controller.completedScan != nil,
               !controller.needsBallReanchor {
                Gate55GuidanceView(controller: controller)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                scanExperience
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
            case .inactive, .background:
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

    private var scanExperience: some View {
        ZStack {
            PlacementARView(controller: controller)
                .ignoresSafeArea()

            if showsReticle {
                OSDAmberReticle(dashedRing: controller.flowState == .placingHole)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
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
                    } else if controller.flowState == .complete, controller.needsBallReanchor {
                        oneWayBallReanchorCard
                    } else if controller.flowState != .complete {
                        scanBottomPanel
                    }
                }
                .padding(.horizontal, OSDTopChromeMetrics.floatingCardHorizontalPadding)
                .padding(.bottom, OSDTopChromeMetrics.floatingCardBottomPadding)
            }
        }
    }

    /// STEP 2/3에서는 안내 카드가 있으므로 파란 placement 배너는 숨김.
    private var showsPlacementBanner: Bool {
        switch controller.flowState {
        case .behindBallSweep, .walkingToHole:
            return false
        default:
            return true
        }
    }

    private var showsTwistCards: Bool {
        switch controller.flowState {
        case .walkingToHole, .placingHole, .returningToBall, .processing:
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
        case .preparing:
            OSDOnboardCard {
                ProgressView("LiDAR와 AR 트래킹 준비 중…")
                    .font(.system(size: 12))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .placingBall:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 1 / 2",
                    title: "볼을 지정하세요",
                    body: controller.meshReady
                        ? "십자선을 실제 볼 중심에 맞춘 뒤 버튼을 누르세요."
                        : "바닥(볼 주변)을 향해 천천히 비추세요. 파란 격자가 보이면 지정할 수 있습니다.",
                    button: controller.meshReady ? "볼 지정" : "지면 준비 중…",
                    action: controller.requestBallPlacement,
                    enabled: controller.meshReady
                ) {
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
        case .behindBallSweep:
            // 레거시 상태 — 바로 걷기로 넘김.
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 2 / 2",
                    title: "홀까지 사선 스캔",
                    body: controller.lidarProfile.puttLineScreenHint,
                    button: "홀 방향 걷기로",
                    action: controller.finishBehindBallSweep,
                    enabled: true
                ) {
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
                        ? "십자선을 홀컵 앞 잔디(컵 중심)에 맞춘 뒤 지정하세요. 지정 직후 경로를 계산하고, 볼로 돌아가 실볼을 재지정합니다."
                        : "십자선을 홀컵 앞 잔디(컵 중심)에 맞춘 뒤 지정하세요. 지정 직후 경로를 계산·표시합니다.",
                    button: "홀 지정 · 바로 계산",
                    action: controller.requestHolePlacement
                ) {
                    referenceStatusCompact
                }
            }
        case .returningToBall:
            OSDOnboardCard {
                stepPanel(
                    step: nil,
                    title: "볼로 복귀",
                    body: "볼로 돌아온 뒤 스캔을 종료하세요.",
                    button: "스캔 종료 · 추천 계산",
                    action: controller.finishScan
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
                    action: controller.reset
                ) {
                    EmptyView()
                }
            }
        default:
            EmptyView()
        }
    }

    private var oneWayBallReanchorCard: some View {
        OSDOnboardCard {
            stepPanel(
                step: nil,
                title: "볼로 돌아가 재지정",
                body: "같은 AR 화면을 유지합니다. 실볼 중심에 십자선을 맞춘 뒤 재지정하세요. 홀·높이맵은 그대로입니다.",
                button: "볼 재지정",
                action: controller.requestBallReanchor
            ) {
                referenceStatusCompact
            }
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
                title: "스캔 시작",
                enabled: true
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
        case .preparing, .placingBall, .behindBallSweep, .walkingToHole, .placingHole, .returningToBall, .processing:
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
        case .behindBallSweep, .walkingToHole:
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
        let region = selectedRegion
        Task.detached(priority: .utility) {
            do {
                let outcome = try ScanExporter.export(scan: scan, region: region)
                await MainActor.run {
                    diagnostics = outcome.diagnostics
                    exportURL = outcome.directory
                    exportError = nil
                }
            } catch {
                await MainActor.run {
                    exportError = "내보내기 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    private func clearScanHistory() {
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
}

// MARK: - AR view with raycast + markers

private struct PlacementARView: UIViewRepresentable {
    @ObservedObject var controller: ARScanSessionController

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
        context.coordinator.attachDisplayLink(controller: controller)
        // 머티리얼 셰이더를 미리 컴파일 — 첫 메시 표시 히칭 제거.
        context.coordinator.brightMesh.prewarmRenderPipelines(in: view)
        // ARView에 session이 붙은 직후 워밍업(onAppear보다 앞서 cold start 단축).
        controller.prewarmSession()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.arView = uiView
        context.coordinator.controller = controller
        context.coordinator.lineWidthPixels = 2
        uiView.debugOptions.remove(.showSceneUnderstanding)
        if controller.meshVisualizationAllowed {
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
        context.coordinator.syncMarkers(
            in: uiView,
            session: controller.session,
            ball: controller.ballAnchor,
            hole: controller.holeAnchor
        )
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
        private var ballARAnchor: ARAnchor?
        private var holeARAnchor: ARAnchor?

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
            } else {
                brightMesh.corridorBallXZ = nil
            }
            if let hole = controller.holeAnchor {
                brightMesh.corridorHoleXZ = SIMD2(hole.worldX, hole.worldZ)
            } else {
                brightMesh.corridorHoleXZ = nil
            }
            brightMesh.update(in: view)
        }

        func syncMarkers(
            in view: ARView,
            session: ARSession,
            ball: ScanPose?,
            hole: ScanPose?
        ) {
            if let ball {
                if ballAnchorEntity == nil {
                    let world = SIMD3<Float>(Float(ball.worldX), Float(ball.worldY), Float(ball.worldZ))
                    ARReferenceMarkers.placeWorldLocked(
                        named: "trueputt.ball",
                        entityFactory: { ARReferenceMarkers.makeBallEntity() },
                        at: world,
                        session: session,
                        in: view,
                        existingEntity: &ballAnchorEntity,
                        existingARAnchor: &ballARAnchor
                    )
                }
            } else {
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &ballAnchorEntity,
                    existingARAnchor: &ballARAnchor
                )
            }

            if let hole {
                if holeAnchorEntity == nil {
                    let world = SIMD3<Float>(Float(hole.worldX), Float(hole.worldY), Float(hole.worldZ))
                    ARReferenceMarkers.placeWorldLocked(
                        named: "trueputt.hole",
                        entityFactory: { ARReferenceMarkers.makeHoleEntity() },
                        at: world,
                        session: session,
                        in: view,
                        existingEntity: &holeAnchorEntity,
                        existingARAnchor: &holeARAnchor
                    )
                }
            } else {
                ARReferenceMarkers.removeWorldLocked(
                    session: session,
                    in: view,
                    existingEntity: &holeAnchorEntity,
                    existingARAnchor: &holeARAnchor
                )
            }
        }
    }
}
