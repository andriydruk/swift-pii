import Foundation

/// spaCy's attribute ruler: fine-grained tag → coarse POS, plus the lemmas and
/// morphological features it assigns directly.
///
/// The tagger emits Penn Treebank tags; rule-mode lemmatization keys off the
/// coarse POS, and this is what maps between them. It also assigns some lemmas
/// outright — "was" → "be", "me" → "I" — before the lemmatizer runs at all.
///
/// **22 rules need the dependency parser** and are not applied here, because
/// this port has no parser. They decide AUX-versus-VERB, `IN`-as-SCONJ, and
/// `DT`/`WDT`-as-PRON. `AttributeRuler.parserDependentRuleCount` reports how
/// many were skipped so the gap is visible rather than implied.
struct AttributeRuler {

    struct Rule: Decodable {
        let tags: [String]?
        let lowers: [String]?
        let pos: String?
        let lemma: String?
        let morph: String?
    }

    struct Payload: Decodable {
        let rules: [Rule]
        let requiresParser: Int

        enum CodingKeys: String, CodingKey {
            case rules
            case requiresParser = "requires_parser"
        }
    }

    private static let payload: Payload? = {
        guard let url = Bundle.module.url(
            forResource: "attribute_ruler", withExtension: "json"
        ),
        let bytes = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(Payload.self, from: bytes)
        else { return nil }
        return decoded
    }()

    static var isLoaded: Bool { payload != nil }
    static var parserDependentRuleCount: Int { payload?.requiresParser ?? 0 }

    struct Attributes {
        var pos: String
        var lemma: String?
        var morph: [String: String]
    }

    /// Apply every matching rule in order; a later rule overwrites an earlier
    /// one, which is spaCy's own behaviour.
    static func attributes(tag: String, lowercased: String) -> Attributes {
        var result = Attributes(pos: defaultPOS(for: tag), lemma: nil, morph: [:])
        guard let rules = payload?.rules else { return result }

        for rule in rules {
            if let tags = rule.tags, !tags.contains(tag) { continue }
            if let lowers = rule.lowers, !lowers.contains(lowercased) { continue }
            if let pos = rule.pos { result.pos = pos }
            if let lemma = rule.lemma { result.lemma = lemma }
            if let morph = rule.morph { result.morph = parseMorph(morph) }
        }
        return result
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
    private let rules = RuleLemmatizer()

    /// - Parameter modelDirectory: an unpacked spaCy model directory.
    public init(modelDirectory: String) throws {
        self.tagger = try TaggerModel(directory: modelDirectory)
    }

    /// Attribute-ruler rules this port cannot apply because they need the
    /// dependency parser. Exposed so the gap is visible rather than implied.
    ///
    /// They decide AUX-versus-VERB, `IN`-as-SCONJ and `DT`/`WDT`-as-PRON. None
    /// of them changes a lemma: the ruler assigns those lemmas directly, and
    /// DET and PRON have no lemma tables to differ over. POS parity is
    /// 5,499/5,513 for exactly this reason; lemma parity is 5,513/5,513.
    public static var parserDependentRuleCount: Int {
        AttributeRuler.parserDependentRuleCount
    }

    public static var isLoaded: Bool {
        AttributeRuler.isLoaded && RuleLemmatizer.isLoaded
    }

    /// Fine-grained tags, for callers that want them.
    public func tags(for tokens: [Token], text: String) -> [String] {
        tagger.tags(for: tokens, text: text)
    }

    /// Coarse POS per token.
    public func partsOfSpeech(for tokens: [Token], text: String) -> [String] {
        let tags = tagger.tags(for: tokens, text: text)
        return tokens.enumerated().map { index, token in
            AttributeRuler.attributes(
                tag: tags[index], lowercased: token.text.lowercased()
            ).pos
        }
    }

    public func lemmas(for tokens: [Token], text: String) -> [String] {
        guard !tokens.isEmpty else { return [] }
        let tags = tagger.tags(for: tokens, text: text)
        return tokens.enumerated().map { index, token in
            let attributes = AttributeRuler.attributes(
                tag: tags[index], lowercased: token.text.lowercased()
            )
            return attributes.lemma ?? rules.lemma(
                text: token.text, pos: attributes.pos, morph: attributes.morph
            )
        }
    }
}
