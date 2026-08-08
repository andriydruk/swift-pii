// A pure-Swift backtracking regex engine covering exactly the feature census of
// Presidio's 155 patterns: alternation, concatenation, greedy/lazy quantifiers,
// capturing and non-capturing groups, lookahead, fixed-width lookbehind,
// character classes, \d \w \s \D \W \S, \b \B, ^ $, numeric backrefs,
// inline (?i), and the global DOTALL|MULTILINE|IGNORECASE flags Presidio sets
// on every pattern (pattern_recognizer.py:59).
//
// Semantics target Python's `regex` module, not ICU or PCRE2:
//   * \w/\d/\s membership comes from the pinned generated tables, so \b
//     behaves identically on every platform. See docs/decisions/0001-regex-backend.md.
//   * \n is the only line terminator, unlike ICU which also breaks on
//     \r \v \f U+0085 U+2028 U+2029.
//   * Offsets are Unicode scalar indices, matching Python and PresidioCore.
//
// Deliberately NOT supported, because Presidio uses none of them: named groups,
// atomic groups, possessive quantifiers, conditionals, \p{...}, variable-width
// lookbehind. The parser rejects them rather than silently mis-matching.
//
// Adapted from the validated prototype in prototypes/pure-swift-regex-Engine.swift.

// MARK: - AST

indirect enum Node {
    case empty
    case lit(UInt32)                       // single scalar
    case cls(CharClass)
    case any                               // .
    case concat([Node])
    case alt([Node])
    case rep(Node, min: Int, max: Int, greedy: Bool)
    case group(Node, capture: Int?)        // capture index or nil
    case look(Node, ahead: Bool, positive: Bool, width: Int)  // width used for lookbehind
    case backref(Int)
    case wordB(Bool)                       // \b / \B
    case bol, eol, inputStart, inputEnd
    /// `(?i:...)` and friends: flags scoped to a subexpression.
    case flags(Node, set: InlineFlags, clear: InlineFlags)
}

struct CharClass {
    var negated = false
    var ranges: [(UInt32, UInt32)] = []
    var classes: [UInt8] = []              // 'd','D','w','W','s','S'
    // ASCII fast path: two 128-bit maps (case-sensitive / case-insensitive), built lazily once.
    private var ascii: (UInt64, UInt64, UInt64, UInt64)? = nil
    mutating func seal() {
        var a0: UInt64 = 0, a1: UInt64 = 0, b0: UInt64 = 0, b1: UInt64 = 0
        for c in UInt32(0)..<128 {
            if rawMatch(c) { if c < 64 { a0 |= 1 << c } else { a1 |= 1 << (c - 64) } }
            var m = rawMatch(c)
            if !m { for v in Fold.variants(c) where v != c { if rawMatch(v) { m = true; break } } }
            if m { if c < 64 { b0 |= 1 << c } else { b1 |= 1 << (c - 64) } }
        }
        ascii = (a0, a1, b0, b1)
    }
    @inline(__always)
    func matches(_ c: UInt32, ignoreCase: Bool) -> Bool {
        if c < 128, let t = ascii {
            let bit: Bool
            if ignoreCase { bit = c < 64 ? (t.2 >> c) & 1 == 1 : (t.3 >> (c - 64)) & 1 == 1 }
            else { bit = c < 64 ? (t.0 >> c) & 1 == 1 : (t.1 >> (c - 64)) & 1 == 1 }
            return negated ? !bit : bit
        }
        var m = rawMatch(c)
        if !m && ignoreCase {
            for alt in Fold.variants(c) where alt != c { if rawMatch(alt) { m = true; break } }
        }
        return negated ? !m : m
    }
    private func rawMatch(_ c: UInt32) -> Bool {
        for (a, b) in ranges where c >= a && c <= b { return true }
        for k in classes {
            switch k {
            case UInt8(ascii: "d"): if UnicodeTables.isDigit(c) { return true }
            case UInt8(ascii: "D"): if !UnicodeTables.isDigit(c) { return true }
            case UInt8(ascii: "w"): if UnicodeTables.isWord(c) { return true }
            case UInt8(ascii: "W"): if !UnicodeTables.isWord(c) { return true }
            case UInt8(ascii: "s"): if UnicodeTables.isWhitespace(c) { return true }
            case UInt8(ascii: "S"): if !UnicodeTables.isWhitespace(c) { return true }
            default: break
            }
        }
        return false
    }
}

