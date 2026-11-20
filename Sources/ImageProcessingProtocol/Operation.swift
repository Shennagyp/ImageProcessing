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
    /// Instance-level identity for values crossing a type-erased runtime boundary.
    var valueTypeIdentifier: OperationValueIdentifier { get }
}

public extension OperationValue {
    var valueTypeIdentifier: OperationValueIdentifier { Self.typeIdentifier }
}

public enum OperationOutputResourcePlanError: Error, Equatable, Sendable {
    case inputValueTypeMismatch
    case negativeOutputIndex(Int)
    case zeroCapacity(Int)
    case invalidAlignment(Int)
    case duplicateOutputIndex(Int)
}

/// Data-derived storage size/alignment needed for one output resource slot.
/// It describes this operation invocation's output, not a provider memory
/// domain or a concrete allocation.
public struct OperationOutputResourceRequirement: Hashable, Sendable {
    public let outputIndex: Int
    public let minimumCapacityBytes: UInt64
    public let minimumAlignmentBytes: UInt64

    public init(
        outputIndex: Int,
        minimumCapacityBytes: UInt64,
        minimumAlignmentBytes: UInt64 = 1
    ) throws {
        guard outputIndex >= 0 else {
            throw OperationOutputResourcePlanError.negativeOutputIndex(outputIndex)
        }
        guard minimumCapacityBytes > 0 else {
            throw OperationOutputResourcePlanError.zeroCapacity(outputIndex)
        }
        guard minimumAlignmentBytes > 0,
              minimumAlignmentBytes.nonzeroBitCount == 1 else {
            throw OperationOutputResourcePlanError.invalidAlignment(outputIndex)
        }
        self.outputIndex = outputIndex
        self.minimumCapacityBytes = minimumCapacityBytes
        self.minimumAlignmentBytes = minimumAlignmentBytes
    }
}

/// Complete generic output-resource slots for one invocation. This plan does
/// not allocate or select a provider, memory domain, or native resource.
public struct OperationOutputResourcePlan: Hashable, Sendable {
    public let resources: [OperationOutputResourceRequirement]

    public static let empty = Self(uncheckedResources: [])

    public init(resources: [OperationOutputResourceRequirement]) throws {
        var seen = Set<Int>()
        for resource in resources {
            guard seen.insert(resource.outputIndex).inserted else {
                throw OperationOutputResourcePlanError.duplicateOutputIndex(resource.outputIndex)
            }
        }
        self.resources = resources.sorted { $0.outputIndex < $1.outputIndex }
    }

    private init(uncheckedResources: [OperationOutputResourceRequirement]) {
        self.resources = uncheckedResources
    }
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

public enum OperationSpecificationValidationError: Error, Equatable, Sendable {
    case undeclaredPrecisionDomain(OperationQualificationDimension)
    case deterministicDimensionRequiresSelectableContract
    case missingNumericalContract
    case invalidNumericalContract
    case invalidParameterSchema(OperationParameterValidationError)
    case invalidPixelDataContract
    case invalidEffectContract
}

/// A typed operation specification. Input/output identifiers are derived from
/// the associated Swift types and therefore cannot drift from the public type contract.
public struct OperationSpecification<Input: OperationValue, Output: OperationValue>: Hashable, Sendable {
    public let identifier: OperationIdentifier
    public let semanticVersion: SemanticVersion
    public let inputType: OperationValueIdentifier
    public let outputType: OperationValueIdentifier
    public let qualificationDimensions: Set<OperationQualificationDimension>
    public let parameterSpecifications: [OperationParameterSpecification]
    public let precisionContract: OperationPrecisionContract
    public let numericalContract: OperationNumericalContract?
    public let effectContract: OperationEffectContract
    public let layerContract: OperationLayerContract
    public let pixelDataContract: OperationPixelDataContract
    private let explicitlyDeclaredQualificationDimensions: Set<OperationQualificationDimension>

    public init(
        identifier: OperationIdentifier,
        semanticVersion: SemanticVersion,
        qualificationDimensions: Set<OperationQualificationDimension> = [],
        parameterSpecifications: [OperationParameterSpecification] = [],
        precisionContract: OperationPrecisionContract = .none,
        numericalContract: OperationNumericalContract? = nil,
        effectContract: OperationEffectContract = .pure,
        layerContract: OperationLayerContract = .none,
        pixelDataContract: OperationPixelDataContract = .none
    ) {
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.inputType = Input.typeIdentifier
        self.outputType = Output.typeIdentifier
        self.explicitlyDeclaredQualificationDimensions = qualificationDimensions
        self.precisionContract = precisionContract
        self.numericalContract = numericalContract
        self.effectContract = effectContract
        self.layerContract = layerContract
        self.pixelDataContract = pixelDataContract
        self.parameterSpecifications = parameterSpecifications

        var dimensions = qualificationDimensions
        dimensions.formUnion(precisionContract.qualificationDimensions)
        if numericalContract?.determinism == .implementationSelectable {
            dimensions.insert(.deterministicResults)
        }
        self.qualificationDimensions = dimensions
    }

