import Foundation

/// The owner screen's rules, kept free of UI so they can be pinned by tests.
public enum GarageSharing {
    /// Whether a grant still opens the door. The server keeps listing grants
    /// past their end date (so they stay removable); they just stop working.
    public static func isActive(_ grant: GarageGrant, now: Date = .now) -> Bool {
        grant.expiresAt.map { $0 > now } ?? true
    }

    /// The line under a person on the owner screen: when their access ends,
    /// or that it already has.
    public static func accessLine(_ grant: GarageGrant, now: Date = .now) -> String {
        guard let end = grant.expiresAt else { return "No end date" }
        let when = end.formatted(date: .abbreviated, time: .shortened)
        return isActive(grant, now: now) ? "Until \(when)" : "Expired \(when)"
    }

    /// People who may be offered for a door: the contacts minus the owner and
    /// anyone with a grant that still works, sorted by the name shown (the
    /// host's, when it has one). Someone whose share ran out is offered again
    /// (sharing again renews their grant).
    public static func candidates(contacts: [GarageContact], grants: [GarageGrant], owner: UUID,
                                  hostNames: [UUID: String] = [:], now: Date = .now) -> [GarageContact] {
        let granted = Set(grants.filter { isActive($0, now: now) }.map(\.granteeID))
        return contacts
            .filter { $0.id != owner && !granted.contains($0.id) }
            .sorted { name(of: $0, hostNames: hostNames).localizedCaseInsensitiveCompare(name(of: $1, hostNames: hostNames)) == .orderedAscending }
    }

    /// How to show a contact: the host's name for them, else the server's.
    public static func name(of contact: GarageContact, hostNames: [UUID: String] = [:]) -> String {
        hostNames[contact.id] ?? contact.name
    }

    /// The candidates whose shown name matches `query` (all of them when it's blank).
    public static func search(_ candidates: [GarageContact], query: String,
                              hostNames: [UUID: String] = [:]) -> [GarageContact] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return candidates }
        return candidates.filter { name(of: $0, hostNames: hostNames).localizedCaseInsensitiveContains(q) }
    }

    /// How to show who a grant is for: the host's name for them, else the
    /// contact's current name, else the label saved with the grant, else a
    /// neutral word.
    public static func displayName(for grant: GarageGrant, contacts: [GarageContact],
                                   hostNames: [UUID: String] = [:]) -> String {
        if let n = hostNames[grant.granteeID] { return n }
        if let c = contacts.first(where: { $0.id == grant.granteeID }), !c.name.isEmpty { return c.name }
        let label = grant.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Someone" : label
    }

    /// An existing door whose name matches `name` (ignoring case and outer
    /// spaces), so adding a device can warn that it creates a second door.
    public static func nameClash(_ name: String, in doors: [GarageDoor]) -> GarageDoor? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        return doors.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The footer under the button picker when adding a door to a board: plain
    /// words for whether the board's firmware already drives that button.
    public static func buttonNote(_ button: Int, wired: [Int]) -> String {
        guard button > 0 else { return "Every button on this board already opens a door." }
        if wired.contains(button) {
            return "Program that remote button to the other opener first. Presses go to button \(button)."
        }
        return "This board doesn't drive button \(button) yet. Wire it and update the board; until then presses to this door won't go out."
    }
}
