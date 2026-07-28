import Darwin
import PuttPhysicsKit
import SwiftUI
import UIKit

@main
struct Gate3BenchmarkApp: App {
    var body: some Scene {
        WindowGroup {
            Gate3BenchmarkView()
        }
    }
}

private struct BenchmarkMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let averageSeconds: Double
    let repetitions: Int
    let detail: String
}

@MainActor
private final class Gate3BenchmarkModel: ObservableObject {
    @Published var isRunning = false
    @Published var metrics: [BenchmarkMetric] = []
    @Published var errorMessage: String?

    var report: String {
        let header = [
            "Gate 3 benchmark",
            "Device: \(UIDevice.current.model)",
            "OS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "Build: \(isDebugBuild ? "Debug (측정 무효)" : "Release")",
            "Grid semantics: exact point count (30×30=900, 130×130=16,900)"
        ]
        let rows = metrics.map {
            "\($0.title): \(String(format: "%.4f", $0.averageSeconds))s avg "
                + "(\($0.repetitions)x), \($0.detail)"
        }
        return (header + rows).joined(separator: "\n")
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        metrics = []
        errorMessage = nil

        Task {
            let measured = await Task.detached(priority: .userInitiated) {
                Gate3BenchmarkRunner.run()
            }.value
            metrics = measured
            if isDebugBuild {
                errorMessage = "Debug 빌드입니다. Gate3Benchmark 스킴을 Release로 실행해 다시 측정하세요."
            }
            isRunning = false
            if ProcessInfo.processInfo.arguments.contains("--automation") {
                print("GATE3_REPORT_BEGIN\n\(report)\nGATE3_REPORT_END")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            }
        }
    }

    func copyReport() {
        UIPasteboard.general.string = report
    }

    private var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}

private enum Gate3BenchmarkRunner {
    static func run() -> [BenchmarkMetric] {
        let smallGrid = grid(pointCount: 30)
        let fullGrid = grid(pointCount: 130)
        let singleConfiguration = FlatPuttConfiguration(
            greenSpeed: 2.5,
            slopeDegrees: 2,
            initialVelocity: 10,
            initialDirectionDegrees: 5,
            stopVelocity: 0,
            timeFinal: 19.99,
            timeDelta: 0.01,
            holeDistance: 1_000,
            holeDirectionDegrees: 0
        )

        _ = FlatPuttPhysics.simulate(
            configuration: singleConfiguration,
            recordTrajectory: false
        )
        _ = FlatPuttPhysics.scanExactGridSerial(configuration: smallGrid)
        _ = FlatPuttPhysics.scanExactGridParallel(configuration: smallGrid)

        var metrics: [BenchmarkMetric] = []
        let single = measure(repetitions: 20) {
            let result = FlatPuttPhysics.simulate(
                configuration: singleConfiguration,
                recordTrajectory: false
            )
            return result.numberOfSteps
        }
        metrics.append(
            BenchmarkMetric(
                id: "single",
                title: "단일 2,000스텝",
                averageSeconds: single.seconds,
                repetitions: 20,
                detail: "checksum \(single.checksum)"
            )
        )

        metrics.append(scanMetric(
            id: "30-serial",
            title: "30×30 직렬",
            repetitions: 5,
            configuration: smallGrid,
            parallel: false
        ))
        metrics.append(scanMetric(
            id: "30-parallel",
            title: "30×30 병렬",
            repetitions: 5,
            configuration: smallGrid,
            parallel: true
        ))
        metrics.append(scanMetric(
            id: "130-serial",
            title: "130×130 직렬",
            repetitions: 3,
            configuration: fullGrid,
            parallel: false
        ))
        metrics.append(scanMetric(
            id: "130-parallel",
            title: "130×130 병렬",
            repetitions: 3,
            configuration: fullGrid,
            parallel: true
        ))
        return metrics
    }

    private static func scanMetric(
        id: String,
        title: String,
        repetitions: Int,
        configuration: ExactGridScanConfiguration,
        parallel: Bool
    ) -> BenchmarkMetric {
        let measurement = measure(repetitions: repetitions) {
            let candidates = parallel
                ? FlatPuttPhysics.scanExactGridParallel(configuration: configuration)
                : FlatPuttPhysics.scanExactGridSerial(configuration: configuration)
            return candidates.count
        }
        return BenchmarkMetric(
            id: id,
            title: title,
            averageSeconds: measurement.seconds,
            repetitions: repetitions,
            detail: "\(configuration.combinationCount)조합, checksum \(measurement.checksum)"
        )
    }

    private static func measure(
        repetitions: Int,
        operation: () -> Int
    ) -> (seconds: Double, checksum: Int) {
        var total = 0.0
        var checksum = 0
        for _ in 0..<repetitions {
            let start = ContinuousClock.now
            checksum &+= operation()
            let duration = start.duration(to: .now).components
            total += Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        return (total / Double(repetitions), checksum)
    }

    private static func grid(pointCount: Int) -> ExactGridScanConfiguration {
        ExactGridScanConfiguration(
            greenSpeed: 2.5,
            slopeDegrees: 2,
            minimumVelocity: 1,
            maximumVelocity: 3,
            velocityPointCount: pointCount,
            minimumDirectionDegrees: -13,
            maximumDirectionDegrees: 13,
            directionPointCount: pointCount,
            holeDistance: 3,
            holeDirectionDegrees: 0
        )
    }
}

private struct Gate3BenchmarkView: View {
    @StateObject private var model = Gate3BenchmarkModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Release 빌드로 iPhone 12 Pro에서 실행하세요. 워밍업은 평균에서 제외됩니다.")
                    Text("130×130 병렬 평균이 3초 이하면 게이트 3 합격입니다.")
                }

                if model.isRunning {
                    Section {
                        HStack {
                            ProgressView()
                            Text("5개 벤치마크 실행 중…")
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if !model.metrics.isEmpty {
                    Section("결과") {
                        ForEach(model.metrics) { metric in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.title)
                                    .font(.headline)
                                Text("\(metric.averageSeconds, specifier: "%.4f")초 평균")
                                Text(metric.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button("벤치마크 실행") {
                        model.run()
                    }
                    .disabled(model.isRunning)

                    if !model.metrics.isEmpty {
                        Button("결과 복사") {
                            model.copyReport()
                        }
                    }
                }
            }
            .navigationTitle("게이트 3 벤치마크")
            .task {
                if model.metrics.isEmpty && !model.isRunning {
                    model.run()
                }
            }
        }
    }
}
