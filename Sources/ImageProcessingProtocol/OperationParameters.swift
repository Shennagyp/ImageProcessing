public struct OperationParameterIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct OperationOptionIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum OperationParameterValue: Hashable, Sendable {
    case integer(Int64)
    case unsignedInteger(UInt64)
    case real(Double)
    case boolean(Bool)
    case text(String)
    case option(OperationOptionIdentifier)
}

/// A closed parameter domain. The same type is used by the operation contract
/// and by an implementation to declare a narrower supported subset.
public enum OperationParameterDomain: Hashable, Sendable {
    case integer(minimum: Int64, maximum: Int64)
    case unsignedInteger(minimum: UInt64, maximum: UInt64)
    case real(minimum: Double, maximum: Double)
    case boolean
    case text(Set<String>)
    case options(Set<OperationOptionIdentifier>)

    public var isValid: Bool {
        switch self {
        case let .integer(minimum, maximum):
            return minimum <= maximum
        case let .unsignedInteger(minimum, maximum):
            return minimum <= maximum
        case let .real(minimum, maximum):
            return minimum.isFinite && maximum.isFinite && minimum <= maximum
        case .boolean:
            return true
        case let .text(values):
            return !values.isEmpty && values.allSatisfy { !$0.isEmpty }
        case let .options(values):
            return !values.isEmpty
        }
    }

    public func accepts(_ value: OperationParameterValue) -> Bool {
        guard isValid else { return false }
        switch (self, value) {
        case let (.integer(minimum, maximum), .integer(value)):
            return (minimum...maximum).contains(value)
        case let (.unsignedInteger(minimum, maximum), .unsignedInteger(value)):
            return (minimum...maximum).contains(value)
        case let (.real(minimum, maximum), .real(value)):
            return value.isFinite && (minimum...maximum).contains(value)
        case (.boolean, .boolean):
            return true
        case let (.text(values), .text(value)):
            return values.contains(value)
        case let (.options(values), .option(value)):
            return values.contains(value)
        default:
            return false
        }
    }

    /// True when every value admitted by this domain is also admitted by the other domain.
    public func isSubset(of other: Self) -> Bool {
        guard isValid, other.isValid else { return false }
        switch (self, other) {
        case let (.integer(aMin, aMax), .integer(bMin, bMax)):
            return aMin >= bMin && aMax <= bMax
        case let (.unsignedInteger(aMin, aMax), .unsignedInteger(bMin, bMax)):
            return aMin >= bMin && aMax <= bMax
        case let (.real(aMin, aMax), .real(bMin, bMax)):
            return aMin >= bMin && aMax <= bMax
        case (.boolean, .boolean):
            return true
        case let (.text(a), .text(b)):
            return a.isSubset(of: b)
        case let (.options(a), .options(b)):
            return a.isSubset(of: b)
        default:
            return false
        }
    }
}

public struct OperationParameterSpecification: Hashable, Sendable {
    public let identifier: OperationParameterIdentifier
    public let domain: OperationParameterDomain
    public let isRequired: Bool

    public init(
        identifier: OperationParameterIdentifier,
        domain: OperationParameterDomain,
        isRequired: Bool = true
    ) {
        self.identifier = identifier
        self.domain = domain
        self.isRequired = isRequired
    }
}

/// Parameter subset accepted by one concrete implementation.
public struct OperationParameterSupport: Hashable, Sendable {
    public let identifier: OperationParameterIdentifier
    public let domain: OperationParameterDomain

    public init(identifier: OperationParameterIdentifier, domain: OperationParameterDomain) {
        self.identifier = identifier
        self.domain = domain
    }
}

public enum OperationParameterSupportValidationError: Error, Equatable, Sendable {
    case invalidDomain(OperationParameterIdentifier)
    case duplicateSupport(OperationParameterIdentifier)
    case unknownParameter(OperationParameterIdentifier)
    case missingRequiredSupport(OperationParameterIdentifier)
    case supportOutsideOperationDomain(OperationParameterIdentifier)
}

