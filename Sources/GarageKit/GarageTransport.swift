import Foundation
import Connect
import SwiftProtobuf

/// Transport-level failures.
public enum GarageTransportError: Error, Sendable, Equatable {
    case notAuthenticated            // no token available
    case rpc(code: String, message: String)
    case badResponse(String)
}

/// The kit's view of the server. A protocol so tests and previews can fake it.
public protocol GarageTransport: Sendable {
    func listDoors() async throws -> [GarageDoor]
    /// Trigger a door. Never throws for expected outcomes — they come back as a
    /// `TriggerOutcome`; throws only on programmer error.
    func trigger(doorID: UUID, idempotencyKey: String, pressAgain: Bool) async -> TriggerOutcome
    /// The caller's own presses on a door, newest first.
    func listMyActivity(doorID: UUID, limit: Int) async throws -> [GarageActivity]

    // Owner admin (GarageLab uses these; a grantee-only host doesn't).
    func registerDevice(name: String) async throws -> RegisteredDevice
    func renameDoor(id: UUID, to name: String) async throws
    func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) async throws -> GarageGrant
    func revokeGrant(id: UUID) async throws
    func listGrants(doorID: UUID) async throws -> [GarageGrant]
}

/// `GarageTransport` over Connect/protobuf. Wraps the codegen'd client and injects
/// the bearer token per call.
public struct ConnectGarageTransport: GarageTransport {
    private let client: Garage_V1_GarageServiceClient
    private let tokenProvider: @Sendable () async -> String?

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        let config = ProtocolClientConfig(host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec())
        let proto = ProtocolClient(httpClient: URLSessionHTTPClient(), config: config)
        self.client = Garage_V1_GarageServiceClient(client: proto)
        self.tokenProvider = tokenProvider
    }

    // MARK: plumbing

    private func authHeaders() async throws -> Headers {
        // No token → fail locally rather than send a request the server can only reject.
        guard let tok = await tokenProvider() else { throw GarageTransportError.notAuthenticated }
        return ["Authorization": ["Bearer \(tok)"]]
    }

    private func value<T>(_ r: ResponseMessage<T>) throws -> T {
        if let m = r.message { return m }
        if let e = r.error {
            // A server-side 401 is the same state as having no token: signed out.
            if e.code == .unauthenticated { throw GarageTransportError.notAuthenticated }
            throw GarageTransportError.rpc(code: "\(e.code)", message: e.message ?? "rpc failed")
        }
        throw GarageTransportError.badResponse("empty rpc response")
    }

    private func uuid(_ s: String) throws -> UUID {
        guard let u = UUID(uuidString: s) else { throw GarageTransportError.badResponse("bad uuid \(s)") }
        return u
    }

    // MARK: doors

    public func listDoors() async throws -> [GarageDoor] {
        let r = try value(await client.listDoors(request: .init(), headers: try await authHeaders()))
        return try r.doors.map { d in
            GarageDoor(id: try uuid(d.id), name: d.name, online: d.online, owned: d.owned)
        }
    }

    public func trigger(doorID: UUID, idempotencyKey: String, pressAgain: Bool) async -> TriggerOutcome {
        let headers: Headers
        do { headers = try await authHeaders() } catch { return .failed("Not signed in") }

        var req = Garage_V1_SendCommandRequest()
        req.doorID = doorID.uuidString
        req.action = .toggle
        req.clientCommandID = idempotencyKey
        req.pressAgain = pressAgain
        let r = await client.sendCommand(request: req, headers: headers)

        if let e = r.error {
            switch e.code {
            // Refusals the server makes BEFORE anything is sent to the door.
            case .resourceExhausted: return .slowDown
            case .permissionDenied, .notFound: return .denied
            case .unauthenticated: return .failed("Couldn't verify — try again")
            case .invalidArgument: return .failed(e.message ?? "Bad request")
            // Anything else may have happened after the press left: don't claim
            // it failed, or she presses again and reverses the door.
            default: return .unknown(Self.mayHaveGone)
            }
        }
        guard let m = r.message else { return .unknown(Self.mayHaveGone) }
        switch m.status {
        case .acked: return .done
        case .sent: return .sent
        case .offline: return .offline
        case .refused, .expired: return .refused(m.detail.isEmpty ? "Device declined" : m.detail)
        default: return .failed(m.detail.isEmpty ? "Something went wrong" : m.detail)
        }
    }

    public func listMyActivity(doorID: UUID, limit: Int) async throws -> [GarageActivity] {
        var req = Garage_V1_ListMyActivityRequest()
        req.doorID = doorID.uuidString
        req.limit = Int32(limit)
        let r = try value(await client.listMyActivity(request: req, headers: try await authHeaders()))
        return try r.activity.map { a in
            GarageActivity(id: try uuid(a.id), doorID: try uuid(a.doorID), kind: kind(a.status),
                           at: Date(timeIntervalSince1970: Double(a.at) / 1000), pressAgain: a.pressAgain)
        }
    }

    private func kind(_ s: Garage_V1_CommandStatus) -> GarageActivity.Kind {
        switch s {
        case .acked: .done
        case .sent: .sent
        case .offline: .offline
        case .refused: .refused
        case .expired: .expired
        default: .failed
        }
    }

    static let mayHaveGone = "May have gone through — check the door before pressing again"

    // MARK: owner admin

    public func registerDevice(name: String) async throws -> RegisteredDevice {
        var req = Garage_V1_RegisterDeviceRequest()
        req.name = name
        req.hw = "v1-remote"
        let r = try value(await client.registerDevice(request: req, headers: try await authHeaders()))
        return RegisteredDevice(doorID: try uuid(r.doorID), deviceID: try uuid(r.deviceID), deviceToken: r.deviceToken)
    }

    public func renameDoor(id: UUID, to name: String) async throws {
        var req = Garage_V1_RenameDoorRequest()
        req.doorID = id.uuidString
        req.name = name
        _ = try value(await client.renameDoor(request: req, headers: try await authHeaders()))
    }

    public func createGrant(doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) async throws -> GarageGrant {
        var req = Garage_V1_CreateGrantRequest()
        req.doorID = doorID.uuidString
        req.granteeID = granteeID.uuidString
        req.label = label
        if let expiresAt { req.expiresAt = Int64(expiresAt.timeIntervalSince1970 * 1000) }
        let r = try value(await client.createGrant(request: req, headers: try await authHeaders()))
        return try grant(r.grant)
    }

    public func revokeGrant(id: UUID) async throws {
        var req = Garage_V1_RevokeGrantRequest()
        req.grantID = id.uuidString
        _ = try value(await client.revokeGrant(request: req, headers: try await authHeaders()))
    }

    public func listGrants(doorID: UUID) async throws -> [GarageGrant] {
        var req = Garage_V1_ListGrantsRequest()
        req.doorID = doorID.uuidString
        let r = try value(await client.listGrants(request: req, headers: try await authHeaders()))
        return try r.grants.map(grant)
    }

    private func grant(_ g: Garage_V1_Grant) throws -> GarageGrant {
        GarageGrant(id: try uuid(g.id), doorID: try uuid(g.doorID), granteeID: try uuid(g.granteeID),
                    label: g.label,
                    expiresAt: g.expiresAt > 0 ? Date(timeIntervalSince1970: Double(g.expiresAt) / 1000) : nil)
    }
}
