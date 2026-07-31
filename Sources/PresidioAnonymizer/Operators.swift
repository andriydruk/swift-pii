/// One transformation applied to a detected span.
///
/// Mirrors `presidio_anonymizer.operators.Operator`: validate, then operate.
/// Validation is separate so a bad config fails before any text is touched.
public protocol AnonymizerOperator: Sendable {
    var name: String { get }
    var type: OperatorType { get }

    func validate(params: [String: OperatorParam]) throws(AnonymizerError)
    func operate(text: String, params: [String: OperatorParam]) throws(AnonymizerError) -> String
}

// MARK: - Replace

/// Substitutes a fixed value, defaulting to `<ENTITY_TYPE>`.
public struct ReplaceOperator: AnonymizerOperator {
    public static let newValueKey = "new_value"
    public static let entityTypeKey = "entity_type"

    public let name = "replace"
    public let type = OperatorType.anonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {
        if let value = params[Self.newValueKey], value.stringValue == nil {
            throw .invalidParam("Invalid parameter value for new_value. Expecting 'string'")
        }
    }

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String {
        // Python treats an empty string as absent (`if not new_val`), so an
        // explicit "" still yields the <ENTITY_TYPE> placeholder.
        guard let newValue = params[Self.newValueKey]?.stringValue, !newValue.isEmpty
        else {
            let entity = params[Self.entityTypeKey]?.stringValue ?? "None"
            return "<\(entity)>"
        }
        return newValue
    }
}

// MARK: - Redact

/// Deletes the span entirely.
public struct RedactOperator: AnonymizerOperator {
    public let name = "redact"
    public let type = OperatorType.anonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {}

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String { "" }
}

// MARK: - Keep

/// Leaves the span untouched, but still reports it as an operated-on entity.
public struct KeepOperator: AnonymizerOperator {
    public let name = "keep"
    public let type = OperatorType.anonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {}

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String { text }
}

// MARK: - Mask

/// Replaces a run of characters with a masking character.
public struct MaskOperator: AnonymizerOperator {
    public static let charsToMaskKey = "chars_to_mask"
    public static let fromEndKey = "from_end"
    public static let maskingCharKey = "masking_char"

    public let name = "mask"
    public let type = OperatorType.anonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {
        guard let maskingChar = params[Self.maskingCharKey]?.stringValue else {
            throw .invalidParam("Expected parameter masking_char")
        }
        // Upstream measures with len(), i.e. code points — so a single emoji is
        // accepted but a combining sequence is not.
        if maskingChar.unicodeScalars.count > 1 {
            throw .invalidParam("Invalid input, masking_char must be a character")
        }
        guard params[Self.charsToMaskKey]?.intValue != nil else {
            throw .invalidParam("Expected parameter chars_to_mask")
        }
        guard params[Self.fromEndKey]?.boolValue != nil else {
            throw .invalidParam("Expected parameter from_end")
        }
    }

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String {
        let scalars = Array(text.unicodeScalars)
        let requested = params[Self.charsToMaskKey]?.intValue ?? 0
        // A negative or zero request masks nothing; a request longer than the
        // text is clamped.
        let count = requested > 0 ? min(scalars.count, requested) : 0
        let fromEnd = params[Self.fromEndKey]?.boolValue ?? false
        let maskingChar = params[Self.maskingCharKey]?.stringValue ?? "*"
        let mask = String(repeating: maskingChar, count: count)

        if !fromEnd {
            return mask + String(String.UnicodeScalarView(scalars[count...]))
        }
        let index = scalars.count - count
        return String(String.UnicodeScalarView(scalars[..<index])) + mask
    }
}

// MARK: - Custom

/// Applies a caller-supplied function.
///
/// The only operator whose configuration cannot be serialized, so a config
/// using it will not round-trip through JSON or YAML.
public struct CustomOperator: AnonymizerOperator {
    public static let lambdaKey = "lambda"

    public let name = "custom"
    public let type = OperatorType.anonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {
        guard case .function = params[Self.lambdaKey] else {
            throw .invalidParam("New value must be a callable function")
        }
    }

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String {
        guard case .function(let transform) = params[Self.lambdaKey] else {
            throw .invalidParam("New value must be a callable function")
        }
        return transform(text)
    }
}

// MARK: - Deanonymize

/// The deanonymize-side counterpart of `keep`.
public struct DeanonymizeKeepOperator: AnonymizerOperator {
    public let name = "keep"
    public let type = OperatorType.deanonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {}

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String { text }
}
