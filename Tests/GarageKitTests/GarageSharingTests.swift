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

    @Test func nameClashIgnoresCaseAndSpaces() {
        let doors = [GarageDoor(id: UUID(), name: "Garage", online: true, owned: true)]
        #expect(GarageSharing.nameClash("  garage ", in: doors)?.name == "Garage")
        #expect(GarageSharing.nameClash("Side door", in: doors) == nil)
        #expect(GarageSharing.nameClash("   ", in: doors) == nil)
    }
}
