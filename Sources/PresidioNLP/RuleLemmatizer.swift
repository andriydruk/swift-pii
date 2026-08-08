import Foundation
import PresidioRegex

/// spaCy's attribute ruler: fine-grained tag → coarse POS, plus the lemmas and
/// morphological features it assigns directly.
///
/// The tagger emits Penn Treebank tags; rule-mode lemmatization keys off the
/// coarse POS, and this is what maps between them. It also assigns some lemmas
/// outright — "was" → "be", "me" → "I" — before the lemmatizer runs at all.
///
/// It is a `Matcher` over 179 token patterns, and this is a faithful port of it
/// rather than a flattened approximation. Two properties of spaCy's version are
/// easy to lose and both matter:
///
/// **All matching happens before any annotation.** `match(doc)` runs the whole
/// matcher, then `set_annotations` applies the results, so a rule's `TAG` test
/// sees the tagger's tag — never a tag an earlier rule assigned.
///
/// **Rules apply in pattern order, not token order.** spaCy sorts matches by
/// pattern index, so rule 173 setting `PRON` runs after rule 47 setting `DET`,
/// and `WDT` comes out as spaCy has it. A rule lifted out of the sequence cannot
/// be appended back at the end.
///
/// Thirteen of the rules test `DEP`. With no dependency labels those tests all
/// fail against the unset value — spaCy's own convention, where an unparsed
/// token's `DEP` is the string id of `""` — so a pipeline without a parser needs
/// no separate code path here, it just gets fewer matches.
struct AttributeRuler {

    /// One attribute test, in the four forms spaCy's `Matcher` uses here.
    struct Constraint: Decodable {
        let eq: String?
        let anyOf: [String]?
        let noneOf: [String]?
        let regex: String?

        enum CodingKeys: String, CodingKey {
            case eq
            case anyOf = "in"
            case noneOf = "not_in"
            case regex
        }
    }

    struct TokenPattern: Decodable {
        let tag: Constraint?
        let lower: Constraint?
        let dep: Constraint?
        let isSpace: Bool?

        enum CodingKeys: String, CodingKey {
            case tag, lower, dep
            case isSpace = "is_space"
        }
    }

    struct Rule: Decodable {
        /// spaCy allows a rule several alternative patterns under one key; only
        /// one rule here has two, and dropping the second is how `got` → `get`
        /// went missing for a while.
        let alternatives: [[TokenPattern]]
        /// Which token of the match is annotated. Negative counts from the end,
        /// as `Span` indexing does.
        let index: Int
        let pos: String?
        let lemma: String?
        let morph: String?
        /// One rule reassigns the fine-grained tag (whitespace → `_SP`), and one
        /// reassigns the dependency label. Carried so the ruler's output is what
        /// spaCy's is, not a subset of it.
        let tag: String?
        let dep: String?
    }

