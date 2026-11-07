import Foundation

/// The owner screen's rules, kept free of UI so they can be pinned by tests.
public enum GarageSharing {
    /// People who may be offered for a door: the contacts minus the owner and
    /// anyone who already has a grant on it, sorted by name.
    public static func candidates(contacts: [GarageContact], grants: [GarageGrant], owner: UUID) -> [GarageContact] {
        let granted = Set(grants.map(\.granteeID))
        return contacts
            .filter { $0.id != owner && !granted.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// How to show who a grant is for: the contact's current name, else the
    /// label saved with the grant, else a neutral word.
    public static func displayName(for grant: GarageGrant, contacts: [GarageContact]) -> String {
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
}
