import Foundation

/// A garage door the signed-in user may see.
public struct GarageDoor: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    /// Is the door's device connected to the server right now.
    public let online: Bool
    /// True if the user owns it (vs. was granted access).
    public let owned: Bool
    /// How long this door takes to travel (the dial's "door moving" phase).
    /// nil = not set: the engine uses the host's default.
    public let motion: Duration?
    /// The owner-picked color; `.standard` when none was chosen.
    public let color: GarageDoorColor
    /// Which button of the device's remote drives this door. Owners only (0
    /// for a door shared with you).
    public let button: Int
    /// The device behind the door. Owners only; nil for a door shared with you.
    public let device: GarageDeviceStatus?

    public init(id: UUID, name: String, online: Bool, owned: Bool,
                motion: Duration? = nil, color: GarageDoorColor = .standard,
                button: Int = 0, device: GarageDeviceStatus? = nil) {
        self.id = id
        self.name = name
        self.online = online
        self.owned = owned
        self.motion = motion
        self.color = color
        self.button = button
        self.device = device
    }
}

/// The owner's palette for telling doors apart at a glance. The server stores
/// the raw value; an unknown value (a newer palette) reads as `.standard`. No
/// red or orange: on the dial those mean something went wrong.
public enum GarageDoorColor: String, CaseIterable, Sendable, Hashable {
    case standard = ""
    case cyan, sky, blue, indigo, purple, pink, teal, mint, yellow, brown

    public init(token: String) { self = GarageDoorColor(rawValue: token) ?? .standard }

    /// The ones an owner picks from (`.standard` is "no choice": it looks cyan).
    public static var palette: [GarageDoorColor] { allCases.filter { $0 != .standard } }

    public var label: String {
        switch self {
        case .standard: "Default"
        default: rawValue.capitalized
        }
    }
}

/// What a door's device last said about itself. Shown to the owner only.
public struct GarageDeviceStatus: Sendable, Equatable, Hashable {
    public let deviceID: UUID
    public let firmware: String
    /// Wi-Fi signal in dBm; nil when unknown.
    public let rssi: Int?
    public let lastSeen: Date?
    public let lastHello: Date?
    public let resetReason: String
    public let bootCount: Int
    /// Remote buttons the firmware drives ([1] when it doesn't say).
    public let buttons: [Int]

    public init(deviceID: UUID, firmware: String = "", rssi: Int? = nil, lastSeen: Date? = nil,
                lastHello: Date? = nil, resetReason: String = "", bootCount: Int = 0, buttons: [Int] = [1]) {
        self.deviceID = deviceID
        self.firmware = firmware
        self.rssi = rssi
        self.lastSeen = lastSeen
        self.lastHello = lastHello
        self.resetReason = resetReason
        self.bootCount = bootCount
        self.buttons = buttons.isEmpty ? [1] : buttons
    }

    /// A plain-words read of the Wi-Fi signal.
    public var signal: String? {
        guard let rssi else { return nil }
        if rssi >= -55 { return "Strong" }
        if rssi >= -67 { return "Good" }
        if rssi >= -75 { return "Fair" }
        return "Weak"
    }
}

/// What happened when the user triggered a door. Mirrors the server's
/// CommandStatus, plus the client-side failures.
public enum TriggerOutcome: Sendable, Equatable {
    /// The device confirmed it pressed the button.
    case done
    /// Handed to the device, no confirmation in time. Probably fine.
    case sent
    /// The device isn't connected.
    case offline
    /// The device refused (busy, or reached it too late).
    case refused(String)
    /// Too many presses — the server rate-limited this user.
    case slowDown
    /// No access (grant revoked, or not visible to the owner).
    case denied
    /// The press may or may not have reached the door (the connection failed
    /// after it was sent). Check the door before pressing again — a second
    /// press on a toggle reverses it.
    case unknown(String)
    /// Known not to have been sent: no session, bad request, device error.
    case failed(String)

    /// Whether the outcome counts as success for feedback purposes.
    public var isSuccess: Bool {
        switch self {
        case .done, .sent: true
        default: false
        }
    }
}

/// A newly registered device (owner admin; used by GarageLab to set up a door).
public struct RegisteredDevice: Sendable, Equatable {
    public let doorID: UUID
    public let deviceID: UUID
    /// Shown once — the server keeps only its hash. Goes into the device firmware.
    public let deviceToken: String
}

/// An owner's grant letting another user trigger a door.
public struct GarageGrant: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let doorID: UUID
    public let granteeID: UUID
    public let label: String
    public let expiresAt: Date?

    public init(id: UUID, doorID: UUID, granteeID: UUID, label: String, expiresAt: Date?) {
        self.id = id
        self.doorID = doorID
        self.granteeID = granteeID
        self.label = label
        self.expiresAt = expiresAt
    }
}

/// Someone the signed-in user may share a door with (a friend in the social
/// graph). Only a picker's list: the server still decides whether a share is
/// allowed.
public struct GarageContact: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    /// A small profile image (decoded from the server's base64), if they have one.
    public let avatar: Data?

    public init(id: UUID, name: String, avatar: Data? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

/// One of the user's own presses — the local audit trail.
public struct GarageActivity: Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case done, sent, offline, refused, expired, failed

        /// Counts as "the door was used" (the remote fired).
        public var isUse: Bool { self == .done || self == .sent }
    }

    public let id: UUID
    public let doorID: UUID
    public let kind: Kind
    public let at: Date
    /// Sent by "Stop / press again" (a press while the door was presumably
    /// travelling), not the main dial. Direction is still unknown.
    public let pressAgain: Bool

    public init(id: UUID, doorID: UUID, kind: Kind, at: Date, pressAgain: Bool = false) {
        self.id = id
        self.doorID = doorID
        self.kind = kind
        self.at = at
        self.pressAgain = pressAgain
    }
}
