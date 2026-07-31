import Testing
@testable import PresidioCore

/// Corpora chosen to break offset handling in different ways.
///
/// The emoji strings are the ones the plan calls out: upstream's
/// `test_mask.py` uses 😈 (U+1F608, astral → surrogate pair in UTF-16), which
/// is the fastest way to expose a UTF-16/scalar confusion.
private let corpora: [(name: String, text: String)] = [
    ("empty", ""),
    ("ascii", "My SSN is 078-05-1120 and my card is 4095-2609-9393-4932."),
    ("latin1", "Käse und Straße, café, naïve, Ærø"),
    ("emoji", "😈 devil 😈 my SSN is 078-05-1120 😈"),
    ("emoji-dense", "😈😈😈😈😈"),
    ("cjk", "私の名前は田中です。電話番号は090-1234-5678です。"),
    ("hebrew-rtl", "שלום עולם 078-05-1120 שלום"),
    ("devanagari", "मेरा नाम राम है 078-05-1120"),
    ("combining", "e\u{0301}e\u{0301}e\u{0301} 078-05-1120"),
    ("invisible", "078\u{00AD}-05\u{200B}-1120\u{FEFF}"),
    ("zwj-family", "👨‍👩‍👧‍👦 family 4095260993934932"),
    ("mixed", "Ünïcödé 😈 田中 שלום मेरा e\u{0301} end"),
]

@Suite("TextDocument offset model")
struct TextDocumentTests {

    @Test("scalar count matches Python len() semantics", arguments: [
        ("", 0),
        ("abc", 3),
        ("😈", 1),               // one scalar, two UTF-16 units
        ("😈😈", 2),
        ("e\u{0301}", 2),        // e + combining acute = 2 scalars, 1 grapheme
        ("👨‍👩‍👧‍👦", 7),          // 4 people + 3 ZWJ = 7 scalars, 1 grapheme
    ])
    func scalarCount(text: String, expected: Int) {
        #expect(TextDocument(text).count == expected)
    }

    @Test("scalar count differs from String.count where graphemes cluster")
    func scalarVsGrapheme() {
        let doc = TextDocument("👨‍👩‍👧‍👦")
        #expect(doc.count == 7)
        #expect(doc.text.count == 1)  // one grapheme cluster
        // If these were ever equal, slicing by String.count would appear to
        // work and then silently truncate PII spans on real input.
    }

    @Test("ASCII fast path is detected")
    func asciiDetection() {
        #expect(TextDocument("plain ascii 123").isASCII)
        #expect(!TextDocument("café").isASCII)
        #expect(!TextDocument("😈").isASCII)
    }

    // MARK: - Round-trip properties
    //
    // The load-bearing invariant of the whole package: any span we emit must
    // re-slice to the same text. If this holds, spans cannot silently drift.

    @Test("every substring round-trips through scalar offsets")
    func substringRoundTrip() throws {
        for (name, text) in corpora {
            let doc = TextDocument(text)
            for start in 0...doc.count {
                for end in start...doc.count {
                    let sub = try #require(
                        doc.substring(start: start, end: end),
                        "\(name): nil substring for \(start)..<\(end)"
                    )
                    // Reconstruct independently via the scalar view.
                    let expected = String(
                        String.UnicodeScalarView(doc.scalars[start..<end])
                    )
                    #expect(sub == expected, "\(name): \(start)..<\(end)")
                }
            }
        }
    }

    @Test("scalar offset survives a round trip through UTF-16")
    func utf16RoundTrip() throws {
        for (name, text) in corpora {
            let doc = TextDocument(text)
            for scalar in 0...doc.count {
                let u16 = try #require(
                    doc.utf16Offset(scalarOffset: scalar), "\(name): scalar \(scalar)"
                )
                let back = try #require(
                    doc.scalarOffset(utf16Offset: u16),
                    "\(name): utf16 \(u16) did not map back"
                )
                #expect(back == scalar, "\(name): \(scalar) -> \(u16) -> \(back)")
            }
        }
    }

    @Test("UTF-16 offsets agree with Foundation's own view")
    func utf16AgreesWithStdlib() throws {
        for (name, text) in corpora {
            let doc = TextDocument(text)
            #expect(doc.utf16Count == text.utf16.count, "\(name)")
            // Slicing by our UTF-16 offsets must equal slicing the real view.
            for scalar in 0...doc.count {
                let u16 = try #require(doc.utf16Offset(scalarOffset: scalar))
                let idx = text.utf16.index(text.utf16.startIndex, offsetBy: u16)
                let prefixFromUTF16 = String(text.utf16[..<idx])
                let prefixFromScalars = doc.substring(start: 0, end: scalar)
                #expect(prefixFromUTF16 == prefixFromScalars, "\(name) at \(scalar)")
            }
        }
    }

    @Test("offsets inside a surrogate pair are rejected, not silently rounded")
    func surrogateInteriorRejected() {
        let doc = TextDocument("😈abc")
        // 😈 occupies UTF-16 units 0 and 1; unit 1 is the low surrogate.
        #expect(doc.scalarOffset(utf16Offset: 0) == 0)
        #expect(doc.scalarOffset(utf16Offset: 1) == nil)  // interior
        #expect(doc.scalarOffset(utf16Offset: 2) == 1)    // 'a'
        // Rounding here instead of rejecting is how a redaction rectangle ends
        // up half a character off and leaks a digit.
    }

    @Test("out-of-range offsets return nil rather than trapping")
    func boundsAreSafe() {
        let doc = TextDocument("abc")
        #expect(doc.substring(start: 0, end: 4) == nil)
        #expect(doc.substring(start: -1, end: 2) == nil)
        #expect(doc.substring(start: 2, end: 1) == nil)   // inverted
        #expect(doc.scalarOffset(utf16Offset: 99) == nil)
        #expect(doc.utf16Offset(scalarOffset: 99) == nil)
        #expect(doc.substring(start: 3, end: 3) == "")    // empty at end is valid
    }

    @Test("a UTF-16 span from an ICU-style match converts to the right text")
    func icuStyleSpanConversion() throws {
        // Simulates what NSRegularExpression hands back: UTF-16 offsets into a
        // string with astral characters before the match.
        let text = "😈😈 SSN 078-05-1120 here"
        let doc = TextDocument(text)
        let needle = "078-05-1120"

        // `firstRange(of:)` is stdlib, not Foundation — PresidioCore and its
        // tests must stay free of Foundation string APIs.
        let found = try #require(text.firstRange(of: needle))
        let u16Start = text.utf16.distance(
            from: text.utf16.startIndex, to: found.lowerBound.samePosition(in: text.utf16)!
        )
        let u16End = text.utf16.distance(
            from: text.utf16.startIndex, to: found.upperBound.samePosition(in: text.utf16)!
        )

        let scalarRange = try #require(doc.scalarRange(utf16Range: u16Start..<u16End))
        #expect(doc.substring(scalarRange) == needle)
        // The scalar start must be lower than the UTF-16 start, because the two
        // emoji ahead of it each cost an extra UTF-16 unit.
        #expect(scalarRange.lowerBound == u16Start - 2)
    }

    @Test("stringIndex lands on the same position as scalar slicing")
    func stringIndexAgrees() throws {
        for (name, text) in corpora {
            let doc = TextDocument(text)
            for scalar in 0...doc.count {
                let idx = try #require(doc.stringIndex(scalarOffset: scalar), "\(name)")
                #expect(String(text[..<idx]) == doc.substring(start: 0, end: scalar), "\(name)")
            }
        }
    }
}
