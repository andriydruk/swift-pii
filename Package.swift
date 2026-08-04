// swift-tools-version: 6.1
import PackageDescription

// swift-pii — a Presidio-compatible PII detection and anonymization library.
//
// Not affiliated with the Presidio project. Module names carry the `Presidio`
// prefix to say what they are compatible with; the package does not, because a
// package name implies authorship.
//
// Portability discipline (see PLAN.md §4): this package must never import an
// Apple closed-source framework in a default build. macOS is the first
// supported platform, but the source stays portable so Android/Windows are a
// port, not a rewrite. The single exception is the opt-in `PresidioAccelerate`
// trait below, which Tools/check_portability.sh polices rather than trusts.
// Use `import Foundation` — never `FoundationEssentials`, which does not exist
// on Darwin.
//
// swift-tools-version is 6.1 because traits need it.

let package = Package(
    name: "swift-pii",
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
        .library(name: "PresidioEngine", targets: ["PresidioEngine"]),
        .library(name: "PresidioEngineYAML", targets: ["PresidioEngineYAML"]),
        .library(name: "PresidioModelEnglish", targets: ["PresidioModelEnglish"]),
        .executable(name: "swift-pii", targets: ["swift-pii-cli"]),
    ],
    // Opt-in, and deliberately not a default trait.
    //
    // Enabling it swaps the hand-written SIMD matrix multiply for Accelerate's
    // cblas_sgemm on Apple platforms: ~4.7x on the shapes this model uses, about
    // 25-35% off end-to-end inference. Every parity corpus produces identical
    // *outcomes* either way, but the intermediate floats differ in their last
    // bits, so with this on macOS no longer runs the same arithmetic as Linux and
    // Android. That is the whole reason it is a choice rather than the default.
    // CI runs the parity suites both ways. See Sources/PresidioNLP/GEMM.swift.
    traits: [
        .trait(
            name: "PresidioAccelerate",
            description: "Use Accelerate's BLAS for model inference on Apple platforms."
        )
    ],
    dependencies: [
        // Only PresidioAnonymizerCrypto depends on this. CryptoKit has no
        // AES-CBC mode at all, so encrypt/decrypt needs swift-crypto's
        // _CryptoExtras, which is BoringSSL-backed on every platform.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Only PresidioEngineYAML depends on this. Yams vendors libyaml's C
        // source (MIT, YAML_DECLARE_STATIC), so it needs no system library and
        // builds anywhere there is a C compiler.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
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

        // AnalyzerEngine: composes the recognizers, the context enhancer and
        // the NLP pipeline into the end-to-end entry point. Depends on both
        // PresidioRecognizers and PresidioNLP, which is why it is its own
        // target rather than living in either.
        .target(
            name: "PresidioEngine",
            dependencies: ["PresidioRecognizers", "PresidioNLP", "PresidioAnonymizer"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // YAML configuration. Kept in its own target so the engine stays free
        // of a YAML dependency: reproducing Presidio's *defaults* needs no
        // parser at all, because the default config is extracted to JSON at
        // build time. This target is for reading a user's own config file.
        //
        // Same reasoning as PresidioAnonymizerCrypto: a dependency that not
        // every caller needs does not belong in the target every caller imports.
        .target(
            name: "PresidioEngineYAML",
            dependencies: ["PresidioEngine", .product(name: "Yams", package: "Yams")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The English model, bundled. Its own product so that callers who only
        // need pattern-based detection do not pay 13 MB for weights they never
        // load. Depends on nothing: it is data plus a path.
        .target(
            name: "PresidioModelEnglish",
            resources: [.copy("Resources/model")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The command-line tool. Logic lives in the library so it can be
        // tested; the executable is five lines.
        .target(
            name: "PresidioCLI",
            dependencies: ["PresidioEngine", "PresidioEngineYAML", "PresidioAnonymizer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "swift-pii-cli",
            dependencies: ["PresidioCLI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Benchmark harness. ADR 0001 traded throughput for cross-platform
        // determinism; this keeps a number on that trade.
        .executableTarget(
            name: "presidio-bench",
            dependencies: ["PresidioRegex", "PresidioEngine"],
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
            name: "PresidioEngineTests",
            dependencies: ["PresidioEngine", "PresidioConformance", "PresidioModelEnglish"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "PresidioCLITests",
            dependencies: ["PresidioCLI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "PresidioEngineYAMLTests",
            dependencies: ["PresidioEngineYAML", "PresidioConformance"],
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
