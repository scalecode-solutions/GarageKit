import Foundation
import Testing
@testable import GarageKit

struct GarageSharingTests {
    let owner = UUID()
    let door = UUID()
    let ann = GarageContact(id: UUID(), name: "ann Lee")
    let bob = GarageContact(id: UUID(), name: "Bob Ray")
    let cy = GarageContact(id: UUID(), name: "Cy")

    func grant(_ who: UUID, label: String = "") -> GarageGrant {
        GarageGrant(id: UUID(), doorID: door, granteeID: who, label: label, expiresAt: nil)
    }

    @Test func candidatesSkipOwnerAndAlreadyShared() {
        let me = GarageContact(id: owner, name: "Me")
        let out = GarageSharing.candidates(contacts: [cy, me, bob, ann], grants: [grant(bob.id)], owner: owner)
        #expect(out.map(\.id) == [ann.id, cy.id]) // owner + Bob gone; case-insensitive name order
    }

    @Test func expiredShareIsOfferedAgainActiveOneIsNot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ran = GarageGrant(id: UUID(), doorID: door, granteeID: bob.id, label: "", expiresAt: now.addingTimeInterval(-60))
        let live = GarageGrant(id: UUID(), doorID: door, granteeID: ann.id, label: "", expiresAt: now.addingTimeInterval(60))
        let out = GarageSharing.candidates(contacts: [ann, bob, cy], grants: [ran, live], owner: owner, now: now)
        #expect(out.map(\.id) == [bob.id, cy.id]) // Bob's share ran out; Ann's still works
        #expect(!GarageSharing.isActive(ran, now: now))
        #expect(GarageSharing.isActive(live, now: now))
        #expect(GarageSharing.isActive(grant(cy.id), now: now)) // no end date
    }

    @Test func accessLineSaysExpiredOnceTheEndHasPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let g = { (end: Date?) in GarageGrant(id: UUID(), doorID: door, granteeID: ann.id, label: "", expiresAt: end) }
        #expect(GarageSharing.accessLine(g(nil), now: now) == "No end date")
        #expect(GarageSharing.accessLine(g(now.addingTimeInterval(60)), now: now).hasPrefix("Until "))
        #expect(GarageSharing.accessLine(g(now.addingTimeInterval(-60)), now: now).hasPrefix("Expired "))
    }

    @Test func candidatesWithNoGrantsIsEveryoneButOwner() {
        let out = GarageSharing.candidates(contacts: [bob, ann], grants: [], owner: owner)
        #expect(out.map(\.id) == [ann.id, bob.id])
    }

    @Test func displayNamePrefersContactThenLabelThenNeutral() {
        #expect(GarageSharing.displayName(for: grant(ann.id, label: "old"), contacts: [ann]) == "ann Lee")
        #expect(GarageSharing.displayName(for: grant(UUID(), label: " Shel "), contacts: [ann]) == "Shel")
        #expect(GarageSharing.displayName(for: grant(UUID()), contacts: []) == "Someone")
    }

    @Test func hostNamesWinForDisplaySortAndSearch() {
        // The host calls Bob "Ace" and Cy "zed"; Ann has no host name.
        let host: [UUID: String] = [bob.id: "Ace", cy.id: "zed"]
        #expect(GarageSharing.displayName(for: grant(bob.id, label: "Bob Ray"), contacts: [bob], hostNames: host) == "Ace")
        // A grantee the host knows but who isn't a contact any more still reads the host's name.
        #expect(GarageSharing.displayName(for: grant(cy.id, label: "old"), contacts: [], hostNames: host) == "zed")
        // No host name: the server's contact name, then the label, as before.
        #expect(GarageSharing.displayName(for: grant(ann.id, label: "old"), contacts: [ann], hostNames: host) == "ann Lee")
        // Sorted by the shown name: Ace (Bob), ann Lee, zed (Cy).
        let out = GarageSharing.candidates(contacts: [cy, ann, bob], grants: [], owner: owner, hostNames: host)
        #expect(out.map(\.id) == [bob.id, ann.id, cy.id])
        // Search matches the shown name, not the server's one it replaces.
        #expect(GarageSharing.search(out, query: "ace", hostNames: host).map(\.id) == [bob.id])
        #expect(GarageSharing.search(out, query: "Bob", hostNames: host).isEmpty)
        #expect(GarageSharing.search(out, query: "  ", hostNames: host).count == 3)
        #expect(GarageSharing.name(of: ann, hostNames: host) == "ann Lee")
    }

    @Test func nameClashIgnoresCaseAndSpaces() {
        let doors = [GarageDoor(id: UUID(), name: "Garage", online: true, owned: true)]
        #expect(GarageSharing.nameClash("  garage ", in: doors)?.name == "Garage")
        #expect(GarageSharing.nameClash("Side door", in: doors) == nil)
        #expect(GarageSharing.nameClash("   ", in: doors) == nil)
    }
}
