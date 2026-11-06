import SwiftUI
import GarageKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        switch auth.state {
        case .loggedIn(let profile):
            GarageLabHost(profile: profile, auth: auth)
                .id(profile.userID) // a fresh engine per identity
        default:
            LoginView(auth: auth)
        }
    }
}

/// The dev host: builds a `GarageEngine` with the Lab's token provider and drives
/// `start()`/`stop()` — the same seam a production host uses with its own token store.
struct GarageLabHost: View {
    let auth: AuthModel
    let userID: String
    @State private var engine: GarageEngine

    init(profile: UserProfile, auth: AuthModel) {
        self.auth = auth
        self.userID = profile.userID
        let config = GarageConfig(
            baseURL: auth.server.garageBaseURL,
            currentUserID: UUID(uuidString: profile.userID) ?? UUID(),
            tokenProvider: { [auth] in await auth.accessToken() }
        )
        _engine = State(initialValue: GarageEngine(config: config))
    }

    var body: some View {
        TabView {
            Tab("Garage", systemImage: "door.garage.closed") {
                GarageView(engine: engine)
            }
            Tab("Owner", systemImage: "key.horizontal") {
                // Sign-out wipes this account's local trail (production hosts do the same).
                OwnerView(engine: engine, userID: userID) {
                    engine.wipeLocalStore()
                    auth.logOut()
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { engine.start() }
        .onDisappear { engine.stop() }
    }
}
