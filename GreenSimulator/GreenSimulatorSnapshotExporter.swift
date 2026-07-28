import Foundation
import PuttPhysicsKit
import SceneKit
import UIKit

/// `GREEN_SIM_EXPORT=1` 로 실행 시 Gate5 시나리오 기반 스크린샷·수치를 Documents에 기록한다.
enum GreenSimulatorSnapshotExporter {
    private static let greenSpeed = 2.5
    private static let checklistGreens = [
        "128_001_2_03_4", // 완만
        "128_001_1_05_3", // 중간
        "128_001_2_06_4"  // 급경사
    ]

    static var shouldExport: Bool {
        ProcessInfo.processInfo.environment["GREEN_SIM_EXPORT"] == "1"
            || CommandLine.arguments.contains("--export-checklist")
    }

    @MainActor
    static func exportIfNeeded() {
        guard shouldExport else { return }
        Task {
            do {
                let output = try await exportChecklist()
                print("GREEN_SIM_EXPORT_OK \(output.path)")
            } catch {
                print("GREEN_SIM_EXPORT_FAIL \(error)")
            }
        }
    }

    @MainActor
    static func exportChecklist() async throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("green-sim-checklist", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        var rows: [String] = [
            "green,scenario,candidates,relaxed,primaryV,primaryBeta,passedOver,holeIn,status"
        ]

        for greenID in checklistGreens {
            let url = try GreenSimText.greenURL(id: greenID)
            let green = try GreenHeightmapLoader.load(from: url)
            let scenarios = try GreenAligner.defaultScenarios(for: green, holeCount: 1)
            guard let scenario = scenarios.first else { continue }

            let (alignment, terrain) = try GreenAligner.makeTerrainField(
                from: green,
                ballWorld: scenario.ball,
                holeWorld: scenario.hole
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

            var primaryTrajectoryWorld: [PuttVector2] = []
            var passedOver = false
            var holeIn = false
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
                primaryTrajectoryWorld = result.trajectory.map { alignment.world(local: $0.position) }
                passedOver = result.ballPassOverHoleIf == 1
                holeIn = result.ballHoleIf == 1
            }

            let scene = try buildScene(
                green: green,
                ball: scenario.ball,
                hole: scenario.hole,
                trajectory: primaryTrajectoryWorld,
                passedOver: passedOver
            )
            let image = try render(scene: scene, size: CGSize(width: 1200, height: 900))
            let pngURL = docs.appendingPathComponent("\(greenID)_s0.png")
            guard let data = image.pngData() else {
                throw GreenHeightmapError.cannotReadFile
            }
            try data.write(to: pngURL)

            let primaryV = selection.primary.map { String(format: "%.4f", $0.candidate.initialVelocity) } ?? ""
            let primaryBeta = selection.primary.map { String(format: "%.2f", $0.candidate.directionDegrees) } ?? ""
            rows.append(
                [
                    greenID,
                    "0",
                    "\(selection.allCandidates.count)",
                    selection.usedRelaxedCaptureRadius ? "1" : "0",
                    primaryV,
                    primaryBeta,
                    passedOver ? "1" : "0",
                    holeIn ? "1" : "0",
                    GreenSimText.status(for: selection)
                ].joined(separator: ",")
            )
        }

        let csvURL = docs.appendingPathComponent("checklist.csv")
        try rows.joined(separator: "\n").write(to: csvURL, atomically: true, encoding: .utf8)
        try "done\n".write(
            to: docs.appendingPathComponent("DONE.txt"),
            atomically: true,
            encoding: .utf8
        )
        return docs
    }

    @MainActor
    private static func buildScene(
        green: GreenHeightmap,
        ball: PuttVector2,
        hole: PuttVector2,
        trajectory: [PuttVector2],
        passedOver: Bool
    ) throws -> SCNScene {
        let model = try GreenSceneBuilder.makeDisplayModel(from: green, colorMode: .elevation)
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.08, green: 0.1, blue: 0.12, alpha: 1)
        scene.rootNode.addChildNode(model.node)

        let ballNode = GreenSceneBuilder.makeBallNode()
        let ballH = GreenSceneBuilder.height(atWorld: ball, model: model)
        ballNode.position = GreenSceneBuilder.scenePoint(
            worldX: ball.x,
            worldY: ball.y,
            height: ballH,
            model: model
        )
        scene.rootNode.addChildNode(ballNode)

        let holeNode = GreenSceneBuilder.makeHoleNode()
        let holeH = GreenSceneBuilder.height(atWorld: hole, model: model)
        holeNode.position = SCNVector3(
            hole.x - model.sceneOriginX,
            holeH - model.heightOffset + 0.005,
            hole.y - model.sceneOriginZ
        )
        scene.rootNode.addChildNode(holeNode)

        if !trajectory.isEmpty {
            let traj = GreenSceneBuilder.makeTrajectoryNode(
                worldPoints: trajectory,
                model: model,
                color: passedOver ? .systemYellow : .systemGreen
            )
            scene.rootNode.addChildNode(traj)
        }

        let width = Double(model.smoothed.width - 1) * model.smoothed.cellSize
        let depth = Double(model.smoothed.height - 1) * model.smoothed.cellSize
        let center = SCNVector3(Float(width * 0.5), 0, Float(depth * 0.5))
        let distance = Float(max(width, depth) * 1.2)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 500
        camera.position = SCNVector3(center.x, distance * 0.7, center.z + distance * 0.8)
        camera.look(at: center)
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
        return scene
    }

    @MainActor
    private static func render(scene: SCNScene, size: CGSize) throws -> UIImage {
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image
    }
}
