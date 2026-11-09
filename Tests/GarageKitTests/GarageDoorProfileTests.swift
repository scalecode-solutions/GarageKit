import Foundation
import Testing
@testable import GarageKit

/// Door profiles (MVGARA-24): per-door travel time, color, device status,
/// several doors on one board, and the remembered door.
@MainActor
struct GarageDoorProfileTests {
    let device = GarageDeviceStatus(deviceID: UUID(), firmware: "c3-0.7.0", rssi: -64, buttons: [1, 2])

    func makeEngine(_ t: FakeTransport, user: UUID = UUID()) -> GarageEngine {
        let config = GarageConfig(baseURL: URL(string: "http://localhost")!,
                                  currentUserID: user, tokenProvider: { "tok" },
                                  motionDuration: .seconds(12))
        let e = GarageEngine(config: config, transport: t)
        e.storeInMemory = true
        return e
    }

    @Test func doorTravelTimeWinsOverTheDefault() {
        let e = makeEngine(FakeTransport())
        let timed = GarageDoor(id: UUID(), name: "East", online: true, owned: true, motion: .seconds(9))
        let untimed = GarageDoor(id: UUID(), name: "West", online: true, owned: true)
        #expect(e.motion(for: timed) == .seconds(9))
        #expect(e.motion(for: untimed) == .seconds(12))
    }

    @Test func updateDoorPassesThroughAndRefreshes() async throws {
        let t = FakeTransport()
        let east = GarageDoor(id: UUID(), name: "East", online: true, owned: true, device: device)
        t.set { $0.doors = [east] }
        let e = makeEngine(t)
        await e.refresh()
        try await e.updateDoor(east, motion: .seconds(14), color: .teal)
        #expect(e.doors.first?.motion == .seconds(14))
        #expect(e.doors.first?.color == .teal)
        // .zero clears the travel time back to the default.
        try await e.updateDoor(e.doors[0], motion: .zero)
        #expect(e.doors.first?.motion == nil)
        #expect(e.motion(for: e.doors[0]) == .seconds(12))
    }

    @Test func addDoorLandsOnTheSameBoardInButtonOrder() async throws {
        let t = FakeTransport()
        let east = GarageDoor(id: UUID(), name: "East", online: true, owned: true, button: 1, device: device)
        let other = GarageDoor(id: UUID(), name: "Shed", online: true, owned: true, button: 1,
                               device: GarageDeviceStatus(deviceID: UUID()))
        t.set { $0.doors = [other, east] }
        let e = makeEngine(t)
        await e.refresh()
        try await e.addDoor(on: device, name: "West", button: 2)
        let added = t.state.withLock { $0.added }
        #expect(added.count == 1 && added[0].0 == device.deviceID && added[0].2 == 2)
        #expect(e.doorsOnDevice(of: east).map(\.name) == ["East", "West"])
        #expect(e.doorsOnDevice(of: other).map(\.name) == ["Shed"])
        // A shared door has no device status: no board siblings.
        #expect(e.doorsOnDevice(of: GarageDoor(id: UUID(), name: "x", online: true, owned: false)).isEmpty)
    }

    @Test func theChosenDoorIsRememberedPerUserAndWipedOnSignOut() async {
        let user = UUID()
        let t = FakeTransport()
        let a = GarageDoor(id: UUID(), name: "East", online: true, owned: true)
        let b = GarageDoor(id: UUID(), name: "West", online: true, owned: true)
        t.set { $0.doors = [a, b] }
        let e = makeEngine(t, user: user)
        await e.refresh()
        #expect(e.focusedDoor == a) // nothing chosen: the first
        e.selectedDoorID = b.id
        #expect(e.focusedDoor == b)

        let again = makeEngine(t, user: user) // e.g. next launch
        await again.refresh()
        #expect(again.focusedDoor == b)
        #expect(makeEngine(t).selectedDoorID == nil) // another user: not shared

        again.wipeLocalStore()
        #expect(makeEngine(t, user: user).selectedDoorID == nil)
    }

    @Test func aForgottenDoorFallsBackToTheFirst() async {
        let t = FakeTransport()
        let a = GarageDoor(id: UUID(), name: "East", online: true, owned: true)
        t.set { $0.doors = [a] }
        let e = makeEngine(t)
        e.selectedDoorID = UUID() // a door that's gone (revoked, removed)
        await e.refresh()
        #expect(e.focusedDoor == a)
        e.wipeLocalStore()
    }

    @Test func paletteIsTenWithNoAlarmColorsAndUnknownTokensAreDefault() {
        #expect(GarageDoorColor.palette.count == 10)
        #expect(!GarageDoorColor.palette.map(\.rawValue).contains("red"))
        #expect(!GarageDoorColor.palette.map(\.rawValue).contains("orange"))
        #expect(GarageDoorColor(token: "teal") == .teal)
        #expect(GarageDoorColor(token: "") == .standard)
        #expect(GarageDoorColor(token: "chartreuse") == .standard) // a newer server palette
    }

    @Test func signalWordsAndButtonDefaults() {
        let s = { (r: Int?) in GarageDeviceStatus(deviceID: UUID(), rssi: r).signal }
        #expect(s(-41) == "Strong")
        #expect(s(-64) == "Good")
        #expect(s(-72) == "Fair")
        #expect(s(-85) == "Weak")
        #expect(s(nil) == nil)
        #expect(GarageDeviceStatus(deviceID: UUID(), buttons: []).buttons == [1])
    }

    @Test func buttonNoteSaysWhenTheBoardCantPressItYet() {
        #expect(GarageSharing.buttonNote(2, wired: [1]).contains("doesn't drive button 2"))
        #expect(GarageSharing.buttonNote(2, wired: [1, 2]).contains("Program that remote button"))
        #expect(GarageSharing.buttonNote(0, wired: [1, 2, 3, 4]).contains("already opens a door"))
    }

    /// Transports without profiles (older fakes, host stubs) still conform; the
    /// calls fail plainly instead of pretending.
    @Test func transportsWithoutProfilesStillConform() async {
        struct Minimal: GarageTransport {
            func listDoors() async throws -> [GarageDoor] { [] }
            func trigger(doorID: UUID, idempotencyKey: String, pressAgain: Bool) async -> TriggerOutcome { .done }
            func listMyActivity(doorID: UUID, limit: Int) async throws -> [GarageActivity] { [] }
            func registerDevice(name: String) async throws -> RegisteredDevice { throw CancellationError() }
            func renameDoor(id: UUID, to name: String) async throws {}
            func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) async throws -> GarageGrant { throw CancellationError() }
            func revokeGrant(id: UUID) async throws {}
            func listGrants(doorID: UUID) async throws -> [GarageGrant] { [] }
        }
        await #expect(throws: GarageTransportError.self) {
            try await Minimal().updateDoor(id: UUID(), name: "x", motion: nil, color: nil)
        }
        await #expect(throws: GarageTransportError.self) {
            try await Minimal().addDoor(deviceID: UUID(), name: "x", button: 2)
        }
    }
}
