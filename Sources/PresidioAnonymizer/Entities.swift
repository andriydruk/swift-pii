import PresidioCore

/// A span to operate on. Offsets are Unicode scalar indices, as everywhere else.
///
/// Mirrors `presidio_anonymizer.entities.PIIEntity`.
public struct PIIEntity: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var entityType: String
    /// Carried because conflict resolution needs it: two results with identical
    /// indices are decided by score, and a same-type merge takes the max.
    public var score: Double

    public init(start: Int, end: Int, entityType: String, score: Double = 0) {
        self.start = start
        self.end = end
        self.entityType = entityType
        self.score = score
    }

    public init(_ result: RecognizerResult) {
        self.init(
            start: result.start, end: result.end,
            entityType: result.entityType, score: result.score
        )
    }

    public var length: Int { end - start }

    /// Upstream validates on construction; we validate on demand so a malformed
    /// span surfaces as a thrown error at the engine boundary rather than a
    /// trap deep inside a value type.
    public func validate() throws(AnonymizerError) {
        if start < 0 || end < 0 {
            throw .invalidParam("Invalid input, result start and end must be positive")
        }
        if start > end {
            throw .invalidParam(
                "Invalid input, start index '\(start)' must be smaller than end index '\(end)'"
            )
        }
        if entityType.isEmpty {
            throw .invalidParam("Invalid input, result entity_type cannot be empty")
        }
    }
}

/// Which direction an operator runs in. An operator is registered for exactly
/// one, so `decrypt` is never reachable from `anonymize`.
public enum OperatorType: Sendable, Hashable {
    case anonymize
    case deanonymize
}

/// Parameters for one entity type's operator.
public struct OperatorConfig: Sendable {
    public let operatorName: String
    public let params: [String: OperatorParam]

    public init(_ operatorName: String, _ params: [String: OperatorParam] = [:]) {
        self.operatorName = operatorName
        self.params = params
    }
}

/// A dynamically-typed operator parameter.
///
/// Python passes an untyped dict; Swift needs a closed set. `.function` carries
/// the `custom` operator's lambda, which is the one parameter that cannot be
/// serialized — so a config containing it cannot round-trip through JSON, and
/// that is intentional.
public enum OperatorParam: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case bytes([UInt8])
    case function(@Sendable (String) -> String)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    public var bytesValue: [UInt8]? {
        switch self {
        case .bytes(let value): return value
        case .string(let value): return Array(value.utf8)
        default: return nil
        }
    }
}

/// One applied operation, with the span it occupies in the *output* text.
public struct OperatorResult: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var entityType: String
    public var text: String
    public var `operator`: String

    public init(
        start: Int, end: Int, entityType: String, text: String, operator op: String
    ) {
        self.start = start
        self.end = end
        self.entityType = entityType
        self.text = text
        self.operator = op
    }
}

/// The anonymized text plus what was done to it.
public struct EngineResult: Sendable, Hashable {
    public var text: String
    public var items: [OperatorResult]

    public init(text: String = "", items: [OperatorResult] = []) {
        self.text = text
        self.items = items
    }
}

/// An operator that cannot run as configured.
///
/// The anonymizer's whole error surface, and deliberately small: it does no I/O
/// and loads no resources, so the only thing that can go wrong is the operator
/// spec a caller passed in.
public enum AnonymizerError: Error, Equatable, CustomStringConvertible {
    case invalidParam(String)
    case unknownOperator(String)

    public var description: String {
        switch self {
        case .invalidParam(let message): return message
        case .unknownOperator(let name): return "Invalid operator class '\(name)'."
        }
    }
}
