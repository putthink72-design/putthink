import Foundation
import PuttPhysicsKit

private final class L10nLocaleBox: @unchecked Sendable {
    var locale: Locale = .autoupdatingCurrent
}

private let l10nLocaleBox = L10nLocaleBox()

/// App UI copy. English is the catalog source / fallback for ambiguous locales.
enum L10n {
    /// Updated live when the user changes language in Settings.
    static var locale: Locale {
        get { l10nLocaleBox.locale }
        set { l10nLocaleBox.locale = newValue }
    }

    private static func localizationBundle(for locale: Locale) -> Bundle {
        var candidates: [String] = []
        if let code = locale.language.languageCode?.identifier {
            candidates.append(code)
        }
        candidates.append(locale.identifier)
        if let preferred = Locale.preferredLanguages.first {
            candidates.append(preferred)
            let short = preferred.split(separator: "-").first.map(String.init)
            if let short { candidates.append(short) }
        }
        candidates.append("en")

        var seen = Set<String>()
        for raw in candidates {
            let code = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
            guard seen.insert(code).inserted else { continue }
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }

    private static func s(_ key: String) -> String {
        let bundle = localizationBundle(for: locale)
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: s(key), locale: locale, arguments: args)
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
    static var lockConfirmReticleTitle: String { s("aim.lock.confirm_reticle_title") }
    static var lockConfirmReticleHint: String { s("aim.lock.confirm_reticle_hint") }
    static var lockCoachTapHint: String { s("aim.lock.coach_tap_hint") }
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

    /// 평지환산 − 실거리. 고도가 아니라 홀 뒤 여유(오버런)·그린스피드 환산이다.
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
        case .verified:
            return f("stroke.feel", flatEquivalentDistance)
        case .flatHeuristic:
            return f("stroke.flat", flatEquivalentDistance)
        case .relaxedCapture, .expandedSearch, .proximityEstimate, .noPath:
            return f("stroke.estimate", flatEquivalentDistance)
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
    static var settingsGreenSpeed: String { s("settings.green_speed") }
    static var settingsGreenSpeedFooter: String { s("settings.green_speed.footer") }
    static var settingsGreenSpeedSlow: String { s("settings.green_speed.slow") }
    static var settingsGreenSpeedNormal: String { s("settings.green_speed.normal") }
    static var settingsGreenSpeedSlightlyFast: String { s("settings.green_speed.slightly_fast") }
    static var settingsGreenSpeedFast: String { s("settings.green_speed.fast") }
    static var settingsGreenSpeedVeryFast: String { s("settings.green_speed.very_fast") }
    static var settingsFreeRunsTitle: String { s("settings.free_runs") }
    static var settingsFreeRunsFooter: String { s("settings.free_runs.footer") }
    static var settingsSubscribe: String { s("settings.subscribe") }
    static var settingsSubscribeBody: String { s("settings.subscribe.body") }
    static var settingsSubscribeActive: String { s("settings.subscribe.active") }
    static var settingsSubscribeCTA: String { s("settings.subscribe.cta") }
    static var settingsSubscribeChangeCTA: String { s("settings.subscribe.change_cta") }
    static var settingsSubscribeCurrentPlan: String { s("settings.subscribe.current_plan") }
    static var settingsSubscribeCurrentPlanCTA: String { s("settings.subscribe.current_plan_cta") }
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
    static var settingsDeleteAccount: String { s("settings.delete_account") }
    static var settingsDeleteAccountTitle: String { s("settings.delete_account.title") }
    static var settingsDeleteAccountBody: String { s("settings.delete_account.body") }
    static var settingsDeleteAccountConfirm: String { s("settings.delete_account.confirm") }
    static var settingsDeleteAccountDone: String { s("settings.delete_account.done") }
    static var settingsCancelTitle: String { s("settings.cancel.title") }
    static var settingsNeedsSubscription: String { s("settings.needs_subscription") }
    static var settingsFreeScanAvailable: String { s("settings.free_scan_available") }
    static func settingsFreeRunsRemaining(_ count: Int) -> String {
        String(format: s("settings.free_runs_remaining"), count)
    }

    // MARK: - Showcase upload

    static var showcaseUploadTitle: String { s("showcase.upload.title") }
    static var showcaseUploadSettingsFooter: String { s("showcase.upload.settings_footer") }
    static var showcaseUploadSettingsBody: String { s("showcase.upload.settings_body") }
    static var showcaseUploadOpen: String { s("showcase.upload.open") }
    static var showcaseUploadDo: String { s("showcase.upload.do") }
    static var showcaseReport: String { s("showcase.report") }
    static var showcaseUploadDefaultCaption: String { s("showcase.upload.default_caption") }
    static var nicknameTitle: String { s("nickname.title") }
    static var nicknameFooter: String { s("nickname.footer") }
    static var nicknameSave: String { s("nickname.save") }
    static var nicknameRegenerate: String { s("nickname.regenerate") }
    static var nicknameRejected: String { s("nickname.rejected") }
    static var nicknameTooLong: String { s("nickname.too_long") }
    static var inviteTitle: String { s("invite.title") }
    static var inviteBody: String { s("invite.body") }
    static var inviteFooter: String { s("invite.footer") }
    static var inviteShareCTA: String { s("invite.share_cta") }
    static var invitePreparing: String { s("invite.preparing") }
    static var inviteNeedApple: String { s("invite.need_apple") }
    static var inviteNudgeTitle: String { s("invite.nudge_title") }
    static var inviteNudgeBody: String { s("invite.nudge_body") }
    static var inviteNudgeSkip: String { s("invite.nudge_skip") }
    static var inviteClipboardApply: String { s("invite.clipboard_apply") }
    static var inviteClipboardNotFound: String { s("invite.clipboard_not_found") }
    static var inviteClipboardUnavailable: String { s("invite.clipboard_unavailable") }
    static func inviteClipboardApplied(_ code: String) -> String {
        String(format: s("invite.clipboard_applied"), code)
    }
    static var devModeOn: String { s("dev.mode.on") }
    static var prodModeOn: String { s("dev.mode.prod") }
    static var devModeAsPro: String { s("dev.mode.as_pro") }
    static var showcaseUploadHowTitle: String { s("showcase.upload.how_title") }
    static var showcaseUploadHowBody: String { s("showcase.upload.how_body") }
    static var showcaseUploadGateTitle: String { s("showcase.upload.gate_title") }
    static var showcaseUploadNeedPro: String { s("showcase.upload.need_pro") }
    static var showcaseUploadNeedSignIn: String { s("showcase.upload.need_sign_in") }
    static var showcaseUploadNeedSupabaseSession: String { s("showcase.upload.need_supabase_session") }
    static var showcaseSignInApple: String { s("showcase.upload.sign_in_apple") }
    static var showcaseUploadPickTitle: String { s("showcase.upload.pick_title") }
    static var showcaseUploadPickFooter: String { s("showcase.upload.pick_footer") }
    static var showcaseUploadPickCTA: String { s("showcase.upload.pick_cta") }
    static var showcaseUploadPickReplace: String { s("showcase.upload.pick_replace") }
    static var showcaseUploadPickFailed: String { s("showcase.upload.pick_failed") }
    static var showcaseUploadPickerAdd: String { s("showcase.upload.picker_add") }
    static var showcaseUploadPickerCancel: String { s("showcase.upload.picker_cancel") }
    static var showcaseUploadPickerPermissionTitle: String { s("showcase.upload.picker_permission_title") }
    static var showcaseUploadPickerPermissionBody: String { s("showcase.upload.picker_permission_body") }
    static var showcaseUploadPickerOpenSettings: String { s("showcase.upload.picker_open_settings") }
    static var showcaseUploadPickerEmpty: String { s("showcase.upload.picker_empty") }
    static var showcaseUploadPickerEmptyBody: String { s("showcase.upload.picker_empty_body") }
    static var showcaseUploadReady: String { s("showcase.upload.ready") }
    static func showcaseUploadReadyMB(_ megabytes: Double) -> String {
        f("showcase.upload.ready_mb", megabytes)
    }
    static func showcaseUploadCompressingPct(_ percent: Int) -> String {
        f("showcase.upload.compressing_pct", percent)
    }
    static func showcaseUploadUploadingPct(_ percent: Int) -> String {
        f("showcase.upload.uploading_pct", percent)
    }
    static var showcaseUploadMetaTitle: String { s("showcase.upload.meta_title") }
    static var showcaseUploadCategory: String { s("showcase.upload.category") }
    static var showcaseUploadNickname: String { s("showcase.upload.nickname") }
    static var showcaseUploadCaption: String { s("showcase.upload.caption") }
    static var showcaseUploadClub: String { s("showcase.upload.club") }
    static var showcaseUploadCourse: String { s("showcase.upload.course") }
    static var showcaseUploadHole: String { s("showcase.upload.hole") }
    static var showcaseUploadSubmit: String { s("showcase.upload.submit") }
    static var showcaseUploadUploading: String { s("showcase.upload.uploading") }
    static var showcaseUploadSuccess: String { s("showcase.upload.success") }
    static var showcaseUploadNotConfigured: String { s("showcase.upload.not_configured") }
    static var showcaseUploadEncodeFailed: String { s("showcase.upload.encode_failed") }
    static var showcaseUploadTooLarge: String { s("showcase.upload.too_large") }
    static var showcaseCategoryLongPutt: String { s("showcase.category.long_putt") }
    static var showcaseCategoryMultiBreak: String { s("showcase.category.multi_break") }
    static var showcaseCategoryRecovery: String { s("showcase.category.recovery") }
    static var showcaseCategoryFirstHoled: String { s("showcase.category.first_holed") }

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
