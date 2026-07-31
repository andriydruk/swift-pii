import Testing
import Foundation
import PresidioConformance
@testable import PresidioRegex

/// Verifies the generated character-class tables against the Python `regex`
/// reference they were derived from.
///
/// This matters more than it looks. 131 of Presidio's 155 patterns contain
/// `\b`, which is *defined in terms of* `\w`, so the word-character set decides
/// which PII is found. The tables are compiled in rather than read from the
/// host's ICU precisely so this behaviour cannot drift between Android, macOS
/// and Windows — see docs/decisions/0001-regex-backend.md.
@Suite("Unicode class tables")
struct UnicodeTablesTests {

    struct Reference: Decodable {
        struct Klass: Decodable {
            let count: Int
            let ranges: [[UInt32]]
        }
        let regexVersion: String
        let w: Klass
        let d: Klass
        let s: Klass

        enum CodingKeys: String, CodingKey {
            case regexVersion = "regex_version"
            case w, d, s
        }
    }

    static func reference() throws -> Reference {
        // Regenerate with:
        //   python3 Tools/unicode_classes_python.py \
        //     --out Tests/PresidioConformance/Fixtures/unicode_classes.json \
        //     --swift-out Sources/PresidioRegex/UnicodeTables.swift
        try JSONDecoder().decode(
            Reference.self, from: Corpus.data(named: "unicode_classes")
        )
    }

    @Test("tables were generated from the pinned regex version")
    func versionIsPinned() throws {
        // A version bump changes \w membership and therefore detection results.
        // It must be a deliberate, reviewed diff, not a silent drift.
        #expect(UnicodeTables.sourceVersion == (try Self.reference()).regexVersion)
    }

    @Test("every table is sorted, non-overlapping and non-empty")
    func tablesAreWellFormed() {
        for (name, table) in [
            ("word", UnicodeTables.word),
            ("digit", UnicodeTables.digit),
            ("whitespace", UnicodeTables.whitespace),
        ] {
            #expect(!table.isEmpty, "\(name) is empty")
            for entry in table {
                #expect(entry.lo <= entry.hi, "\(name): inverted range")
            }
            for i in 1..<table.count {
                // Strictly increasing with a gap: adjacent ranges should have
                // been coalesced by the generator, so lo must exceed hi+1.
                #expect(
                    table[i].lo > table[i - 1].hi + 1,
                    "\(name): range \(i) not disjoint/coalesced from its predecessor"
                )
            }
        }
    }

    @Test("membership matches the Python reference for every codepoint")
    func membershipMatchesPythonExactly() throws {
        let ref = try Self.reference()

        func check(_ name: String, _ klass: Reference.Klass,
                   _ predicate: (Unicode.Scalar) -> Bool) {
            var expected = Set<UInt32>()
            for r in klass.ranges where r.count == 2 {
                for cp in r[0]...r[1] { expected.insert(cp) }
            }
            #expect(expected.count == klass.count, "\(name): reference self-inconsistent")

            var mismatches = 0
            var firstMismatch: UInt32?
            for cp in UInt32(0)...0x10FFFF {
                if (0xD800...0xDFFF).contains(cp) { continue }
                guard let scalar = Unicode.Scalar(cp) else { continue }
                if predicate(scalar) != expected.contains(cp) {
                    mismatches += 1
                    if firstMismatch == nil { firstMismatch = cp }
                }
            }
            #expect(
                mismatches == 0,
                """
                \(name): \(mismatches) codepoints disagree with Python `regex`; \
                first at U+\(String(firstMismatch ?? 0, radix: 16, uppercase: true))
                """
            )
        }

        check("\\w", ref.w, UnicodeTables.isWord)
        check("\\d", ref.d, UnicodeTables.isDigit)
        check("\\s", ref.s, UnicodeTables.isWhitespace)
    }

    /// The specific codepoints where the rejected backends diverge. If a future
    /// change swapped the tables for a host-ICU or Swift-Regex implementation,
    /// these are the cases that would break, so they are pinned explicitly.
    @Test("codepoints that discriminate between backends")
    func discriminatingCodepoints() {
        // Swift Regex omits combining marks from \w, which breaks \b around
        // any accented text. Python includes them.
        for cp: UInt32 in [0x0300, 0x0301, 0x0302, 0x1AB0] {
            #expect(UnicodeTables.isWord(Unicode.Scalar(cp)!),
                    "U+\(String(cp, radix: 16)) (Mn) must be a word character")
        }

        // ZWJ / ZWNJ are word characters under UTS#18. Swift Regex drops them;
        // PCRE2 under UCP drops them too.
        #expect(UnicodeTables.isWord(Unicode.Scalar(0x200C)!))  // ZWNJ
        #expect(UnicodeTables.isWord(Unicode.Scalar(0x200D)!))  // ZWJ

        // Spacing and enclosing marks: in for Python, out for PCRE2/UCP.
        #expect(UnicodeTables.isWord(Unicode.Scalar(0x0903)!))  // Mc
        #expect(UnicodeTables.isWord(Unicode.Scalar(0x0488)!))  // Me

        // Connector punctuation.
        #expect(UnicodeTables.isWord(Unicode.Scalar(0x005F)!))  // _
        #expect(UnicodeTables.isWord(Unicode.Scalar(0x203F)!))  // ‿

        // Swift Regex treats superscripts, fractions and Roman numerals as
        // digits. Python does not — this is why `\b\d{6,14}\b` would otherwise
        // match "①②③④⑤⑥⑦⑧⑨⑩" and "½½½½½½½½½½".
        for cp: UInt32 in [0x00B2, 0x00B3, 0x00B9, 0x00BD, 0x2160, 0x2460] {
            #expect(!UnicodeTables.isDigit(Unicode.Scalar(cp)!),
                    "U+\(String(cp, radix: 16)) must NOT be a digit")
        }

        // Arabic-Indic digits are digits, and Swift Regex's .unicodeScalar mode
        // drops them.
        for cp: UInt32 in [0x0660, 0x0669, 0x06F0] {
            #expect(UnicodeTables.isDigit(Unicode.Scalar(cp)!),
                    "U+\(String(cp, radix: 16)) must be a digit")
        }

        // ASCII sanity.
        #expect(UnicodeTables.isDigit("0"))
        #expect(UnicodeTables.isDigit("9"))
        #expect(!UnicodeTables.isDigit("a"))
        #expect(UnicodeTables.isWord("a"))
        #expect(!UnicodeTables.isWord("-"))
        #expect(UnicodeTables.isWhitespace(" "))
        #expect(UnicodeTables.isWhitespace("\t"))
        #expect(!UnicodeTables.isWhitespace("a"))
    }

    @Test("ASCII membership is consistent with the stdlib's own view")
    func asciiSanity() {
        for cp in UInt32(0)...127 {
            let scalar = Unicode.Scalar(cp)!
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "_" {
                #expect(UnicodeTables.isWord(scalar), "U+\(cp) should be \\w")
            }
        }
    }
}
