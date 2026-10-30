// swift-tools-version: 6.0
import PackageDescription

// Logik der App ohne UI: SOAP-Client, lokale Datenbank, Suche, Inventar.
// Läuft auch auf macOS, damit `swift test` ohne Simulator und ohne Xcode-Projekt geht.
let package = Package(
    name: "BlechWikiCore",
    defaultLocalization: "de",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BlechWikiCore", targets: ["BlechWikiCore"]),
    ],
    targets: [
        .target(
            name: "BlechWikiCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "BlechWikiCoreTests",
            dependencies: ["BlechWikiCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