enum Fold {
    /// Case-insensitive scalar comparison.
    ///
    /// The ASCII path avoids `variants`, which builds a String, a Set and an
    /// Array per call — ruinous on a per-character hot path.
    @inline(__always)
    static func equalIgnoringCase(_ a: UInt32, _ b: UInt32) -> Bool {
        if a == b { return true }
        if a < 128 && b < 128 {
            let la = (a >= 65 && a <= 90) ? a + 32 : a
            let lb = (b >= 65 && b <= 90) ? b + 32 : b
            return la == lb
        }
        return variants(a).contains(b)
    }

    // Simple case folding sufficient for the ASCII/Latin/Greek/Cyrillic ranges Presidio touches.
    static func variants(_ c: UInt32) -> [UInt32] {
        guard let u = Unicode.Scalar(c) else { return [c] }
        let s = String(Character(u))
        var out: Set<UInt32> = [c]
        for v in s.lowercased().unicodeScalars { out.insert(v.value) }
        for v in s.uppercased().unicodeScalars { out.insert(v.value) }
        return Array(out)
    }
}

// MARK: - Inline flags

/// The subset of Python's inline flags this engine can honour.
///
/// `u` is accepted and ignored because Unicode is Python 3's default and this
/// engine has no other mode. `a` (ASCII), `L` (locale) and `x` (verbose) are
/// *rejected* rather than ignored: each genuinely changes what the pattern
/// means — `a` redefines `\w`, `\d` and `\s`, `x` changes whether whitespace
/// is literal — and a silently ignored flag is a pattern that matches the
/// wrong thing forever. That was not hypothetical: this engine used to ignore
/// every flag it did not understand, which is how French's `(?iu)` token_match
/// came to be compiled case-sensitively.
public struct InlineFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ignoreCase = InlineFlags(rawValue: 1 << 0)
    public static let dotAll     = InlineFlags(rawValue: 1 << 1)
    public static let multiline  = InlineFlags(rawValue: 1 << 2)

    static func letter(_ scalar: UInt32) -> InlineFlags? {
        switch scalar {
        case UInt32(UInt8(ascii: "i")): return .ignoreCase
        case UInt32(UInt8(ascii: "s")): return .dotAll
        case UInt32(UInt8(ascii: "m")): return .multiline
        case UInt32(UInt8(ascii: "u")): return []      // Unicode: already the default
        default: return nil
        }
    }
}

// MARK: - Parser

/// A pattern that will not compile.
///
/// A struct rather than an enum because there is nothing to branch on: the
/// engine reports where and why in prose, and every caller either propagates it
/// or reports it.
public struct ParseError: Error, CustomStringConvertible {
    public let msg: String
    public var description: String { msg }
}

struct Parser {
    let p: [UInt32]
    var i = 0
    var ncap = 0

    /// Flags from a *flag-only* group, `(?i)`.
    ///
    /// Python applies these to the whole pattern no matter where they appear —
    /// `\b(?i)abc` is entirely case-insensitive, including the `\b` before the
    /// group. Presidio's `ItDriverLicenseRecognizer` relies on exactly that.
    /// (Python 3.11 deprecated the non-leading form and 3.12 errors on it; the
    /// patterns this port has to read predate that, so it is accepted and
    /// applied globally rather than rejected.) Collecting them here and merging
    /// at compile time gets the semantics right without a second pass over the
    /// pattern.
    var globalSet: InlineFlags = []
    var globalClear: InlineFlags = []

    init(_ s: String) { p = s.unicodeScalars.map { $0.value } }

    mutating func parse() throws -> (Node, Int) {
        let n = try parseAlt()
        if i < p.count { throw ParseError(msg: "trailing ) at \(i)") }
        return (n, ncap)
    }