    struct Payload: Decodable {
        let rules: [Rule]
        let requiresParser: Int
        let schemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case rules
            case requiresParser = "requires_parser"
            case schemaVersion = "schema_version"
        }
    }

    private struct Loaded {
        let rules: [Rule]
        let requiresParser: Int
        /// Compiled once at load: three patterns, and recompiling them per token
        /// would be the most expensive thing in the component.
        let regexes: [String: PureRegex]
    }

    private static let loaded: Loaded? = {
        guard let url = Bundle.module.url(
            forResource: "attribute_ruler", withExtension: "json"
        ),
        let bytes = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(Payload.self, from: bytes),
        // A v1 file is the flattened shape this loader no longer understands.
        // Refusing it beats reading `rules` and silently ignoring `index`.
        decoded.schemaVersion == 2
        else { return nil }

        var regexes: [String: PureRegex] = [:]
        for rule in decoded.rules {
            for alternative in rule.alternatives {
                for spec in alternative {
                    for constraint in [spec.tag, spec.lower, spec.dep] {
                        guard let pattern = constraint?.regex else { continue }
                        regexes[pattern] = try? PureRegex(pattern)
                    }
                }
            }
        }
        return Loaded(
            rules: decoded.rules,
            requiresParser: decoded.requiresParser,
            regexes: regexes
        )
    }()

    static var isLoaded: Bool { loaded != nil }

    /// Rules whose patterns test `DEP`, and which therefore match nothing unless
    /// a dependency parse is supplied.
    ///
    /// Exposed so the difference between the two configurations is a number
    /// rather than a footnote. They decide AUX-versus-VERB, `IN`-as-SCONJ,
    /// `DT`/`WDT`-as-PRON and the `Case` feature on personal pronouns.
    static var parserDependentRuleCount: Int { loaded?.requiresParser ?? 0 }

    struct Attributes {
        /// The fine-grained tag *after* the ruler, which for whitespace is not
        /// the tag the tagger produced.
        var tag: String
        var pos: String
        var lemma: String?
        var morph: [String: String]
        var dep: String
    }

    /// Run the ruler over a whole tokenization.
    ///
    /// Per-document rather than per-token because eight of the rules match two
    /// adjacent tokens, and because the `DEP` ones need the parse.
    ///
    /// - Parameter deps: dependency labels, or empty for a pipeline with no
    ///   parser. A short array is padded with the unset label, so a caller
    ///   cannot half-supply them and get something in between.
    static func annotate(
        tags: [String], lowercased: [String], isSpace: [Bool], deps: [String] = []
    ) -> [Attributes] {
        let count = tags.count
        var result = (0..<count).map {
            Attributes(
                tag: tags[$0], pos: defaultPOS(for: tags[$0]), lemma: nil,
                morph: [:], dep: $0 < deps.count ? deps[$0] : ""
            )
        }
        guard let loaded, count > 0 else { return result }
        // The labels matching reads are the pre-ruler ones, so they are captured
        // here rather than read back out of `result` as it is mutated.
        let depLabels = (0..<count).map { $0 < deps.count ? deps[$0] : "" }

        for rule in loaded.rules {
            for alternative in rule.alternatives where !alternative.isEmpty {
                let width = alternative.count
                guard width <= count else { continue }
                for start in 0...(count - width) {
                    var matched = true
                    for offset in 0..<width {
                        let token = start + offset
                        if !matches(
                            alternative[offset], tag: tags[token],
                            lowercased: lowercased[token], dep: depLabels[token],
                            isSpace: isSpace[token], regexes: loaded.regexes
                        ) {
                            matched = false
                            break
                        }
                    }
                    guard matched else { continue }
                    let target = start + (rule.index >= 0 ? rule.index : width + rule.index)
                    guard target >= start, target < start + width else { continue }
                    if let pos = rule.pos { result[target].pos = pos }
                    if let lemma = rule.lemma { result[target].lemma = lemma }
                    if let morph = rule.morph { result[target].morph = parseMorph(morph) }
                    if let tag = rule.tag { result[target].tag = tag }
                    if let dep = rule.dep { result[target].dep = dep }
                }
            }
        }
        return result
    }

    private static func matches(
        _ spec: TokenPattern, tag: String, lowercased: String, dep: String,
        isSpace: Bool, regexes: [String: PureRegex]
    ) -> Bool {
        if let expected = spec.isSpace, expected != isSpace { return false }
        for (constraint, value) in [
            (spec.tag, tag), (spec.lower, lowercased), (spec.dep, dep),
        ] {
            guard let constraint else { continue }
            if !satisfies(constraint, value, regexes) { return false }
        }
        return true
    }

    private static func satisfies(
        _ constraint: Constraint, _ value: String, _ regexes: [String: PureRegex]
    ) -> Bool {
        if let eq = constraint.eq { return value == eq }
        if let anyOf = constraint.anyOf { return anyOf.contains(value) }
        // `""` in a NOT_IN list is spaCy's "must be set": an unannotated
        // attribute is the string id of the empty string.
        if let noneOf = constraint.noneOf { return !noneOf.contains(value) }
        if let pattern = constraint.regex {
            // `re.search`, which is what the Matcher's REGEX does. The three
            // patterns here are anchored, so it amounts to a full match.
            return regexes[pattern]?.firstMatch(in: value) != nil
        }
        return true
    }

    /// `Feat=Val|Feat=Val`, or `_` for "no features".
    static func parseMorph(_ text: String) -> [String: String] {
        guard text != "_" else { return [:] }
        var out: [String: String] = [:]
        for field in text.split(separator: "|") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    /// Fallback for a tag no rule mentions. Every tag in the model's label set
    /// is covered by a rule, so this only matters for an unexpected tag.
    static func defaultPOS(for tag: String) -> String {
        switch tag {
        case "NN", "NNS": return "NOUN"
        case "NNP", "NNPS": return "PROPN"
        case "VB", "VBD", "VBG", "VBN", "VBP", "VBZ": return "VERB"
        case "JJ", "JJR", "JJS": return "ADJ"
        case "RB", "RBR", "RBS": return "ADV"
        case "_SP": return "SPACE"
        default: return "X"
        }
    }
}

