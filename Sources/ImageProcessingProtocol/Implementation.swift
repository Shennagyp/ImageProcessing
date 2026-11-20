import GeneralExecutionProtocol

public struct OperationImplementationIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ImplementationDeterminism: String, Hashable, Sendable {
    case deterministic
    case nondeterministic
}

public enum ImplementationResourceRole: Hashable, Sendable {
    case input(Int)
    case output(Int)
    case temporary(String)

    public var isValid: Bool {
        switch self {
        case let .input(index), let .output(index):
            return index >= 0
        case let .temporary(identifier):
            return !identifier.isEmpty
        }
    }
}

/// A static resource constraint for one input, output, or temporary allocation.
/// It contains no live availability or capacity observation.
public struct ImplementationResourceRequirement: Hashable, Sendable {
    public let role: ImplementationResourceRole
    public let kind: ExecutionResourceKind
    public let allowedMemoryDomains: Set<ExecutionMemoryDomain>
    public let minimumAlignmentBytes: UInt64
    public let access: ExecutionResourceAccessMode
    public let requiresImport: Bool

    public init(
        role: ImplementationResourceRole,
        kind: ExecutionResourceKind,
        allowedMemoryDomains: Set<ExecutionMemoryDomain>,
        minimumAlignmentBytes: UInt64 = 1,
        access: ExecutionResourceAccessMode,
        requiresImport: Bool = false
    ) {
        self.role = role
        self.kind = kind
        self.allowedMemoryDomains = allowedMemoryDomains
        self.minimumAlignmentBytes = minimumAlignmentBytes
        self.access = access
        self.requiresImport = requiresImport
    }

    public var isValid: Bool {
        role.isValid
            && !allowedMemoryDomains.isEmpty
            && minimumAlignmentBytes > 0
            && minimumAlignmentBytes.nonzeroBitCount == 1
    }
}

public struct ImplementationPerformanceHints: Hashable, Sendable {
    /// Approximate fixed submission/setup overhead, in nanoseconds.
    public let fixedOverheadNanoseconds: Double?
    /// Approximate arithmetic work per processed element, in operations/element.
    public let operationsPerElement: Double?
    /// Approximate temporary memory per processed element, in bytes/element.
    public let temporaryBytesPerElement: Double?

    public init(
        fixedOverheadNanoseconds: Double? = nil,
        operationsPerElement: Double? = nil,
        temporaryBytesPerElement: Double? = nil
    ) {
        self.fixedOverheadNanoseconds = fixedOverheadNanoseconds
        self.operationsPerElement = operationsPerElement
        self.temporaryBytesPerElement = temporaryBytesPerElement
    }

