import Foundation
import Observation

/// The kit coordinator. Hosts build it inert, `start()` it on sign-in, `stop()`
/// it when going away, and call `wipeLocalStore()` on sign-out (the engine
/// lifetime law). While started it keeps the door list fresh (so the online dot
/// is honest) and runs presses.
@MainActor
@Observable
public final class GarageEngine {
    /// What a door's control is doing right now. The trigger UI animates from this.
    public enum Phase: Sendable, Equatable {
        case idle
        /// A press is on its way to the device.
        case sending
        /// The device confirmed the press; the door is presumably travelling. The
        /// big dial is locked so a stray second press can't stop it mid-travel.
        case moving
        /// A finished press (after `.moving` for a confirmed one).
        case finished(TriggerOutcome)
        /// A "Stop / press again" went through. No motion is implied — the door
        /// most likely stopped.
        case pressedAgain
    }

    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var doors: [GarageDoor] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var phases: [UUID: Phase] = [:]
    /// The user's own presses per door, newest first (local audit trail).
    public private(set) var activity: [UUID: [GarageActivity]] = [:]

    /// How long the "door moving" phase lasts after a confirmed press. Starts at
    /// `config.motionDuration`; hosts (GarageLab) may tune it live.
    public var motionDuration: Duration

    public let config: GarageConfig
    private let transport: any GarageTransport
    private var refreshTask: Task<Void, Never>?
    private var phaseTasks: [UUID: Task<Void, Never>] = [:]
    private var store: GarageStore?
    /// Bumped by stop(): any work that started before it must not write after it.
    private var generation = 0
    /// Bumped per refresh(): a slower, older refresh must not apply its list.
    private var refreshToken = 0
    /// Doors with a press on the wire. Survives stop() on purpose: a stop/start
    /// must never allow a second toggle while the first is still in flight.
    private var inFlight: Set<UUID> = []

    /// Tests use an in-memory store.
    var storeInMemory = false
    /// How many of the user's presses to keep per door.
    var activityLimit = 50
    /// How often the door list (online dots) refreshes while started.
    var refreshInterval: Duration = .seconds(20)
    /// How long a finished outcome stays on screen before the control resets.
    var resultHold: Duration = .seconds(2.4)

    public init(config: GarageConfig, transport: (any GarageTransport)? = nil) {
        self.config = config
        self.transport = transport ?? config.transport
        self.motionDuration = config.motionDuration
    }

    public func phase(for door: GarageDoor) -> Phase { phases[door.id] ?? .idle }

    /// When the user last actually used a door (the remote fired).
    public func lastUsed(_ door: GarageDoor) -> Date? {
        activity[door.id]?.first(where: { $0.kind.isUse })?.at
    }

    /// Whether the big dial may start a press now.
    public func canTrigger(_ door: GarageDoor) -> Bool {
        guard !inFlight.contains(door.id) else { return false }
        switch phase(for: door) {
        case .sending, .moving: return false
        default: return true
        }
    }

    /// Whether the secondary "Stop / press again" control applies now: while the
    /// door is (presumably) moving, or just after a press went through.
    public func canPressAgain(_ door: GarageDoor) -> Bool {
        guard !inFlight.contains(door.id) else { return false }
        switch phase(for: door) {
        case .moving, .pressedAgain: return true
        case .finished(let o): return o.isSuccess
        default: return false
        }
    }

    // MARK: lifecycle

    /// Begin keeping doors fresh. Idempotent.
    public func start() {
        guard refreshTask == nil else { return }
        // Open the local trail now (not in init — the engine stays inert until
        // started) and show it immediately, before the network answers.
        if store == nil {
            store = try? GarageStore(userID: config.currentUserID, appGroup: config.appGroup,
                                     inMemory: storeInMemory)
        }
        if let store { activity = store.all() }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop all work. Safe to call repeatedly. In-flight network calls finish, but
    /// nothing they return is applied.
    public func stop() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        phaseTasks.values.forEach { $0.cancel() }
        phaseTasks = [:]
        phases = [:]
    }

    /// Sign-out wipe: stop first (so nothing in flight writes back), then clear the
    /// local trail and forget the doors.
    public func wipeLocalStore() {
        stop()
        store?.wipeAll()
        store = nil
        activity = [:]
        doors = []
        loadState = .idle
    }

