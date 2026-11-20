/// Provider-neutral categories for execution failures. Native error codes and
/// messages may be retained as opaque diagnostic values without exposing vendor types.
public enum ExecutionProviderFailureKind: String, Hashable, Sendable {
    case providerUnavailable
    case deviceUnavailable
    case deviceLost
    case capabilityUnavailable
    case resourceAllocationFailed
    case resourceImportFailed
    case invalidResource
    case workSubmissionFailed
    case dependencyFailed
    case workExecutionFailed
    case synchronizationFailed
}

/// Recovery guidance is advisory. The runtime must still re-check the original
/// operation and hard qualification constraints before retrying or rerouting.
public enum ExecutionProviderRecovery: String, Hashable, Sendable {
    case retrySameTarget
    case refreshEnvironment
    case tryAnotherTarget
    case permanent
}

public enum ExecutionProviderFailureValidationError: Error, Equatable, Sendable {
    case targetProviderMismatch(expected: ExecutionProviderID, actual: ExecutionProviderID)
    case emptyMessage
    case emptyNativeCode
}

/// Structured failure emitted by a provider or normalized by the runtime.
///
/// kind is machine-readable; recovery describes the provider's recommended
/// next action. nativeCode and message are optional diagnostics only and
/// must not be used as the machine-readable decision surface.
public struct ExecutionProviderFailure: Error, Hashable, Sendable {
    public let providerID: ExecutionProviderID
    public let target: ExecutionTargetReference?
    public let kind: ExecutionProviderFailureKind
    public let recovery: ExecutionProviderRecovery
    public let message: String?
    public let nativeCode: String?

    public init(
        providerID: ExecutionProviderID,
        target: ExecutionTargetReference? = nil,
        kind: ExecutionProviderFailureKind,
        recovery: ExecutionProviderRecovery,
        message: String? = nil,
        nativeCode: String? = nil
    ) throws {
        if let target, target.providerID != providerID {
            throw ExecutionProviderFailureValidationError.targetProviderMismatch(
                expected: providerID,
                actual: target.providerID
            )
        }
        if let message, message.isEmpty {
            throw ExecutionProviderFailureValidationError.emptyMessage
        }
        if let nativeCode, nativeCode.isEmpty {
            throw ExecutionProviderFailureValidationError.emptyNativeCode
        }
        self.providerID = providerID
        self.target = target
        self.kind = kind
        self.recovery = recovery
        self.message = message
        self.nativeCode = nativeCode
    }
}
