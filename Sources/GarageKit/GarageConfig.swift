import Foundation

/// Everything GarageKit needs from the host. The token provider is `@Sendable` +
/// `async` so the host can hand over its current mvServer access token
/// (auto-refreshed) from its own actor. GarageKit never logs anyone in.
public struct GarageConfig: Sendable {
    public let baseURL: URL
    /// The signed-in user (mvServer UUID).
    public let currentUserID: UUID
    public let tokenProvider: @Sendable () async -> String?
    /// Require a press-and-hold to trigger (default). A stray tap never fires.
    public let holdToTrigger: Bool
    /// How long the dial shows "door moving" after a confirmed press, before the
    /// checkmark. Roughly the door's travel time; the dial is locked meanwhile.
    public let motionDuration: Duration
    /// The host's App-Group identifier for the local activity store (e.g.
    /// "group.com.example.app"); nil → the app's own container (GarageLab/dev).
    public let appGroup: String?
    /// Where the local activity store lives, when the host wants it somewhere
    /// specific (e.g. a folder it keeps out of device backups). The kit creates
    /// the folder if needed and keeps its files in it (`Garage-<user id>.store`
    /// and SQLite's `-wal`/`-shm` beside it). Takes precedence over `appGroup`;
    /// nil → `appGroup`'s rules.
    public let storeDirectory: URL?

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                holdToTrigger: Bool = true,
                motionDuration: Duration = .seconds(6),
                appGroup: String? = nil,
                storeDirectory: URL? = nil) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.holdToTrigger = holdToTrigger
        self.motionDuration = motionDuration
        self.appGroup = appGroup
        self.storeDirectory = storeDirectory
    }

    /// The live transport — Connect/protobuf against mvGarage.
    public var transport: any GarageTransport {
        ConnectGarageTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