/// Port of `EnglishLemmatizer` in rule mode.
///
/// This is what spaCy's English pipeline actually runs, as opposed to the
/// POS-free lookup table: it needs the coarse POS from the attribute ruler,
/// which needs the tag from the tagger, which is why the whole chain had to be
/// ported to get exact lemmas.
public struct RuleLemmatizer: Sendable {

    struct Tables: Decodable {
        let rules: [String: [[String]]]
        let exceptions: [String: [String: [String]]]
        let index: [String: [String]]
    }

    private struct Loaded: Sendable {
        let rules: [String: [(suffix: String, replacement: String)]]
        let exceptions: [String: [String: [String]]]
        let index: [String: Set<String>]
    }

    private static let loaded: Loaded? = {
        guard let url = Bundle.module.url(
            forResource: "en_lemmatizer", withExtension: "json"
        ),
        let bytes = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(Tables.self, from: bytes)
        else { return nil }
        var rules: [String: [(String, String)]] = [:]
        for (pos, pairs) in decoded.rules {
            rules[pos] = pairs.compactMap {
                $0.count == 2 ? ($0[0], $0[1]) : nil
            }
        }
        return Loaded(
            rules: rules,
            exceptions: decoded.exceptions,
            index: decoded.index.mapValues(Set.init)
        )
    }()

    public static var isLoaded: Bool { loaded != nil }

    public init() {}

    /// Port of `EnglishLemmatizer.is_base_form`.
    ///
    /// An uninflected paradigm needs no lemmatization, so it short-circuits to
    /// the lowercased text. Reads `Number`, `VerbForm`, `Tense` and `Degree`,
    /// which is the whole reason the attribute ruler's MORPH assignments had to
    /// be carried through as well.
    static func isBaseForm(pos: String, morph: [String: String]) -> Bool {
        let lower = pos.lowercased()
        if lower == "noun", morph["Number"] == "Sing" { return true }
        if lower == "verb", morph["VerbForm"] == "Inf" { return true }
        if lower == "verb", morph["VerbForm"] == "Fin",
           morph["Tense"] == "Pres", morph["Number"] == nil { return true }
        if lower == "adj", morph["Degree"] == "Pos" { return true }
        if morph["VerbForm"] == "Inf" { return true }
        if morph["VerbForm"] == "None" { return true }
        if morph["Degree"] == "Pos" { return true }
        return false
    }

    /// Port of `Lemmatizer.rule_lemmatize`, returning the first candidate —
    /// which is the lemma spaCy assigns.
    public func lemma(text: String, pos: String, morph: [String: String]) -> String {
        let candidates = lemmas(text: text, pos: pos, morph: morph)
        return candidates.first ?? text.lowercased()
    }

    func lemmas(text: String, pos: String, morph: [String: String]) -> [String] {
        let univPOS = pos.lowercased()
        if univPOS.isEmpty || univPOS == "eol" || univPOS == "space" {
            return [text.lowercased()]
        }
        if Self.isBaseForm(pos: pos, morph: morph) { return [text.lowercased()] }

        guard let tables = Self.loaded else { return [text.lowercased()] }
        let index = tables.index[univPOS]
        let exceptions = tables.exceptions[univPOS]
        let rules = tables.rules[univPOS]

        // "if not any((index, exc, rules))" — a POS with no tables at all keeps
        // the surface form, and PROPN keeps its case.
        if (index?.isEmpty ?? true) && (exceptions?.isEmpty ?? true)
            && (rules?.isEmpty ?? true) {
            return univPOS == "propn" ? [text] : [text.lowercased()]
        }

        let original = text
        let lowered = text.lowercased()
        var forms: [String] = []
        var oovForms: [String] = []

        for (suffix, replacement) in rules ?? [] where lowered.hasSuffix(suffix) {
            let form = String(lowered.dropLast(suffix.count)) + replacement
            if form.isEmpty { continue }
            if index?.contains(form) == true {
                // A known word goes to the front, which is what decides
                // between competing rules.
                forms.insert(form, at: 0)
            } else if !form.allSatisfy(\.isLetter) {
                forms.append(form)
            } else {
                oovForms.append(form)
            }
        }

        // Deduplicate, preserving order.
        var seen = Set<String>()
        forms = forms.filter { seen.insert($0).inserted }

        for form in exceptions?[lowered] ?? [] where !forms.contains(form) {
            forms.insert(form, at: 0)
        }
        if forms.isEmpty { forms = oovForms }
        if forms.isEmpty { forms = [original] }
        return forms
    }
}

