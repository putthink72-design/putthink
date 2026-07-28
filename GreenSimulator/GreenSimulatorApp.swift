import Combine
import PuttPhysicsKit
import SceneKit
import SwiftUI

@main
struct GreenSimulatorApp: App {
    init() {
        GreenSimulatorSnapshotExporter.exportIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            GreenSimulatorRootView()
        }
    }
}

@MainActor
final class GreenSimulatorModel: ObservableObject {
    enum PlacementMode {
        case none
        case ball
        case hole
    }

    struct RecommendationSummary: Equatable {
        var statusText: String
        var primary: RankedPuttCandidate?
        var secondary: RankedPuttCandidate?
        var primaryGuide: PuttGuide?
        var secondaryGuide: PuttGuide?
        var elevationDelta: Double
        var alignment: GreenAlignment?
        var terrain: HeightMapTerrainField?
        var primaryTrajectoryWorld: [PuttVector2]
        var passedOver: Bool
    }

    struct PuttGuide: Equatable {
        var flatEquivalentDistance: Double
        var distanceAdjustment: Double
        var initialVelocity: Double
        var directionDegrees: Double
        var stopPosition: PuttVector2
        var overrunDistance: Double
    }

    @Published var greenIDs: [String] = []
    @Published var selectedGreenID: String = ""
    @Published var placementMode: PlacementMode = .none
    @Published var statusMessage = "그린을 선택한 뒤 볼과 홀을 배치하세요."
    @Published var recommendation: RecommendationSummary?
    @Published var isComputing = false
    @Published var slowMotion = false
    @Published var isAnimating = false
    /// +1 확대, −1 축소. SceneKitTapView가 소비 후 0으로 리셋.
    @Published var cameraZoomRequest: Int = 0
    @Published var colorMode: GreenColorMode = .elevation
    private(set) var cameraOrbitTarget = SCNVector3(0, 0, 0)
    private(set) var cameraOrbitRevision = 0

    let scene = SCNScene()
    private(set) var displayModel: GreenDisplayModel?
    private var ballNode: SCNNode?
    private var holeNode: SCNNode?
    private var trajectoryNode: SCNNode?
    private var animatedBallNode: SCNNode?
    private var ballWorld: PuttVector2?
    private var holeWorld: PuttVector2?
    private let greenSpeed = 2.5

    init() {
        configureScene()
        greenIDs = Self.loadGreenIDs()
        if let first = greenIDs.first {
            selectedGreenID = first
            loadSelectedGreen()
        }
    }

    func selectGreen(_ id: String) {
        selectedGreenID = id
        clearPlacement()
        loadSelectedGreen()
    }

    func setPlacementMode(_ mode: PlacementMode) {
        placementMode = mode
        switch mode {
        case .ball:
            statusMessage = "지형을 탭해 볼을 배치하세요."
        case .hole:
            statusMessage = "지형을 탭해 홀을 배치하세요."
        case .none:
            break
        }
    }

    func handleTap(scenePoint: SCNVector3) {
        guard let model = displayModel else { return }
        let world = GreenSceneBuilder.worldPoint(scene: scenePoint, model: model)
        let point = PuttVector2(x: world.x, y: world.y)
        guard GreenSceneBuilder.isValidWorldPoint(point, green: model.green) else {
            statusMessage = "유효한 그린 영역 밖입니다. 다시 탭하세요."
            return
        }

        switch placementMode {
        case .ball:
            placeBall(at: point)
            placementMode = .none
        case .hole:
            placeHole(at: point)
            placementMode = .none
        case .none:
            statusMessage = "먼저 ‘볼 놓기’ 또는 ‘홀 놓기’를 선택하세요."
        }
    }

    func putt() {
        guard let recommendation,
              let primary = recommendation.primary,
              let alignment = recommendation.alignment,
              let model = displayModel,
              !recommendation.primaryTrajectoryWorld.isEmpty else {
            statusMessage = "추천 결과가 없어 퍼팅할 수 없습니다."
            return
        }
        animateTrajectory(
            worldPoints: recommendation.primaryTrajectoryWorld,
            holeIn: primary.candidate.result.ballHoleIf == 1,
            passedOver: recommendation.passedOver,
            model: model,
            alignment: alignment
        )
    }

