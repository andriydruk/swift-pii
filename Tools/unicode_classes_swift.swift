// Character-class differential: Swift regex backends vs Python's `regex` module.
//
// The reference side of this comparison comes from Tools/unicode_classes_python.py.
// Run:
//     python3 Tools/unicode_classes_python.py --out /tmp/py_classes.json
//     swift Tools/unicode_classes_swift.swift /tmp/py_classes.json
//
// This settles PLAN.md §5 decision 1. Presidio uses the third-party `regex`
// module, whose \w follows UTS#18. ICU (NSRegularExpression) and Swift Regex
// each define \w differently, and 131 of 155 Presidio patterns contain \b,
// which is *defined in terms of* \w. So a class mismatch is not academic: it
// changes which PII is found.

import Foundation

// MARK: - Reference data

struct PyClass: Decodable {
    let count: Int
    let ranges: [[Int]]
}

struct PyClasses: Decodable {
    let regexVersion: String
    let unicodeVersion: String
    let w: PyClass
    let d: PyClass
    let s: PyClass

    enum CodingKeys: String, CodingKey {
        case regexVersion = "regex_version"
        case unicodeVersion = "unicode_version"
        case w, d, s
    }
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: unicode_classes_swift.swift <py_classes.json>\n".utf8))
    exit(2)
}

let refURL = URL(fileURLWithPath: CommandLine.arguments[1])
let reference = try JSONDecoder().decode(PyClasses.self, from: Data(contentsOf: refURL))

func expand(_ ranges: [[Int]]) -> Set<Int> {
    var out = Set<Int>()
    for r in ranges where r.count == 2 {
        for cp in r[0]...r[1] { out.insert(cp) }
    }
    return out
}

let maxCodepoint = 0x10FFFF
let surrogates = 0xD800...0xDFFF

func allCodepoints() -> [Int] {
    (0...maxCodepoint).filter { !surrogates.contains($0) }
}

let codepoints = allCodepoints()

// MARK: - Backends

/// ICU, via Foundation. Chunked: one call per codepoint would be ~1.1M
/// NSRegularExpression invocations.
func icuMembers(_ pattern: String) -> Set<Int> {
    let rx = try! NSRegularExpression(pattern: pattern, options: [])
    var members = Set<Int>()
    let chunk = 8192
    var i = 0
    while i < codepoints.count {
        let slice = codepoints[i..<min(i + chunk, codepoints.count)]
        var view = String.UnicodeScalarView()
        var utf16ToCodepoint = [Int: Int]()
        var utf16Pos = 0
        for cp in slice {
            guard let scalar = Unicode.Scalar(UInt32(cp)) else { continue }
            view.append(scalar)
            utf16ToCodepoint[utf16Pos] = cp
            utf16Pos += scalar.value > 0xFFFF ? 2 : 1
        }
        let text = String(view)
        rx.enumerateMatches(
            in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)
        ) { match, _, _ in
            guard let m = match, let cp = utf16ToCodepoint[m.range.location] else { return }
            // \w matches exactly one character; anything else means the probe
            // is not a single-character class and the mapping is unsound.
            members.insert(cp)
        }
        i += chunk
    }
    return members
}

/// Swift Regex (_StringProcessing), runtime-constructed.
func swiftRegexMembers(_ pattern: String, semantics: RegexSemanticLevel? = nil) -> Set<Int>? {
    guard var rx = try? Regex(pattern) else { return nil }
    if let semantics { rx = rx.matchingSemantics(semantics) }
    var members = Set<Int>()
    for cp in codepoints {
        guard let scalar = Unicode.Scalar(UInt32(cp)) else { continue }
        if (try? rx.wholeMatch(in: String(Character(scalar)))) ?? nil != nil {
            members.insert(cp)
        }
    }
    return members
}

// MARK: - Reporting

func categoryName(_ cp: Int) -> String {
    guard let scalar = Unicode.Scalar(UInt32(cp)) else { return "??" }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter: return "Lu"
    case .lowercaseLetter: return "Ll"
    case .titlecaseLetter: return "Lt"
    case .modifierLetter: return "Lm"
    case .otherLetter: return "Lo"
    case .nonspacingMark: return "Mn"
    case .spacingMark: return "Mc"
    case .enclosingMark: return "Me"
    case .decimalNumber: return "Nd"
    case .letterNumber: return "Nl"
    case .otherNumber: return "No"
    case .connectorPunctuation: return "Pc"
    case .format: return "Cf"
    case .unassigned: return "Cn"
    case .privateUse: return "Co"
    case .otherSymbol: return "So"
    case .mathSymbol: return "Sm"
    default: return "other"
    }
}

func report(_ label: String, _ got: Set<Int>, vs expected: Set<Int>) -> Int {
    let onlyGot = got.subtracting(expected)
    let onlyExpected = expected.subtracting(got)
    let total = onlyGot.count + onlyExpected.count

    print("")
    print("  \(label)")
    print("    python \(expected.count)   \(label.split(separator: " ").first ?? "") \(got.count)")
    if total == 0 {
        print("    IDENTICAL")
        return 0
    }
    print("    DIVERGENT: \(onlyGot.count) extra, \(onlyExpected.count) missing")

    func breakdown(_ set: Set<Int>, _ title: String) {
        guard !set.isEmpty else { return }
        var byCat = [String: [Int]]()
        for cp in set { byCat[categoryName(cp), default: []].append(cp) }
        print("      \(title):")
        for (cat, cps) in byCat.sorted(by: { $0.value.count > $1.value.count }) {
            let samples = cps.sorted().prefix(3)
                .map { String(format: "U+%04X", $0) }.joined(separator: " ")
            print("        \(cat) \(cps.count)  e.g. \(samples)")
        }
    }
    breakdown(onlyGot, "extra (would create false positives)")
    breakdown(onlyExpected, "missing (would create false negatives)")
    return total
}

// MARK: - Run

print("Character-class differential vs Python `regex` \(reference.regexVersion) "
      + "(Unicode \(reference.unicodeVersion))")
print("Codepoints probed: \(codepoints.count)")

var totalDivergence = 0

for (name, pattern, ref) in [
    ("w", #"\w"#, reference.w),
    ("d", #"\d"#, reference.d),
    ("s", #"\s"#, reference.s),
] {
    let expected = expand(ref.ranges)
    print("")
    print(String(repeating: "-", count: 72))
    print("\\\(name)")

    totalDivergence += report("NSRegularExpression (ICU)", icuMembers(pattern), vs: expected)

    if let members = swiftRegexMembers(pattern) {
        totalDivergence += report("Swift Regex (default)", members, vs: expected)
    } else {
        print("\n  Swift Regex (default)\n    FAILED TO COMPILE")
    }

    if let members = swiftRegexMembers(pattern, semantics: .unicodeScalar) {
        totalDivergence += report("Swift Regex (.unicodeScalar)", members, vs: expected)
    }
}

print("")
print(String(repeating: "=", count: 72))
print("total divergent codepoints across all classes/backends: \(totalDivergence)")
