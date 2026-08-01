import Testing
import Foundation
@testable import PresidioCLI

@Suite("CLI")
struct CommandLineToolTests {

    /// Captures output so behaviour is checked in-process rather than by
    /// spawning a binary and matching on stdout.
    final class Capture: CommandLineTool.Output, @unchecked Sendable {
        var lines: [String] = []
        var errors: [String] = []
        func write(_ line: String) { lines.append(line) }
        func writeError(_ line: String) { errors.append(line) }
        var text: String { lines.joined(separator: "\n") }
    }

    static func withTemporaryFile(
        _ contents: String, _ body: (String) throws -> Void
    ) rethrows {
        let path = NSTemporaryDirectory() + "swift-pii-cli-test-\(UUID().uuidString).txt"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    static func run(_ arguments: [String]) -> (status: Int32, out: Capture) {
        let capture = Capture()
        let tool = CommandLineTool(output: capture, environment: [:], isTTY: false)
        return (tool.run(arguments), capture)
    }

    // MARK: - Exit status

    /// The whole reason this port exists rather than wrapping upstream's:
    /// `presidio-cli` computes `max_level = 0`, never updates it, and exits on
    /// that — so it exits 0 whatever it finds and cannot gate CI.
    @Test("exits 1 when PII is found and 0 when it is not")
    func exitStatusReflectsFindings() {
        Self.withTemporaryFile("my card is 4095-2609-9393-4932\n") { path in
            #expect(Self.run(["analyze", path]).status == 1)
        }
        Self.withTemporaryFile("nothing to see here\n") { path in
            #expect(Self.run(["analyze", path]).status == 0)
        }
    }

    @Test("a usage error exits 2 and explains itself")
    func usageErrorExitsTwo() {
        let (status, out) = Self.run(["analyze", "--nope", "x"])
        #expect(status == 2)
        #expect(out.errors.contains { $0.contains("--nope") })
        // ...and prints usage rather than leaving the caller guessing.
        #expect(out.text.contains("USAGE:"))
    }

    @Test("no input at all is an error, not an empty success")
    func noInputIsAnError() {
        let (status, out) = Self.run(["analyze"])
        #expect(status == 2)
        #expect(out.errors.contains { $0.contains("no input") })
    }

    @Test("an unreadable file exits 2")
    func unreadableFileExitsTwo() {
        let (status, out) = Self.run(["analyze", "/definitely/not/here.txt"])
        #expect(status == 2)
        #expect(out.errors.contains { $0.contains("cannot read") })
    }

    @Test("--help and --version exit 0")
    func helpAndVersion() {
        #expect(Self.run(["--help"]).status == 0)
        let (status, out) = Self.run(["--version"])
        #expect(status == 0)
        #expect(out.text.contains(CommandLineTool.version))
    }

    // MARK: - Output formats

    @Test("standard format reports 1-based line and column")
    func standardFormat() {
        Self.withTemporaryFile("clean line\nmy card is 4095-2609-9393-4932\n") { path in
            let (status, out) = Self.run(["analyze", "-f", "standard", path])
            #expect(status == 1)
            // The card starts at offset 11 of line 2, so 2:12.
            #expect(out.text.contains("2:12"), "\(out.text)")
            #expect(out.text.contains("CREDIT_CARD"))
            #expect(out.lines.first == path, "the file name heads its findings")
        }
    }

    @Test("parsable format emits one JSON object per finding")
    func parsableFormat() throws {
        try Self.withTemporaryFile("my card is 4095-2609-9393-4932\n") { path in
            let (_, out) = Self.run(["analyze", "-f", "parsable", path])
            let objects = out.lines.filter { $0.hasPrefix("{") }
            #expect(objects.count == 1)
            let decoded = try JSONSerialization.jsonObject(
                with: Data(objects[0].utf8)
            ) as? [String: Any]
            let json = try #require(decoded)
            #expect(json["entity_type"] as? String == "CREDIT_CARD")
            #expect(json["line"] as? Int == 1)
            #expect(json["column"] as? Int == 12)
            #expect(json["recognizer"] as? String == "CreditCardRecognizer")
        }
    }

    @Test("github format brackets its findings in a group")
    func githubFormat() {
        Self.withTemporaryFile("my card is 4095-2609-9393-4932\n") { path in
            let (_, out) = Self.run(["analyze", "-f", "github", path])
            #expect(out.lines.first == "::group::\(path)")
            #expect(out.lines.contains { $0.contains("[CREDIT_CARD]") })
            #expect(out.lines.contains("::endgroup::"))
        }
    }

    @Test("auto format resolves from the environment, not from guesswork")
    func autoFormatResolution() {
        let capture = Capture()
        let onCI = CommandLineTool(
            output: capture,
            environment: ["GITHUB_ACTIONS": "true", "GITHUB_WORKFLOW": "ci"],
            isTTY: false
        )
        #expect(onCI.resolveFormat(.auto) == .github)

        let terminal = CommandLineTool(output: capture, environment: [:], isTTY: true)
        #expect(terminal.resolveFormat(.auto) == .colored)

        let piped = CommandLineTool(output: capture, environment: [:], isTTY: false)
        #expect(piped.resolveFormat(.auto) == .standard)
        // An explicit choice is never overridden.
        #expect(onCI.resolveFormat(.parsable) == .parsable)
    }

    // MARK: - Filtering

    @Test("--entities restricts what is reported")
    func entityFilter() {
        Self.withTemporaryFile("card 4095-2609-9393-4932 mail a@example.com\n") { path in
            let (_, all) = Self.run(["analyze", "-f", "parsable", path])
            let (_, only) = Self.run(
                ["analyze", "-f", "parsable", "-e", "EMAIL_ADDRESS", path]
            )
            #expect(all.lines.count > only.lines.count)
            #expect(only.lines.allSatisfy { $0.contains("EMAIL_ADDRESS") })
        }
    }

    @Test("--threshold drops low-scoring findings")
    func thresholdFilter() {
        Self.withTemporaryFile("call 212-555-5555\n") { path in
            let (low, _) = Self.run(["analyze", "-t", "0.1", path])
            let (high, _) = Self.run(["analyze", "-t", "0.99", path])
            #expect(low == 1)
            #expect(high == 0, "0.4 phone score is below 0.99")
        }
    }

    @Test("a threshold outside 0...1 is rejected")
    func badThreshold() {
        #expect(throws: CommandLineTool.ToolError.badThreshold("2.0")) {
            _ = try CommandLineTool.Options(parsing: ["analyze", "-t", "2.0", "f"])
        }
        #expect(throws: CommandLineTool.ToolError.badThreshold("abc")) {
            _ = try CommandLineTool.Options(parsing: ["analyze", "-t", "abc", "f"])
        }
    }

    // MARK: - anonymize

    @Test("anonymize rewrites findings and round-trips the rest verbatim")
    func anonymizeReplaces() {
        Self.withTemporaryFile("my card is 4095-2609-9393-4932\nkeep me\n") { path in
            let (status, out) = Self.run(["anonymize", path])
            #expect(status == 0, "anonymize succeeds even when it found something")
            #expect(out.text == "my card is <CREDIT_CARD>\nkeep me")
        }
    }

    @Test("--operator selects the anonymization strategy")
    func anonymizeOperators() {
        Self.withTemporaryFile("card 4095-2609-9393-4932\n") { path in
            let (_, redacted) = Self.run(["anonymize", "-o", "redact", path])
            #expect(redacted.text == "card ")

            let (_, masked) = Self.run(["anonymize", "-o", "mask", path])
            #expect(masked.text == "card " + String(repeating: "*", count: 19))

            // hash needs a salt: this port will not invent one, because a
            // random salt per run makes the output irreproducible.
            let (missing, _) = Self.run(["anonymize", "-o", "hash", path])
            #expect(missing == 2, "a missing salt is an error, not a silent default")

            let (status, hashed) = Self.run(
                ["anonymize", "-o", "hash", "-s", "0123456789abcdef", path]
            )
            #expect(status == 0)
            #expect(hashed.text.hasPrefix("card "))
            #expect(!hashed.text.contains("4095"))
        }
    }

    // MARK: - Parsing

    @Test("options parse into the expected shape")
    func optionParsing() throws {
        let options = try CommandLineTool.Options(
            parsing: ["analyze", "-l", "en", "-e", "A, B ,,C", "-t", "0.5",
                      "-f", "github", "-c", "conf.yaml", "a.txt", "b.txt"]
        )
        #expect(options.command == .analyze)
        #expect(options.language == "en")
        #expect(options.entities == ["A", "B", "C"], "trims and drops empties")
        #expect(options.threshold == 0.5)
        #expect(options.format == .github)
        #expect(options.configFile == "conf.yaml")
        #expect(options.files == ["a.txt", "b.txt"])
        #expect(!options.readsStdin)
    }

    @Test("the subcommand may be omitted and defaults to analyze")
    func defaultsToAnalyze() throws {
        let options = try CommandLineTool.Options(parsing: ["a.txt"])
        #expect(options.command == .analyze)
        #expect(options.files == ["a.txt"])
    }

    @Test("a flag missing its value is an error, not a silent default")
    func missingValue() {
        #expect(throws: CommandLineTool.ToolError.missingValue("--language")) {
            _ = try CommandLineTool.Options(parsing: ["analyze", "f.txt", "--language"])
        }
    }

    @Test("'-' reads standard input")
    func stdinFlag() throws {
        let options = try CommandLineTool.Options(parsing: ["analyze", "-"])
        #expect(options.readsStdin)
        #expect(options.files.isEmpty)
    }

    // MARK: - Line splitting

    /// Upstream's `line_generator`: split on "\n", drop a preceding "\r", and
    /// always yield a final line even without a trailing newline.
    @Test("line splitting matches upstream's generator")
    func lineSplitting() {
        #expect("a\nb".splitIntoLines() == ["a", "b"])
        #expect("a\nb\n".splitIntoLines() == ["a", "b", ""])
        #expect("a\r\nb".splitIntoLines() == ["a", "b"])
        #expect("".splitIntoLines() == [""])
        #expect("solo".splitIntoLines() == ["solo"])
    }
}