public enum OperationParameterSupportValidation {
    public static func validate(
        operationSpecifications: [OperationParameterSpecification],
        implementationSupport: [OperationParameterSupport]
    ) throws {
        try OperationParameterValidation.validateSpecifications(operationSpecifications)

        var supportByID: [OperationParameterIdentifier: OperationParameterSupport] = [:]
        for support in implementationSupport {
            guard support.domain.isValid else {
                throw OperationParameterSupportValidationError.invalidDomain(support.identifier)
            }
            guard supportByID[support.identifier] == nil else {
                throw OperationParameterSupportValidationError.duplicateSupport(support.identifier)
            }
            supportByID[support.identifier] = support
        }

        let operationIDs = Set(operationSpecifications.map(\\.identifier))
        for support in implementationSupport where !operationIDs.contains(support.identifier) {
            throw OperationParameterSupportValidationError.unknownParameter(support.identifier)
        }

        for specification in operationSpecifications {
            guard let support = supportByID[specification.identifier] else {
                if specification.isRequired {
                    throw OperationParameterSupportValidationError.missingRequiredSupport(specification.identifier)
                }
                continue
            }
            guard support.domain.isSubset(of: specification.domain) else {
                throw OperationParameterSupportValidationError.supportOutsideOperationDomain(specification.identifier)
            }
        }
    }

    public static func accepts(
        _ values: [OperationParameterValueRecord],
        implementationSupport: [OperationParameterSupport]
    ) -> Bool {
        let supportByID = Dictionary(
            uniqueKeysWithValues: implementationSupport.map { ($0.identifier, $0.domain) }
        )
        return values.allSatisfy { supportByID[$0.identifier]?.accepts($0.value) ?? false }
    }
}

public struct OperationParameterValueRecord: Hashable, Sendable {
    public let identifier: OperationParameterIdentifier
    public let value: OperationParameterValue

    public init(identifier: OperationParameterIdentifier, value: OperationParameterValue) {
        self.identifier = identifier
        self.value = value
    }
}

public enum OperationParameterValidationError: Error, Equatable, Sendable {
    case invalidDomain(OperationParameterIdentifier)
    case duplicateSpecification(OperationParameterIdentifier)
    case duplicateValue(OperationParameterIdentifier)
    case missingRequiredValue(OperationParameterIdentifier)
    case unknownValue(OperationParameterIdentifier)
    case valueOutsideDomain(OperationParameterIdentifier)
}

public enum OperationParameterValidation {
    public static func validateSpecifications(
        _ specifications: [OperationParameterSpecification]
    ) throws {
        var identifiers = Set<OperationParameterIdentifier>()
        for specification in specifications {
            guard specification.domain.isValid else {
                throw OperationParameterValidationError.invalidDomain(specification.identifier)
            }
            guard identifiers.insert(specification.identifier).inserted else {
                throw OperationParameterValidationError.duplicateSpecification(specification.identifier)
            }
        }
    }

    public static func validate(
        specifications: [OperationParameterSpecification],
        values: [OperationParameterValueRecord]
    ) throws {
        try validateSpecifications(specifications)
        let specificationByID = Dictionary(
            uniqueKeysWithValues: specifications.map { ($0.identifier, $0) }
        )
        var seenValues = Set<OperationParameterIdentifier>()
        for entry in values {
            guard seenValues.insert(entry.identifier).inserted else {
                throw OperationParameterValidationError.duplicateValue(entry.identifier)
            }
            guard let specification = specificationByID[entry.identifier] else {
                throw OperationParameterValidationError.unknownValue(entry.identifier)
            }
            guard specification.domain.accepts(entry.value) else {
                throw OperationParameterValidationError.valueOutsideDomain(entry.identifier)
            }
        }

        for specification in specifications where specification.isRequired {
            guard seenValues.contains(specification.identifier) else {
                throw OperationParameterValidationError.missingRequiredValue(specification.identifier)
            }
        }
    }
}
