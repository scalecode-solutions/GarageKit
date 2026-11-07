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
        // Hosted the way a production host does it: the garage screen in a
        // navigation stack, owner tools pushed from a toolbar gear. (A production
        // host shows the gear only when one of engine.doors is owned; GarageLab
        // always shows it so a fresh account can add its first device.)
        NavigationStack {
            GarageView(engine: engine)
                .navigationTitle("Garage")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            GarageOwnerView(engine: engine) { accountSection }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Manage doors")
                    }
                }
        }
        .task { engine.start() }
        .onDisappear { engine.stop() }
    }

    /// GarageLab's own rows, appended to the kit's owner screen.
    private var accountSection: some View {
        Section {
            LabeledContent("User ID") {
                Text(userID).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Server", value: auth.server.rawValue)
            // Sign-out wipes this account's local trail (production hosts do the same).
            Button("Sign out", role: .destructive) {
                engine.wipeLocalStore()
                auth.logOut()
            }
        } header: {
            Text("Account")
        }
    }
}