    /// Parses the letters of a flag group: `imsu`, or `i-s`, up to `)` or `:`.
    mutating func parseFlagLetters() throws -> (set: InlineFlags, clear: InlineFlags) {
        var set: InlineFlags = []
        var clear: InlineFlags = []
        var negating = false
        while i < p.count,
              p[i] != UInt32(UInt8(ascii: ")")), p[i] != UInt32(UInt8(ascii: ":")) {
            let c = p[i]
            if c == UInt32(UInt8(ascii: "-")) {
                guard !negating else { throw ParseError(msg: "repeated '-' in flag group") }
                negating = true; i += 1; continue
            }
            guard let flag = InlineFlags.letter(c) else {
                let name = String(UnicodeScalar(c) ?? " ")
                throw ParseError(msg: "unsupported inline flag '\(name)': "
                                 + "this engine implements i, s, m and u")
            }
            if negating { clear.insert(flag) } else { set.insert(flag) }
            i += 1
        }
        guard i < p.count else { throw ParseError(msg: "unterminated flag group") }
        guard set.isDisjoint(with: clear) else {
            throw ParseError(msg: "flag both set and cleared in one group")
        }
        return (set, clear)
    }
    mutating func parseAlt() throws -> Node {
        var branches = [try parseConcat()]
        while i < p.count, p[i] == UInt32(UInt8(ascii: "|")) { i += 1; branches.append(try parseConcat()) }
        return branches.count == 1 ? branches[0] : .alt(branches)
    }
    mutating func parseConcat() throws -> Node {
        var items: [Node] = []
        while i < p.count, p[i] != UInt32(UInt8(ascii: "|")), p[i] != UInt32(UInt8(ascii: ")")) {
            items.append(try parseQuant())
        }
        if items.isEmpty { return .empty }
        return items.count == 1 ? items[0] : .concat(items)
    }
    mutating func parseQuant() throws -> Node {
        var atom = try parseAtom()
        loop: while i < p.count {
            var lo = -1, hi = -1
            switch p[i] {
            case UInt32(UInt8(ascii: "*")): lo = 0; hi = Int.max; i += 1
            case UInt32(UInt8(ascii: "+")): lo = 1; hi = Int.max; i += 1
            case UInt32(UInt8(ascii: "?")): lo = 0; hi = 1; i += 1
            case UInt32(UInt8(ascii: "{")):
                let save = i; i += 1
                var a = 0, sawA = false
                while i < p.count, isDigit(p[i]) { a = a * 10 + Int(p[i] - 48); i += 1; sawA = true }
                if !sawA { i = save; break loop }
                var b = a
                if i < p.count, p[i] == UInt32(UInt8(ascii: ",")) {
                    i += 1; b = Int.max
                    if i < p.count, isDigit(p[i]) { b = 0; while i < p.count, isDigit(p[i]) { b = b * 10 + Int(p[i] - 48); i += 1 } }
                }
                guard i < p.count, p[i] == UInt32(UInt8(ascii: "}")) else { i = save; break loop }
                i += 1; lo = a; hi = b
            default: break loop
            }
            var greedy = true
            if i < p.count, p[i] == UInt32(UInt8(ascii: "?")) { greedy = false; i += 1 }
            else if i < p.count, p[i] == UInt32(UInt8(ascii: "+")) { i += 1 } // possessive -> treat greedy
            atom = .rep(atom, min: lo, max: hi, greedy: greedy)
        }
        return atom
    }
    func isDigit(_ c: UInt32) -> Bool { c >= 48 && c <= 57 }