    public var isValid: Bool {
        (fixedOverheadNanoseconds.map { $0.isFinite && $0 >= 0 } ?? true)
            && (operationsPerElement.map { $0.isFinite && $0 >= 0 } ?? true)
            && (temporaryBytesPerElement.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public enum ImplementationSpecificationValidationError: Error, Equatable, Sendable {
    case operationIdentityMismatch
    case unsupportedOperationVersion
    case inputTypeMismatch
    case outputTypeMismatch
    case parameterSupport(OperationParameterSupportValidationError)
    case precisionSupportMismatch(PrecisionDimension)
    case determinismMismatch
    case effectContractMismatch
    case layerSupportMismatch
    case pixelRepresentationMismatch(inputOutput: String)
    case invalidResourceRequirement(ImplementationResourceRole)
    case duplicateResourceRequirement(ImplementationResourceRole)
    case invalidPerformanceHints
    case invalidRequiredCapability
}

public struct ImplementationSpecification: Hashable, Sendable {
    public let identifier: OperationImplementationIdentifier
    public let version: SemanticVersion
    public let operationIdentifier: OperationIdentifier
    public let supportedOperationVersions: SemanticVersionRange
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier
    public let requiredProviderID: ExecutionProviderID?
    public let requiredCapabilities: [ExecutionCapabilityConstraint]
    public let parameterSupport: [OperationParameterSupport]
    public let precisionSupport: OperationPrecisionContract
    public let determinism: ImplementationDeterminism
    public let effectContract: OperationEffectContract
    public let layerSupport: ImplementationLayerSupport
    public let pixelDataSupport: OperationPixelDataContract
    public let resourceRequirements: [ImplementationResourceRequirement]
    public let performanceHints: ImplementationPerformanceHints?

    public init(
        identifier: OperationImplementationIdentifier,
        version: SemanticVersion,
        operationIdentifier: OperationIdentifier,
        supportedOperationVersions: SemanticVersionRange,
        inputType: OperationValueIdentifier,
        outputType: OperationValueIdentifier,
        requiredProviderID: ExecutionProviderID? = nil,
        requiredCapabilities: [ExecutionCapabilityConstraint] = [],
        parameterSupport: [OperationParameterSupport] = [],
        precisionSupport: OperationPrecisionContract = .none,
        determinism: ImplementationDeterminism = .deterministic,
        effectContract: OperationEffectContract = .pure,
        layerSupport: ImplementationLayerSupport = .init(),
        pixelDataSupport: OperationPixelDataContract = .none,
        resourceRequirements: [ImplementationResourceRequirement] = [],
        performanceHints: ImplementationPerformanceHints? = nil
    ) {
        self.identifier = identifier
        self.version = version
        self.operationIdentifier = operationIdentifier
        self.supportedOperationVersions = supportedOperationVersions
        self.inputType = inputType
        self.outputType = outputType
        self.requiredProviderID = requiredProviderID
        self.requiredCapabilities = requiredCapabilities
        self.parameterSupport = parameterSupport
        self.precisionSupport = precisionSupport
        self.determinism = determinism
        self.effectContract = effectContract
        self.layerSupport = layerSupport
        self.pixelDataSupport = pixelDataSupport
        self.resourceRequirements = resourceRequirements
        self.performanceHints = performanceHints
    }

    /// Validates static implementation declarations against the operation contract.
    /// Dynamic provider/device state is intentionally not considered here.
    public func validate(implements operation: AnyOperationSpecification) throws {
        try operation.validateContract()

        guard operation.identifier == operationIdentifier else {
            throw ImplementationSpecificationValidationError.operationIdentityMismatch
        }
        guard supportedOperationVersions.contains(operation.semanticVersion) else {
            throw ImplementationSpecificationValidationError.unsupportedOperationVersion
        }
        guard operation.inputType == inputType else {
            throw ImplementationSpecificationValidationError.inputTypeMismatch
        }
        guard operation.outputType == outputType else {
            throw ImplementationSpecificationValidationError.outputTypeMismatch
        }

        do {
            try OperationParameterSupportValidation.validate(
                operationSpecifications: operation.parameterSpecifications,
                implementationSupport: parameterSupport
            )
        } catch let error as OperationParameterSupportValidationError {
            throw ImplementationSpecificationValidationError.parameterSupport(error)
        }

        for dimension in [
            PrecisionDimension.inputStorage,
            .computation,
            .accumulation,
            .output
        ] {
            let operationValues = operation.precisionContract.values(for: dimension)
            let implementationValues = precisionSupport.values(for: dimension)
            if operationValues.isEmpty {
                guard implementationValues.isEmpty else {
                    throw ImplementationSpecificationValidationError.precisionSupportMismatch(dimension)
                }
            } else {
                guard !implementationValues.isEmpty,
                      implementationValues.isSubset(of: operationValues) else {
                    throw ImplementationSpecificationValidationError.precisionSupportMismatch(dimension)
                }
            }
        }

        switch operation.numericalContract?.determinism {
        case .required, nil:
            guard determinism == .deterministic else {
                throw ImplementationSpecificationValidationError.determinismMismatch
            }
        case .implementationSelectable:
            break
        }

        if operation.effectContract.inputMutation == .never,
           effectContract.inputMutation == .permitted {
            throw ImplementationSpecificationValidationError.effectContractMismatch
        }
        if operation.effectContract.outputAliasing == .distinctFromInputs,
           effectContract.outputAliasing == .mayAliasInput {
            throw ImplementationSpecificationValidationError.effectContractMismatch
        }
        guard effectContract.effects.isSubset(of: operation.effectContract.effects) else {
            throw ImplementationSpecificationValidationError.effectContractMismatch
        }

        guard layerSupport.inputKinds.isSubset(of: operation.layerContract.acceptedInputKinds),
              layerSupport.outputKinds.isSubset(of: operation.layerContract.producedOutputKinds),
              (!operation.layerContract.acceptedInputKinds.isEmpty ? !layerSupport.inputKinds.isEmpty : layerSupport.inputKinds.isEmpty),
              (!operation.layerContract.producedOutputKinds.isEmpty ? !layerSupport.outputKinds.isEmpty : layerSupport.outputKinds.isEmpty) else {
            throw ImplementationSpecificationValidationError.layerSupportMismatch
        }

        try validatePixelRepresentation(
            implementation: pixelDataSupport.input,
            operation: operation.pixelDataContract.input,
            direction: "input"
        )
        try validatePixelRepresentation(
            implementation: pixelDataSupport.output,
            operation: operation.pixelDataContract.output,
            direction: "output"
        )

        var resourceRoles = Set<ImplementationResourceRole>()
        for requirement in resourceRequirements {
            guard requirement.isValid else {
                throw ImplementationSpecificationValidationError.invalidResourceRequirement(requirement.role)
            }
            guard resourceRoles.insert(requirement.role).inserted else {
                throw ImplementationSpecificationValidationError.duplicateResourceRequirement(requirement.role)
            }
        }

        if let performanceHints, !performanceHints.isValid {
            throw ImplementationSpecificationValidationError.invalidPerformanceHints
        }
    }

    private func validatePixelRepresentation(
        implementation: PixelRepresentationDomain?,
        operation: PixelRepresentationDomain?,
        direction: String
    ) throws {
        switch (implementation, operation) {
        case (nil, nil):
            return
        case let (.some(implementation), .some(operation))
            where implementation.isSubset(of: operation):
            return
        default:
            throw ImplementationSpecificationValidationError.pixelRepresentationMismatch(
                inputOutput: direction
            )
        }
    }

    public func implements(_ operation: AnyOperationSpecification) -> Bool {
        do {
            try validate(implements: operation)
            return true
        } catch {
            return false
        }
    }

    /// Checks both static implementation compatibility and the actual parameter values
    /// carried by this operation occurrence.
    public func supports(_ step: AnyImageOperationStep) -> Bool {
        guard implements(step.specification) else { return false }
        do {
            try step.validateParameters()
        } catch {
            return false
        }
        return OperationParameterSupportValidation.accepts(
            step.parameterValues,
            implementationSupport: parameterSupport
        )
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

    func supports(_ operation: Operation) -> Bool {
        let step = AnyImageOperationStep(operation: operation)
        return specification.supports(step)
    }
}
