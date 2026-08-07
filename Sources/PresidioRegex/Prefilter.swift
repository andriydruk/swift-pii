// Start-position prefilter: skip offsets that provably cannot begin a match.
//
// This runs at *every position for every pattern*, so it is the hottest code in
// the package — a 155-pattern sweep evaluates it once per pattern per character.
// It was previously a closure derived from the AST, and for an alternation that
// meant one escaping closure call per branch per character. Presidio's patterns
// are alternation-heavy, so that cost dominated.
//
// It is now a precomputed bitmap: exact for ASCII, conservative above it.
// A prefilter may over-accept without changing results — it only ever skips
// positions that provably cannot match — so being conservative for non-ASCII
// costs a little speed on non-Latin text and nothing in correctness.

/// The set of scalars that could begin a match.
struct Prefilter {
    /// Membership for U+0000–U+003F and U+0040–U+007F.
    let asciiLow: UInt64
    let asciiHigh: UInt64
    /// Whether any scalar ≥ U+0080 could start a match. Conservative: `true`
    /// means "do not skip", never "must match".
    let mayStartNonASCII: Bool

    @inline(__always)
    func mayStart(_ scalar: UInt32) -> Bool {
        if scalar < 64 { return (asciiLow >> scalar) & 1 == 1 }
        if scalar < 128 { return (asciiHigh >> (scalar - 64)) & 1 == 1 }
        return mayStartNonASCII
    }

    /// Build from a pattern's AST, or nil when no useful filter exists.
    init?(_ node: Node, ignoreCase: Bool) {
        guard let predicate = PureRegex.firstSet(node, ignoreCase) else { return nil }
        var low: UInt64 = 0
        var high: UInt64 = 0
        // Evaluate the derived predicate once per ASCII scalar at compile time,
        // so the scan loop never calls it.
        for scalar in UInt32(0)..<128 where predicate(scalar) {
            if scalar < 64 { low |= 1 << scalar } else { high |= 1 << (scalar - 64) }
        }
        // A filter that accepts everything is worse than none: it costs a test
        // per character and skips nothing.
        if low == .max && high == .max
            && PureRegex.firstSetMayBeNonASCII(node, ignoreCase) {
            return nil
        }
        self.asciiLow = low
        self.asciiHigh = high
        self.mayStartNonASCII = PureRegex.firstSetMayBeNonASCII(node, ignoreCase)
    }
}

extension PureRegex {
    static func firstSet(_ n: Node, _ ic: Bool) -> ((UInt32) -> Bool)? {
        switch n {
        case .lit(let c):
            if ic { let vs = Set(Fold.variants(c)); return { vs.contains($0) } }
            return { $0 == c }
        case .cls(let cc): return { cc.matches($0, ignoreCase: ic) }
        case .any, .backref, .empty, .wordB, .bol, .eol, .inputStart, .inputEnd, .look: return nil
        case .group(let x, _): return firstSet(x, ic)
        case .flags(let x, let set, let clear):
            // The prefilter only reasons about the first character, so only
            // the case flag can matter to it; set wins over the outer value,
            // clear turns it off.
            return firstSet(x, set.contains(.ignoreCase)
                            || (ic && !clear.contains(.ignoreCase)))
        case .alt(let xs):
            var fs: [(UInt32) -> Bool] = []
            for x in xs { guard let f = firstSet(x, ic) else { return nil }; fs.append(f) }
            return { c in fs.contains { $0(c) } }
        case .rep(let x, let lo, _, _):
            return lo >= 1 ? firstSet(x, ic) : nil
        case .concat(let xs):
            for x in xs {
                switch x {
                case .wordB, .bol, .inputStart: continue          // zero-width, keep scanning
                case .look: continue
                default: return firstSet(x, ic)
                }
            }
            return nil
        }
    }

    /// Could a scalar ≥ U+0080 begin a match?
    ///
    /// Determined structurally rather than by probing, because probing a sample
    /// of non-ASCII scalars could miss a member and turn the prefilter from
    /// conservative into wrong.
    static func firstSetMayBeNonASCII(_ n: Node, _ ic: Bool) -> Bool {
        switch n {
        case .lit(let c):
            if c >= 128 { return true }
            return ic && Fold.variants(c).contains { $0 >= 128 }
        case .cls(let cc):
            // A negated class admits almost everything above ASCII, and the
            // shorthand classes (\d \w \s and their complements) all have
            // non-ASCII members in the Unicode tables.
            if cc.negated || !cc.classes.isEmpty { return true }
            return cc.ranges.contains { $0.1 >= 128 }
        case .any: return true
        case .group(let x, _): return firstSetMayBeNonASCII(x, ic)
        case .flags(let x, let set, let clear):
            return firstSetMayBeNonASCII(x, set.contains(.ignoreCase)
                                         || (ic && !clear.contains(.ignoreCase)))
        case .alt(let xs): return xs.contains { firstSetMayBeNonASCII($0, ic) }
        case .rep(let x, let lo, _, _):
            return lo >= 1 ? firstSetMayBeNonASCII(x, ic) : true
        case .concat(let xs):
            for x in xs {
                switch x {
                case .wordB, .bol, .inputStart, .look: continue
                default: return firstSetMayBeNonASCII(x, ic)
                }
            }
            return true
        case .backref, .empty, .wordB, .bol, .eol, .inputStart, .inputEnd, .look:
            return true
        }
    }
}
