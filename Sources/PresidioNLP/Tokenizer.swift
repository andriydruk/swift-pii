import Foundation
import PresidioRegex

/// A token with its offset into the source text and its NORM.
///
/// `offset` is a Unicode scalar index — the same contract as everywhere else in
/// the package, and the same unit Python's `token.idx` uses.
public struct Token: Sendable, Hashable {
    public let text: String
    public let offset: Int
    /// spaCy's `token.norm_`. Consumed as a feature by the NER model, so it is
    /// produced here rather than derived later.
    public let norm: String

    public init(text: String, offset: Int, norm: String) {
        self.text = text
        self.offset = offset
        self.norm = norm
    }

    public var end: Int { offset + text.unicodeScalars.count }
}

/// spaCy's English tokenizer, ported.
///
/// The tokenizer is the one part of the pipeline that is entirely rule-based —
/// four regexes plus a special-case table — so it ports exactly rather than
/// approximately. This matters twice over: token boundaries decide what the NER
/// model sees, and they decide the ±5-token context window that every regex
/// recognizer's score depends on.
///
/// Matching runs on `PureRegex`, not `NSRegularExpression`, so behaviour does
/// not drift with the host's ICU version. See docs/decisions/0001-regex-backend.md.
/// `@unchecked Sendable`: every stored property is immutable after `init`
/// except the memoization cache, which is guarded by `cacheLock`. The three
/// derived special-case tables used to be `lazy var`, whose initialization is
/// itself a data race when the tokenizer is shared; they are now computed
/// eagerly in `init`.
public final class SpacyTokenizer: @unchecked Sendable {

    struct Rules: Decodable {
        struct Special: Decodable {
            let orth: String
            let norm: String?
        }
        let spacyVersion: String
        let prefix: String
        let suffix: String
        let infix: String
        let url: String?
        let specials: [String: [Special]]
        let baseNorms: [String: String]
        let lexemeNorm: [String: String]

        enum CodingKeys: String, CodingKey {
            case spacyVersion = "spacy_version"
            case prefix, suffix, infix, url, specials
            case baseNorms = "base_norms"
            case lexemeNorm = "lexeme_norm"
        }
    }

    public enum LoadError: Error, CustomStringConvertible {
        case resourceMissing
        case unsupportedLanguage(String)
        case badPattern(String, Error)

        public var description: String {
            switch self {
            case .resourceMissing:
                return """
                    en_tokenizer.json not found. Regenerate with:
                      python3 Tools/extract_tokenizer.py --python <venv> \
                    --out Sources/PresidioNLP/Resources/en_tokenizer.json
                    """
            case .unsupportedLanguage(let language):
                return """
                    no bundled tokenizer rules for '\(language)'. Bundled: \
                    \(SpacyTokenizer.bundledLanguages.joined(separator: ", ")). \
                    Add one with:
                      python3 Tools/extract_tokenizer.py --python <venv> \
                    --lang \(language) \
                    --out Sources/PresidioNLP/Resources/\(language)_tokenizer.json
                    """
            case .badPattern(let name, let error):
                return "tokenizer pattern '\(name)' failed to compile: \(error)"
            }
        }
    }

    private let rules: Rules
    private let prefixRegex: PureRegex
    private let suffixRegex: PureRegex
    private let infixRegex: PureRegex
    private let urlRegex: PureRegex?

    /// Special-case pieces keyed by the raw key, as `(orth, norm)` pairs.
    private let specials: [String: [Token0]]
    struct Token0 { let orth: String; let norm: String? }

    public var spacyVersion: String { rules.spacyVersion }

    /// Languages with bundled tokenizer rules.
    ///
    /// Rules are data, so adding a language is an extraction rather than a code
    /// change — but only for languages spaCy tokenizes by rule. Japanese and
    /// Chinese are segmented by SudachiPy and pkuseg, which are models, not
    /// tables, and cannot be bundled this way at all.
    public static let bundledLanguages = ["de", "en", "es", "it"]

    public static func english() throws -> SpacyTokenizer {
        try forLanguage("en")
    }

