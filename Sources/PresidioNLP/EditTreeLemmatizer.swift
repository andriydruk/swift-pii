import Foundation

/// Port of spaCy's `EditTreeLemmatizer` — the *neural* lemmatizer.
///
/// English uses a rule lemmatizer: tables of suffix rewrites keyed by coarse
/// POS. German does not. Its lemmatizer is a trained classifier over **edit
/// trees**, and the two share nothing but a name. `RuleLemmatizer` cannot
/// produce a German lemma at all, and the lookup table that might stand in for
/// it agrees with spaCy on only 67% of tokens — sometimes confidently wrongly,
/// mapping "er" to "ich".
///
/// An edit tree is a recipe for turning a form into its lemma, expressed so
/// that one recipe generalizes across a whole inflection class. Two node kinds:
///
///   * **match** `(prefix_len, suffix_len, prefix_tree, suffix_tree)` — split
///     the form into prefix / middle / suffix, recursively rewrite the prefix
///     and suffix, keep the middle verbatim.
///   * **substitution** `(orig, subst)` — if this piece is exactly `orig`,
///     replace it with `subst`, otherwise the tree does not apply.
///
/// So "gelaufen" → "laufen" is stored once as "strip the prefix ge-, rewrite
/// the suffix", and applies to every verb of that shape.
///
/// The classifier is `spacy.Tagger.v2` over the pipeline's shared tok2vec —
/// architecturally identical to the tagger, which is why this reuses
/// `TaggerModel` wholesale and only has to interpret its output differently:
/// 1,311 edit-tree ids rather than 52 tags.
public final class EditTreeLemmatizer: @unchecked Sendable {

    /// `NULL_TREE_ID` in spaCy: "no subtree here".
    static let nullTree: UInt32 = 4_294_967_295

    enum Node {
        case match(prefixLength: Int, suffixLength: Int, prefixTree: UInt32, suffixTree: UInt32)
        case substitution(original: String, replacement: String)
    }

    private let classifier: TaggerModel
    private let trees: [Node]
    /// Softmax column -> tree id.
    private let treeIDs: [UInt32]

    /// Alias, like the tagger's and the parser's. The prefix its own enum used
    /// to add is now written at the throw sites, where the message already says
    /// which file it is talking about.
    public typealias LoadError = ComponentLoadError

    /// - Parameter directory: an unpacked spaCy model directory whose pipeline
    ///   contains a `trainable_lemmatizer`.
    public init(directory: String) throws {
        let treePath = directory + "/lemmatizer/trees"
        guard FileManager.default.fileExists(atPath: treePath) else {
            throw LoadError.missing(treePath)
        }
        self.classifier = try TaggerModel(directory: directory, component: "lemmatizer")
        self.treeIDs = classifier.labels.compactMap { UInt32($0) }
        guard treeIDs.count == classifier.labels.count else {
            throw LoadError.malformed("lemmatizer/cfg labels are not edit-tree ids")
        }

        // --- trees ---------------------------------------------------------
        var reader = MPReader(readFile(treePath))
        let root = reader.value()
        guard let raw = root.m("trees")?.asArr else {
            throw LoadError.malformed("lemmatizer/trees has no 'trees'")
        }

        // Substitution nodes carry string-store *hashes*, so the strings have
        // to be recovered. Rather than hashing all 459,824 strings in the
        // vocabulary, collect the hashes actually referenced first -- a few
        // thousand -- and resolve only those.
        var wanted = Set<UInt64>()
        for node in raw {
            if let original = node.m("orig")?.asUInt { wanted.insert(original) }
            if let replacement = node.m("subst")?.asUInt { wanted.insert(replacement) }
        }
        let strings = try Self.resolve(hashes: wanted, directory: directory)

        var parsed: [Node] = []
        parsed.reserveCapacity(raw.count)
        for node in raw {
            if let prefixLength = node.m("prefix_len")?.asInt,
               let suffixLength = node.m("suffix_len")?.asInt,
               let prefixTree = node.m("prefix_tree")?.asUInt,
               let suffixTree = node.m("suffix_tree")?.asUInt {
                parsed.append(.match(
                    prefixLength: prefixLength, suffixLength: suffixLength,
                    prefixTree: UInt32(truncatingIfNeeded: prefixTree),
                    suffixTree: UInt32(truncatingIfNeeded: suffixTree)
                ))
            } else if let original = node.m("orig")?.asUInt,
                      let replacement = node.m("subst")?.asUInt {
                parsed.append(.substitution(
                    original: strings[original] ?? "",
                    replacement: strings[replacement] ?? ""
                ))
            } else {
                throw LoadError.malformed("edit tree \(parsed.count) is neither node kind")
            }
        }
        self.trees = parsed
    }

