import Foundation
import PuttPhysicsKit
import SwiftUI

enum Gate55ComputeMode: String, CaseIterable, Identifiable {
    case recommend
    case forward

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommend: return "추천(모드2)"
        case .forward: return "순검증(모드1)"
        }
    }
}

@MainActor
final class Gate55GuidanceModel: ObservableObject {
    @Published var greenSpeed: Double = 2.5
    @Published var computeMode: Gate55ComputeMode = .recommend
    @Published var manualV0: Double = 2.0
    @Published var manualBeta: Double = 0
    @Published var isComputing = false
    @Published var statusMessage = "추천 계산 대기"
    @Published var recommendation: Gate55Recommendation?
    @Published var forwardResult: Gate55ForwardResult?
    @Published var context: Gate55TerrainContext?
    @Published var thermalLevel: ThermalPerformance.Level = .nominal

    /// AR 조준선에 쓸 현재 β (도).
    var aimBetaDegrees: Double {
        switch computeMode {
        case .recommend:
            return recommendation?.directionDegrees ?? 0
        case .forward:
            return manualBeta
        }
    }

    var hasAimLine: Bool {
        switch computeMode {
        case .recommend:
            return recommendation?.primary != nil
        case .forward:
            return forwardResult != nil
        }
    }

    private var thermalObserver: NSObjectProtocol?

    init() {
        thermalLevel = ThermalPerformance.level
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ThermalPerformance.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalLevel = ThermalPerformance.level
            }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    func bind(scan: CompletedScan) {
        do {
            context = try Gate55Validation.contextFromScan(
                result: scan.result,
                startPose: scan.startPose,
                holePose: scan.holePose
            )
            thermalLevel = ThermalPerformance.level
            statusMessage = String(
                format: "홀까지 %.2fm · 추천 계산 중…",
                scan.holeDistance
            )
            recompute()
        } catch {
            statusMessage = "지형 컨텍스트 실패: \(error.localizedDescription)"
        }
    }

    func recompute() {
        guard let context else { return }
        isComputing = true
        thermalLevel = ThermalPerformance.level
        let greenSpeed = self.greenSpeed
        let mode = computeMode
        let v0 = manualV0
        let beta = manualBeta
        let snapshot = context
        let points = PerformanceSettings.effectiveRecommendPointCount
        let taskPriority: TaskPriority =
            thermalLevel >= .serious ? .utility : .userInitiated
        Task.detached(priority: taskPriority) {
            switch mode {
            case .recommend:
                let result = Gate55Validation.recommend(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    velocityPointCount: points,
                    directionPointCount: points
                )
                await MainActor.run {
                    self.recommendation = result
                    self.forwardResult = nil
                    self.isComputing = false
                    let gridNote = "\(points)×\(points)"
                    if result.primary == nil {
                        self.statusMessage = result.usedRelaxedCaptureRadius
                            ? "반경 완화 재계산 후에도 후보 없음 (\(gridNote))"
                            : "후보 없음 (\(gridNote))"
                    } else if result.usedRelaxedCaptureRadius {
                        self.statusMessage =
                            "반경 완화 · 후보 \(result.candidateCount)개 (\(gridNote))"
                    } else {
                        self.statusMessage =
                            "후보 \(result.candidateCount)개 · 1순위 (\(gridNote))"
                    }
                }
            case .forward:
                let result = Gate55Validation.runForward(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    initialVelocity: v0,
                    directionDegrees: beta
                )
                await MainActor.run {
                    self.forwardResult = result
                    self.recommendation = nil
                    self.isComputing = false
                    self.statusMessage = String(
                        format: "순검증 정지 (%.2f, %.2f)",
                        result.stopPosition.x,
                        result.stopPosition.y
                    )
                }
            }
        }
    }
}