    /// German, whose rules differ from English mostly in the infix pattern —
    /// 22,324 characters against 15,520 — and in having a third as many
    /// tokenizer exceptions.
    public static func german() throws -> SpacyTokenizer {
        try forLanguage("de")
    }

    /// Spanish. Fewest exceptions of the four (282), but the infix pattern has
    /// to cope with inverted punctuation opening a clause mid-sentence.
    public static func spanish() throws -> SpacyTokenizer {
        try forLanguage("es")
    }

    /// Italian, where the interesting work is elision: `dell'`, `un'`, `n'`
    /// all split, and the apostrophe stays with the *first* piece.
    public static func italian() throws -> SpacyTokenizer {
        try forLanguage("it")
    }

    public static func forLanguage(_ language: String) throws -> SpacyTokenizer {
        guard bundledLanguages.contains(language) else {
            throw LoadError.unsupportedLanguage(language)
        }
        guard let url = Bundle.module.url(
            forResource: "\(language)_tokenizer", withExtension: "json"
        ) else { throw LoadError.resourceMissing }
        let rules = try JSONDecoder().decode(
            Rules.self, from: Data(contentsOf: url)
        )
        return try SpacyTokenizer(rules: rules)
    }

    init(rules: Rules) throws {
        self.rules = rules
        // spaCy compiles these with no flags: case-sensitive, `.` excludes
        // newline, `^`/`$` are string anchors.
        func compile(_ pattern: String, _ name: String) throws -> PureRegex {
            do {
                return try PureRegex(
                    pattern, ignoreCase: false, dotAll: false, multiline: false
                )
            } catch { throw LoadError.badPattern(name, error) }
        }
        self.prefixRegex = try compile(rules.prefix, "prefix")
        self.suffixRegex = try compile(rules.suffix, "suffix")
        self.infixRegex = try compile(rules.infix, "infix")
        self.urlRegex = try rules.url.map { try compile($0, "url") }
        self.specials = rules.specials.mapValues { pieces in
            pieces.map { Token0(orth: $0.orth, norm: $0.norm) }
        }
        // Derived tables, eagerly: see buildSpecialSequences.
        self.specialSequences = [:]
        self.specialFirsts = []
        self.specialMaxLength = 1
        let sequences = buildSpecialSequences()
        self.specialSequences = sequences
        self.specialFirsts = Set(sequences.keys.compactMap(\.first))
        self.specialMaxLength = sequences.keys.map(\.count).max() ?? 1
    }

    // MARK: - NORM

    /// Resolution order determined empirically against spaCy, not from docs.
    ///
    /// The lexeme table is keyed by the **exact** surface form rather than the
    /// lowercase one: "licence" normalizes to "license", but "PLZ" stays "plz"
    /// because only "plz" is a key.
    public func norm(for text: String, specialNorm: String? = nil) -> String {
        if let specialNorm { return specialNorm }
        if let value = rules.lexemeNorm[text] { return value }
        if let value = rules.baseNorms[text] { return value }
        return text.lowercased()
    }

    // MARK: - Tokenize

    /// Python's `str.isspace()`, which is broader than ASCII whitespace.
    static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0,
             0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Tokenize, returning scalar offsets into `text`.
    ///
    /// Port of `Tokenizer._tokenize_affixes` followed by
    /// `Tokenizer._apply_special_cases`.
    public func tokenize(_ text: String) -> [Token] {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }

        var pieces: [(String, Int, String?)] = []   // text, offset, specialNorm
        var start = 0
        var inWhitespace = Self.isPythonSpace(scalars[0])
        var index = 0
        while index < scalars.count {
            let isSpace = Self.isPythonSpace(scalars[index])
            if isSpace != inWhitespace {
                if start < index { emit(scalars, start, index, &pieces) }
                // A plain space is consumed; other whitespace starts the next
                // span, matching spaCy's handling of `\n` and friends.
                start = scalars[index].value == 0x20 ? index + 1 : index
                inWhitespace.toggle()
            }
            index += 1
        }
        if start < index { emit(scalars, start, index, &pieces) }

