import SwiftUI

/// GarageLab — the harness app for GarageKit. Logs into mvServer (real JWT via
/// MvAuth), then hosts the kit exactly the way a production host does: engine built with an
/// injected token provider, started on sign-in, stopped on sign-out. All garage
/// UI development happens here, not inside a production host.
@main
struct GarageLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.cyan)
        }
    }
}
