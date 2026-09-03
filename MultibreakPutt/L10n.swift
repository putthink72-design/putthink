import Foundation
import PuttPhysicsKit

/// App UI copy. English is the catalog source / fallback for ambiguous locales.
enum L10n {
    private static func s(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    private static func f(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        String(format: String(localized: key), locale: .current, arguments: args)
    }

    // MARK: - Scan idle / steps

    static var scanIdleHint: String { s("scan.idle.hint") }
    static var scanStart: String { s("scan.idle.start") }
    static var lidarPreparing: String { s("scan.idle.lidar_preparing") }

    static var step1Label: String { s("scan.step1.label") }
    static var step1Title: String { s("scan.step1.title") }
    static var step1TitleConfirm: String { s("scan.step1.title_confirm") }
    static var step1Body: String { s("scan.step1.body") }
    static var placeBall: String { s("scan.step1.button") }
    static var groundPreparing: String { s("scan.step1.ground_preparing") }

    static func depthReady(meshPoints: Int) -> String {
        f("scan.step1.depth_ready", meshPoints)
    }

    static func meshProgress(current: Int, threshold: Int) -> String {
        f("scan.step1.mesh_progress", current, threshold)
    }

    static var step2Label: String { s("scan.step2.label") }
    static var step2Title: String { s("scan.step2.title") }
    static var step2Body: String { s("scan.step2.body") }
    static var arriveMarkHole: String { s("scan.step2.button") }

    static var step3Label: String { s("scan.step3.label") }
    static var step3Title: String { s("scan.step3.title") }
    static var step3Body: String { s("scan.step3.body") }
    static var markHoleCalculate: String { s("scan.step3.button") }

    static var processingHeightMap: String { s("scan.processing") }
    static var scanFailed: String { s("scan.failed.title") }
    static var startOver: String { s("scan.failed.retry") }
    static var trackingTip: String { s("scan.tracking_tip") }

    static func exportFailed(_ detail: String) -> String {
        f("scan.export_failed", detail)
    }

    // MARK: - Pitch

    static var pitchHintNone: String { s("pitch.hint.none") }
    static var pitchHintLow: String { s("pitch.hint.low") }
    static var pitchHintHigh: String { s("pitch.hint.high") }

    static func pitchHintOK(degrees: Int) -> String {
        f("pitch.hint.ok", degrees)
    }

    // MARK: - Aim chrome

    static var newScan: String { s("aim.new_scan") }
    static var computing: String { s("aim.computing") }
    static var aimWaiting: String { s("aim.waiting") }
    static var noPathTitle: String { s("aim.no_path.title") }
    static var noPathBody: String { s("aim.no_path.body") }
    static var rescan: String { s("aim.no_path.button") }
    static var contours: String { s("aim.viz.contours") }
    static var gridFlow: String { s("aim.viz.grid") }

    static var confirmCrosshair: String { s("aim.lock.confirm_reticle") }
    static var lockWaiting: String { s("aim.lock.waiting") }
    static var lockSearching: String { s("aim.lock.searching") }
    static var lockCandidate: String { s("aim.lock.candidate") }
    static var lockBall: String { s("aim.lock.ball") }
    static var lockOnScreen: String { s("aim.lock.on_screen") }
    static var lockDetecting: String { s("aim.lock.detecting") }
    static var lockNeedsConfirm: String { s("aim.lock.needs_confirm") }
    static var lockMatched: String { s("aim.lock.matched") }
    static var lockAligned: String { s("aim.lock.aligned") }

    // MARK: - OSD readout

    static func actualDistance(_ meters: Double) -> String {
        f("osd.actual_distance", meters)
    }

    static var unitMeters: String { s("osd.unit_m") }

    static func adjustment(meters: Double) -> String {
        let label = meters >= 0 ? s("osd.adj.uphill") : s("osd.adj.downhill")
        return f("osd.adj.format", meters, label)
    }

    static func elevation(_ delta: Double) -> String {
        if abs(delta) < 0.005 { return s("osd.elev.same") }
        if delta > 0 {
            return f("osd.elev.higher", delta)
        }
        return f("osd.elev.lower", abs(delta))
    }

    static var speedCorridor: String { s("osd.corridor.title") }

    static func overrun(meters: Double, index: Int, count: Int) -> String {
        f("osd.corridor.overrun", meters, index, count)
    }

    static var corridorSafe: String { s("osd.corridor.safe") }
    static var corridorAggressive: String { s("osd.corridor.aggressive") }
    static var corridorNone: String { s("osd.corridor.none") }
    static var corridorOne: String { s("osd.corridor.one") }

    // MARK: - Stroke / tiers / status

    static func strokeGuidance(
        tier: CandidateSearchTier,
        flatEquivalentDistance: Double
    ) -> String {
        switch tier {
        case .proximityEstimate:
            return f("stroke.estimate", flatEquivalentDistance)
        case .flatHeuristic:
            return f("stroke.flat", flatEquivalentDistance)
        case .noPath:
            return s("stroke.none")
        default:
            return f("stroke.feel", flatEquivalentDistance)
        }
    }

    static func tierLabel(_ tier: CandidateSearchTier) -> String {
        switch tier {
        case .verified: return s("tier.verified")
        case .relaxedCapture: return s("tier.relaxed")
        case .expandedSearch: return s("tier.expanded")
        case .proximityEstimate: return s("tier.proximity")
        case .flatHeuristic: return s("tier.flat")
        case .noPath: return s("tier.none")
        }
    }

    static func status(
        tier: CandidateSearchTier,
        candidateCount: Int,
        corridorCount: Int,
        gridNote: String
    ) -> String {
        switch tier {
        case .verified:
            return f("status.verified", candidateCount, corridorCount, gridNote)
        case .relaxedCapture:
            return f("status.relaxed", candidateCount, gridNote)
        case .expandedSearch:
            return f("status.expanded", candidateCount, gridNote)
        case .proximityEstimate:
            return f("status.proximity", gridNote)
        case .flatHeuristic:
            return f("status.flat", gridNote)
        case .noPath:
            return s("tier.none")
        }
    }

    static var statusWaiting: String { s("status.waiting") }

    static func holeDistance(_ meters: Double) -> String {
        f("status.hole_distance", meters)
    }

    static func computingForHole(_ meters: Double) -> String {
        f("status.computing_for_hole", meters)
    }

    static func contextFailed(_ detail: String) -> String {
        f("status.context_failed", detail)
    }

    // MARK: - Failures

    static var failNoLiDAR: String { s("fail.no_lidar") }
    static var failNoDepth: String { s("fail.no_depth") }
    static var failNoReturnPose: String { s("fail.no_return_pose") }
    static var failNoCameraPose: String { s("fail.no_camera_pose") }

    static func terrainError(_ error: TerrainPipelineError) -> String {
        switch error {
        case .coincidentBallAndHole:
            return s("fail.terrain.coincident")
        case .noVertices:
            return s("fail.terrain.no_vertices")
        case .invalidCellSize:
            return s("fail.terrain.invalid_cell")
        case .gridTooLarge(let count):
            return f("fail.terrain.grid_too_large", count)
        }
    }

    static func localizedFailure(_ message: String) -> String {
        switch message {
        case "이 기기는 LiDAR 메시 재구성을 지원하지 않습니다.",
             L10n.failNoLiDAR:
            return failNoLiDAR
        case "이 기기는 sceneDepth를 지원하지 않습니다.",
             L10n.failNoDepth:
            return failNoDepth
        case "볼 복귀 위치를 기록하지 못했습니다.",
             L10n.failNoReturnPose:
            return failNoReturnPose
        case "볼 지정 시 카메라 pose가 없습니다.",
             L10n.failNoCameraPose:
            return failNoCameraPose
        default:
            return message
        }
    }

    // MARK: - Settings

    static var settingsTitle: String { s("settings.title") }
    static var settingsDone: String { s("settings.done") }
    static var settingsLanguage: String { s("settings.language") }
    static var settingsLanguageSystem: String { s("settings.language.system") }
    static var settingsLanguageEnglish: String { s("settings.language.en") }
    static var settingsLanguageKorean: String { s("settings.language.ko") }
    static var settingsLanguageJapanese: String { s("settings.language.ja") }
    static var settingsLanguageFooter: String { s("settings.language.footer") }
    static var settingsLanguageReloadTitle: String { s("settings.language.reload.title") }
    static var settingsLanguageReloadBody: String { s("settings.language.reload.body") }
    static var settingsLanguageReloadLater: String { s("settings.language.reload.later") }
    static var settingsLanguageReloadNow: String { s("settings.language.reload.now") }
    static var settingsSubscribe: String { s("settings.subscribe") }
    static var settingsSubscribeBody: String { s("settings.subscribe.body") }
    static var settingsSubscribeActive: String { s("settings.subscribe.active") }
    static var settingsSubscribeCTA: String { s("settings.subscribe.cta") }
    static var settingsStartTrial: String { s("settings.subscribe.trial_cta") }
    static var settingsTrialBadge: String { s("settings.subscribe.trial_badge") }
    static var settingsTrialShort: String { s("settings.subscribe.trial_short") }
    static var settingsSubscribeLegalFooter: String { s("settings.subscribe.legal_footer") }
    static var settingsRestore: String { s("settings.restore") }
    static var settingsRestoreSuccess: String { s("settings.restore.success") }
    static var settingsRestoreEmpty: String { s("settings.restore.empty") }
    static var settingsManage: String { s("settings.manage") }
    static var settingsStoreUnavailable: String { s("settings.store.unavailable") }
    static var settingsLegal: String { s("settings.legal") }
    static var settingsPrivacy: String { s("settings.privacy") }
    static var settingsEULA: String { s("settings.eula") }
    static var settingsCancelTitle: String { s("settings.cancel.title") }
    static var settingsNeedsSubscription: String { s("settings.needs_subscription") }
    static var planMonth: String { s("plan.month") }
    static var planQuarter: String { s("plan.quarter") }
    static var planSixMonth: String { s("plan.six_month") }
    static var planYear: String { s("plan.year") }
    static var planMonthDetail: String { s("plan.month.detail") }
    static var planQuarterDetail: String { s("plan.quarter.detail") }
    static var planSixMonthDetail: String { s("plan.six_month.detail") }
    static var planYearDetail: String { s("plan.year.detail") }
    static var planMonthRenew: String { s("plan.month.renew") }
    static var planQuarterRenew: String { s("plan.quarter.renew") }
    static var planSixMonthRenew: String { s("plan.six_month.renew") }
    static var planYearRenew: String { s("plan.year.renew") }
    static var planStandardRate: String { s("plan.standard") }
    static var planTrialChip: String { s("plan.trial_chip") }

    static func planSavePercent(_ percent: Int) -> String {
        f("plan.save_percent", percent)
    }
}
