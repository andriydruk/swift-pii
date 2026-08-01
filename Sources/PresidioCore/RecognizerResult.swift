/// A detected entity span.
///
/// Mirrors Python `presidio_analyzer.RecognizerResult`
/// (`presidio-analyzer/presidio_analyzer/recognizer_result.py`). `start` and
/// `end` are Unicode scalar offsets — see `TextDocument`.
public struct RecognizerResult: Sendable, Hashable {

    /// Metadata keys, matching the Python class constants verbatim so that
    /// serialized output is wire-compatible.
    public enum MetadataKey {
        public static let recognizerName = "recognizer_name"
        public static let recognizerIdentifier = "recognizer_identifier"
        public static let isScoreEnhancedByContext = "is_score_enhanced_by_context"
    }

    public var entityType: String
    public var start: Int
    public var end: Int
    public var score: Double
    public var recognitionMetadata: [String: String]

    /// The recognizer context word that raised this result's score, if any.
    /// Part of upstream's `analysis_explanation`.
    public var supportiveContextWord: String?

    public init(
        entityType: String,
        start: Int,
        end: Int,
        score: Double,
        recognitionMetadata: [String: String] = [:],
        supportiveContextWord: String? = nil
    ) {
        self.entityType = entityType
        self.start = start
        self.end = end
        self.score = score
        self.recognitionMetadata = recognitionMetadata
        self.supportiveContextWord = supportiveContextWord
    }

    // MARK: - Equality
    //
    // Deliberately narrower than the stored properties. Python compares and
    // hashes on `(entity_type, start, end, score)` only — metadata and the
    // analysis explanation are excluded:
    //
    //     hash(f"{self.start} {self.end} {self.score} {self.entity_type}")
    //
    // `remove_duplicates` starts with `list(set(results))`, so this is what
    // decides whether two results collapse. Synthesized conformance would also
    // compare `recognitionMetadata`, which is invisible within a single
    // recognizer — every result carries the same name — but diverges the moment
    // the engine merges results from several, since the identical span found by
    // two recognizers would then survive as two results instead of one.

    public static func == (lhs: RecognizerResult, rhs: RecognizerResult) -> Bool {
        lhs.entityType == rhs.entityType && lhs.start == rhs.start
            && lhs.end == rhs.end && lhs.score == rhs.score
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(entityType)
        hasher.combine(start)
        hasher.combine(end)
        hasher.combine(score)
    }

    /// Length of the span in Unicode scalars.
    public var length: Int { end - start }

    public var range: Range<Int> { start..<end }

    // MARK: - Span algebra
    //
    // These four predicates are ported line-for-line from the Python source.
    // The conflict-resolution and dedup algorithms are built on them, so any
    // divergence here propagates into every result set.

    /// Number of overlapping scalars, or 0 if the spans do not overlap.
    ///
    /// Note the boundary behaviour inherited from Python: abutting spans
    /// (`self.end == other.start`) return 0 rather than being treated as
    /// disjoint by an early return.
    public func intersects(_ other: RecognizerResult) -> Int {
        if end < other.start || other.end < start { return 0 }
        return Swift.min(end, other.end) - Swift.max(start, other.start)
    }

    /// True if `self` falls entirely within `other`.
    public func containedIn(_ other: RecognizerResult) -> Bool {
        start >= other.start && end <= other.end
    }

    /// True if `self` wholly contains `other` (equal spans count as contained).
    public func contains(_ other: RecognizerResult) -> Bool {
        start <= other.start && end >= other.end
    }

    /// True if both spans cover exactly the same range.
    public func equalIndices(_ other: RecognizerResult) -> Bool {
        start == other.start && end == other.end
    }

    /// Python `has_conflict`: self loses to `other` if their indices match and
    /// self scores no higher, or if self is contained within other.
    public func hasConflict(with other: RecognizerResult) -> Bool {
        if equalIndices(other) { return score <= other.score }
        return other.contains(self)
    }
}

// MARK: - Ordering

extension RecognizerResult: Comparable {
    /// Python `__gt__`: order by start, then by end.
    ///
    /// This is a *partial* ordering — it ignores `entityType` and `score`, so
    /// results that differ only in those compare as equal. Python then sorts
    /// with it after a `list(set(...))` round trip, which makes upstream's tie
    /// ordering dependent on `PYTHONHASHSEED` and therefore nondeterministic
    /// across processes. Use `totalOrderIsLess` for anything that must be
    /// reproducible; see `sortedDeterministically`.
    public static func < (lhs: RecognizerResult, rhs: RecognizerResult) -> Bool {
        if lhs.start == rhs.start { return lhs.end < rhs.end }
        return lhs.start < rhs.start
    }
}

extension RecognizerResult {
    /// A deterministic total order over results.
    ///
    /// Presidio's own ordering cannot be reproduced bit-for-bit because it
    /// derives from Python `set` iteration. Rather than chase that, this
    /// library defines its own total order and documents it as the contract:
    ///
    /// 1. descending `score`
    /// 2. ascending `start`
    /// 3. descending `length` (longer span first)
    /// 4. ascending `entityType` (the tie-break Python omits)
    ///
    /// Steps 1–3 match upstream's declared sort key; step 4 is the addition
    /// that makes the result reproducible.
    public static func totalOrderIsLess(_ a: RecognizerResult, _ b: RecognizerResult) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.start != b.start { return a.start < b.start }
        if a.length != b.length { return a.length > b.length }
        return a.entityType < b.entityType
    }
}

extension Array where Element == RecognizerResult {
    /// Sort using the documented deterministic total order.
    public func sortedDeterministically() -> [RecognizerResult] {
        sorted(by: RecognizerResult.totalOrderIsLess)
    }

    /// Sort by start offset only — the normalization the upstream test
    /// assertions apply before comparing spans
    /// (`presidio-analyzer/tests/assertions.py`).
    public func sortedByStart() -> [RecognizerResult] {
        sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
}
