import GeneralExecutionProtocol

public struct OperationImplementationIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Declarative, static support metadata for one concrete operation implementation.
/// Dynamic availability and device load are supplied separately by the environment.
public struct ImplementationSpecification: Hashable, Sendable {
    public let identifier: OperationImplementationIdentifier
    public let version: SemanticVersion
    public let operationIdentifier: OperationIdentifier
    public let supportedOperationVersions: SemanticVersionRange
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier
    public let requiredProviderID: ExecutionProviderID?
    public let requiredCapabilities: [ExecutionCapabilityConstraint]

    public init(
        identifier: OperationImplementationIdentifier,
        version: SemanticVersion,
        operationIdentifier: OperationIdentifier,
        supportedOperationVersions: SemanticVersionRange,
        inputType: OperationValueIdentifier,
        outputType: OperationValueIdentifier,
        requiredProviderID: ExecutionProviderID? = nil,
        requiredCapabilities: [ExecutionCapabilityConstraint] = []
    ) {
        self.identifier = identifier
        self.version = version
        self.operationIdentifier = operationIdentifier
        self.supportedOperationVersions = supportedOperationVersions
        self.inputType = inputType
        self.outputType = outputType
        self.requiredProviderID = requiredProviderID
        self.requiredCapabilities = requiredCapabilities
    }

    public func implements(_ operation: AnyOperationSpecification) -> Bool {
        operation.identifier == operationIdentifier
            && supportedOperationVersions.contains(operation.semanticVersion)
            && operation.inputType == inputType
            && operation.outputType == outputType
    }
}

/// One implementation class realizes exactly one strongly typed operation.
/// Qualification is performed by the common runtime resolver from the published
/// specification and the execution-environment snapshot, not by this protocol.
public protocol ImageOperationImplementation: Sendable {
    associatedtype Operation: ImageOperation

    var specification: ImplementationSpecification { get }

    func execute(
        operation: Operation,
        input: Operation.Input,
        context: any ExecutionContext
    ) async throws -> Operation.Output
}

public extension ImageOperationImplementation {
    var implementsDeclaredOperation: Bool {
        specification.implements(Operation.specification.erased)
    }
}