    mutating func parseAtom() throws -> Node {
        guard i < p.count else { return .empty }
        let c = p[i]
        switch c {
        case UInt32(UInt8(ascii: "(")):
            i += 1
            if i < p.count, p[i] == UInt32(UInt8(ascii: "?")) {
                i += 1
                guard i < p.count else { throw ParseError(msg: "bad (?") }
                let k = p[i]
                if k == UInt32(UInt8(ascii: ":")) { i += 1; let n = try parseAlt(); try expect(")"); return .group(n, capture: nil) }
                if k == UInt32(UInt8(ascii: "=")) { i += 1; let n = try parseAlt(); try expect(")"); return .look(n, ahead: true, positive: true, width: 0) }
                if k == UInt32(UInt8(ascii: "!")) { i += 1; let n = try parseAlt(); try expect(")"); return .look(n, ahead: true, positive: false, width: 0) }
                if k == UInt32(UInt8(ascii: "<")), i + 1 < p.count,
                   p[i+1] == UInt32(UInt8(ascii: "=")) || p[i+1] == UInt32(UInt8(ascii: "!")) {
                    let pos = p[i+1] == UInt32(UInt8(ascii: "="))
                    i += 2
                    let n = try parseAlt(); try expect(")")
                    guard let w = fixedWidth(n) else { throw ParseError(msg: "variable-width lookbehind") }
                    return .look(n, ahead: false, positive: pos, width: w)
                }
                // Inline flags: `(?i)` global, `(?i:...)` and `(?-i:...)` scoped.
                let (set, clear) = try parseFlagLetters()
                if i < p.count, p[i] == UInt32(UInt8(ascii: ":")) {
                    // `^` and `$` consult multiline at match time, so it cannot
                    // vary by subexpression here. Rejected rather than applied
                    // pattern-wide, which would be the wrong answer delivered
                    // quietly. No bundled pattern uses it.
                    guard !set.contains(.multiline), !clear.contains(.multiline) else {
                        throw ParseError(msg: "scoped (?m:...) is not supported; "
                                         + "multiline can only be set for the whole pattern")
                    }
                    i += 1; let n = try parseAlt(); try expect(")")
                    return .flags(n, set: set, clear: clear)
                }
                try expect(")")
                // Flag-only form: Python applies it to the entire pattern.
                globalSet.formUnion(set)
                globalClear.formUnion(clear)
                return .empty
            }
            ncap += 1; let idx = ncap
            let n = try parseAlt(); try expect(")")
            return .group(n, capture: idx)
        case UInt32(UInt8(ascii: "[")): return .cls(try parseClass())
        case UInt32(UInt8(ascii: ".")): i += 1; return .any
        case UInt32(UInt8(ascii: "^")): i += 1; return .bol
        case UInt32(UInt8(ascii: "$")): i += 1; return .eol
        case UInt32(UInt8(ascii: "\\")): return try parseEscape()
        default: i += 1; return .lit(c)
        }
    }
    mutating func expect(_ ch: Character) throws {
        guard i < p.count, p[i] == ch.unicodeScalars.first!.value else { throw ParseError(msg: "expected \(ch)") }
        i += 1
    }
    mutating func parseEscape() throws -> Node {
        i += 1
        guard i < p.count else { throw ParseError(msg: "trailing backslash") }
        let c = p[i]; i += 1
        switch c {
        case UInt32(UInt8(ascii: "d")), UInt32(UInt8(ascii: "D")), UInt32(UInt8(ascii: "w")),
             UInt32(UInt8(ascii: "W")), UInt32(UInt8(ascii: "s")), UInt32(UInt8(ascii: "S")):
            var cc = CharClass(); cc.classes = [UInt8(c)]; return .cls(cc)
        case UInt32(UInt8(ascii: "b")): return .wordB(true)
        case UInt32(UInt8(ascii: "B")): return .wordB(false)
        case UInt32(UInt8(ascii: "A")): return .inputStart
        case UInt32(UInt8(ascii: "Z")), UInt32(UInt8(ascii: "z")): return .inputEnd
        case UInt32(UInt8(ascii: "n")): return .lit(10)
        case UInt32(UInt8(ascii: "r")): return .lit(13)
        case UInt32(UInt8(ascii: "t")): return .lit(9)
        case UInt32(UInt8(ascii: "f")): return .lit(12)
        case UInt32(UInt8(ascii: "v")): return .lit(11)
        case UInt32(UInt8(ascii: "0")): return .lit(0)
        case UInt32(UInt8(ascii: "x")): return .lit(try hex(2))
        case UInt32(UInt8(ascii: "u")): return .lit(try hex(4))
        // Python's 8-hex-digit escape. Omitting it is not a missing feature but
        // a silent corruption: "\U00010137-\U0001013F" parses as a literal 'U'
        // followed by digits, yielding a spurious '7'-'U' range that swallows
        // ASCII uppercase.
        case UInt32(UInt8(ascii: "U")): return .lit(try hex(8))
        case 49...57: return .backref(Int(c - 48))
        default: return .lit(c)
        }
    }
    mutating func hex(_ n: Int) throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<n {
            guard i < p.count, let d = hexVal(p[i]) else { throw ParseError(msg: "bad hex") }
            v = v * 16 + d; i += 1
        }
        return v
    }
    func hexVal(_ c: UInt32) -> UInt32? {
        if c >= 48 && c <= 57 { return c - 48 }
        if c >= 97 && c <= 102 { return c - 87 }
        if c >= 65 && c <= 70 { return c - 55 }
        return nil
    }
    mutating func parseClass() throws -> CharClass {
        i += 1
        var cc = CharClass()
        if i < p.count, p[i] == UInt32(UInt8(ascii: "^")) { cc.negated = true; i += 1 }
        var first = true
        while i < p.count {
            if p[i] == UInt32(UInt8(ascii: "]")) && !first { i += 1; return cc }
            first = false
            var lo: UInt32
            if p[i] == UInt32(UInt8(ascii: "\\")) {
                i += 1
                guard i < p.count else { throw ParseError(msg: "bad class escape") }
                let e = p[i]; i += 1
                switch e {
                case UInt32(UInt8(ascii: "d")), UInt32(UInt8(ascii: "D")), UInt32(UInt8(ascii: "w")),
                     UInt32(UInt8(ascii: "W")), UInt32(UInt8(ascii: "s")), UInt32(UInt8(ascii: "S")):
                    cc.classes.append(UInt8(e)); continue
                case UInt32(UInt8(ascii: "n")): lo = 10
                case UInt32(UInt8(ascii: "r")): lo = 13
                case UInt32(UInt8(ascii: "t")): lo = 9
                case UInt32(UInt8(ascii: "f")): lo = 12
                case UInt32(UInt8(ascii: "v")): lo = 11
                case UInt32(UInt8(ascii: "x")): lo = try hex(2)
                case UInt32(UInt8(ascii: "u")): lo = try hex(4)
                case UInt32(UInt8(ascii: "U")): lo = try hex(8)
                default: lo = e
                }
            } else { lo = p[i]; i += 1 }
            if i + 1 < p.count, p[i] == UInt32(UInt8(ascii: "-")), p[i+1] != UInt32(UInt8(ascii: "]")) {
                i += 1
                var hi: UInt32
                if p[i] == UInt32(UInt8(ascii: "\\")) {
                    i += 1; let e = p[i]; i += 1
                    switch e {
                    case UInt32(UInt8(ascii: "x")): hi = try hex(2)
                    case UInt32(UInt8(ascii: "u")): hi = try hex(4)
                    case UInt32(UInt8(ascii: "U")): hi = try hex(8)
                    case UInt32(UInt8(ascii: "n")): hi = 10
                    default: hi = e
                    }
                } else { hi = p[i]; i += 1 }
                cc.ranges.append((lo, hi))
            } else {
                cc.ranges.append((lo, lo))
            }
        }
        throw ParseError(msg: "unterminated class")
    }
}

