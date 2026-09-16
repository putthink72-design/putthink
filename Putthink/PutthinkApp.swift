import SwiftUI

@main
struct PutthinkApp: App {
    @StateObject private var language = AppLanguageStore()
    @StateObject private var subscriptions = SubscriptionStore()
    @StateObject private var freeRuns = FreeRunsStore()
    @StateObject private var auth = AuthSessionStore()
    @StateObject private var devMode = DevModeStore()
    @StateObject private var nicknameStore = NicknameStore()
    @StateObject private var invite = InviteStore()

    init() {
        AppLanguageStore.applyPersistedLanguageAtLaunch()
        OSDDoneTextField.prewarmAccessoryBar()
    }

    var body: some Scene {
        WindowGroup {
            ScanFlowView()
                .environmentObject(language)
                .environmentObject(subscriptions)
                .environmentObject(freeRuns)
                .environmentObject(auth)
                .environmentObject(devMode)
                .environmentObject(nicknameStore)
                .environmentObject(invite)
                .environment(\.locale, language.locale)
                .onOpenURL { url in
                    if let code = InviteDeepLink.parseInviteCode(from: url) {
                        freeRuns.rememberInviteCode(code)
                        Task { await freeRuns.syncClaimWithServer(auth: auth) }
                    }
                }
                .task {
                    await freeRuns.syncClaimWithServer(auth: auth)
                }
        }
    }
}
