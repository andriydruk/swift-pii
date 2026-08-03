import Foundation
import PresidioCore
import PresidioAnalyzer
import PresidioEngine
import PresidioRecognizers
import PresidioEngineYAML
import PresidioAnonymizer

/// Port of `presidio-cli`, plus anonymization.
///
/// The logic lives in a library rather than in `main.swift` so it can be
/// tested: a CLI whose behaviour is only reachable by spawning a process
/// tends to be a CLI whose behaviour is not checked at all.
public struct CommandLineTool {

    /// Where output goes. Injected so tests can read it.
    public protocol Output: AnyObject {
        func write(_ line: String)
        func writeError(_ line: String)
    }

    public final class StandardOutput: Output {
        public init() {}
        public func write(_ line: String) { print(line) }
        public func writeError(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    public enum Format: String, CaseIterable, Sendable {
        case standard, colored, github, parsable, auto
    }

    public static let version = "0.1.0"

    let output: any Output
    let environment: [String: String]
    let isTTY: Bool

    public init(
        output: any Output = StandardOutput(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTTY: Bool = isatty(STDOUT_FILENO) == 1
    ) {
        self.output = output
        self.environment = environment
        self.isTTY = isTTY
    }

    // MARK: - Entry point

    /// Runs one invocation and returns the process exit status.
    ///
    /// **Exit status is meaningful here, unlike upstream.** `presidio-cli`
    /// computes `max_level = 0`, never updates it, and exits on that — so it
    /// always exits 0 whatever it finds, which makes it useless as a CI gate.
    /// PLAN.md lists that as a bug not to reproduce. This returns 1 when PII
    /// was found, 2 on a usage or I/O error.
    public func run(_ arguments: [String]) -> Int32 {
        var options: Options
        do {
            options = try Options(parsing: arguments)
        } catch {
            output.writeError("error: \(error)")
            output.writeError("")
            printUsage()
            return 2
        }

        if options.wantsHelp { printUsage(); return 0 }
        if options.wantsVersion { output.write("swift-pii \(Self.version)"); return 0 }

        do {
            switch options.command {
            case .analyze: return try runAnalyze(options)
            case .anonymize: return try runAnonymize(options)
            }
        } catch {
            output.writeError("error: \(error)")
            return 2
        }
    }

    // MARK: - analyze

    func runAnalyze(_ options: Options) throws -> Int32 {
        let engine = try makeEngine(options)
        let format = resolveFormat(options.format)
        var found = 0

        for source in try readSources(options) {
            var headerPrinted = false
            // Line by line, like upstream — which is what makes the reported
            // column meaningful, since offsets are relative to the line.
            for (number, line) in source.text.splitIntoLines().enumerated() {
                let results = try engine.analyze(
                    text: line,
                    language: options.language,
                    entities: options.entities,
                    scoreThreshold: options.threshold
                )
                for result in results {
                    found += 1
                    emit(
                        result, line: number + 1, file: source.name,
                        format: format, headerPrinted: &headerPrinted
                    )
                }
            }
            if headerPrinted {
                if format == .github { output.write("::endgroup::") }
                if format != .parsable { output.write("") }
            }
        }
        return found > 0 ? 1 : 0
    }

    private func emit(
        _ result: RecognizerResult, line: Int, file: String,
        format: Format, headerPrinted: inout Bool
    ) {
        // Column is 1-based within the line, matching upstream.
        let column = result.start + 1
        switch format {
        case .parsable:
            output.write(json(result, line: line, column: column, file: file))
        case .github:
            if !headerPrinted { output.write("::group::\(file)"); headerPrinted = true }
            output.write(
                "::\(result.score) file=\(file),line=\(line),col=\(column)::"
                + "\(line):\(column) [\(result.entityType)]"
            )
        case .colored:
            if !headerPrinted { output.write("\u{1B}[4m\(file)\u{1B}[0m"); headerPrinted = true }
            var text = "  \u{1B}[2m\(line):\(column)\u{1B}[0m"
            text += String(repeating: " ", count: max(20 - text.count, 0))
            let score = result.score < 1
                ? "\u{1B}[33m\(result.score)\u{1B}[0m"
                : "\u{1B}[31m\(result.score)\u{1B}[0m"
            text += score
            text += String(repeating: " ", count: max(38 - text.count, 0))
            text += result.entityType
            output.write(text)
        case .standard, .auto:
            if !headerPrinted { output.write(file); headerPrinted = true }
            var text = "  \(line):\(column)"
            text += String(repeating: " ", count: max(12 - text.count, 0))
            text += "\(result.score)"
            text += String(repeating: " ", count: max(21 - text.count, 0))
            text += result.entityType
            output.write(text)
        }
    }

    private func json(
        _ result: RecognizerResult, line: Int, column: Int, file: String
    ) -> String {
        let recognizer = result.recognitionMetadata[
            RecognizerResult.MetadataKey.recognizerName] ?? ""
        return """
            {"file":\(quote(file)),"line":\(line),"column":\(column),\
            "entity_type":\(quote(result.entityType)),"start":\(result.start),\
            "end":\(result.end),"score":\(result.score),\
            "recognizer":\(quote(recognizer))}
            """
    }

    private func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - anonymize

    func runAnonymize(_ options: Options) throws -> Int32 {
        let engine = try makeEngine(options)
        let anonymizer = AnonymizerEngine()

        for source in try readSources(options) {
            let results = try engine.analyze(
                text: source.text, language: options.language,
                entities: options.entities, scoreThreshold: options.threshold
            )
            let result = try anonymizer.anonymize(
                text: source.text, analyzerResults: results,
                operators: ["DEFAULT": options.operatorConfig]
            )
            // `write` appends a newline, and the source text usually ends
            // with one already; emitting both would add a blank line and
            // change the file on a round trip.
            var text = result.text
            if text.hasSuffix("\n") { text.removeLast() }
            output.write(text)
        }
        return 0
    }

    // MARK: - Support

    struct Source {
        let name: String
        let text: String
    }

    func readSources(_ options: Options) throws -> [Source] {
        if options.readsStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return [Source(name: "stdin", text: String(decoding: data, as: UTF8.self))]
        }
        return try options.files.map { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw ToolError.unreadable(path)
            }
            return Source(name: path, text: text)
        }
    }