/// The full lemma chain: tagger → attribute ruler → rule-mode lemmatization.
///
/// This is what spaCy's English pipeline does, rather than an approximation of
/// it. Measured against spaCy over 5,513 tokens: **lemmas are exact**.
///
/// The three stages are separate types because they fail differently — the
/// tagger needs weights, the ruler needs its patterns, the lemmatizer needs its
/// tables — but callers want the chain.
public final class SpacyLemmatizer: @unchecked Sendable {

    private let tagger: TaggerModel
    private let parser: DependencyParser?
    private let rules = RuleLemmatizer()

    /// - Parameters:
    ///   - modelDirectory: an unpacked spaCy model directory.
    ///   - parseDependencies: load the parser, when the model ships one, so the
    ///     ruler's thirteen `DEP` rules can fire. That is what makes coarse POS
    ///     exact. It is cheaper here than it sounds: the parser listens to the
    ///     same tok2vec the tagger does, so one forward pass feeds both and the
    ///     only added work is the transitions.
    ///
    ///     Lemmas are exact either way — asserted by a test that runs the whole
    ///     chain both ways over the corpus and compares, rather than by argument.
    public init(modelDirectory: String, parseDependencies: Bool = true) throws {
        self.tagger = try TaggerModel(directory: modelDirectory)
        if parseDependencies,
           FileManager.default.fileExists(atPath: modelDirectory + "/parser/model") {
            self.parser = try DependencyParser(
                directory: modelDirectory, tok2vec: tagger.tok2vec
            )
        } else {
            self.parser = nil
        }
    }

    /// Attribute-ruler rules that test `DEP`, and so match nothing without a
    /// parse. Exposed so the difference between the two configurations is a
    /// number rather than a footnote.
    ///
    /// They decide AUX-versus-VERB, `IN`-as-SCONJ, `DT`/`WDT`-as-PRON and the
    /// `Case` feature on personal pronouns. None of them changes a lemma: the
    /// ruler assigns those lemmas directly, and DET and PRON have no lemma tables
    /// to differ over.
    public static var parserDependentRuleCount: Int {
        AttributeRuler.parserDependentRuleCount
    }

    /// Whether dependency labels are being supplied to the ruler.
    ///
    /// False means coarse POS is spaCy-without-a-parser: 5,499 of 5,513 on the
    /// corpus. Lemmas are exact either way.
    public var usesDependencies: Bool { parser != nil }

    public static var isLoaded: Bool {
        AttributeRuler.isLoaded && RuleLemmatizer.isLoaded
    }

    /// Fine-grained tags, for callers that want them.
    public func tags(for tokens: [Token], text: String) -> [String] {
        annotate(tokens: tokens, text: text).map(\.tag)
    }

    /// Coarse POS per token.
    public func partsOfSpeech(for tokens: [Token], text: String) -> [String] {
        annotate(tokens: tokens, text: text).map(\.pos)
    }

    public func lemmas(for tokens: [Token], text: String) -> [String] {
        let attributes = annotate(tokens: tokens, text: text)
        return tokens.enumerated().map { index, token in
            attributes[index].lemma ?? rules.lemma(
                text: token.text, pos: attributes[index].pos,
                morph: attributes[index].morph
            )
        }
    }

    /// The whole chain up to the lemmatizer: tok2vec once, then the tagger and
    /// the parser over the same vectors, then the ruler.
    private func annotate(tokens: [Token], text: String) -> [AttributeRuler.Attributes] {
        guard !tokens.isEmpty else { return [] }
        let vectors = tagger.tok2vec.encode(tokens: tokens, text: text)
        let tags = tagger.tags(for: tokens, vectors: vectors)
        let deps = parser?.parse(tokens: tokens, vectors: vectors).deps ?? []
        return AttributeRuler.annotate(
            tags: tags,
            lowercased: tokens.map { $0.text.lowercased() },
            isSpace: tokens.map { token in
                !token.text.isEmpty && token.text.unicodeScalars.allSatisfy {
                    $0.properties.isWhitespace
                }
            },
            deps: deps
        )
    }
}
