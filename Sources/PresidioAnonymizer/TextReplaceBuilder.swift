import PresidioCore

/// Applies replacements to the text from the end backwards.
///
/// Port of `presidio_anonymizer.core.TextReplaceBuilder`. Working right-to-left
/// is what lets the engine use the *original* offsets throughout: replacing a
/// span never shifts any offset to its left.
///
/// Two details are load-bearing:
///
///  * `textInPosition` reads from the **original** text, while replacement
///    writes to the **output** text. Reading from the output would feed an
///    already-anonymized value into the next operator.
///  * The replaced range ends at `min(end, lastReplacementIndex)`, which is how
///    overlapping entities are absorbed rather than double-applied.
struct TextReplaceBuilder {

    private let original: [Unicode.Scalar]
    private var output: [Unicode.Scalar]
    private let textLength: Int
    private var lastReplacementIndex: Int

    init(originalText: String) {
        let scalars = Array(originalText.unicodeScalars)
        self.original = scalars
        self.output = scalars
        self.textLength = scalars.count
        self.lastReplacementIndex = scalars.count
    }

    var outputText: String {
        String(String.UnicodeScalarView(output))
    }

    /// Slice of the original text, in scalar offsets.
    func textInPosition(start: Int, end: Int) throws(AnonymizerError) -> String {
        guard start >= 0, end >= start, textLength >= start, end <= textLength else {
            throw .invalidParam(
                "Invalid analyzer result, start: \(start) and end: \(end), "
                + "while text length is only \(textLength)."
            )
        }
        return String(String.UnicodeScalarView(original[start..<end]))
    }

    /// Replace `[start, end)` in the output and return the replacement's
    /// distance from the end of the text.
    ///
    /// Indices are tracked from the end because the text length is still
    /// changing; `EngineResult` normalizes them to start-relative once the loop
    /// finishes.
    mutating func replaceTextGetInsertionIndex(
        _ replacement: String, start: Int, end: Int
    ) -> Int {
        let endOfText = min(end, lastReplacementIndex)
        lastReplacementIndex = start

        let replacementScalars = Array(replacement.unicodeScalars)
        let clampedStart = min(max(start, 0), output.count)
        let clampedEnd = min(max(endOfText, clampedStart), output.count)

        let afterCount = output.count - clampedEnd
        output.replaceSubrange(clampedStart..<clampedEnd, with: replacementScalars)
        return afterCount + replacementScalars.count
    }
}

extension EngineResult {
    /// Convert end-relative indices to start-relative, now that the output
    /// length is final.
    mutating func normalizeItemIndexes() {
        let length = text.unicodeScalars.count
        for index in items.indices {
            items[index].start = length - items[index].end
            items[index].end =
                items[index].start + items[index].text.unicodeScalars.count
        }
    }
}
