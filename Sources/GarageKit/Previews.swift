#if DEBUG
import SwiftUI

/// In-memory transport for previews: one door, configurable outcome and latency.
final class PreviewGarageTransport: GarageTransport, @unchecked Sendable {
    var doors: [GarageDoor]
    var outcome: TriggerOutcome
    var latency: Duration

    init(doors: [GarageDoor] = [.init(id: UUID(), name: "Garage", online: true, owned: false)],
         outcome: TriggerOutcome = .done, latency: Duration = .seconds(1.2)) {
        self.doors = doors
        self.outcome = outcome
        self.latency = latency
    }

    func listDoors() async throws -> [GarageDoor] { doors }
    func trigger(doorID: UUID, idempotencyKey: String, pressAgain: Bool) async -> TriggerOutcome {
        try? await Task.sleep(for: latency)
        return outcome
    }
    func listMyActivity(doorID: UUID, limit: Int) async throws -> [GarageActivity] {
        [.init(id: UUID(), doorID: doorID, kind: .done, at: .now.addingTimeInterval(-720)),
         .init(id: UUID(), doorID: doorID, kind: .offline, at: .now.addingTimeInterval(-90_000)),
         .init(id: UUID(), doorID: doorID, kind: .done, at: .now.addingTimeInterval(-100_000))]
    }
    func registerDevice(name: String) async throws -> RegisteredDevice {
        RegisteredDevice(doorID: UUID(), deviceID: UUID(), deviceToken: "preview")
    }
    func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) async throws -> GarageGrant {
        GarageGrant(id: UUID(), doorID: doorID, granteeID: granteeID, label: label, expiresAt: expiresAt)
    }
    func revokeGrant(id: UUID) async throws {}
    func renameDoor(id: UUID, to name: String) async throws {}
    func listGrants(doorID: UUID) async throws -> [GarageGrant] { [] }
}

@MainActor
private func previewEngine(_ outcome: TriggerOutcome, online: Bool = true) -> GarageEngine {
    let config = GarageConfig(baseURL: URL(string: "http://localhost:6092")!,
                              currentUserID: UUID(), tokenProvider: { "preview" })
    let transport = PreviewGarageTransport(
        doors: [.init(id: UUID(), name: "Garage", online: online, owned: false)], outcome: outcome)
    let engine = GarageEngine(config: config, transport: transport)
    engine.storeInMemory = true
    engine.start()
    return engine
}

#Preview("Success") { GarageView(engine: previewEngine(.done)) }
#Preview("Offline") { GarageView(engine: previewEngine(.offline, online: false)) }
#Preview("Denied") { GarageView(engine: previewEngine(.denied)) }
#endif
