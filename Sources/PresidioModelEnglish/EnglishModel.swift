import Foundation

/// The bundled English model.
///
/// Add this product and named-entity recognition and exact lemmas work with no
/// setup — no downloads, no file paths, no `SPACY_MODEL_DIR`. It is a separate
/// product precisely so that callers who only need pattern-based detection
/// (credit cards, IBANs, emails, phone numbers — the majority) do not pay 13 MB
/// for weights they never load.
///
/// ```swift
/// import PresidioEngine
/// import PresidioModelEnglish
///
/// let nlp = try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
/// ```
///
/// The weights are spaCy's `en_core_web_sm` 3.7.1, MIT-licensed. Only the
/// files this package actually reads are kept — the sentence recognizer, the
/// lemmatizer lookups (extracted separately into PresidioNLP) and spaCy's
/// `vocab/strings.json` are all dropped, which takes 15 MB down to 12.
/// `strings.json` in particular is spaCy's string cache and is never consulted:
/// ids are recomputed with MurmurHash64A plus the reserved symbol table.
///
/// | file | what it is |
/// |---|---|
/// | `tok2vec/model` | shared embedding network the tagger and parser read |
/// | `ner/model` | the entity recognizer, with its own separate tok2vec |
/// | `tagger/model` + `cfg` | softmax over 50 Penn Treebank tags, and their names |
/// | `parser/model` + `moves` | arc-eager dependency parser, for sentence boundaries |
/// | `ner/moves` | the transition system's action set |
/// | `vocab/*` | key-to-row and vectors; empty in `sm`, which ships no word vectors |
///
/// The parser was dropped once, as "files nothing reads". It is back because
/// something does: spaCy forbids an entity from spanning a sentence boundary,
/// and this is where the boundaries come from. `parser/cfg` stays dropped — the
/// loader reads the transition table from `moves` and every dimension from the
/// weights.
public enum EnglishModel {

    /// Version of the underlying spaCy model.
    public static let version = "en_core_web_sm-3.7.1"

    /// The bundled weights are not in the bundle.
    ///
    /// Package-resource domain: not something a caller can cause or fix at
    /// runtime, which is why `directory` traps on it and `directoryIfPresent`
    /// exists for anyone who wants to check.
    public enum ModelError: Error, CustomStringConvertible {
        case notBundled

        public var description: String {
            "the English model resource is missing from the bundle; "
            + "this build of PresidioModelEnglish is broken"
        }
    }

    /// Path to the unpacked model directory.
    ///
    /// Traps if the resource is absent, because that is a broken build rather
    /// than a runtime condition a caller can handle — use `directoryIfPresent`
    /// to check.
    public static var directory: String {
        guard let path = directoryIfPresent else {
            preconditionFailure(ModelError.notBundled.description)
        }
        return path
    }

    public static var directoryIfPresent: String? {
        guard let root = Bundle.module.resourceURL else { return nil }
        let path = root.appendingPathComponent("model").path
        guard FileManager.default.fileExists(
            atPath: path + "/tok2vec/model"
        ) else { return nil }
        return path
    }
}
