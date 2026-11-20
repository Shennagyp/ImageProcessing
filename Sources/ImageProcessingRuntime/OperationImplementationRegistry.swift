import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol

public struct OperationImplementationKey: Hashable, Sendable, CustomStringConvertible {
    public let identifier: OperationImplementationIdentifier
    public let version: SemanticVersion

    public init(
        identifier: OperationImplementationIdentifier,
        version: SemanticVersion
    ) {
        self.identifier = identifier
        self.version = version
    }

    public var description: String {
        "\(identifier.rawValue)@\(version)"
    }
}

/// Public immutable metadata for one implementation registered by the runtime.
public struct RegisteredOperationImplementation: Hashable, Sendable {
    public let key: OperationImplementationKey
    /// Distinguishes separate registrations that reuse the same implementation key.
    public let registrationIdentifier: UUID
    public let specification: ImplementationSpecification
}

public enum OperationImplementationRegistryError: Error, Equatable, Sendable {
    case duplicateRegistration(OperationImplementationKey)
    case registrationNotFound(OperationImplementationKey)
    case operationIdentifierMismatch(expected: OperationIdentifier, actual: OperationIdentifier)
    case unsupportedOperationVersion(OperationImplementationKey, SemanticVersion)
    case inputTypeMismatch(expected: OperationValueIdentifier, actual: OperationValueIdentifier)
    case outputTypeMismatch(expected: OperationValueIdentifier, actual: OperationValueIdentifier)
    case unsupportedOperationStep(OperationImplementationKey)
    case typedDispatchMismatch(OperationImplementationKey)
    case registrationChanged(OperationImplementationKey)
    case candidateContextTargetMismatch(expected: ExecutionTargetReference, actual: ExecutionTargetReference)
    case outputValidationFailed(String)
}

private struct AnyRegisteredOperationImplementation: Sendable {
    typealias SupportsStep = @Sendable (AnyImageOperationStep) -> Bool
    typealias MatchesOperationType = @Sendable (any ImageOperation) -> Bool
    typealias MatchesInputType = @Sendable (any OperationValue) -> Bool
    typealias Execute = @Sendable (
        any ImageOperation,
        any OperationValue,
        any ExecutionContext
    ) async throws -> any OperationValue

    let descriptor: RegisteredOperationImplementation
    let supportsStep: SupportsStep
    let matchesOperationType: MatchesOperationType
    let matchesInputType: MatchesInputType
    let execute: Execute
}

enum OperationImplementationBindingCompatibility: Sendable {
    case compatible
    case registrationUnavailable
    case registrationChanged
    case operationConcreteTypeMismatch
    case inputConcreteTypeMismatch
}

