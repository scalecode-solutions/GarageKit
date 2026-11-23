import SwiftUI
import GarageKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        if LabDemo.isOn {
            // In-memory server, no sign-in (the UI tests run this way).
            GarageLabHost(demoAuth: auth)
        } else {
            signedIn
        }
    }

    @ViewBuilder
    private var signedIn: some View {
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
    let demo: Bool
    @State private var engine: GarageEngine
    /// The fake host's people (MVCALE-122). On by default; LAB_HOST_PEOPLE=0
    /// starts with it off. Signed in to a real server, the host names everyone
    /// "Host …" so the override is visible on any account.
    @State private var host = LabHostPeople(
        enabled: ProcessInfo.processInfo.environment["LAB_HOST_PEOPLE"] != "0",
        names: LabDemo.hostNames)

    init(profile: UserProfile, auth: AuthModel) {
        self.auth = auth
        self.userID = profile.userID
        self.demo = false
        let config = GarageConfig(
            baseURL: auth.server.garageBaseURL,
            currentUserID: UUID(uuidString: profile.userID) ?? UUID(),
            tokenProvider: { [auth] in await auth.accessToken() }
        )
        _engine = State(initialValue: GarageEngine(config: config))
    }

    /// The demo host: an in-memory server and a fixed identity.
    init(demoAuth auth: AuthModel) {
        self.auth = auth
        self.userID = LabDemo.me.uuidString
        self.demo = true
        let config = GarageConfig(baseURL: URL(string: "http://demo.invalid")!,
                                  currentUserID: LabDemo.me, tokenProvider: { "demo" })
        _engine = State(initialValue: GarageEngine(config: config, transport: LabDemoTransport()))
    }

    var body: some View {
        // Hosted the way a production host does it: the garage screen in a
        // navigation stack, owner tools pushed from a toolbar gear. (A production
        // host shows the gear only when one of engine.doors is owned; GarageLab
        // always shows it so a fresh account can add its first device.)
        NavigationStack {
            if demo {
                // The demo opens on the owner screens: the dial's ambient
                // animation never lets a UI test see the app idle.
                GarageOwnerView(engine: engine) { accountSection }
                    .navigationTitle("Doors")
            } else {
                garage
            }
        }
        .garageHostPeople(host.people)
        .overlay(alignment: .bottom) {
            LabHostPeopleControls(host: host, renameID: LabDemo.avery)
        }
        .task {
            if !demo { host.nameEveryone = true }
            engine.start()
        }
        .onDisappear { engine.stop() }
    }

    /// The garage screen, owner tools pushed from a toolbar gear.
    private var garage: some View {
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

    /// GarageLab's own rows, appended to the kit's owner screen.
    private var accountSection: some View {
        Section {
            LabeledContent("User ID") {
                Text(userID).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Server", value: demo ? "Demo (in memory)" : auth.server.rawValue)
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
