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
