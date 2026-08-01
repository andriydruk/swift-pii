import PresidioAnonymizer

public extension CommandLineTool {

    enum Command: String, Sendable {
        case analyze
        case anonymize
    }

    /// Hand-parsed rather than pulling in an argument-parsing dependency: the
    /// grammar is a subcommand plus eight flags, and every branch below is
    /// covered by a test. A parser library would be the right call for a
    /// larger surface.
    struct Options: Sendable {
        public var command: Command = .analyze
        public var files: [String] = []
        public var readsStdin = false
        public var language = "en"
        public var entities: [String]?
        public var threshold: Double?
        public var configFile: String?
        public var format: Format = .auto
        public var operatorName = "replace"
        public var salt: String?
        public var wantsHelp = false
        public var wantsVersion = false

        /// The anonymizer configuration for `--operator`.
        public var operatorConfig: OperatorConfig {
            switch operatorName {
            case "redact": return OperatorConfig("redact")
            case "mask":
                // A default that produces something useful without four more
                // flags: mask everything with '*', keeping nothing.
                return OperatorConfig("mask", [
                    "masking_char": .string("*"),
                    "chars_to_mask": .int(100),
                    "from_end": .bool(false),
                ])
            case "hash":
                // Upstream generates a random salt per run. This port refuses
                // to, because a random salt makes the output irreproducible
                // and silently unlinkable across runs — so the caller supplies
                // one and the operator raises if they did not.
                return OperatorConfig("hash", salt.map {
                    ["salt": .string($0), "hash_type": .string("sha256")]
                } ?? [:])
            default: return OperatorConfig("replace")
            }
        }

        public init() {}

        public init(parsing arguments: [String]) throws {
            self.init()
            var index = 0

            // A leading bare word is the subcommand; anything else defaults to
            // `analyze`, so `swift-pii file.txt` does the obvious thing.
            if let first = arguments.first, !first.hasPrefix("-") {
                if let parsed = Command(rawValue: first) {
                    command = parsed
                    index = 1
                } else if Command.allCases.contains(where: { $0.rawValue.hasPrefix(first) }) {
                    throw ToolError.unknownCommand(first)
                }
            }

            func value(_ flag: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw ToolError.missingValue(flag) }
                return arguments[index]
            }

            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "-h", "--help": wantsHelp = true
                case "-v", "--version": wantsVersion = true
                case "-": readsStdin = true
                case "-l", "--language": language = try value(argument)
                case "-c", "--config", "--config-file": configFile = try value(argument)
                case "-o", "--operator": operatorName = try value(argument)
                case "-s", "--salt": salt = try value(argument)
                case "-e", "--entities":
                    entities = try value(argument)
                        .split(separator: ",")
                        .map { $0.trimmingWhitespace() }
                        .filter { !$0.isEmpty }
                case "-t", "--threshold":
                    let raw = try value(argument)
                    guard let parsed = Double(raw), parsed >= 0, parsed <= 1 else {
                        throw ToolError.badThreshold(raw)
                    }
                    threshold = parsed
                case "-f", "--format":
                    let raw = try value(argument)
                    guard let parsed = Format(rawValue: raw) else {
                        throw ToolError.unknownOption("--format \(raw)")
                    }
                    format = parsed
                default:
                    if argument.hasPrefix("-") {
                        throw ToolError.unknownOption(argument)
                    }
                    files.append(argument)
                }
                index += 1
            }

            if !wantsHelp, !wantsVersion, files.isEmpty, !readsStdin {
                throw ToolError.noInput
            }
        }
    }
}

extension CommandLineTool.Command: CaseIterable {}

private extension Substring {
    func trimmingWhitespace() -> String {
        var slice = self
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return String(slice)
    }
}
