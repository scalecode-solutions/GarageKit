import SwiftUI
import GarageKit

// GarageLab's stand-in for a host that knows people (MVCALE-122).
//
// A production host hands GarageKit its own names and photos with
// `.garageHostPeople(_:)`. The Lab fakes one: a few host names, a drawn photo,
// a switch to turn it off (the kit falls back to the server's names) and a
// rename that changes a name while a screen is open. `LAB_DEMO=1` runs the Lab
// against an in-memory server with three people, so the UI test needs no
// backend or sign-in.

@MainActor
@Observable
final class LabHostPeople {
    var enabled: Bool
    /// Signed in to a real server the Lab doesn't know anyone's id, so it names
    /// everyone "Host …" (the override shows on any account).
    var nameEveryone = false
    private(set) var names: [UUID: String]

    init(enabled: Bool, names: [UUID: String]) {
        self.enabled = enabled
        self.names = names
    }

    /// Change one person's host name (a rename in the host while the kit is open).
    func rename(_ id: UUID, to name: String) { names[id] = name }

    /// What the Lab hands GarageKit. The closures read this object while the
    /// kit draws, so flipping `enabled` or renaming redraws open screens.
    var people: GarageHostPeople {
        GarageHostPeople(
            name: { [weak self] id in
                guard let self, self.enabled else { return nil }
                if let n = self.names[id] { return n }
                return self.nameEveryone ? "Host \(id.uuidString.prefix(4))" : nil
            },
            avatar: { [weak self] id, size in
                guard let self, self.enabled, self.names[id] != nil || self.nameEveryone else { return nil }
                return AnyView(LabHostAvatar(size: size))
            }
        )
    }
}

/// The Lab's "host photo": unmistakably not the kit's initials.
private struct LabHostAvatar: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.orange.gradient, in: .circle)
    }
}

/// The Lab's on-screen controls for the fake host, shown over every screen.
struct LabHostPeopleControls: View {
    @Bindable var host: LabHostPeople
    let renameID: UUID

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Host people", isOn: $host.enabled)
                .toggleStyle(.button)
                .accessibilityIdentifier("lab.hostPeople")
            Button("Rename") { host.rename(renameID, to: "Avery renamed") }
                .accessibilityIdentifier("lab.rename")
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .padding(6)
        .background(.regularMaterial, in: .capsule)
        .padding(.bottom, 4)
    }
}

// MARK: - Demo server

enum LabDemo {
    static var isOn: Bool { ProcessInfo.processInfo.environment["LAB_DEMO"] == "1" }

    static let me = UUID(uuidString: "00000000-0000-4000-8000-0000000000a0")!
    static let avery = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    static let blake = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!
    static let casey = UUID(uuidString: "00000000-0000-4000-8000-0000000000a3")!
    static let door = UUID(uuidString: "00000000-0000-4000-8000-0000000000d1")!

    /// The host knows Avery and Casey, not Blake (Blake shows the server's name).
    static let hostNames: [UUID: String] = [avery: "Avery (host)", casey: "Casey (host)"]
}

/// An in-memory mvGarage: one owned door, three contacts, Avery already shared.
final class LabDemoTransport: GarageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [GarageGrant] = [
        GarageGrant(id: UUID(), doorID: LabDemo.door, granteeID: LabDemo.avery, label: "Avery Backend", expiresAt: nil),
    ]

    func listDoors() async throws -> [GarageDoor] {
        [GarageDoor(id: LabDemo.door, name: "Demo door", online: true, owned: true, button: 1)]
    }
    func trigger(doorID: UUID, idempotencyKey: String, pressAgain: Bool) async -> TriggerOutcome { .done }
    func listMyActivity(doorID: UUID, limit: Int) async throws -> [GarageActivity] { [] }
    func registerDevice(name: String) async throws -> RegisteredDevice {
        throw GarageTransportError.badResponse("not in the demo")
    }
    func renameDoor(id: UUID, to name: String) async throws {}
    func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) async throws -> GarageGrant {
        let g = GarageGrant(id: UUID(), doorID: doorID, granteeID: granteeID, label: label, expiresAt: expiresAt)
        lock.withLock { grants.append(g) }
        return g
    }
    func revokeGrant(id: UUID) async throws { lock.withLock { grants.removeAll { $0.id == id } } }
    func listGrants(doorID: UUID) async throws -> [GarageGrant] { lock.withLock { grants.filter { $0.doorID == doorID } } }
    func listContacts() async throws -> [GarageContact] {
        [GarageContact(id: LabDemo.avery, name: "Avery Backend"),
         GarageContact(id: LabDemo.blake, name: "Blake Backend"),
         GarageContact(id: LabDemo.casey, name: "Casey Backend")]
    }
}