func fixedWidth(_ n: Node) -> Int? {
    switch n {
    case .empty, .wordB, .bol, .eol, .inputStart, .inputEnd: return 0
    case .lit, .cls, .any: return 1
    case .concat(let xs):
        var t = 0
        for x in xs { guard let w = fixedWidth(x) else { return nil }; t += w }
        return t
    case .alt(let xs):
        var w: Int? = nil
        for x in xs { guard let a = fixedWidth(x) else { return nil }; if w == nil { w = a } else if w != a { return nil } }
        return w
    case .rep(let x, let lo, let hi, _):
        guard lo == hi, let w = fixedWidth(x) else { return nil }
        return w * lo
    case .group(let x, _): return fixedWidth(x)
    case .look: return 0
    case .backref: return nil
    case .flags(let x, _, _): return fixedWidth(x)
    }
}

// MARK: - Matcher (recursive backtracking with continuations)

/// A compiled pattern.
///
/// Offsets returned by `matches(in:)` are Unicode **scalar** indices, matching
/// Python and `PresidioCore.TextDocument`.
///
/// Not `Sendable`: matching mutates per-instance scratch state, so an instance
/// must not be shared across concurrent tasks. Compile one per task, or gate
/// access. Making compiled patterns shareable is scheduled for the hardening
/// milestone (PLAN.md M5).
/// A compiled pattern.
///
/// Immutable after construction and therefore `Sendable`: all match state lives
/// in a `VM` created per call, so one compiled pattern can be shared across
/// tasks and swept concurrently.
public final class PureRegex: Sendable {
    let root: Node
    let ncap: Int
    let ignoreCase: Bool
    let dotAll: Bool
    let multiline: Bool

