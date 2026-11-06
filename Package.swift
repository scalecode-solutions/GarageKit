// swift-tools-version: 6.2
import PackageDescription

// GarageKit — the garage-door client as a self-contained SPM: Connect transport,
// a small engine, and the trigger UI. Talks to mvGarage (Connect/protobuf). A host
// (GarageLab, or a production app) adds a thin wrapper that supplies identity + a token.
//
// Mirrors TraxKit's shape: the kit never owns login — the host injects a
// `tokenProvider`. Swift 6 strict concurrency from line one.
let package = Package(
    name: "GarageKit",
    platforms: [.iOS(.v26)], // iOS-only
    products: [
        .library(name: "GarageKit", targets: ["GarageKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.27.0"),
    ],
    targets: [
        .target(
            name: "GarageKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GarageKitTests",
            dependencies: ["GarageKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