    private func configureScene() {
        scene.background.contents = UIColor(red: 0.08, green: 0.1, blue: 0.12, alpha: 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 500
        camera.position = SCNVector3(0, 18, 22)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 900
        light.eulerAngles = SCNVector3(-0.9, 0.4, 0)
        scene.rootNode.addChildNode(light)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)
    }

    private func loadSelectedGreen() {
        guard let url = Bundle.main.url(
            forResource: "\(selectedGreenID).grnh",
            withExtension: "gz",
            subdirectory: "samples_all36"
        ) ?? Bundle.main.url(forResource: "\(selectedGreenID).grnh", withExtension: "gz") else {
            statusMessage = "그린 파일을 찾지 못했습니다: \(selectedGreenID)"
            return
        }
        do {
            let green = try GreenHeightmapLoader.load(from: url)
            let model = try GreenSceneBuilder.makeDisplayModel(from: green, colorMode: colorMode)
            displayModel?.node.removeFromParentNode()
            displayModel = model
            scene.rootNode.addChildNode(model.node)
            fitCamera(to: model)
            statusMessage = "\(selectedGreenID) 로드 완료. relief \(String(format: "%.2f", green.reliefMeters))m"
        } catch {
            statusMessage = "로드 실패: \(error.localizedDescription)"
        }
    }

    /// 색 모드만 바꾸고 볼·홀·추천 상태는 유지한 채 메시만 다시 칠한다.
    func setColorMode(_ mode: GreenColorMode) {
        guard mode != colorMode else { return }
        colorMode = mode
        guard let current = displayModel else { return }
        do {
            let model = try GreenSceneBuilder.makeDisplayModel(
                from: current.green,
                colorMode: mode
            )
            current.node.removeFromParentNode()
            displayModel = model
            scene.rootNode.addChildNode(model.node)
            redrawPlacementNodes()
        } catch {
            statusMessage = "색 모드 변경 실패: \(error.localizedDescription)"
        }
    }

    /// 메시 노드가 교체된 뒤 볼·홀·궤적 노드를 현재 상태에 맞춰 다시 그린다.
    private func redrawPlacementNodes() {
        if let ballWorld {
            placeBall(at: ballWorld, recompute: false)
        }
        if let holeWorld {
            placeHole(at: holeWorld, recompute: false)
        }
        if let recommendation {
            drawTrajectoryPreview(recommendation)
        }
    }