    /// Defaults mirror the flags Presidio sets on every pattern
    /// (`pattern_recognizer.py:59`: `DOTALL | MULTILINE | IGNORECASE`).
    public init(
        _ pattern: String,
        ignoreCase: Bool = true,
        dotAll: Bool = true,
        multiline: Bool = true
    ) throws {
        var p = Parser(pattern)
        var (r, n) = try p.parse()
        r = PureRegex.seal(r)
        (root, ncap) = (r, n)

        // A flag-only group, `(?i)`, applies to the entire pattern in Python —
        // wherever it appears — so it is merged into the caller's flags rather
        // than scoped to what follows it. Ignoring these is what made French's
        // `(?iu)` token_match compile case-sensitively.
        func resolve(_ flag: InlineFlags, _ base: Bool) -> Bool {
            if p.globalSet.contains(flag) { return true }
            if p.globalClear.contains(flag) { return false }
            return base
        }
        let ignoreCase = resolve(.ignoreCase, ignoreCase)
        let dotAll = resolve(.dotAll, dotAll)
        let multiline = resolve(.multiline, multiline)

        self.ignoreCase = ignoreCase; self.dotAll = dotAll; self.multiline = multiline
        // The AST is retained for the prefilter; matching runs on the program.
        self.program = Compiler.compile(
            r, captureCount: n,
            ignoreCase: ignoreCase, dotAll: dotAll, multiline: multiline
        )
        // Computed here rather than lazily: a `lazy var` is mutable state and
        // would cost Sendable conformance.
        self.pre = Prefilter(r, ignoreCase: ignoreCase)
    }

    let program: Program

    /// Precomputed at compile time; see Prefilter.swift for why it is not a
    /// closure any more.
    let pre: Prefilter?

    static func seal(_ n: Node) -> Node {
        switch n {
        case .cls(var c): c.seal(); return .cls(c)
        case .concat(let xs): return .concat(xs.map(seal))
        case .alt(let xs): return .alt(xs.map(seal))
        case .rep(let x, let a, let b, let g): return .rep(seal(x), min: a, max: b, greedy: g)
        case .group(let x, let c): return .group(seal(x), capture: c)
        case .look(let x, let a, let p, let w): return .look(seal(x), ahead: a, positive: p, width: w)
        case .flags(let x, let set, let clear): return .flags(seal(x), set: set, clear: clear)
        default: return n
        }
    }

    /// One match, with the spans of its capturing groups.
    ///
    /// Group numbering follows the regex convention: group 0 is the whole
    /// match, groups 1... are the capturing parens left to right. A group that
    /// did not participate has span `nil`, matching Python's `match.span(n)`
    /// returning `(-1, -1)`.
    public struct Match: Sendable, Hashable {
        public let start: Int
        public let end: Int
        /// Index 0 is the whole match; `groups[n]` is capture group `n`.
        public let groups: [Range<Int>?]

        public init(start: Int, end: Int, groups: [Range<Int>?]) {
            self.start = start
            self.end = end
            self.groups = groups
        }

