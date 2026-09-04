import SwiftUI

@main
struct PutthinkApp: App {
    @StateObject private var language = AppLanguageStore()
    @StateObject private var subscriptions = SubscriptionStore()

    init() {
        AppLanguageStore.applyPersistedLanguageAtLaunch()
        OSDDoneTextField.prewarmAccessoryBar()
    }

    var body: some Scene {
        WindowGroup {
            ScanFlowView()
                .environmentObject(language)
                .environmentObject(subscriptions)
                .environment(\.locale, language.locale)
        }
    }
}
