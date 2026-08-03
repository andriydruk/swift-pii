/// The offset model.
///
/// Presidio's wire contract is the **Unicode scalar offset** (Python's string
/// indexing unit). Every span this library emits or accepts is expressed in
/// scalar offsets so that a Swift result and a Python result are directly
/// comparable.
///
/// Three offset systems collide in a Swift port and conflating them produces
/// silently wrong spans — a PII-leak class of bug:
///
/// | System | Unit | Where it comes from |
/// |---|---|---|
/// | Python / Presidio | Unicode scalar | the fixture corpus, the REST contract |
/// | `NSRegularExpression` | UTF-16 code unit | any ICU-backed regex match |
/// | Swift `String` | grapheme cluster | `String.Index`, `count`, slicing |
///
/// `TextDocument` owns the conversions. Nothing else in the package should do
/// index arithmetic on a `String` directly.
public struct TextDocument: Sendable, Hashable {

    /// The original text, unmodified.
    public let text: String

    /// The text decomposed into Unicode scalars. Index `i` here is exactly the
    /// offset Python would report for the same character.
    public let scalars: [Unicode.Scalar]

    /// `utf16Starts[i]` is the UTF-16 offset at which scalar `i` begins.
    /// Present only when the text is non-ASCII; ASCII text uses the identity
    /// fast path, where scalar offset == UTF-16 offset == byte offset.
    private let utf16Starts: [Int]?

    /// True when every scalar is ASCII, in which case all three offset systems
    /// coincide and conversion is free.
    public let isASCII: Bool

    public init(_ text: String) {
        self.text = text
        let scalars = Array(text.unicodeScalars)
        self.scalars = scalars
        let ascii = scalars.allSatisfy { $0.isASCII }
        self.isASCII = ascii
        if ascii {
            self.utf16Starts = nil
        } else {
            var starts = [Int]()
            starts.reserveCapacity(scalars.count + 1)
            var running = 0
            for s in scalars {
                starts.append(running)
                running += UTF16.width(s)
            }
            // Sentinel: one past the end, so end-offsets convert without a
            // special case.
            starts.append(running)
            self.utf16Starts = starts
        }
    }

    /// Number of Unicode scalars — the length Python's `len()` would report.
    public var count: Int { scalars.count }

    public var isEmpty: Bool { scalars.isEmpty }

    /// Total UTF-16 length, i.e. what `NSRegularExpression` sees.
    public var utf16Count: Int {
        if let starts = utf16Starts { return starts[starts.count - 1] }
        return scalars.count
    }

    // MARK: - Slicing

    /// The substring covered by a scalar range.
    ///
    /// Returns `nil` for an out-of-bounds or inverted range rather than
    /// trapping, so a malformed span from a fixture or a backend surfaces as a
    /// test failure instead of a crash.
    public func substring(_ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= scalars.count,
              range.lowerBound <= range.upperBound
        else { return nil }
        var view = String.UnicodeScalarView()
        view.reserveCapacity(range.count)
        for i in range { view.append(scalars[i]) }
        return String(view)
    }

    /// Bounds are validated *before* the `Range` is formed: constructing
    /// `2..<1` traps inside `Range.init`, so an inverted span from a malformed
    /// fixture would crash rather than surface as a test failure.
    public func substring(start: Int, end: Int) -> String? {
        guard start >= 0, end <= scalars.count, start <= end else { return nil }
        return substring(start..<end)
    }

    // MARK: - Offset conversion

    /// Convert a UTF-16 offset (as reported by `NSRegularExpression` and any
    /// other ICU-backed API) to a scalar offset.
    ///
    /// Returns `nil` if the offset is out of range or lands *inside* a
    /// surrogate pair — the latter means a backend produced a span that splits
    /// an astral character, which is always a bug worth surfacing.
    public func scalarOffset(utf16Offset: Int) -> Int? {
        guard let starts = utf16Starts else {
            return (utf16Offset >= 0 && utf16Offset <= scalars.count) ? utf16Offset : nil
        }
        guard utf16Offset >= 0, utf16Offset <= starts[starts.count - 1] else { return nil }
        // Binary search for the scalar whose UTF-16 start equals utf16Offset.
        var lo = 0
        var hi = starts.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] == utf16Offset { return mid }
            if starts[mid] < utf16Offset { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil  // landed inside a surrogate pair
    }

    /// Convert a scalar offset to a UTF-16 offset.
    public func utf16Offset(scalarOffset: Int) -> Int? {
        guard scalarOffset >= 0, scalarOffset <= scalars.count else { return nil }
        guard let starts = utf16Starts else { return scalarOffset }
        return starts[scalarOffset]
    }

    /// Convert a UTF-16 range to a scalar range.
    public func scalarRange(utf16Range: Range<Int>) -> Range<Int>? {
        guard let lo = scalarOffset(utf16Offset: utf16Range.lowerBound),
              let hi = scalarOffset(utf16Offset: utf16Range.upperBound),
              lo <= hi
        else { return nil }
        return lo..<hi
    }

    /// Convert a scalar offset to a `String.Index` for interoperating with
    /// Swift string APIs.
    public func stringIndex(scalarOffset: Int) -> String.Index? {
        guard scalarOffset >= 0, scalarOffset <= scalars.count else { return nil }
        return text.unicodeScalars.index(
            text.unicodeScalars.startIndex, offsetBy: scalarOffset
        )
    }
}

public extension TextDocument {
    /// The `String.Index` range for a scalar span, for callers that want to
    /// slice or replace the original string directly.
    ///
    /// Scalar offsets are the wire contract everywhere in this package, but
    /// Swift strings are grapheme-indexed, so anyone reaching for
    /// `text[range]` needs this conversion rather than inventing their own.
    func range(start: Int, end: Int, in text: String) -> Range<String.Index>? {
        guard start >= 0, start <= end, end <= scalars.count else { return nil }
        let scalars = text.unicodeScalars
        guard let lower = scalars.index(
                scalars.startIndex, offsetBy: start, limitedBy: scalars.endIndex
              ),
              let upper = scalars.index(
                scalars.startIndex, offsetBy: end, limitedBy: scalars.endIndex
              )
        else { return nil }
        return lower..<upper
    }
}
