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
            if controller.flowState == .complete, controller.completedScan != nil {
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
                controller.prewarmSession()
            case .inactive, .background:
                restoreBrightness()
                UIApplication.shared.isIdleTimerDisabled = false
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

            VStack(spacing: 0) {
                scanTopChrome
                    .padding(.horizontal, OSDTopChromeMetrics.horizontalPadding)
                    .padding(.top, OSDTopChromeMetrics.topPadding)

                if showsCoverageUI {
                    coverageBanner
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                if let message = controller.placementMessage {
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
                        : "바닥(볼 주변)을 향해 천천히 좌우로 비추세요. 가까운 지면 메시가 쌓이면 지정할 수 있습니다.",
                    button: controller.meshReady ? "볼 지정" : "메시 준비 중…",
                    action: controller.requestBallPlacement,
                    enabled: controller.meshReady
                ) {
                    if !controller.meshReady {
                        HStack(spacing: 8) {
                            ProgressView().tint(OSDPalette.accent)
                            Text("메시 \(controller.meshVertexCount.formatted()) / \(ARScanSessionController.meshReadyVertexThreshold)점")
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
                    title: "홀까지 스캔하세요",
                    body: "바닥 메시가 이어지도록 천천히 홀까지 걸어가세요.",
                    button: "홀 도착 · 홀 지정",
                    action: controller.beginHolePlacement
                ) {
                    referenceStatusCompact
                }
            }
        case .placingHole:
            OSDOnboardCard {
                stepPanel(
                    step: "STEP 2 / 2",
                    title: "홀을 지정하세요",
                    body: controller.pathMode == .oneWay
                        ? "십자선을 홀컵 중심에 맞춘 뒤 지정하세요. 편도 모드라 지정 직후 바로 계산합니다."
                        : "십자선을 실제 홀컵 중심에 맞춘 뒤 버튼을 누르세요.",
                    button: controller.pathMode == .oneWay ? "홀 지정 · 바로 계산" : "홀 기준점 지정",
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
                    body: "같은 경로를 따라 돌아온 뒤 스캔을 종료하세요. 왕복으로 드리프트를 보정합니다.",
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

    private var idleOnboardCard: some View {
        OSDOnboardCard {
            Text("볼과 홀컵 사이의 그린을 스캔하면\n퍼팅 경로를 안내합니다.")
                .font(.system(size: 12.5))
                .foregroundStyle(OSDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            if !controller.scanStartReady {
                HStack(spacing: 8) {
                    ProgressView().tint(OSDPalette.accent)
                    Text("LiDAR 준비 중…")
                        .font(.caption)
                        .foregroundStyle(OSDPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
            OSDPrimaryButton(
                title: "스캔 시작",
                enabled: controller.scanStartReady
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
        default:
            return false
        }
    }

    private var showsCoverageUI: Bool {
        switch controller.flowState {
        case .preparing, .placingBall, .walkingToHole, .placingHole, .returningToBall, .processing:
            return true
        default:
            return false
        }
    }

    private var coverageBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("파랑(선+면)=추가 스캔", systemImage: "square.grid.3x3.fill")
                    .foregroundStyle(Color.blue)
                Label("흰 선=완료", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.white)
                Spacer()
            }
            .font(.caption2.weight(.semibold))

            Text(controller.coverageSnapshot.statusLine)
                .font(.caption.monospacedDigit().weight(.semibold))

            ProgressView(value: controller.coverageSnapshot.stableRatio)
                .tint(OSDPalette.accent)

            Text(controller.coverageQualityMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))

            Text("스캔 모드: \(ScanFieldSettings.fieldMode.label) · \(ScanFieldSettings.fieldMode.settingsDetail)")
                .font(.caption2)
                .foregroundStyle(OSDPalette.textTertiary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OSDPalette.glassStrong, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
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
        do {
            let outcome = try ScanExporter.export(scan: scan, region: selectedRegion)
            diagnostics = outcome.diagnostics
            exportURL = outcome.directory
            exportError = nil
        } catch {
            exportError = "내보내기 실패: \(error.localizedDescription)"
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
            context.coordinator.meshEnabled = false
            context.coordinator.brightMesh.setEnabled(false, in: uiView)
        }
        context.coordinator.syncMarkers(
            in: uiView,
            session: controller.session,
            ball: controller.ballAnchor,
            hole: controller.holeAnchor
        )
        if let request = controller.placementRequest {
            let coordinator = context.coordinator
            let sessionController = controller
            DispatchQueue.main.async {
                coordinator.performCenterRaycast(
                    in: uiView,
                    kind: request,
                    controller: sessionController
                )
            }
        }
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
        private var lastHandledRequest: PlacementKind?

        func attachDisplayLink(controller: ARScanSessionController) {
            self.controller = controller
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
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
                    ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
                    : CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
                burstRateApplied = burst
            }
            // 숨김 워밍업은 여유 있게, 첫 공개 burst는 촘촘히 갱신.
            let tickInterval: TimeInterval = meshHidden ? 0.12 : (burst ? 0.04 : 0.08)
            guard link.timestamp - lastMeshTick >= tickInterval else { return }
            lastMeshTick = link.timestamp
            brightMesh.setEnabled(true, in: view)
            brightMesh.contentHidden = meshHidden
            brightMesh.lineWidthPixels = lineWidthPixels
            brightMesh.burstMode = burst
            brightMesh.coverageSnapshot = controller.meshCoverageSnapshot
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

        func performCenterRaycast(
            in view: ARView,
            kind: PlacementKind,
            controller: ARScanSessionController
        ) {
            guard lastHandledRequest != kind else { return }
            lastHandledRequest = kind

            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard view.bounds.width > 1, view.bounds.height > 1 else {
                lastHandledRequest = nil
                return
            }

            let results = view.raycast(
                from: center,
                allowing: .estimatedPlane,
                alignment: .any
            )
            if let hit = results.first {
                let t = hit.worldTransform.columns.3
                let timestamp = view.session.currentFrame?.timestamp ?? Date().timeIntervalSince1970
                controller.applyRaycastHit(
                    worldX: Double(t.x),
                    worldY: Double(t.y),
                    worldZ: Double(t.z),
                    timestamp: timestamp
                )
                lastHandledRequest = nil
            } else {
                let meshResults = view.raycast(
                    from: center,
                    allowing: .existingPlaneGeometry,
                    alignment: .any
                )
                if let hit = meshResults.first {
                    let t = hit.worldTransform.columns.3
                    let timestamp = view.session.currentFrame?.timestamp
                        ?? Date().timeIntervalSince1970
                    controller.applyRaycastHit(
                        worldX: Double(t.x),
                        worldY: Double(t.y),
                        worldZ: Double(t.z),
                        timestamp: timestamp
                    )
                    lastHandledRequest = nil
                } else {
                    controller.reportRaycastFailure(
                        "지면을 찾지 못했습니다. 십자선을 잔디/바닥에 맞추고 다시 시도하세요."
                    )
                    lastHandledRequest = nil
                }
            }
        }
    }
}