    /// Recover strings for a set of string-store hashes.
    ///
    /// The store is MurmurHash64A except for the reserved symbols, so this
    /// hashes each candidate and keeps the ones that were asked for. The empty
    /// string hashes to 0 by definition rather than by the algorithm, which is
    /// load-bearing here: a substitution that deletes a suffix is stored as a
    /// replacement with `subst == 0`.
    private static func resolve(
        hashes: Set<UInt64>, directory: String
    ) throws -> [UInt64: String] {
        var out: [UInt64: String] = [0: ""]
        var remaining = hashes.subtracting([0])
        guard !remaining.isEmpty else { return out }

        // Reserved symbols first: they are not hashes, so no amount of
        // hashing candidate strings would ever recover them.
        for id in remaining {
            if let text = SpacySymbols.text(for: id) {
                out[id] = text
            }
        }
        remaining.subtract(out.keys)
        guard !remaining.isEmpty else { return out }

        let path = directory + "/vocab/strings.json"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError.missing(path)
        }
        guard let all = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw LoadError.malformed("vocab/strings.json is not an array of strings")
        }
        for candidate in all {
            let hash = murmurHash64A(Array(candidate.utf8), 1)
            if remaining.contains(hash) {
                out[hash] = candidate
                remaining.remove(hash)
                if remaining.isEmpty { break }
            }
        }
        return out
    }

    /// Lemmas for a tokenized text.
    ///
    /// A tree that does not apply falls back to the surface form, which is
    /// spaCy's `backoff = "orth"` — the German pipeline's configured default.
    public func lemmas(for tokens: [Token], text: String) -> [String] {
        let predicted = classifier.predictions(for: tokens, text: text)
        return zip(tokens, predicted).map { token, column in
            let id = treeIDs[column]
            return apply(tree: id, to: token.text) ?? token.text
        }
    }

    /// Port of `EditTrees.apply`.
    ///
    /// Returns `nil` when the tree cannot be applied, which the caller turns
    /// into the backoff. spaCy signals this with an exception; the difference
    /// is only in spelling.
    func apply(tree id: UInt32, to form: String) -> String? {
        guard Int(id) < trees.count else { return nil }
        var pieces: [String] = []
        guard apply(tree: id, part: Array(form.unicodeScalars), into: &pieces) else {
            return nil
        }
        return pieces.joined()
    }

    private func apply(
        tree id: UInt32, part: [Unicode.Scalar], into pieces: inout [String]
    ) -> Bool {
        guard Int(id) < trees.count else { return false }
        switch trees[Int(id)] {
        case .match(let prefixLength, let suffixLength, let prefixTree, let suffixTree):
            // Lengths are in code points, matching Python's `len()` on a `str`
            // — which is why this walks scalars rather than Characters.
            guard prefixLength + suffixLength <= part.count else { return false }
            let suffixStart = part.count - suffixLength
            if prefixTree != Self.nullTree {
                guard apply(
                    tree: prefixTree, part: Array(part[0..<prefixLength]), into: &pieces
                ) else { return false }
            }
            pieces.append(String(String.UnicodeScalarView(part[prefixLength..<suffixStart])))
            if suffixTree != Self.nullTree {
                guard apply(
                    tree: suffixTree, part: Array(part[suffixStart...]), into: &pieces
                ) else { return false }
            }
            return true

        case .substitution(let original, let replacement):
            guard String(String.UnicodeScalarView(part)) == original else { return false }
            pieces.append(replacement)
            return true
        }
    }

    public var treeCount: Int { trees.count }
    public var labelCount: Int { treeIDs.count }
}
