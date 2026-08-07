import SwiftUI

@main
struct MultibreakPuttApp: App {
    init() {
        OSDDoneTextField.prewarmAccessoryBar()
    }

    var body: some Scene {
        WindowGroup {
            ScanFlowView()
        }
    }
}