    public func validateContract() throws {
        for dimension in explicitlyDeclaredQualificationDimensions {
            switch dimension {
            case .inputStoragePrecision, .computationPrecision,
                 .accumulationPrecision, .outputPrecision:
                guard qualificationDimensions.contains(dimension),
                      precisionContract.qualificationDimensions.contains(dimension) else {
                    throw OperationSpecificationValidationError.undeclaredPrecisionDomain(dimension)
                }
            case .deterministicResults:
                guard numericalContract?.determinism == .implementationSelectable else {
                    throw OperationSpecificationValidationError.deterministicDimensionRequiresSelectableContract
                }
            }
        }

        if !precisionContract.qualificationDimensions.isEmpty, numericalContract == nil {
            throw OperationSpecificationValidationError.missingNumericalContract
        }
        if let numericalContract, !numericalContract.isValid {
            throw OperationSpecificationValidationError.invalidNumericalContract
        }
        guard effectContract.isValid else {
            throw OperationSpecificationValidationError.invalidEffectContract
        }
        if !(pixelDataContract.input?.isValid ?? true)
            || !(pixelDataContract.output?.isValid ?? true) {
            throw OperationSpecificationValidationError.invalidPixelDataContract
        }

        let pixelLayerKinds: Set<LayerKind> = [.raster, .mask, .labelMap]
        if !layerContract.acceptedInputKinds.isDisjoint(with: pixelLayerKinds),
           pixelDataContract.input == nil {
            throw OperationSpecificationValidationError.invalidPixelDataContract
        }
        if !layerContract.producedOutputKinds.isDisjoint(with: pixelLayerKinds),
           pixelDataContract.output == nil {
            throw OperationSpecificationValidationError.invalidPixelDataContract
        }

        do {
            try OperationParameterValidation.validateSpecifications(parameterSpecifications)
        } catch let error as OperationParameterValidationError {
            throw OperationSpecificationValidationError.invalidParameterSchema(error)
        }
    }

