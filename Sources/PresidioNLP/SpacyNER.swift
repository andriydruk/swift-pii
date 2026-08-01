import Foundation

/// A named entity, as a scalar-offset span in the source text.
///
/// The model works in token indices; this is the translation back to character
/// offsets, which is what every consumer downstream actually needs.
public struct NamedEntity: Sendable, Hashable {
    public let label: String
    /// Unicode scalar offset of the first character.
    public let start: Int
    /// Unicode scalar offset one past the last character.
    public let end: Int
    public let text: String

    public init(label: String, start: Int, end: Int, text: String) {
        self.label = label
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum NERError: Error, CustomStringConvertible {
    case modelNotFound(String)
    case modelIncomplete(String)

    public var description: String {
        switch self {
        case .modelNotFound(let path):
            return """
                spaCy model not found at '\(path)'. Point at an unpacked model \
                directory, e.g. .../en_core_web_sm-3.7.1, containing ner/model \
                and vocab/.
                """
        case .modelIncomplete(let detail):
            return "spaCy model is incomplete: \(detail)"
        }
    }
}

/// spaCy's NER pipeline: tokenizer + statistical model, composed.
///
/// This is the piece that makes the port useful rather than merely correct in
/// parts. The tokenizer and the model were each validated separately against
/// spaCy; composing them is where offsets, NORMs and token boundaries have to
/// line up simultaneously.
///
/// `@unchecked Sendable`. This was audited rather than assumed: `SpacyTokenizer`
/// guards its memoization cache with a lock and builds its derived tables
/// eagerly, and `NERModel`'s weights are written only during `init`. Inference
/// allocates its scratch per call, so nothing is shared across threads but
/// read-only data.
public final class SpacyNER: @unchecked Sendable {

    private let tokenizer: SpacyTokenizer
    private let model: NERModel

    /// Loads a model from an unpacked spaCy model directory.
    ///
    /// Weights are not bundled — `en_core_web_sm` is 15 MB and `lg` is 619 MB,
    /// so they are loaded from disk at runtime rather than committed.
    public init(modelDirectory: String, tokenizer: SpacyTokenizer? = nil) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: modelDirectory, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw NERError.modelNotFound(modelDirectory)
        }
        let nerModel = modelDirectory + "/ner/model"
        guard FileManager.default.fileExists(atPath: nerModel) else {
            throw NERError.modelIncomplete("missing ner/model under \(modelDirectory)")
        }

        self.tokenizer = try tokenizer ?? SpacyTokenizer.english()
        self.model = NERModel(dir: modelDirectory)
        guard !self.model.actMove.isEmpty else {
            throw NERError.modelIncomplete("no transition actions loaded from ner/moves")
        }
    }

    /// Number of transition actions the model was built with. Useful as a
    /// cheap sanity check that a model loaded.
    public var actionCount: Int { model.actMove.count }

    /// Tokenize `text` and run NER over it.
    public func entities(in text: String) -> [NamedEntity] {
        let tokens = tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return [] }
        return entities(in: text, tokens: tokens)
    }

    /// NER over pre-computed tokens, for callers that already tokenized.
    public func entities(in text: String, tokens: [Token]) -> [NamedEntity] {
        guard !tokens.isEmpty else { return [] }
        let spans = runNER(model, tokens.map(\.text), tokens.map(\.norm))
        let scalars = Array(text.unicodeScalars)

        return spans.compactMap { span in
            guard span.start >= 0, span.end <= tokens.count, span.start < span.end
            else { return nil }
            // A token-index range becomes a character range by taking the first
            // token's offset and the last token's end — the intervening
            // whitespace belongs to the entity, exactly as spaCy reports it.
            let from = tokens[span.start].offset
            let to = tokens[span.end - 1].end
            guard from >= 0, to <= scalars.count, from <= to else { return nil }
            let slice = String(String.UnicodeScalarView(scalars[from..<to]))
            return NamedEntity(label: span.label, start: from, end: to, text: slice)
        }
    }

    /// The tokenization used, exposed so callers can reuse it rather than
    /// tokenizing twice.
    public func tokenize(_ text: String) -> [Token] {
        tokenizer.tokenize(text)
    }
}