    private func fitCamera(to model: GreenDisplayModel) {
        let width = Double(model.smoothed.width - 1) * model.smoothed.cellSize
        let depth = Double(model.smoothed.height - 1) * model.smoothed.cellSize
        let center = SCNVector3(Float(width * 0.5), 0, Float(depth * 0.5))
        if let camera = scene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            let distance = Float(max(width, depth) * 1.2)
            camera.position = SCNVector3(center.x, distance * 0.7, center.z + distance * 0.8)
            camera.look(at: center)
            cameraOrbitTarget = center
            cameraOrbitRevision += 1
        }
    }

    private func placeBall(at point: PuttVector2, recompute: Bool = true) {
        guard let model = displayModel else { return }
        ballWorld = point
        ballNode?.removeFromParentNode()
        let node = GreenSceneBuilder.makeBallNode()
        let height = GreenSceneBuilder.height(atWorld: point, model: model)
        node.position = GreenSceneBuilder.scenePoint(
            worldX: point.x,
            worldY: point.y,
            height: height,
            model: model
        )
        scene.rootNode.addChildNode(node)
        ballNode = node
        if recompute {
            statusMessage = "볼 배치 완료."
            recomputeIfReady()
        }
    }

    private func placeHole(at point: PuttVector2, recompute: Bool = true) {
        guard let model = displayModel else { return }
        holeWorld = point
        holeNode?.removeFromParentNode()
        let node = GreenSceneBuilder.makeHoleNode()
        let height = GreenSceneBuilder.height(atWorld: point, model: model)
        node.position = SCNVector3(
            point.x - model.sceneOriginX,
            height - model.heightOffset + 0.005,
            point.y - model.sceneOriginZ
        )
        scene.rootNode.addChildNode(node)
        holeNode = node
        if recompute {
            statusMessage = "홀 배치 완료."
            recomputeIfReady()
        }
    }

    private func clearPlacement() {
        ballWorld = nil
        holeWorld = nil
        recommendation = nil
        ballNode?.removeFromParentNode()
        holeNode?.removeFromParentNode()
        trajectoryNode?.removeFromParentNode()
        animatedBallNode?.removeFromParentNode()
        ballNode = nil
        holeNode = nil
        trajectoryNode = nil
        animatedBallNode = nil
        isAnimating = false
    }

    private func recomputeIfReady() {
        guard let ballWorld, let holeWorld, displayModel != nil else { return }
        isComputing = true
        statusMessage = "추천 계산 중…"
        let greenSpeed = self.greenSpeed
        Task.detached(priority: .userInitiated) {
            do {
                let greenID = await MainActor.run { self.selectedGreenID }
                let greenURL = try GreenSimText.greenURL(id: greenID)
                let green = try GreenHeightmapLoader.load(from: greenURL)
                let (alignment, terrain) = try GreenAligner.makeTerrainField(
                    from: green,
                    ballWorld: ballWorld,
                    holeWorld: holeWorld
                )
                let selection = CandidateSelector.select(
                    terrain: terrain,
                    greenSpeed: greenSpeed,
                    holeDistance: alignment.holeDistance,
                    minimumVelocity: 1.2,
                    maximumVelocity: 5.0,
                    velocityPointCount: 36,
                    minimumDirectionDegrees: -35,
                    maximumDirectionDegrees: 35,
                    directionPointCount: 36
                )
                let elevationDelta =
                    terrain.height(at: PuttVector2(x: 0, y: alignment.holeDistance))
                    - terrain.height(at: PuttVector2(x: 0, y: 0))
                let primaryGuide = selection.primary.map {
                    GreenSimMetrics.guide(
                        for: $0,
                        greenSpeed: greenSpeed,
                        holeDistance: alignment.holeDistance
                    )
                }
                let secondaryGuide = selection.secondary.map {
                    GreenSimMetrics.guide(
                        for: $0,
                        greenSpeed: greenSpeed,
                        holeDistance: alignment.holeDistance
                    )
                }

                var primaryTrajectoryWorld: [PuttVector2] = []
                var passedOver = false
                if let primary = selection.primary {
                    let result = MultibreakPuttPhysics.simulate(
                        configuration: MultibreakPuttConfiguration(
                            greenSpeed: greenSpeed,
                            initialVelocity: primary.candidate.initialVelocity,
                            initialDirectionDegrees: primary.candidate.directionDegrees,
                            holeDistance: alignment.holeDistance,
                            holeDirectionDegrees: 0
                        ),
                        terrain: terrain,
                        recordTrajectory: true,
                        captureRadius: primary.usedRelaxedCaptureRadius ? 0.5 : 0.054
                    )
                    primaryTrajectoryWorld = result.trajectory.map {
                        alignment.world(local: $0.position)
                    }
                    passedOver = result.ballPassOverHoleIf == 1
                }

                let summary = RecommendationSummary(
                    statusText: GreenSimText.status(for: selection),
                    primary: selection.primary,
                    secondary: selection.secondary,
                    primaryGuide: primaryGuide,
                    secondaryGuide: secondaryGuide,
                    elevationDelta: elevationDelta,
                    alignment: alignment,
                    terrain: terrain,
                    primaryTrajectoryWorld: primaryTrajectoryWorld,
                    passedOver: passedOver
                )
                await MainActor.run {
                    self.recommendation = summary
                    self.isComputing = false
                    self.statusMessage = summary.statusText
                    self.drawTrajectoryPreview(summary)
                }
            } catch {
                await MainActor.run {
                    self.isComputing = false
                    self.statusMessage = "계산 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    private func drawTrajectoryPreview(_ summary: RecommendationSummary) {
        guard let model = displayModel else { return }
        trajectoryNode?.removeFromParentNode()
        let color: UIColor = summary.passedOver
            ? .systemYellow
            : .systemGreen
        let node = GreenSceneBuilder.makeTrajectoryNode(
            worldPoints: summary.primaryTrajectoryWorld,
            model: model,
            color: color
        )
        scene.rootNode.addChildNode(node)
        trajectoryNode = node
    }

    private func animateTrajectory(
        worldPoints: [PuttVector2],
        holeIn: Bool,
        passedOver: Bool,
        model: GreenDisplayModel,
        alignment: GreenAlignment
    ) {
        animatedBallNode?.removeFromParentNode()
        let node = GreenSceneBuilder.makeBallNode()
        scene.rootNode.addChildNode(node)
        animatedBallNode = node
        isAnimating = true

        let speedScale = slowMotion ? 0.3 : 1.0
        let dt = 0.01 / speedScale
        var actions: [SCNAction] = []
        for point in worldPoints {
            let height = GreenSceneBuilder.height(atWorld: point, model: model)
            let position = GreenSceneBuilder.scenePoint(
                worldX: point.x,
                worldY: point.y,
                height: height,
                model: model
            )
            actions.append(.move(to: position, duration: dt))
        }
        if holeIn {
            actions.append(.scale(to: 0.05, duration: 0.2))
            actions.append(.fadeOut(duration: 0.15))
        }
        actions.append(.run { [weak self] _ in
            Task { @MainActor in
                self?.isAnimating = false
                self?.statusMessage = holeIn
                    ? "홀인"
                    : (passedOver ? "홀 통과(미진입)" : "정지")
            }
        })
        node.runAction(.sequence(actions))
        _ = alignment
    }

    private static func loadGreenIDs() -> [String] {
        GreenSimText.loadGreenIDs()
    }
}

enum GreenSimText {
    static func status(for selection: CandidateSelectionResult) -> String {
        if selection.allCandidates.isEmpty {
            return selection.usedRelaxedCaptureRadius
                ? "반경 완화 재계산 후에도 후보 없음"
                : "후보 없음"
        }
        if selection.usedRelaxedCaptureRadius {
            return "반경 완화 재계산 결과 \(selection.allCandidates.count)개 확보"
        }
        return "후보 \(selection.allCandidates.count)개"
    }

    static func loadGreenIDs() -> [String] {
        let urls =
            Bundle.main.urls(forResourcesWithExtension: "gz", subdirectory: "samples_all36")
            ?? Bundle.main.urls(forResourcesWithExtension: "gz", subdirectory: nil)
            ?? []
        return urls
            .map(\.lastPathComponent)
            .compactMap { name -> String? in
                guard name.hasSuffix(".grnh.gz") else { return nil }
                return String(name.dropLast(".grnh.gz".count))
            }
            .sorted()
    }

    static func greenURL(id: String) throws -> URL {
        if let url = Bundle.main.url(
            forResource: "\(id).grnh",
            withExtension: "gz",
            subdirectory: "samples_all36"
        ) ?? Bundle.main.url(forResource: "\(id).grnh", withExtension: "gz") {
            return url
        }
        throw GreenHeightmapError.cannotReadFile
    }
}

enum GreenSimMetrics {
    static func guide(
        for ranked: RankedPuttCandidate,
        greenSpeed: Double,
        holeDistance: Double
    ) -> GreenSimulatorModel.PuttGuide {
        // 게이트 2의 기본 stopVelocity/timeFinal/timeDelta를 그대로 사용한다.
        // 홀 판정으로 조기 종료되지 않도록 가상 홀은 충분히 멀리 둔다.
        let flat = FlatPuttPhysics.simulate(
            configuration: FlatPuttConfiguration(
                greenSpeed: greenSpeed,
                slopeDegrees: 0,
                initialVelocity: ranked.candidate.initialVelocity,
                initialDirectionDegrees: 0,
                holeDistance: 10_000,
                holeDirectionDegrees: 0
            ),
            recordTrajectory: false
        )
        return GreenSimulatorModel.PuttGuide(
            flatEquivalentDistance: flat.arcLength,
            distanceAdjustment: flat.arcLength - holeDistance,
            initialVelocity: ranked.candidate.initialVelocity,
            directionDegrees: ranked.candidate.directionDegrees,
            stopPosition: ranked.overrunStopPosition,
            overrunDistance: ranked.distanceToOverrunTarget
        )
    }
}

struct GreenSimulatorRootView: View {
    @StateObject private var model = GreenSimulatorModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SceneKitTapView(
                    scene: model.scene,
                    cameraZoom: $model.cameraZoomRequest,
                    orbitTarget: model.cameraOrbitTarget,
                    orbitRevision: model.cameraOrbitRevision
                ) { point in
                    model.handleTap(scenePoint: point)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Picker("그린", selection: Binding(
                        get: { model.selectedGreenID },
                        set: { model.selectGreen($0) }
                    )) {
                        ForEach(model.greenIDs, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }

                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let recommendation = model.recommendation {
                        RecommendationPanel(summary: recommendation)
                    }

                    HStack {
                        Button("볼 놓기") { model.setPlacementMode(.ball) }
                        Button("홀 놓기") { model.setPlacementMode(.hole) }
                        Toggle("느리게", isOn: $model.slowMotion)
                            .frame(width: 110)
                        Button("퍼팅") { model.putt() }
                            .disabled(model.recommendation?.primary == nil || model.isAnimating || model.isComputing)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 12) {
                        Picker("색", selection: Binding(
                            get: { model.colorMode },
                            set: { model.setColorMode($0) }
                        )) {
                            ForEach(GreenColorMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)

                        Text("확대")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("−") { model.cameraZoomRequest = -1 }
                            .frame(width: 40)
                            .buttonStyle(.bordered)
                        Button("+") { model.cameraZoomRequest = 1 }
                            .frame(width: 40)
                            .buttonStyle(.bordered)
                        Spacer()
                    }

                    if model.colorMode == .elevation {
                        ElevationLegend()
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle("3D 그린 시뮬레이터")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if model.isComputing {
                    ProgressView("계산 중")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

struct RecommendationPanel: View {
    let summary: GreenSimulatorModel.RecommendationSummary

    var body: some View {
        if let guide = summary.primaryGuide {
            PuttGuideCard(guide: guide, elevationDelta: summary.elevationDelta)
        } else {
            EmptyGuideCard()
        }
    }
}

private struct PuttGuideCard: View {
    let guide: GreenSimulatorModel.PuttGuide
    let elevationDelta: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("1순위")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("평지환산거리")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f m", guide.flatEquivalentDistance))
                        .font(.title.bold())
                }
                Spacer()
                DirectionIndicator(degrees: guide.directionDegrees)
                    .frame(width: 64, height: 64)
            }

            Text(adjustmentText(guide.distanceAdjustment))
                .font(.subheadline.weight(.medium))

            Text(elevationText(elevationDelta))
                .font(.subheadline)

            Divider()

            Text(
                "v0 \(String(format: "%.2f", guide.initialVelocity)) m/s · "
                    + "β \(signedDegrees(guide.directionDegrees))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "정지위치 (\(String(format: "%.2f", guide.stopPosition.x)), "
                    + "\(String(format: "%.2f", guide.stopPosition.y))) · "
                    + "오버런 오차 \(String(format: "%.2f", guide.overrunDistance)) m"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.5))
        }
    }

    private func signedDegrees(_ value: Double) -> String {
        String(format: "%+.1f°", value)
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

/// 볼→홀 기준선(0°, 위쪽)을 중심으로 β만큼 회전한 조준 방향을 가리키는 나침반형 인디케이터.
struct DirectionIndicator: View {
    let degrees: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.06))
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)

            // 0° 기준선 (볼→홀 직선)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1)
                .padding(.vertical, 8)

            // β 방향 화살표 (시계방향 +)
            Arrow()
                .fill(Color.blue)
                .rotationEffect(.degrees(degrees))

            Text(String(format: "%+.1f°", degrees))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .offset(y: 24)
        }
    }
}

private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        var path = Path()
        // 위쪽을 가리키는 화살표 (0°일 때 정북)
        path.move(to: CGPoint(x: cx, y: h * 0.14))
        path.addLine(to: CGPoint(x: cx - w * 0.12, y: h * 0.40))
        path.addLine(to: CGPoint(x: cx - w * 0.045, y: h * 0.40))
        path.addLine(to: CGPoint(x: cx - w * 0.045, y: h * 0.60))
        path.addLine(to: CGPoint(x: cx + w * 0.045, y: h * 0.60))
        path.addLine(to: CGPoint(x: cx + w * 0.045, y: h * 0.40))
        path.addLine(to: CGPoint(x: cx + w * 0.12, y: h * 0.40))
        path.closeSubpath()
        return path
    }
}