        return applySpecialCases(pieces).map {
            Token(text: $0.0, offset: $0.1, norm: norm(for: $0.0, specialNorm: $0.2))
        }
    }

    // Memoized span splits. Worth 4.3x on repeated text, so it stays -- but a
    // shared tokenizer means concurrent mutation, hence the lock. Contention is
    // low: the critical sections are two dictionary operations.
    private let cacheLock = NSLock()
    private var cache: [String: [(String, String?)]] = [:]
    private let maxCache = 10_000

    private func emit(
        _ scalars: [Unicode.Scalar], _ from: Int, _ to: Int,
        _ out: inout [(String, Int, String?)]
    ) {
        let span = String(String.UnicodeScalarView(scalars[from..<to]))
        cacheLock.lock()
        let cached = cache[span]
        cacheLock.unlock()

        let split: [(String, String?)]
        if let cached {
            split = cached
        } else {
            // Computed outside the lock: two tasks may duplicate the work for
            // the same span, which costs a little and is always consistent,
            // whereas holding the lock across tokenizeSpan would serialize it.
            var accumulated: [(String, String?)] = []
            tokenizeSpan(span, &accumulated, withSpecials: true)
            cacheLock.lock()
            if cache.count < maxCache { cache[span] = accumulated }
            cacheLock.unlock()
            split = accumulated
        }
        var offset = from
        for (piece, specialNorm) in split {
            out.append((piece, offset, specialNorm))
            offset += piece.unicodeScalars.count
        }
    }

    // MARK: - Affix splitting

    /// Length in scalars of the prefix match, or 0.
    func prefixLength(_ text: String) -> Int {
        // The pattern is a disjunction of `^`-anchored alternatives, so only a
        // match starting at 0 counts.
        for (matchStart, matchEnd) in prefixRegex.matches(in: text)
        where matchStart == 0 {
            return matchEnd
        }
        return 0
    }

    /// Length in scalars of the suffix match, or 0.
    func suffixLength(_ text: String) -> Int {
        let length = text.unicodeScalars.count
        for (matchStart, matchEnd) in suffixRegex.matches(in: text)
        where matchEnd == length {
            return length - matchStart
        }
        return 0
    }

    func infixRanges(_ text: String) -> [(Int, Int)] {
        infixRegex.matches(in: text)
    }

    func isURL(_ text: String) -> Bool {
        guard let urlRegex else { return false }
        let length = text.unicodeScalars.count
        return urlRegex.matches(in: text).contains { $0.0 == 0 && $0.1 == length }
    }

    /// Port of `_split_affixes` + `_attach_tokens`.
    private func tokenizeSpan(
        _ span: String, _ out: inout [(String, String?)], withSpecials: Bool
    ) {
        var prefixes: [String] = []
        var suffixes: [String] = []
        var current = Array(span.unicodeScalars)

        func string(_ range: Range<Int>) -> String {
            String(String.UnicodeScalarView(current[range]))
        }

        var lastSize = -1
        while !current.isEmpty && current.count != lastSize {
            let whole = String(String.UnicodeScalarView(current))
            if withSpecials && specials[whole] != nil { break }
            lastSize = current.count

            let preLen = prefixLength(whole)
            var minusPrefix: [Unicode.Scalar] = []
            if preLen != 0 {
                minusPrefix = Array(current[preLen...])
                let candidate = String(String.UnicodeScalarView(minusPrefix))
                if withSpecials && !candidate.isEmpty && specials[candidate] != nil {
                    prefixes.append(string(0..<preLen))
                    current = minusPrefix
                    break
                }
            }

            let tail = preLen == 0 ? whole : String(String.UnicodeScalarView(current[preLen...]))
            let sufLen = suffixLength(tail)
            var minusSuffix: [Unicode.Scalar] = []
            if sufLen != 0 {
                minusSuffix = Array(current[..<(current.count - sufLen)])
                let candidate = String(String.UnicodeScalarView(minusSuffix))
                if withSpecials && !candidate.isEmpty && specials[candidate] != nil {
                    suffixes.append(string((current.count - sufLen)..<current.count))
                    current = minusSuffix
                    break
                }
            }

            if preLen > 0 && sufLen > 0 && (preLen + sufLen) <= current.count {
                prefixes.append(string(0..<preLen))
                suffixes.append(string((current.count - sufLen)..<current.count))
                current = Array(current[preLen..<(current.count - sufLen)])
            } else if preLen > 0 {
                prefixes.append(string(0..<preLen))
                current = minusPrefix
            } else if sufLen > 0 {
                suffixes.append(string((current.count - sufLen)..<current.count))
                current = minusSuffix
            }
        }

        for prefix in prefixes { out.append((prefix, nil)) }

        if !current.isEmpty {
            let whole = String(String.UnicodeScalarView(current))
            if withSpecials, let special = specials[whole] {
                for piece in special { out.append((piece.orth, piece.norm)) }
            } else if isURL(whole) {
                out.append((whole, nil))
            } else {
                let matches = infixRanges(whole)
                if matches.isEmpty {
                    out.append((whole, nil))
                } else {
                    var start = 0
                    for (matchStart, matchEnd) in matches {
                        // spaCy skips an infix at position 0 — it would produce
                        // an empty leading token.
                        if matchStart == 0 { continue }
                        if matchStart != start {
                            out.append((string(start..<matchStart), nil))
                        }
                        if matchStart != matchEnd {
                            out.append((string(matchStart..<matchEnd), nil))
                        }
                        start = matchEnd
                    }
                    if start < current.count {
                        out.append((string(start..<current.count), nil))
                    }
                }
            }
        }

        for suffix in suffixes.reversed() { out.append((suffix, nil)) }
    }

    // MARK: - Special cases

    /// Special cases are applied as a second pass over the *token sequence*, so
    /// a key like "N.Y." that affix-splitting broke apart is re-merged.
    // `var` only because building them calls instance methods, which Swift
    // permits only once every stored property is initialized. Written once at
    // the end of `init` and never again.
    private var specialSequences: [[String]: [Token0]]
    private var specialFirsts: Set<String>
    private var specialMaxLength: Int

    /// Special cases applied as a second pass over the token sequence.
    /// Computed in `init` rather than lazily: a `lazy var` on a shared
    /// instance races on first use.
    private func buildSpecialSequences() -> [[String]: [Token0]] {
        var map: [[String]: [Token0]] = [:]
        for (key, pieces) in specials {
            // spaCy's faster_heuristics gate: only keys that themselves contain
            // an affix boundary (or a space) reach the phrase-matcher stage.
            let gated = prefixLength(key) > 0 || suffixLength(key) > 0
                || !infixRanges(key).isEmpty || key.contains(" ")
            guard gated else { continue }
            var accumulated: [(String, String?)] = []
            tokenizeSpan(key, &accumulated, withSpecials: false)
            let sequence = accumulated.map(\.0)
            if sequence != pieces.map(\.orth) { map[sequence] = pieces }
        }
        return map
    }

    private func applySpecialCases(
        _ tokens: [(String, Int, String?)]
    ) -> [(String, Int, String?)] {
        guard !specialSequences.isEmpty else { return tokens }
        var out: [(String, Int, String?)] = []
        out.reserveCapacity(tokens.count)
        var index = 0

        while index < tokens.count {
            var matched = false
            if specialFirsts.contains(tokens[index].0) {
                var length = min(specialMaxLength, tokens.count - index)
                while length >= 1 {
                    let key = (index..<(index + length)).map { tokens[$0].0 }
                    if let replacement = specialSequences[key] {
                        // The tokens must be contiguous in the source; a space
                        // between them means this is not the special case.
                        var contiguous = true
                        var offset = tokens[index].1
                        for position in index..<(index + length) {
                            if tokens[position].1 != offset { contiguous = false; break }
                            offset += tokens[position].0.unicodeScalars.count
                        }
                        if contiguous {
                            var offset = tokens[index].1
                            for piece in replacement {
                                out.append((piece.orth, offset, piece.norm))
                                offset += piece.orth.unicodeScalars.count
                            }
                            index += length
                            matched = true
                            break
                        }
                    }
                    length -= 1
                }
            }
            if !matched {
                out.append(tokens[index])
                index += 1
            }
        }
        return out
    }
}