        public func span(_ group: Int) -> Range<Int>? {
            group >= 0 && group < groups.count ? groups[group] : nil
        }

        /// Number of capturing groups, excluding group 0.
        public var groupCount: Int { Swift.max(0, groups.count - 1) }
    }

    /// Number of capturing groups in the pattern, excluding group 0.
    public var captureCount: Int { ncap }

    /// All non-overlapping matches, as half-open scalar ranges.
    public func matches(in text: String) -> [(Int, Int)] {
        matchesWithGroups(in: text).map { ($0.start, $0.end) }
    }

    /// All non-overlapping matches, including capture-group spans.
    ///
    /// Needed by recognizers that fall back to progressively shorter prefixes
    /// of a match — `IbanRecognizer` walks its groups in reverse until one
    /// passes the checksum, which is how it avoids swallowing trailing text.
    public func matchesWithGroups(in text: String) -> [Match] {
        let input = text.unicodeScalars.map(\.value)
        var out: [Match] = []
        var vm = VM(program: program, input: input, multiline: multiline)
        var at = 0
        while let match = scan(&vm, input, from: at) {
            out.append(match)
            at = match.end > match.start ? match.end : match.start + 1
        }
        return out
    }

    /// Scalar values of `text`, for callers that scan the same input repeatedly.
    ///
    /// Converting a String to scalars is linear, so a caller doing several
    /// searches over one document should convert once rather than per search.
    public static func scalarValues(of text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    /// The first match at or after `start`, or nil.
    ///
    /// Distinct from `matchesWithGroups(in:).first` in what it *does not* do:
    /// that computes every match in the input and then discards all but one.
    /// For a scanner that consumes matches left to right — the phone number
    /// matcher is the case that motivated this — the difference is quadratic.
    public func firstMatch(inScalars input: [UInt32], from start: Int = 0) -> Match? {
        var vm = VM(program: program, input: input, multiline: multiline)
        return scan(&vm, input, from: start)
    }

    /// Whether the pattern matches starting at offset 0, tried once.
    ///
    /// For a pattern anchored `^...$` a match can only begin at the start, so
    /// the ordinary left-to-right scan spends its time re-running a program
    /// that cannot succeed anywhere else. This runs the VM once.
    ///
    /// The pattern must carry its own `$`. Checking `end == count` here instead
    /// would be wrong: the VM returns the first end it reaches, so for
    /// `a|ab` against "ab" it returns 1 and never backtracks — it is the `$`
    /// that forces the engine to keep looking for an end-of-input match.
    public func matchesAnchored(_ text: String) -> Bool {
        let input = Self.scalarValues(of: text)
        var vm = VM(program: program, input: input, multiline: multiline)
        vm.reset()
        return vm.run(entry: 0, start: 0) != nil
    }

    public func firstMatch(in text: String, from start: Int = 0) -> Match? {
        firstMatch(inScalars: Self.scalarValues(of: text), from: start)
    }

    /// One left-to-right search step, shared by the scanning entry points.
    ///
    /// The VM is passed `inout` because constructing one per start position
    /// reallocates the slot array on every character of the input.
    private func scan(_ vm: inout VM, _ input: [UInt32], from start: Int) -> Match? {
        var at = start
        while at <= input.count {
            if let prefilter = pre {
                while at < input.count, !prefilter.mayStart(input[at]) { at += 1 }
                // Matches the original scan loop exactly, including this: with
                // a prefilter, an empty match at end-of-input is never
                // attempted, because no scalar there can start one.
                if at >= input.count { return nil }
            }
            vm.reset()
            if let end = vm.run(entry: 0, start: at) {
                var groups: [Range<Int>?] = [at..<end]
                if ncap >= 1 {
                    for g in 1...ncap {
                        let lo = vm.slots[g * 2], hi = vm.slots[g * 2 + 1]
                        groups.append(lo >= 0 && hi >= lo ? lo..<hi : nil)
                    }
                }
                return Match(start: at, end: end, groups: groups)
            }
            at += 1
        }
        return nil
    }

}
