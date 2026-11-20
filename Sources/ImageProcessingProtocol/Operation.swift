import Foundation

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

public enum OperationQualificationDimension: String, Hashable, Sendable {
    /// Input pixels may have implementation-selectable storage component types.
    case inputStoragePrecision
    /// The operation permits implementation-selectable arithmetic precision.
    case computationPrecision
    /// The operation permits implementation-selectable accumulation precision.
    case accumulationPrecision
    /// The operation permits implementation-selectable output storage types.
    case outputPrecision
    /// The operation permits implementation variation in determinism.
    case deterministicResults
}

/// A typed operation specification. Input/output identifiers are derived from
/// the associated Swift types and therefore cannot drift from the public type contract.
public struct OperationSpecification<Input: OperationValue, Output: OperationValue>: Hashable, Sendable {
    public let identifier: OperationIdentifier
    public let semanticVersion: SemanticVersion
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier
    public let qualificationDimensions: Set<OperationQualificationDimension>

    public init(
        identifier: OperationIdentifier,
        semanticVersion: SemanticVersion,
        qualificationDimensions: Set<OperationQualificationDimension> = []
    ) {
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.inputType = Input.typeIdentifier
        self.outputType = Output.typeIdentifier
        self.qualificationDimensions = qualificationDimensions
    }

    public var erased: AnyOperationSpecification {
        AnyOperationSpecification(
            identifier: identifier,
            semanticVersion: semanticVersion,
            inputType: inputType,
            outputType: outputType,
            qualificationDimensions: qualificationDimensions
        )
    }
}

/// Type-erased operation metadata used by heterogeneous registries and resolution.
public struct AnyOperationSpecification: Hashable, Sendable {
    public let identifier: OperationIdentifier
    public let semanticVersion: SemanticVersion
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier
    public let qualificationDimensions: Set<OperationQualificationDimension>

    public init(
        identifier: OperationIdentifier,
        semanticVersion: SemanticVersion,
        inputType: OperationValueIdentifier,
        outputType: OperationValueIdentifier,
        qualificationDimensions: Set<OperationQualificationDimension> = []
    ) {
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.inputType = inputType
        self.outputType = outputType
        self.qualificationDimensions = qualificationDimensions
    }
}

public struct OperationStepIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public static func generate() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }

    public var description: String { rawValue }
}

/// One typed operation occurrence in a sequential image function.
/// identifier distinguishes this occurrence in a composed function;
/// sourceIdentifier records the original step identity before composition rebased it.
public struct AnyImageOperationStep: Sendable {
    public let identifier: OperationStepIdentifier
    public let sourceIdentifier: OperationStepIdentifier
    public let operation: any ImageOperation
    public let specification: AnyOperationSpecification

    public init<Operation: ImageOperation>(
        operation: Operation,
        identifier: OperationStepIdentifier = .generate()
    ) {
        self.identifier = identifier
        self.sourceIdentifier = identifier
        self.operation = operation
        self.specification = Operation.specification.erased
    }

    func reidentifiedForComposition() -> Self {
        Self(
            identifier: .generate(),
            sourceIdentifier: sourceIdentifier,
            operation: operation,
            specification: specification
        )
    }

    private init(
        identifier: OperationStepIdentifier,
        sourceIdentifier: OperationStepIdentifier,
        operation: any ImageOperation,
        specification: AnyOperationSpecification
    ) {
        self.identifier = identifier
        self.sourceIdentifier = sourceIdentifier
        self.operation = operation
        self.specification = specification
    }
}

/// Operation values are strongly typed in Swift. Runtime descriptors remain
/// available because data formats and resource layouts are discovered dynamically.
public protocol ImageOperation: Sendable {
    associatedtype Input: OperationValue
    associatedtype Output: OperationValue

    static var specification: OperationSpecification<Input, Output> { get }
}
