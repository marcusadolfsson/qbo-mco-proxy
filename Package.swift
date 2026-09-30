// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QBOBar",
    // macOS 14: MenuBarExtra (13+) and the Observation framework (14+).
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QBOCore", targets: ["QBOCore"]),
        .executable(name: "QBOBar", targets: ["QBOBar"]),
    ],
    targets: [
        // Everything that is not UI: the HTTP/SSE gateway, the per-company
        // upstream supervisor, Intuit OAuth, and on-disk/Keychain state.
        .target(name: "QBOCore"),
        // The menu bar app. Assembled into QBOBar.app by `make app`, since a
        // MenuBarExtra needs a bundle with LSUIElement to run as a status item.
        .executableTarget(name: "QBOBar", dependencies: ["QBOCore"]),
        .testTarget(
            name: "QBOCoreTests", dependencies: ["QBOCore"],
            resources: [.copy("Fixtures")],
            // XCTestCase is not Sendable, and the concurrency tests fan out
            // from it; the product targets stay in Swift 6 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
