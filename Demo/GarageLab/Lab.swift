import Foundation

/// Which backend GarageLab talks to. Auth goes to mvServer (WebSocket via MvAuth);
/// garage calls go to mvGarage (Connect via GarageKit). Same credentials, two
/// services. Develop against **Local** (mvServer + mvGarage in local Docker).
enum LabServer: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case local = "Local"

    var id: String { rawValue }

    /// mvServer WebSocket endpoint MvAuth logs in against.
    var authWS: URL {
        switch self {
        case .production: URL(string: "wss://api.mvchat.app/v0/ws")!
        case .local:      URL(string: "ws://localhost:6170/v0/ws")!
        }
    }

    /// mvGarage base URL GarageKit talks to. Production hostname is a placeholder
    /// until the mvchat.app subdomain is picked (DESIGN.md open question).
    var garageBaseURL: URL {
        switch self {
        case .production: URL(string: "https://garage.mvchat.app")!
        case .local:      URL(string: "http://localhost:6092")!
        }
    }
}
