// swift-tools-version: 6.0
import PackageDescription

// Swift Presidio — a Presidio-compatible PII detection and anonymization library.
//
// Portability discipline (see PLAN.md §4): this package must never import an
// Apple closed-source framework. macOS is the first supported platform, but the
// source stays portable so Android/Windows are a port, not a rewrite.
// Use `import Foundation` — never `FoundationEssentials`, which does not exist
// on Darwin.

let package = Package(
    name: "SwiftPresidio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PresidioCore", targets: ["PresidioCore"])
    ],
    targets: [
        .target(
            name: "PresidioCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Test-support target holding the conformance corpus harvested from
        // Presidio's own pytest suite. Shared by every test target so the
        // fixtures live in exactly one place.
        .target(
            name: "PresidioConformance",
            path: "Tests/PresidioConformance",
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "PresidioCoreTests",
            dependencies: ["PresidioCore", "PresidioConformance"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