/// 등고 컬러 범례: 낮음(파랑) → 높음(빨강).
struct ElevationLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("낮음")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.30, blue: 0.85),
                    Color(red: 0.25, green: 0.65, blue: 0.95),
                    Color(red: 0.55, green: 0.85, blue: 0.45),
                    Color(red: 0.20, green: 0.65, blue: 0.25),
                    Color(red: 0.95, green: 0.60, blue: 0.15),
                    Color(red: 0.85, green: 0.15, blue: 0.12)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 10)
            .clipShape(Capsule())
            Text("높음")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyGuideCard: View {
    var body: some View {
        HStack {
            Text("1순위")
                .font(.caption.weight(.semibold))
            Spacer()
            Text("후보 없음")
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SceneKitTapView: UIViewRepresentable {
    let scene: SCNScene
    @Binding var cameraZoom: Int
    let orbitTarget: SCNVector3
    let orbitRevision: Int
    let onTap: (SCNVector3) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .black
        context.coordinator.attach(to: view, onTap: onTap)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
        context.coordinator.onTap = onTap
        if context.coordinator.lastOrbitRevision != orbitRevision {
            context.coordinator.lastOrbitRevision = orbitRevision
            uiView.defaultCameraController.target = orbitTarget
            uiView.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        }
        if cameraZoom != 0 {
            context.coordinator.applyZoom(steps: cameraZoom, in: uiView)
            DispatchQueue.main.async {
                cameraZoom = 0
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: ((SCNVector3) -> Void)?
        var lastOrbitRevision = -1
        private weak var view: SCNView?
        private var didAttach = false

        func attach(to view: SCNView, onTap: @escaping (SCNVector3) -> Void) {
            self.view = view
            self.onTap = onTap
            guard !didAttach else { return }
            didAttach = true

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            view.addGestureRecognizer(tap)

            let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
            scroll.minimumNumberOfTouches = 0
            scroll.maximumNumberOfTouches = 0
            scroll.allowedScrollTypesMask = [.discrete, .continuous]
            scroll.delegate = self
            view.addGestureRecognizer(scroll)
        }

        func applyZoom(steps: Int, in view: SCNView) {
            let delta = Float(steps) * -2.5
            let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            view.defaultCameraController.dolly(
                by: delta,
                onScreenPoint: point,
                viewport: view.bounds.size
            )
        }

        @objc func handleScroll(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            let dy = Float(translation.y)
            guard abs(dy) > 0.1 else { return }
            let delta = dy * 0.08
            let point = gesture.location(in: view)
            view.defaultCameraController.dolly(
                by: delta,
                onScreenPoint: point,
                viewport: view.bounds.size
            )
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(
                location,
                options: [
                    .searchMode: SCNHitTestSearchMode.all.rawValue,
                    .boundingBoxOnly: false
                ]
            )
            guard let hit = hits.first(where: { $0.node.name == "greenMesh" }) ?? hits.first else {
                return
            }
            onTap?(hit.worldCoordinates)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