    func makeEngine(_ options: Options) throws -> AnalyzerEngine {
        if let configPath = options.configFile {
            let registry = try YAMLConfiguration.registry(
                atPath: configPath, languages: [options.language]
            )
            return try AnalyzerEngine(
                registry: registry,
                nlpEngine: try TokenizerOnlyNlpEngine(),
                supportedLanguages: [options.language]
            )
        }
        // Same defaults as `PIIDetector`: the tokenizer costs no weights and
        // lets words near a candidate raise its score, so the CLI and the
        // library do not disagree about the same text.
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        return try AnalyzerEngine(
            registry: registry, nlpEngine: try TokenizerOnlyNlpEngine()
        )
    }

    /// Port of the `auto` format resolution: GitHub Actions first, then a
    /// colour-capable terminal, then plain.
    func resolveFormat(_ requested: Format) -> Format {
        guard requested == .auto else { return requested }
        if environment["GITHUB_ACTIONS"] != nil, environment["GITHUB_WORKFLOW"] != nil {
            return .github
        }
        return isTTY ? .colored : .standard
    }

    public enum ToolError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case unknownCommand(String)
        case unknownOption(String)
        case missingValue(String)
        case badThreshold(String)
        case noInput

        public var description: String {
            switch self {
            case .unreadable(let path): return "cannot read \(path)"
            case .unknownCommand(let name): return "unknown command '\(name)'"
            case .unknownOption(let name): return "unknown option '\(name)'"
            case .missingValue(let name): return "\(name) requires a value"
            case .badThreshold(let value):
                return "threshold must be a number between 0.0 and 1.0, got '\(value)'"
            case .noInput: return "no input: pass a file, or '-' to read stdin"
            }
        }
    }

    func printUsage() {
        output.write("""
            swift-pii \(Self.version) — Presidio-compatible PII detection

            USAGE:
              swift-pii analyze   [options] <file>... | -
              swift-pii anonymize [options] <file>... | -

            OPTIONS:
              -l, --language <code>     language to analyze as (default: en)
              -e, --entities <a,b,c>    restrict to these entity types
              -t, --threshold <0..1>    drop results scoring below this
              -c, --config <file.yaml>  recognizer configuration
              -f, --format <name>       analyze output: standard, colored,
                                        github, parsable, auto (default: auto)
              -o, --operator <name>     anonymize with: replace, redact,
                                        mask, hash (default: replace)
              -s, --salt <value>        salt for --operator hash (required;
                                        at least 16 bytes)
              -h, --help                show this message
              -v, --version             show the version

            EXIT STATUS:
              0  no PII found
              1  PII found
              2  usage or I/O error

            Note: upstream presidio-cli always exits 0, which makes it useless
            as a CI gate. This exits 1 when it finds something.
            """)
    }
}

extension String {
    /// Split into lines the way upstream's `line_generator` does: on "\n",
    /// dropping a preceding "\r", and always yielding a final line even when
    /// the text does not end in a newline.
    /// Iterates *scalars*, not `Character`s. Swift treats "\r\n" as a single
    /// grapheme cluster, so a Character loop never sees the "\n" at all and the
    /// text comes back as one line — which is exactly the bug this comment
    /// replaced.
    func splitIntoLines() -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            if scalar == "\n" {
                if current.last == "\r" { current.removeLast() }
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }
}