    public var erased: AnyOperationSpecification {
        AnyOperationSpecification(
            identifier: identifier,
            semanticVersion: semanticVersion,
            inputType: inputType,
            outputType: outputType,
            qualificationDimensions: qualificationDimensions,
            parameterSpecifications: parameterSpecifications,
            precisionContract: precisionContract,
            numericalContract: numericalContract,
            effectContract: effectContract,
            layerContract: layerContract,
            pixelDataContract: pixelDataContract
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
    public let parameterSpecifications: [OperationParameterSpecification]
    public let precisionContract: OperationPrecisionContract
    public let numericalContract: OperationNumericalContract?
    public let effectContract: OperationEffectContract
    public let layerContract: OperationLayerContract
    public let pixelDataContract: OperationPixelDataContract

    public func validateContract() throws {
        let precisionDimensions = Set(qualificationDimensions.filter {
            switch $0 {
            case .inputStoragePrecision, .computationPrecision,
                 .accumulationPrecision, .outputPrecision:
                return true
            case .deterministicResults:
                return false
            }
        })
        if let missing = precisionDimensions
            .subtracting(precisionContract.qualificationDimensions)
            .first {
            throw OperationSpecificationValidationError.undeclaredPrecisionDomain(missing)
        }
        if qualificationDimensions.contains(.deterministicResults),
           numericalContract?.determinism != .implementationSelectable {
            throw OperationSpecificationValidationError.deterministicDimensionRequiresSelectableContract
        }
        if !precisionContract.qualificationDimensions.isEmpty, numericalContract == nil {
            throw OperationSpecificationValidationError.missingNumericalContract
        }
        if let numericalContract, !numericalContract.isValid {
            throw OperationSpecificationValidationError.invalidNumericalContract
        }
        guard effectContract.isValid else {
            throw OperationSpecificationValidationError.invalidEffectContract
        }
        if !(pixelDataContract.input?.isValid ?? true)
            || !(pixelDataContract.output?.isValid ?? true) {
            throw OperationSpecificationValidationError.invalidPixelDataContract
        }

        let pixelLayerKinds: Set<LayerKind> = [.raster, .mask, .labelMap]
        if !layerContract.acceptedInputKinds.isDisjoint(with: pixelLayerKinds),
           pixelDataContract.input == nil {
            throw OperationSpecificationValidationError.invalidPixelDataContract
        }
        if !layerContract.producedOutputKinds.isDisjoint(with: pixelLayerKinds),
           pixelDataContract.output == nil {
            throw OperationSpecificationValidationError.invalidPixelDataContract
        }
        do {
            try OperationParameterValidation.validateSpecifications(parameterSpecifications)
        } catch let error as OperationParameterValidationError {
            throw OperationSpecificationValidationError.invalidParameterSchema(error)
        }
    }

    public init(
        identifier: OperationIdentifier,
        semanticVersion: SemanticVersion,
        inputType: OperationValueIdentifier,
        outputType: OperationValueIdentifier,
        qualificationDimensions: Set<OperationQualificationDimension> = [],
        parameterSpecifications: [OperationParameterSpecification] = [],
        precisionContract: OperationPrecisionContract = .none,
        numericalContract: OperationNumericalContract? = nil,
        effectContract: OperationEffectContract = .pure,
        layerContract: OperationLayerContract = .none,
        pixelDataContract: OperationPixelDataContract = .none
    ) {
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.inputType = inputType
        self.outputType = outputType
        self.qualificationDimensions = qualificationDimensions.union(precisionContract.qualificationDimensions).union(
            numericalContract?.determinism == .implementationSelectable ? [.deterministicResults] : []
        )
        self.parameterSpecifications = parameterSpecifications
        self.precisionContract = precisionContract
        self.numericalContract = numericalContract
        self.effectContract = effectContract
        self.layerContract = layerContract
        self.pixelDataContract = pixelDataContract
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
    public let parameterValues: [OperationParameterValueRecord]
    private let outputResourcePlanner: @Sendable (any OperationValue) throws -> OperationOutputResourcePlan

    public init<Operation: ImageOperation>(
        operation: Operation,
        identifier: OperationStepIdentifier = .generate()
    ) {
        self.identifier = identifier
        self.sourceIdentifier = identifier
        self.operation = operation
        self.specification = Operation.specification.erased
        self.parameterValues = operation.parameterValues
        self.outputResourcePlanner = { inputValue in
            guard let typedInput = inputValue as? Operation.Input else {
                throw OperationOutputResourcePlanError.inputValueTypeMismatch
            }
            return try operation.outputResourcePlan(for: typedInput)
        }
    }

    func reidentifiedForComposition() -> Self {
        Self(
            identifier: .generate(),
            sourceIdentifier: sourceIdentifier,
            operation: operation,
            specification: specification,
            parameterValues: parameterValues,
            outputResourcePlanner: outputResourcePlanner
        )
    }

    private init(
        identifier: OperationStepIdentifier,
        sourceIdentifier: OperationStepIdentifier,
        operation: any ImageOperation,
        specification: AnyOperationSpecification,
        parameterValues: [OperationParameterValueRecord],
        outputResourcePlanner: @escaping @Sendable (any OperationValue) throws -> OperationOutputResourcePlan
    ) {
        self.identifier = identifier
        self.sourceIdentifier = sourceIdentifier
        self.operation = operation
        self.specification = specification
        self.parameterValues = parameterValues
        self.outputResourcePlanner = outputResourcePlanner
    }

    /// Derives invocation-specific output resource size/alignment from the
    /// exact typed input and immutable operation instance.
    public func outputResourcePlan(
        for input: any OperationValue
    ) throws -> OperationOutputResourcePlan {
        try outputResourcePlanner(input)
    }

    public func validateParameters() throws {
        try specification.validateContract()
        try OperationParameterValidation.validate(
            specifications: specification.parameterSpecifications,
            values: parameterValues
        )
    }
}

/// Operation values are strongly typed in Swift. Runtime descriptors remain
/// available because data formats and resource layouts are discovered dynamically.
public protocol ImageOperation: Sendable {
    associatedtype Input: OperationValue
    associatedtype Output: OperationValue

    static var specification: OperationSpecification<Input, Output> { get }
    var parameterValues: [OperationParameterValueRecord] { get }

    /// Describes output resource sizes for this exact operation/input pair.
    func outputResourcePlan(for input: Input) throws -> OperationOutputResourcePlan
}

public extension ImageOperation {
    var parameterValues: [OperationParameterValueRecord] { [] }

    /// Default for operations with no runtime-allocated generic output resources.
    func outputResourcePlan(for input: Input) throws -> OperationOutputResourcePlan {
        .empty
    }
}
