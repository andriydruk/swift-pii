// Start-position prefilter: skip offsets that provably cannot begin a match.
// Adapted from prototypes/ — a large win on the 155-pattern sweep, where most
// patterns are anchored on a digit or a specific literal.

extension PureRegex {
    static func firstSet(_ n: Node, _ ic: Bool) -> ((UInt32) -> Bool)? {
        switch n {
        case .lit(let c):
            if ic { let vs = Set(Fold.variants(c)); return { vs.contains($0) } }
            return { $0 == c }
        case .cls(let cc): return { cc.matches($0, ignoreCase: ic) }
        case .any, .backref, .empty, .wordB, .bol, .eol, .inputStart, .inputEnd, .look: return nil
        case .group(let x, _): return firstSet(x, ic)
        case .caseToggle(let x, let g): return firstSet(x, g || ic)
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
}
