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

public extension ExecutionResourceKind {
    var isValid: Bool {
        if case let .opaque(identifier) = self {
            return !identifier.isEmpty
        }
        return true
    }
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
    public let minimumCapacityBytes: UInt64
    public let minimumAlignmentBytes: UInt64
    public let access: ExecutionResourceAccessMode
    public let requiresImport: Bool

    public init(
        role: ImplementationResourceRole,
        kind: ExecutionResourceKind,
        allowedMemoryDomains: Set<ExecutionMemoryDomain>,
        minimumCapacityBytes: UInt64 = 1,
        minimumAlignmentBytes: UInt64 = 1,
        access: ExecutionResourceAccessMode,
        requiresImport: Bool = false
    ) {
        self.role = role
        self.kind = kind
        self.allowedMemoryDomains = allowedMemoryDomains
        self.minimumCapacityBytes = minimumCapacityBytes
        self.minimumAlignmentBytes = minimumAlignmentBytes
        self.access = access
        self.requiresImport = requiresImport
    }

    public var isValid: Bool {
        role.isValid
            && kind.isValid
            && !allowedMemoryDomains.isEmpty
            && minimumCapacityBytes > 0
            && minimumAlignmentBytes > 0
            && minimumAlignmentBytes.nonzeroBitCount == 1
    }
}

/// Numerical behavior actually supported by one implementation.
/// The values are guarantees, not preferred modes or measured telemetry.
public struct ImplementationNumericalSupport: Hashable, Sendable {
    public let roundingModes: Set<OperationRoundingMode>
    public let overflowBehaviors: Set<OperationOverflowBehavior>
    public let outputRangeBehaviors: Set<OperationOutputRangeBehavior>
    /// Maximum absolute error guaranteed by this implementation, when known.
    public let maximumAbsoluteError: Double?
    /// Maximum relative error guaranteed by this implementation, when known.
    public let maximumRelativeError: Double?

    public init(
        roundingModes: Set<OperationRoundingMode>,
        overflowBehaviors: Set<OperationOverflowBehavior>,
        outputRangeBehaviors: Set<OperationOutputRangeBehavior>,
        maximumAbsoluteError: Double? = nil,
        maximumRelativeError: Double? = nil
    ) {
        self.roundingModes = roundingModes
        self.overflowBehaviors = overflowBehaviors
        self.outputRangeBehaviors = outputRangeBehaviors
        self.maximumAbsoluteError = maximumAbsoluteError
        self.maximumRelativeError = maximumRelativeError
    }

    public var isValid: Bool {
        !roundingModes.isEmpty
            && !overflowBehaviors.isEmpty
            && !outputRangeBehaviors.isEmpty
            && (maximumAbsoluteError.map { $0.isFinite && $0 >= 0 } ?? true)
            && (maximumRelativeError.map { $0.isFinite && $0 >= 0 } ?? true)
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
    case invalidNumericalSupport
    case missingNumericalSupport
    case numericalSupportMismatch
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
    public let numericalSupport: ImplementationNumericalSupport?
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
        numericalSupport: ImplementationNumericalSupport? = nil,
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
        self.numericalSupport = numericalSupport
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
        guard requiredCapabilities.allSatisfy(Self.isValidCapabilityConstraint) else {
            throw ImplementationSpecificationValidationError.invalidRequiredCapability
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

        switch (operation.numericalContract, numericalSupport) {
        case (nil, nil):
            break
        case let (.some(contract), .some(support)):
            guard support.isValid else {
                throw ImplementationSpecificationValidationError.invalidNumericalSupport
            }
            guard support.roundingModes.contains(contract.rounding),
                  support.overflowBehaviors.contains(contract.overflow),
                  support.outputRangeBehaviors.contains(contract.outputRange),
                  errorBound(support.maximumAbsoluteError, satisfies: contract.absoluteErrorTolerance),
                  errorBound(support.maximumRelativeError, satisfies: contract.relativeErrorTolerance) else {
                throw ImplementationSpecificationValidationError.numericalSupportMismatch
            }
        case (.some, nil):
            throw ImplementationSpecificationValidationError.missingNumericalSupport
        case (nil, .some):
            throw ImplementationSpecificationValidationError.numericalSupportMismatch
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
        guard operation.effectContract.isValid,
              effectContract.isValid,
              operation.effectContract.requiredEffects.isSubset(of: effectContract.requiredEffects),
              effectContract.permittedEffects.isSubset(of: operation.effectContract.permittedEffects) else {
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

    private func errorBound(
        _ implementationBound: Double?,
        satisfies operationTolerance: Double?
    ) -> Bool {
        guard let operationTolerance else {
            return true
        }
        guard let implementationBound,
              implementationBound.isFinite,
              implementationBound >= 0 else {
            return false
        }
        return implementationBound <= operationTolerance
    }

    private static func isValidCapabilityConstraint(
        _ constraint: ExecutionCapabilityConstraint
    ) -> Bool {
        switch constraint.requirement {
        case let .exact(_, .decimal(value)):
            return value.isFinite
        case let .exact(_, .string(value)):
            return !value.isEmpty
        case let .exact(_, .stringSet(values)):
            return !values.isEmpty && values.allSatisfy { !$0.isEmpty }
        case let .decimalAtLeast(_, minimum):
            return minimum.isFinite
        case let .stringSetContains(_, value):
            return !value.isEmpty
        case .exact, .integerAtLeast:
            return true
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