    /// Reload the door list now.
    public func refresh() async {
        let gen = generation
        refreshToken += 1
        let token = refreshToken
        if doors.isEmpty { loadState = .loading }
        do {
            let fresh = try await transport.listDoors()
            guard gen == generation, token == refreshToken else { return }
            if fresh != doors { doors = fresh }
            loadState = .loaded
            // Forget the trail for doors that are gone (e.g. a revoked grant).
            let ids = fresh.map(\.id)
            if activity.keys.contains(where: { !ids.contains($0) }) {
                store?.purge(keeping: ids)
                activity = activity.filter { ids.contains($0.key) }
            }
            for door in fresh { await refreshActivity(door) }
        } catch GarageTransportError.notAuthenticated {
            guard gen == generation else { return }
            loadState = .failed("Couldn't verify — try again")
        } catch {
            guard gen == generation else { return }
            // Keep the last good list on a transient failure; only surface an
            // error when there's nothing to show.
            if doors.isEmpty { loadState = .failed("Can't reach the garage right now") }
        }
    }

    /// Pull the user's latest presses for a door into the local trail. On failure
    /// the cached copy stays.
    public func refreshActivity(_ door: GarageDoor) async {
        let gen = generation
        guard let fresh = try? await transport.listMyActivity(doorID: door.id, limit: activityLimit),
              gen == generation,
              doors.contains(where: { $0.id == door.id }),
              fresh != activity[door.id] else { return }
        store?.replace(doorID: door.id, with: fresh)
        activity[door.id] = fresh
    }

    // MARK: presses

    /// The big dial. Allowed when idle or after a finished press; ignored while
    /// sending or while the door is moving. Returns the outcome, or nil if ignored.
    @discardableResult
    public func trigger(_ door: GarageDoor) async -> TriggerOutcome? {
        guard canTrigger(door) else { return nil }
        return await press(door, again: false)
    }

    /// "Stop / press again": the same toggle, allowed while the door is moving (a
    /// press during travel stops it; the next reverses it). Never while sending.
    @discardableResult
    public func pressAgain(_ door: GarageDoor) async -> TriggerOutcome? {
        guard canPressAgain(door) else { return nil }
        return await press(door, again: true)
    }

    private func press(_ door: GarageDoor, again: Bool) async -> TriggerOutcome {
        let gen = generation
        inFlight.insert(door.id)
        phaseTasks[door.id]?.cancel()
        phases[door.id] = .sending

        let outcome = await transport.trigger(doorID: door.id, idempotencyKey: UUID().uuidString,
                                              pressAgain: again)
        inFlight.remove(door.id)
        guard gen == generation else { return outcome } // stopped meanwhile: show nothing

        if outcome == .done && !again {
            // Confirmed press: show the door moving, then the checkmark.
            phases[door.id] = .moving
            schedule(door, after: motionDuration, then: .finished(.done), andReset: true)
        } else if again && outcome.isSuccess {
            phases[door.id] = .pressedAgain
            schedule(door, after: resultHold, then: .idle, andReset: false)
        } else {
            phases[door.id] = .finished(outcome)
            schedule(door, after: resultHold, then: .idle, andReset: false)
        }

        // An offline result means our online dot was stale — refresh it.
        if outcome == .offline { Task { await refresh() } }
        Task { await refreshActivity(door) }
        return outcome
    }

    /// After `delay`, set the door's phase (and optionally hold it, then go idle).
    private func schedule(_ door: GarageDoor, after delay: Duration, then next: Phase, andReset: Bool) {
        let gen = generation
        let hold = resultHold
        phaseTasks[door.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.phases[door.id] = next
            guard andReset else { return }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, gen == self.generation else { return }
            self.phases[door.id] = .idle
        }
    }

    // MARK: owner admin (GarageLab)

    public func registerDevice(name: String) async throws -> RegisteredDevice {
        let d = try await transport.registerDevice(name: name)
        await refresh()
        return d
    }

    /// Rename a door you own. Identity is the id; the name is a label, so the new
    /// name reaches every client (grantees too) on their next refresh.
    public func renameDoor(_ door: GarageDoor, to name: String) async throws {
        try await transport.renameDoor(id: door.id, to: name)
        await refresh()
    }

    public func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date? = nil) async throws -> GarageGrant {
        try await transport.createGrant(doorID: doorID, granteeID: granteeID, label: label, expiresAt: expiresAt)
    }

    public func revokeGrant(id: UUID) async throws { try await transport.revokeGrant(id: id) }

    public func listGrants(doorID: UUID) async throws -> [GarageGrant] {
        try await transport.listGrants(doorID: doorID)
    }
}
