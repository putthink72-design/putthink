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
    @State private var showClearHistoryConfirmation = false
    /// 앱 진입 전 사용자 밝기 — 나갈 때 복원.
    @State private var savedBrightness: CGFloat?
    @State private var showPerformanceSettings = false

    var body: some View {
        Group {
            if controller.flowState == .complete, controller.completedScan != nil {
                Gate55GuidanceView(controller: controller)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ZStack {
                    PlacementARView(controller: controller)
                        .ignoresSafeArea()

                    // 중앙 십자선 — 볼/홀 기준점 조준용
                    if showsReticle {
                        CenterReticle()
                            .allowsHitTesting(false)
                    }

                    // 게이트 6 섀도 후보 오버레이 (탭해도 앵커에 반영되지 않음)
                    if showsReticle, let shadow = controller.gate6Shadow {
                        GeometryReader { geo in
                            Gate6ShadowOverlay(observation: shadow)
                                .onAppear { controller.updateGate6Viewport(geo.size) }
                                .onChange(of: geo.size) { _, size in
                                    controller.updateGate6Viewport(size)
                                }
                        }
                        .allowsHitTesting(false)
                    }

                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    VStack(spacing: 12) {
                        trackingHeader
                        if showsCoverageUI {
                            coverageBanner
                        }
                        if let message = controller.placementMessage {
                            Text(message)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(.blue.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let shadow = controller.gate6Shadow, showsReticle {
                            Text(shadow.statusLine)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(.purple.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                            Text("섀도 모드 — 자동 좌표는 볼·홀 기준으로 사용하지 않습니다")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        referenceStatusBanner
                        flowPanel
                    }
                    .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            applyBrightnessPolicy()
            UIApplication.shared.isIdleTimerDisabled = true
            // 카메라 프리뷰만 — LiDAR는 스캔 시작 버튼에서 가동
            controller.prewarmCameraPreview()
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
                controller.prewarmCameraPreview()
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
        .alert("저장된 스캔 기록을 초기화할까요?", isPresented: $showClearHistoryConfirmation) {
            Button("취소", role: .cancel) {}
            Button("모두 삭제", role: .destructive, action: clearScanHistory)
        } message: {
            Text("실내 측정값을 포함한 모든 진단 파일이 삭제되며, 최근 3회 RMS는 다음 스캔부터 새로 계산됩니다.")
        }
        .sheet(isPresented: $showPerformanceSettings) {
            PerformanceSettingsView()
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

    private var trackingHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(controller.trackingLimited ? .orange : .green)
                    .frame(width: 10, height: 10)
                Text("트래킹 \(controller.trackingDescription)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showPerformanceSettings = true
                } label: {
                    Image(systemName: "thermometer.medium")
                }
                .accessibilityLabel("성능·발열 설정")
                Text("메시 \(controller.meshVertexCount.formatted())점")
                    .font(.caption.monospacedDigit())
            }
            if controller.trackingLimited {
                Text("천천히 움직이고 잔디의 특징이 보이도록 카메라 방향을 조정하세요.")
                    .font(.caption)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                .tint(.white)

            Text(controller.coverageQualityMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var referenceStatusBanner: some View {
        if controller.ballAnchor != nil || controller.holeAnchor != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("기준점: AR 지면 raycast (카메라 위치 아님)")
                    .font(.caption2.weight(.semibold))
                if let ball = controller.ballAnchor {
                    Text(
                        String(
                            format: "볼 (%.2f, %.2f, %.2f)",
                            ball.worldX, ball.worldY, ball.worldZ
                        )
                    )
                    .font(.caption2.monospacedDigit())
                }
                if let hole = controller.holeAnchor {
                    Text(
                        String(
                            format: "홀 (%.2f, %.2f, %.2f)",
                            hole.worldX, hole.worldY, hole.worldZ
                        )
                    )
                    .font(.caption2.monospacedDigit())
                }
                if let distance = controller.currentHoleDistance {
                    Text(String(format: "볼→홀 %.2f m", distance))
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var flowPanel: some View {
        switch controller.flowState {
        case .idle:
            instructionPanel(
                title: "볼·홀 기준점 스캔",
                message: "실제 볼과 홀컵 중심에 화면 중앙 십자선을 맞춰 지정합니다. 카메라 위치가 아니라 지면 좌표가 기준입니다.",
                buttonTitle: "스캔 시작",
                action: {
                    // 버튼 하이라이트가 먼저 그려진 뒤 시작 (체감 응답성)
                    Task { @MainActor in
                        await Task.yield()
                        controller.startScan()
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("스캔 경로")
                        .font(.caption.weight(.semibold))
                    Picker("스캔 경로", selection: $controller.pathMode) {
                        ForEach(ScanPathMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(controller.pathMode.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("스무딩 σ: \(controller.sigma, specifier: "%.2f")셀")
                        .font(.caption)
                    Slider(value: $controller.sigma, in: 0.5...3, step: 0.25)

                    Button(role: .destructive) {
                        showClearHistoryConfirmation = true
                    } label: {
                        Label("저장된 스캔 기록 초기화", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if let exportError {
                        Text(exportError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        case .preparing:
            // 레거시 경로 — startScan은 바로 placingBall로 감
            ProgressView("LiDAR와 AR 트래킹 준비 중…")
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .placingBall:
            instructionPanel(
                title: "1. 볼 기준점 지정",
                message: controller.meshReady
                    ? "십자선을 실제 골프공 중심에 맞춘 뒤 버튼을 누르세요. 흰 구 마커가 그 지점에 고정됩니다."
                    : "LiDAR 메시를 생성하는 중입니다. 폰을 바닥 쪽으로 향하고 천천히 좌우로 움직이세요.",
                buttonTitle: controller.meshReady ? "볼 기준점 지정" : "메시 준비 중…",
                action: controller.requestBallPlacement,
                enabled: controller.meshReady
            ) {
                if !controller.meshReady {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("메시 \(controller.meshVertexCount.formatted())점 수집 중")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .walkingToHole:
            instructionPanel(
                title: "2. 홀까지 스캔",
                message: "바닥 메시가 이어지도록 천천히 홀까지 걸어가세요. 도착하면 홀컵을 지정합니다.",
                buttonTitle: "홀에 도착 · 홀 지정으로",
                action: controller.beginHolePlacement
            )
        case .placingHole:
            instructionPanel(
                title: "3. 홀 기준점 지정",
                message: controller.pathMode == .oneWay
                    ? "십자선을 홀컵 중심에 맞춘 뒤 지정하세요. 편도 모드라 지정 직후 바로 계산합니다(드리프트 미보정)."
                    : "십자선을 실제 홀컵 중심에 맞춘 뒤 버튼을 누르세요. 깃대 마커가 고정됩니다.",
                buttonTitle: controller.pathMode == .oneWay
                    ? "홀 지정 · 바로 계산"
                    : "홀 기준점 지정",
                action: controller.requestHolePlacement
            )
        case .returningToBall:
            instructionPanel(
                title: "4. 볼로 복귀",
                message: "같은 경로를 따라 돌아온 뒤 스캔을 종료하세요. 왕복으로 드리프트를 보정합니다.",
                buttonTitle: "스캔 종료 · 추천 계산",
                action: controller.finishScan
            )
        case .processing:
            ProgressView("5cm 높이맵 처리 중…")
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .complete:
            EmptyView()
        case .failed(let message):
            instructionPanel(
                title: "스캔 실패",
                message: message,
                buttonTitle: "처음부터 다시",
                action: controller.reset
            )
        }
    }

    private func instructionPanel<Content: View>(
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void,
        enabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!enabled)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func instructionPanel(
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void,
        enabled: Bool = true
    ) -> some View {
        instructionPanel(
            title: title,
            message: message,
            buttonTitle: buttonTitle,
            action: action,
            enabled: enabled
        ) {
            EmptyView()
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

    /// 설정이 켜져 있을 때만 최대 밝기. 기본은 off.
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

// MARK: - Gate 6 shadow overlay (표시 전용)

private struct Gate6ShadowOverlay: View {
    let observation: Gate6ShadowObservation

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(observation.displayCandidates.enumerated()), id: \.offset) { _, candidate in
                    Circle()
                        .strokeBorder(
                            candidate.depthAccepted ? Color.cyan : Color.yellow.opacity(0.85),
                            lineWidth: candidate.depthAccepted ? 2.5 : 1.5
                        )
                        .frame(
                            width: max(22, candidate.radiusNorm * geo.size.width * 2.8),
                            height: max(22, candidate.radiusNorm * geo.size.width * 2.8)
                        )
                        .position(
                            x: candidate.viewNormalizedX * geo.size.width,
                            y: candidate.viewNormalizedY * geo.size.height
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reticle

private struct CenterReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.green.opacity(0.9), lineWidth: 2)
                .frame(width: 44, height: 44)
            Rectangle()
                .fill(Color.green.opacity(0.9))
                .frame(width: 2, height: 28)
            Rectangle()
                .fill(Color.green.opacity(0.9))
                .frame(width: 28, height: 2)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
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
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.arView = uiView
        context.coordinator.controller = controller
        context.coordinator.lineWidthPixels = 2
        // 메시 시각화는 LiDAR 가동 직후 유예 뒤 (시작 버튼 행업 완화)
        if controller.meshVisualizationAllowed {
            context.coordinator.meshEnabled = true
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
            // updateUIView 사이클 밖에서 raycast → @Published 갱신
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
        var lineWidthPixels: Float = 2
        private var displayLink: CADisplayLink?
        private var lastMeshTick: CFTimeInterval = 0
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

        @objc private func onDisplayLink(_ link: CADisplayLink) {
            guard meshEnabled, let controller, let view = arView else { return }
            guard link.timestamp - lastMeshTick >= 0.08 else { return }
            lastMeshTick = link.timestamp
            brightMesh.setEnabled(true, in: view)
            brightMesh.lineWidthPixels = lineWidthPixels
            brightMesh.coverageSnapshot = controller.meshCoverageSnapshot
            brightMesh.update(in: view)
        }

        /// 지정 위치에 한 번만 고정. 매 프레임 좌표를 덮어쓰지 않아 카메라 따라가지 않음.
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
            // 같은 요청을 updateUIView마다 반복 처리하지 않음
            guard lastHandledRequest != kind else { return }
            lastHandledRequest = kind

            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard view.bounds.width > 1, view.bounds.height > 1 else {
                // 레이아웃 전이 — 다음 프레임에서 재시도
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
                // existingPlane / mesh 재시도
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