/// Thread-safe registry of heterogeneous operation implementations.
///
/// Registration validates static implementation conformance. Candidate listing
/// does not rank or select. Execution requires an explicit key, leaving
/// environment-aware qualification and selection to the common resolver.
public actor OperationImplementationRegistry {
    private var entries: [OperationImplementationKey: AnyRegisteredOperationImplementation] = [:]

    public init() {}

    public var count: Int { entries.count }

    public func register<Implementation: ImageOperationImplementation>(
        _ implementation: Implementation
    ) throws {
        let operation = Implementation.Operation.specification.erased
        try implementation.specification.validate(implements: operation)

        let key = OperationImplementationKey(
            identifier: implementation.specification.identifier,
            version: implementation.specification.version
        )
        guard entries[key] == nil else {
            throw OperationImplementationRegistryError.duplicateRegistration(key)
        }

        let specification = implementation.specification
        let descriptor = RegisteredOperationImplementation(
            key: key,
            registrationIdentifier: UUID(),
            specification: specification
        )

        let supportsStep: AnyRegisteredOperationImplementation.SupportsStep = {
            step in specification.supports(step)
        }
        let matchesOperationType: AnyRegisteredOperationImplementation.MatchesOperationType = {
            operation in operation is Implementation.Operation
        }
        let matchesInputType: AnyRegisteredOperationImplementation.MatchesInputType = {
            input in input is Implementation.Operation.Input
        }
        let execute: AnyRegisteredOperationImplementation.Execute = {
            operation, input, context in
            guard let typedOperation = operation as? Implementation.Operation,
                  let typedInput = input as? Implementation.Operation.Input else {
                throw OperationImplementationRegistryError.typedDispatchMismatch(key)
            }
            return try await implementation.execute(
                operation: typedOperation,
                input: typedInput,
                context: context
            )
        }

        entries[key] = AnyRegisteredOperationImplementation(
            descriptor: descriptor,
            supportsStep: supportsStep,
            matchesOperationType: matchesOperationType,
            matchesInputType: matchesInputType,
            execute: execute
        )
    }

    @discardableResult
    public func unregister(_ key: OperationImplementationKey) -> Bool {
        entries.removeValue(forKey: key) != nil
    }

    public func registeredImplementations() -> [RegisteredOperationImplementation] {
        entries.values
            .map(\.descriptor)
            .sorted { lhs, rhs in
                if lhs.key.identifier.rawValue != rhs.key.identifier.rawValue {
                    return lhs.key.identifier.rawValue < rhs.key.identifier.rawValue
                }
                return lhs.key.version < rhs.key.version
            }
    }

    /// Confirms that a metadata candidate still refers to the exact registration
    /// that was enumerated and that its erased Swift operation/input types match
    /// the actual invocation values. Stable identifiers alone are insufficient:
    /// two unrelated Swift types can accidentally reuse the same semantic ID.
    func bindingCompatibility(
        of registered: RegisteredOperationImplementation,
        for step: AnyImageOperationStep,
        input: any OperationValue
    ) -> OperationImplementationBindingCompatibility {
        guard let entry = entries[registered.key] else {
            return .registrationUnavailable
        }
        guard entry.descriptor.registrationIdentifier == registered.registrationIdentifier else {
            return .registrationChanged
        }
        guard entry.matchesOperationType(step.operation) else {
            return .operationConcreteTypeMismatch
        }
        guard entry.matchesInputType(input) else {
            return .inputConcreteTypeMismatch
        }
        return .compatible
    }

    /// Lists implementations whose static specification is compatible with the
    /// operation identity/version and typed value contract.
    public func implementations(
        for operation: AnyOperationSpecification
    ) -> [RegisteredOperationImplementation] {
        entries.values
            .filter { $0.descriptor.specification.implements(operation) }
            .map(\.descriptor)
            .sorted { lhs, rhs in
                if lhs.key.identifier.rawValue != rhs.key.identifier.rawValue {
                    return lhs.key.identifier.rawValue < rhs.key.identifier.rawValue
                }
                return lhs.key.version < rhs.key.version
            }
    }

    /// Lists implementations that also support this operation occurrence's
    /// concrete parameter values. No provider state or ranking is evaluated.
    public func implementations(
        supporting step: AnyImageOperationStep
    ) -> [RegisteredOperationImplementation] {
        entries.values
            .filter { $0.supportsStep(step) }
            .map(\.descriptor)
            .sorted { lhs, rhs in
                if lhs.key.identifier.rawValue != rhs.key.identifier.rawValue {
                    return lhs.key.identifier.rawValue < rhs.key.identifier.rawValue
                }
                return lhs.key.version < rhs.key.version
            }
    }

    /// Executes only the exact operation, typed input, registration, and context
    /// captured by a qualified candidate. The call cannot substitute new values
    /// after qualification.
    func execute(
        using candidate: QualifiedOperationImplementation
    ) async throws -> any OperationValue {
        let registered = candidate.implementation
        let step = candidate.operationStep
        let input = candidate.input
        let context = candidate.context

        guard context.target == candidate.target else {
            throw OperationImplementationRegistryError.candidateContextTargetMismatch(
                expected: candidate.target,
                actual: context.target
            )
        }
        guard let entry = entries[registered.key] else {
            throw OperationImplementationRegistryError.registrationNotFound(registered.key)
        }
        guard entry.descriptor.registrationIdentifier == registered.registrationIdentifier else {
            throw OperationImplementationRegistryError.registrationChanged(registered.key)
        }

        let specification = entry.descriptor.specification
        guard specification.operationIdentifier == step.specification.identifier else {
            throw OperationImplementationRegistryError.operationIdentifierMismatch(
                expected: specification.operationIdentifier,
                actual: step.specification.identifier
            )
        }
        guard specification.supportedOperationVersions.contains(step.specification.semanticVersion) else {
            throw OperationImplementationRegistryError.unsupportedOperationVersion(
                registered.key,
                step.specification.semanticVersion
            )
        }
        guard specification.inputType == step.specification.inputType,
              input.valueTypeIdentifier == specification.inputType else {
            throw OperationImplementationRegistryError.inputTypeMismatch(
                expected: specification.inputType,
                actual: input.valueTypeIdentifier
            )
        }
        guard entry.matchesInputType(input) else {
            throw OperationImplementationRegistryError.typedDispatchMismatch(registered.key)
        }
        guard specification.outputType == step.specification.outputType else {
            throw OperationImplementationRegistryError.outputTypeMismatch(
                expected: specification.outputType,
                actual: step.specification.outputType
            )
        }
        guard entry.matchesOperationType(step.operation),
              entry.supportsStep(step) else {
            throw OperationImplementationRegistryError.typedDispatchMismatch(registered.key)
        }

        let output = try await entry.execute(step.operation, input, context)
        guard output.valueTypeIdentifier == specification.outputType else {
            throw OperationImplementationRegistryError.outputTypeMismatch(
                expected: specification.outputType,
                actual: output.valueTypeIdentifier
            )
        }
        do {
            try step.validateOutput(
                output,
                for: input,
                implementation: specification
            )
        } catch {
            throw OperationImplementationRegistryError.outputValidationFailed(
                String(describing: error)
            )
        }
        return output
    }

}
