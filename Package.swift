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
        .library(name: "PresidioCore", targets: ["PresidioCore"]),
        .library(name: "PresidioRegex", targets: ["PresidioRegex"]),
        .library(name: "PresidioAnalyzer", targets: ["PresidioAnalyzer"]),
        .library(name: "PresidioRecognizers", targets: ["PresidioRecognizers"]),
        .library(name: "PresidioAnonymizer", targets: ["PresidioAnonymizer"]),
        .library(name: "PresidioAnonymizerCrypto", targets: ["PresidioAnonymizerCrypto"]),
        .library(name: "PresidioNLP", targets: ["PresidioNLP"]),
    ],
    dependencies: [
        // Only PresidioAnonymizerCrypto depends on this. CryptoKit has no
        // AES-CBC mode at all, so encrypt/decrypt needs swift-crypto's
        // _CryptoExtras, which is BoringSSL-backed on every platform.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "PresidioCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Regex substrate. Character-class tables are generated from Python's
        // `regex` module and compiled in as source rather than read from the
        // host's ICU, whose Unicode data version varies by platform.
        // See docs/decisions/0001-regex-backend.md.
        .target(
            name: "PresidioRegex",
            dependencies: ["PresidioCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Recognizer engine: patterns + scoring + dedup.
        .target(
            name: "PresidioAnalyzer",
            dependencies: ["PresidioCore", "PresidioRegex"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The recognizer catalogue (data) plus the checksum logic that cannot
        // be expressed as data.
        .target(
            name: "PresidioRecognizers",
            dependencies: ["PresidioAnalyzer"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // De-identification: operators plus the span-rewriting engine.
        // Pure string manipulation — one regex upstream, no NLP — so it stays
        // dependency-free, including its own SHA-2.
        .target(
            name: "PresidioAnonymizer",
            dependencies: ["PresidioCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // AES-CBC encrypt/decrypt. Kept in its own target so the anonymizer
        // core stays dependency-free — swift-crypto vendors BoringSSL, which
        // does not build everywhere (WASM notably), and most callers do not
        // need reversible pseudonymization.
        .target(
            name: "PresidioAnonymizerCrypto",
            dependencies: [
                "PresidioAnonymizer",
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // spaCy's rule-based English tokenizer, plus the NORM tables the NER
        // model consumes as a feature. Rule-based, so it ports exactly.
        .target(
            name: "PresidioNLP",
            dependencies: ["PresidioCore", "PresidioRegex"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Benchmark harness. ADR 0001 traded throughput for cross-platform
        // determinism; this keeps a number on that trade.
        .executableTarget(
            name: "presidio-bench",
            dependencies: ["PresidioRegex"],
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
        .testTarget(
            name: "PresidioRecognizersTests",
            dependencies: ["PresidioRecognizers", "PresidioConformance"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PresidioAnonymizerCryptoTests",
            dependencies: ["PresidioAnonymizerCrypto", "PresidioConformance"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PresidioAnonymizerTests",
            dependencies: ["PresidioAnonymizer", "PresidioConformance"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PresidioNLPTests",
            dependencies: ["PresidioNLP", "PresidioConformance"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PresidioRegexTests",
            dependencies: ["PresidioRegex", "PresidioConformance"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
