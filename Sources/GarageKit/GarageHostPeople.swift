import SwiftUI

/// What the host knows about people, so the owner screens name and picture
/// someone the same way the rest of the host app does. Every field is optional:
/// a closure that returns nil (or an empty name) falls back to the kit's own
/// data from the server, then to the name saved with a share, then to a
/// neutral word. The closures run while a view draws, so reading observable
/// host state inside them keeps open screens live when a name or photo changes.
///
/// Nothing a host returns here is sent to the server: a share's saved label is
/// always the server's own name for the person.
///
/// The same shape exists in each of the sibling kits, so a host can build all
/// of them from one place. GarageKit reads `name` and `avatar`; `shortName` and
/// `presence` are accepted for that symmetry and not shown anywhere yet.
public struct GarageHostPeople: Sendable {
    let name: @MainActor @Sendable (UUID) -> String?
    let shortName: @MainActor @Sendable (UUID) -> String?
    let avatar: @MainActor @Sendable (UUID, CGFloat) -> AnyView?
    let presence: @MainActor @Sendable (UUID) -> GarageHostPresence?

    /// - Parameters:
    ///   - name: The person's name as the host shows it, already formatted.
    ///   - shortName: A short form for tight spots. Unused by GarageKit.
    ///   - avatar: The host draws the person's photo at the given diameter.
    ///     nil = the kit's own avatar (the server's photo, else initials).
    ///   - presence: Whether the person is around. Unused by GarageKit.
    public init(name: @escaping @MainActor @Sendable (UUID) -> String? = { _ in nil },
                shortName: @escaping @MainActor @Sendable (UUID) -> String? = { _ in nil },
                avatar: @escaping @MainActor @Sendable (UUID, CGFloat) -> AnyView? = { _, _ in nil },
                presence: @escaping @MainActor @Sendable (UUID) -> GarageHostPresence? = { _ in nil }) {
        self.name = name
        self.shortName = shortName
        self.avatar = avatar
        self.presence = presence
    }

    /// No host data: the server's names and photos alone (the kit's behaviour
    /// before hosts could supply people).
    public static let none = GarageHostPeople()

    /// The host's name for `id`, or nil when it has none.
    @MainActor
    func hostName(_ id: UUID) -> String? {
        guard let n = name(id)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return n
    }

    /// The host's names for `ids`, for the pure rules in `GarageSharing`.
    @MainActor
    func hostNames(_ ids: some Sequence<UUID>) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for id in ids { if let n = hostName(id) { out[id] = n } }
        return out
    }
}

/// Whether a person is around, as the host would show it. Mirrors the sibling
/// kits' type; GarageKit doesn't display presence.
public enum GarageHostPresence: Sendable, Equatable {
    /// In the host app right now.
    case active
    /// The host app is open but not in front; when they were last active, if known.
    case background(lastSeen: Date?)
    /// Away; when they were last seen, if known.
    case lastSeen(Date?)
}

extension EnvironmentValues {
    @Entry var garageHostPeople: GarageHostPeople = .none
}

public extension View {
    /// Name and picture people in GarageKit's views as the host does.
    func garageHostPeople(_ people: GarageHostPeople) -> some View {
        environment(\.garageHostPeople, people)
    }
}
