// Raw-value overloads for the generated tables.
//
// The matcher works in `UInt32` scalar values rather than `Unicode.Scalar`,
// because `Unicode.Scalar.init(UInt32)` is failable and this is the hottest
// path in the engine — every character of every candidate match goes through
// it.

extension UnicodeTables {

    @inlinable
    public static func contains(_ table: Table, _ value: UInt32) -> Bool {
        var lo = 0
        var hi = table.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let entry = table[mid]
            if value < entry.lo { hi = mid - 1 }
            else if value > entry.hi { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    @inlinable
    public static func isWord(_ value: UInt32) -> Bool { contains(word, value) }

    @inlinable
    public static func isDigit(_ value: UInt32) -> Bool { contains(digit, value) }

    @inlinable
    public static func isWhitespace(_ value: UInt32) -> Bool {
        contains(whitespace, value)
    }
}
