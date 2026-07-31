import PresidioCore

/// How overlapping entities are reconciled before any text is changed.
public enum ConflictResolutionStrategy: Sendable, Hashable {
    /// Merge same-type overlaps, then drop anything contained in another
    /// result. Upstream's default.
    case mergeSimilarOrContained
    /// As above, then trim the remaining overlaps so no two spans intersect.
    case removeIntersections
}

/// Applies operators to detected spans.
///
/// Port of `presidio_anonymizer.AnonymizerEngine`. The package is unusually
/// portable — 2,457 LOC of pure string manipulation with exactly one regex and
/// no NLP — so this is a close transliteration rather than a redesign.
public struct AnonymizerEngine: Sendable {

    /// Upstream's `DEFAULT = "replace"`.
    public static let defaultOperatorName = "replace"
    public static let defaultConfigKey = "DEFAULT"

    private let operators: [String: any AnonymizerOperator]

    public init(operators: [any AnonymizerOperator]? = nil) {
        let all: [any AnonymizerOperator] = operators ?? [
            ReplaceOperator(), RedactOperator(), MaskOperator(),
            KeepOperator(), CustomOperator(), HashOperator(),
        ]
        self.operators = Dictionary(
            all.filter { $0.type == .anonymize }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public var supportedOperators: [String] { operators.keys.sorted() }

    public func anonymize(
        text: String,
        analyzerResults: [RecognizerResult],
        operators configs: [String: OperatorConfig] = [:],
        conflictResolution: ConflictResolutionStrategy = .mergeSimilarOrContained,
        mergeEntitiesWithSpaces: Bool = true
    ) throws(AnonymizerError) -> EngineResult {
        var entities = analyzerResults.map { PIIEntity($0) }
        for entity in entities { try entity.validate() }

        // Downstream whitespace merging assumes (start, end) order.
        entities.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        entities = Self.removeConflicts(entities, strategy: conflictResolution)

        if mergeEntitiesWithSpaces {
            entities = Self.mergeEntitiesWithSpacesBetween(text: text, entities: entities)
        }

        return try operate(
            text: text,
            entities: entities,
            configs: Self.withDefaultOperator(configs),
            type: .anonymize
        )
    }

    // MARK: - Conflict resolution

    /// Port of `_remove_conflicts_and_get_text_manipulation_data`.
    ///
    /// Two passes, both over a Python-style `other_elements` working list: the
    /// current element is removed from it before checking, and appended back
    /// only if it survives. Order matters, because both passes `break` on the
    /// first match.
    ///
    /// Pass 1 merges overlapping spans **of the same entity type** by widening
    /// the survivor. The subtlety is that Python mutates the other element in
    /// place and keeps iterating the same objects, so a later iteration sees the
    /// widened span — reproduced here by reading from a mutable pool rather than
    /// from the original input.
    ///
    /// Pass 2 drops anything that conflicts with a survivor: identical indices
    /// with a lower-or-equal score, or containment within another span.
    static func removeConflicts(
        _ entities: [PIIEntity], strategy: ConflictResolutionStrategy
    ) -> [PIIEntity] {
        var pool = entities
        var active = Array(entities.indices)  // mirrors `other_elements`
        var mergedIndexes: [Int] = []

        for index in entities.indices {
            active.removeAll { $0 == index }
            var didMerge = false
            for other in active {
                guard pool[other].entityType == pool[index].entityType else { continue }
                guard intersects(pool[index], pool[other]) != 0 else { continue }
                pool[other].start = min(pool[index].start, pool[other].start)
                pool[other].end = max(pool[index].end, pool[other].end)
                pool[other].score = max(pool[index].score, pool[other].score)
                didMerge = true
                break
            }
            if !didMerge {
                active.append(index)
                mergedIndexes.append(index)
            }
        }
        let merged = mergedIndexes.map { pool[$0] }

        var survivors: [PIIEntity] = []
        var activeSecond = Array(merged.indices)
        for index in merged.indices {
            activeSecond.removeAll { $0 == index }
            let conflicted = activeSecond.contains { hasConflict(merged[index], merged[$0]) }
            if !conflicted {
                activeSecond.append(index)
                survivors.append(merged[index])
            }
        }

        guard strategy == .removeIntersections else { return survivors }

        // Trim residual overlaps so no two spans intersect. The higher-scoring
        // span keeps its extent and the other is pushed aside.
        var trimmed = survivors.sorted { $0.start < $1.start }
        var index = 0
        while index < trimmed.count - 1 {
            if trimmed[index].end <= trimmed[index + 1].start {
                index += 1
            } else {
                if trimmed[index].score >= trimmed[index + 1].score {
                    trimmed[index + 1].start = trimmed[index].end
                } else {
                    trimmed[index].end = trimmed[index + 1].start
                }
                trimmed.sort { $0.start < $1.start }
            }
        }
        return trimmed.filter { $0.start <= $0.end }
    }

    static func intersects(_ a: PIIEntity, _ b: PIIEntity) -> Int {
        if a.end < b.start || b.end < a.start { return 0 }
        return min(a.end, b.end) - max(a.start, b.start)
    }

    /// Port of `RecognizerResult.has_conflict`: identical indices lose on a
    /// tie (note the `<=`), otherwise containment loses.
    static func hasConflict(_ a: PIIEntity, _ b: PIIEntity) -> Bool {
        if a.start == b.start && a.end == b.end { return a.score <= b.score }
        return b.start <= a.start && b.end >= a.end
    }

    /// Merge adjacent same-type entities separated only by spaces.
    ///
    /// This is the single regex in the whole package (`^( )+$`), implemented
    /// directly: literal ASCII spaces only, and at least one.
    static func mergeEntitiesWithSpacesBetween(
        text: String, entities: [PIIEntity]
    ) -> [PIIEntity] {
        let scalars = Array(text.unicodeScalars)
        var merged: [PIIEntity] = []
        var previous: PIIEntity?

        for var entity in entities {
            if let prev = previous, prev.entityType == entity.entityType,
               prev.end <= entity.start, entity.start <= scalars.count {
                let between = scalars[prev.end..<entity.start]
                if !between.isEmpty && between.allSatisfy({ $0 == " " }) {
                    merged.removeAll { $0 == prev }
                    entity.start = prev.start
                }
            }
            merged.append(entity)
            previous = entity
        }
        return merged
    }

    static func withDefaultOperator(
        _ configs: [String: OperatorConfig]
    ) -> [String: OperatorConfig] {
        var out = configs
        if out[defaultConfigKey] == nil {
            out[defaultConfigKey] = OperatorConfig(defaultOperatorName)
        }
        return out
    }

    // MARK: - Operate

    func operate(
        text: String,
        entities: [PIIEntity],
        configs: [String: OperatorConfig],
        type: OperatorType
    ) throws(AnonymizerError) -> EngineResult {
        try OperatorRegistry(operators.values, type: type)
            .operate(text: text, entities: entities, configs: configs)
    }
}

/// The shared span-rewriting machinery.
///
/// Both engines run the same loop; they differ only in which operators are
/// registered. Keeping it here avoids DeanonymizeEngine having to borrow an
/// AnonymizerEngine, whose initializer filters out deanonymize operators.
struct OperatorRegistry: Sendable {
    let operators: [String: any AnonymizerOperator]
    let type: OperatorType

    init(_ available: some Sequence<any AnonymizerOperator>, type: OperatorType) {
        self.type = type
        self.operators = Dictionary(
            available.filter { $0.type == type }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func operate(
        text: String,
        entities: [PIIEntity],
        configs: [String: OperatorConfig]
    ) throws(AnonymizerError) -> EngineResult {
        var builder = TextReplaceBuilder(originalText: text)
        var result = EngineResult()

        // `sorted(pii_entities, reverse=True)` with `__gt__` comparing only
        // `start`. Python's sort is stable and `reverse=True` does not reverse
        // equal elements, so ties keep their input order — reproduced here with
        // an index tiebreak, since Swift's sort is not guaranteed stable.
        let ordered = entities.enumerated()
            .sorted {
                $0.element.start == $1.element.start
                    ? $0.offset < $1.offset
                    : $0.element.start > $1.element.start
            }
            .map(\.element)

        for entity in ordered {
            let source = try builder.textInPosition(start: entity.start, end: entity.end)
            guard let config = configs[entity.entityType]
                ?? configs[AnonymizerEngine.defaultConfigKey]
            else {
                throw .invalidParam("Invalid config, no operator for \(entity.entityType)")
            }
            guard let op = operators[config.operatorName] else {
                throw .unknownOperator(config.operatorName)
            }

            var params = config.params
            params[ReplaceOperator.entityTypeKey] = .string(entity.entityType)
            try op.validate(params: params)
            let changed = try op.operate(text: source, params: params)

            let indexFromEnd = builder.replaceTextGetInsertionIndex(
                changed, start: entity.start, end: entity.end
            )
            result.items.append(
                OperatorResult(
                    start: 0, end: indexFromEnd,
                    entityType: entity.entityType,
                    text: changed,
                    operator: config.operatorName
                )
            )
        }

        result.text = builder.outputText
        result.normalizeItemIndexes()
        return result
    }
}

/// Reverses `encrypt`-style operators over already-anonymized text.
public struct DeanonymizeEngine: Sendable {
    private let registry: OperatorRegistry

    public init(operators: [any AnonymizerOperator]? = nil) {
        let all: [any AnonymizerOperator] = operators ?? [DeanonymizeKeepOperator()]
        self.registry = OperatorRegistry(all, type: .deanonymize)
    }

    public var supportedOperators: [String] { registry.operators.keys.sorted() }

    public func deanonymize(
        text: String,
        entities: [OperatorResult],
        operators configs: [String: OperatorConfig]
    ) throws(AnonymizerError) -> EngineResult {
        let pii = entities.map {
            PIIEntity(start: $0.start, end: $0.end, entityType: $0.entityType)
        }
        for entity in pii { try entity.validate() }
        return try registry.operate(text: text, entities: pii, configs: configs)
    }
}
