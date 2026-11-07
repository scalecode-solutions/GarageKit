import Foundation
import Synchronization
import Testing
@testable import GarageKit

/// Scriptable transport for engine tests. State is behind a Mutex so the
/// nonisolated transport calls don't race the test body.
final class FakeTransport: GarageTransport, Sendable {
    struct State {
        var doors: [GarageDoor] = []
        var outcome: TriggerOutcome = .done
        var listError: GarageTransportError?
        var myActivity: [GarageActivity] = []
        var triggerCalls = 0
        var pressAgainFlags: [Bool] = []
        var activityCalls = 0
        var holdTriggers = false
        var contacts: [GarageContact] = []
        var gate: CheckedContinuation<Void, Never>?
    }
    let state = Mutex(State())

    func set(_ f: (inout State) -> Void) { state.withLock { f(&$0) } }
    var triggerCalls: Int { state.withLock { $0.triggerCalls } }
    var activityCalls: Int { state.withLock { $0.activityCalls } }

    func listDoors() async throws -> [GarageDoor] {
        try state.withLock { s in
            if let e = s.listError { throw e }
            return s.doors
        }
    }
    func trigger(doorID: UUID, idempotencyKey: String, pressAgain: Bool) async -> TriggerOutcome {
        let hold = state.withLock { s in
            s.triggerCalls += 1
            s.pressAgainFlags.append(pressAgain)
            return s.holdTriggers
        }
        if hold { await withCheckedContinuation { c in state.withLock { $0.gate = c } } }
        return state.withLock { $0.outcome }
    }
    func release() { state.withLock { s in s.gate?.resume(); s.gate = nil } }
    func listMyActivity(doorID: UUID, limit: Int) async throws -> [GarageActivity] {
        state.withLock { s in
            s.activityCalls += 1
            return s.myActivity.filter { $0.doorID == doorID }
        }
    }
    func registerDevice(name: String) async throws -> RegisteredDevice {
        RegisteredDevice(doorID: UUID(), deviceID: UUID(), deviceToken: "t")
    }
    func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) async throws -> GarageGrant {
        GarageGrant(id: UUID(), doorID: doorID, granteeID: granteeID, label: label, expiresAt: expiresAt)
    }
    func revokeGrant(id: UUID) async throws {}
    func renameDoor(id: UUID, to name: String) async throws {}
    func listGrants(doorID: UUID) async throws -> [GarageGrant] { [] }
    func listContacts() async throws -> [GarageContact] { state.withLock { $0.contacts } }
}

@MainActor
struct GarageEngineTests {
    let door = GarageDoor(id: UUID(), name: "Garage", online: true, owned: false)

    func makeEngine(_ t: FakeTransport) -> GarageEngine {
        let config = GarageConfig(baseURL: URL(string: "http://localhost")!,
                                  currentUserID: UUID(), tokenProvider: { "tok" })
        let e = GarageEngine(config: config, transport: t)
        e.resultHold = .milliseconds(50)
        e.motionDuration = .milliseconds(80)
        e.storeInMemory = true
        return e
    }

