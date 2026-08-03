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
/// The weights are spaCy's `en_core_web_sm` 3.7.1, MIT-licensed and
/// redistributed unmodified. Components this package never runs — the
/// dependency parser, the sentence recognizer — are stripped, which is most of
/// why 13 MB rather than the 15 MB spaCy ships.
public enum EnglishModel {

    /// Version of the underlying spaCy model.
    public static let version = "en_core_web_sm-3.7.1"

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
