import GeneralExecutionProtocol

public struct OperationIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct OperationValueIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Stable semantic identity for a value that can flow into or out of an operation.
public protocol OperationValue: Sendable {
    static var typeIdentifier: OperationValueIdentifier { get }
}

/// A typed operation specification. Input/output identifiers are derived from
/// the associated Swift types and therefore cannot drift from the public type contract.
public struct OperationSpecification<Input: OperationValue, Output: OperationValue>: Hashable, Sendable {
    public let identifier: OperationIdentifier
    public let semanticVersion: SemanticVersion
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier

    public init(
        identifier: OperationIdentifier,
        semanticVersion: SemanticVersion
    ) {
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.inputType = Input.typeIdentifier
        self.outputType = Output.typeIdentifier
    }

    public var erased: AnyOperationSpecification {
        AnyOperationSpecification(
            identifier: identifier,
            semanticVersion: semanticVersion,
            inputType: inputType,
            outputType: outputType
        )
    }
}

/// Type-erased operation metadata used by heterogeneous registries and resolution.
public struct AnyOperationSpecification: Hashable, Sendable {
    public let identifier: OperationIdentifier
    public let semanticVersion: SemanticVersion
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier

    public init(
        identifier: OperationIdentifier,
        semanticVersion: SemanticVersion,
        inputType: OperationValueIdentifier,
        outputType: OperationValueIdentifier
    ) {
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.inputType = inputType
        self.outputType = outputType
    }
}

/// Operation values are strongly typed in Swift. Runtime descriptors remain
/// available because data formats and resource layouts are discovered dynamically.
public protocol ImageOperation: Sendable {
    associatedtype Input: OperationValue
    associatedtype Output: OperationValue

    static var specification: OperationSpecification<Input, Output> { get }
}