    /// Wait (bounded) until the engine reaches a phase.
    func waitFor(_ e: GarageEngine, _ p: GarageEngine.Phase, within ms: Int = 1000) async -> Bool {
        for _ in 0..<(ms / 10) {
            if e.phase(for: door) == p { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return e.phase(for: door) == p
    }

    /// Wait (bounded) for a condition — start() runs its own refresh concurrently,
    /// and only the newest refresh applies, so tests wait for the outcome.
    func until(_ cond: () -> Bool, within ms: Int = 1000) async -> Bool {
        for _ in 0..<(ms / 10) {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    // MARK: doors

    @Test func listContactsPassesThrough() async throws {
        let t = FakeTransport()
        let ann = GarageContact(id: UUID(), name: "Ann", avatar: Data([1, 2]))
        t.set { $0.contacts = [ann] }
        #expect(try await makeEngine(t).listContacts() == [ann])
    }

    /// A transport that doesn't implement contacts (older fakes, host stubs)
    /// still conforms, and offers nobody.
    @Test func defaultContactsIsEmpty() async throws {
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
        #expect(try await Minimal().listContacts().isEmpty)
    }

    @Test func refreshLoadsDoors() async {
        let t = FakeTransport(); t.set { $0.doors = [door] }
        let e = makeEngine(t)
        await e.refresh()
        #expect(e.doors == [door])
        #expect(e.loadState == .loaded)
    }

    @Test func notAuthenticatedSurfaces() async {
        let t = FakeTransport(); t.set { $0.listError = .notAuthenticated }
        let e = makeEngine(t)
        await e.refresh()
        #expect(e.loadState == .failed("Couldn't verify — try again"))
    }

    @Test func transientFailureKeepsLastGoodList() async {
        let t = FakeTransport(); t.set { $0.doors = [door] }
        let e = makeEngine(t)
        await e.refresh()
        t.set { $0.listError = .badResponse("boom") }
        await e.refresh()
        #expect(e.doors == [door])
        #expect(e.loadState == .loaded)
    }

    // MARK: press sequence

    @Test func confirmedPressMovesThenChecksThenIdles() async {
        let t = FakeTransport(); t.set { $0.outcome = .done }
        let e = makeEngine(t)
        let outcome = await e.trigger(door)
        #expect(outcome == .done)
        #expect(e.phase(for: door) == .moving)
        #expect(await waitFor(e, .finished(.done)))
        #expect(await waitFor(e, .idle))
    }

    @Test func failuresAndUnknownSkipMotion() async {
        for o: TriggerOutcome in [.offline, .denied, .unknown("?"), .failed("x"), .sent] {
            let t = FakeTransport(); t.set { $0.outcome = o }
            let e = makeEngine(t)
            await e.trigger(door)
            #expect(e.phase(for: door) == .finished(o), "outcome \(o)")
        }
    }

    @Test func bigDialLockedWhileMoving() async {
        let t = FakeTransport(); t.set { $0.outcome = .done }
        let e = makeEngine(t)
        e.motionDuration = .seconds(5)
        await e.trigger(door)
        #expect(e.phase(for: door) == .moving)
        #expect(e.canTrigger(door) == false)
        #expect(await e.trigger(door) == nil)
        #expect(t.triggerCalls == 1)
        e.stop()
    }

    @Test func pressAgainWhileMovingGoesStraightToPressed() async {
        let t = FakeTransport(); t.set { $0.outcome = .done }
        let e = makeEngine(t)
        e.motionDuration = .seconds(5)
        await e.trigger(door)
        #expect(e.canPressAgain(door))
        let again = await e.pressAgain(door)
        #expect(again == .done)
        #expect(e.phase(for: door) == .pressedAgain) // no motion implied
        #expect(t.triggerCalls == 2)
        #expect(t.state.withLock { $0.pressAgainFlags } == [false, true]) // audit flag sent
        e.stop()
    }

    @Test func pressAgainNotOfferedAtIdleOrAfterFailure() async {
        let t = FakeTransport(); t.set { $0.outcome = .offline }
        let e = makeEngine(t)
        #expect(e.canPressAgain(door) == false)
        await e.trigger(door)
        #expect(e.canPressAgain(door) == false)
        #expect(await e.pressAgain(door) == nil)
    }

    @Test func secondPressWhileSendingIsIgnored() async throws {
        let t = FakeTransport(); t.set { $0.holdTriggers = true }
        let e = makeEngine(t)
        let first = Task { await e.trigger(door) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(e.phase(for: door) == .sending)
        #expect(await e.trigger(door) == nil)
        #expect(await e.pressAgain(door) == nil)
        t.release()
        _ = await first.value
        #expect(t.triggerCalls == 1)
    }

    @Test func stopStartCannotDoubleToggleWhileInFlight() async throws {
        let t = FakeTransport(); t.set { $0.holdTriggers = true }
        let e = makeEngine(t)
        let first = Task { await e.trigger(door) }
        try await Task.sleep(for: .milliseconds(30))
        e.stop()                    // phases cleared, but the press is still on the wire
        e.start()
        #expect(e.phase(for: door) == .idle)
        #expect(await e.trigger(door) == nil)
        t.release()
        _ = await first.value
        #expect(t.triggerCalls == 1)
        #expect(e.phase(for: door) == .idle) // the stale result was not applied
        e.stop()
    }

    @Test func stopClearsPhases() async {
        let t = FakeTransport()
        let e = makeEngine(t)
        e.motionDuration = .seconds(60)
        await e.trigger(door)
        e.stop()
        #expect(e.phase(for: door) == .idle)
    }

    // MARK: activity trail

    @Test func refreshPullsActivityAndLastUsedSkipsFailures() async {
        let t = FakeTransport()
        let used = Date(timeIntervalSince1970: 1_000)
        t.set {
            $0.doors = [door]
            $0.myActivity = [
                .init(id: UUID(), doorID: door.id, kind: .offline, at: Date(timeIntervalSince1970: 2_000)),
                .init(id: UUID(), doorID: door.id, kind: .done, at: used),
            ]
        }
        let e = makeEngine(t)
        e.start()
        #expect(await until { e.activity[door.id]?.count == 2 })
        #expect(e.lastUsed(door) == used)
        e.stop()
    }

    @Test func revokedDoorTrailIsPurged() async {
        let t = FakeTransport()
        t.set { $0.doors = [door]; $0.myActivity = [.init(id: UUID(), doorID: door.id, kind: .done, at: .now)] }
        let e = makeEngine(t)
        e.start()
        #expect(await until { e.lastUsed(door) != nil })
        t.set { $0.doors = [] }
        await e.refresh()
        #expect(await until { e.activity[door.id] == nil })
        e.stop()
    }

    @Test func pressRefreshesActivity() async throws {
        let t = FakeTransport(); t.set { $0.doors = [door] }
        let e = makeEngine(t)
        e.start()
        await e.refresh()
        let before = t.activityCalls
        await e.trigger(door)
        try await Task.sleep(for: .milliseconds(50))
        #expect(t.activityCalls > before)
        e.stop()
    }

    @Test func wipeClearsTrailAndNothingWritesBack() async throws {
        let t = FakeTransport()
        t.set { $0.doors = [door]; $0.myActivity = [.init(id: UUID(), doorID: door.id, kind: .done, at: .now)] }
        let e = makeEngine(t)
        e.start()
        await e.refresh()
        await e.trigger(door)       // leaves an activity refresh Task in flight
        e.wipeLocalStore()
        try await Task.sleep(for: .milliseconds(80))
        #expect(e.activity.isEmpty)
        #expect(e.doors.isEmpty)
    }
}
