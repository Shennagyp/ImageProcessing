public enum PrecisionDimension: String, Hashable, Sendable {
    case inputStorage
    case computation
    case accumulation
    case output
}

/// Precision used by arithmetic rather than the storage representation of pixels.
public enum ArithmeticPrecision: String, Hashable, Sendable {
    case int32
    case int64
    case float16
    case float32
    case float64
}

public enum PrecisionValue: Hashable, Sendable {
    case storage(PixelComponentType)
    case arithmetic(ArithmeticPrecision)

    public static let float16 = Self.arithmetic(.float16)
    public static let float32 = Self.arithmetic(.float32)
    public static let float64 = Self.arithmetic(.float64)
    public static let int32 = Self.arithmetic(.int32)
    public static let int64 = Self.arithmetic(.int64)

    public static let uint8 = Self.storage(.uint8)
    public static let uint16 = Self.storage(.uint16)
    public static let uint32 = Self.storage(.uint32)
    public static let int16 = Self.storage(.int16)
    public static let storageFloat16 = Self.storage(.float16)
    public static let storageFloat32 = Self.storage(.float32)
    public static let storageFloat64 = Self.storage(.float64)
}

/// Semantic precision choices the operation permits. An empty set means that
/// the operation does not expose that precision dimension.
public struct OperationPrecisionContract: Hashable, Sendable {
    public let inputStorage: Set<PixelComponentType>
    public let computation: Set<ArithmeticPrecision>
    public let accumulation: Set<ArithmeticPrecision>
    public let outputStorage: Set<PixelComponentType>

    public init(
        inputStorage: Set<PixelComponentType> = [],
        computation: Set<ArithmeticPrecision> = [],
        accumulation: Set<ArithmeticPrecision> = [],
        outputStorage: Set<PixelComponentType> = []
    ) {
        self.inputStorage = inputStorage
        self.computation = computation
        self.accumulation = accumulation
        self.outputStorage = outputStorage
    }

    public static let none = Self()

    public var qualificationDimensions: Set<OperationQualificationDimension> {
        var dimensions = Set<OperationQualificationDimension>()
        if !inputStorage.isEmpty { dimensions.insert(.inputStoragePrecision) }
        if !computation.isEmpty { dimensions.insert(.computationPrecision) }
        if !accumulation.isEmpty { dimensions.insert(.accumulationPrecision) }
        if !outputStorage.isEmpty { dimensions.insert(.outputPrecision) }
        return dimensions
    }

    public func values(for dimension: PrecisionDimension) -> Set<PrecisionValue> {
        switch dimension {
        case .inputStorage:
            return Set(inputStorage.map(PrecisionValue.storage))
        case .computation:
            return Set(computation.map(PrecisionValue.arithmetic))
        case .accumulation:
            return Set(accumulation.map(PrecisionValue.arithmetic))
        case .output:
            return Set(outputStorage.map(PrecisionValue.storage))
        }
    }
}

/// Image-layer kinds an operation accepts and produces. Empty sides mean that
/// the corresponding value is not represented as a layer.
public struct OperationLayerContract: Hashable, Sendable {
    public let acceptedInputKinds: Set<LayerKind>
    public let producedOutputKinds: Set<LayerKind>

    public init(
        acceptedInputKinds: Set<LayerKind> = [],
        producedOutputKinds: Set<LayerKind> = []
    ) {
        self.acceptedInputKinds = acceptedInputKinds
        self.producedOutputKinds = producedOutputKinds
    }

    public static let none = Self()
}

public enum PixelStorageLayoutKind: String, Hashable, Sendable {
    case interleaved
    case planar
}

public enum PixelInterpretationKind: String, Hashable, Sendable {
    case color
    case scientific
}

/// Semantic pixel representation domain for a pixel-bearing operation input/output.
/// Required sets are explicit; optional sets use nil to mean that the operation
/// does not constrain that particular attribute.
public struct PixelRepresentationDomain: Hashable, Sendable {
    public let layouts: Set<PixelStorageLayoutKind>
    public let interpretations: Set<PixelInterpretationKind>
    public let colorModels: Set<ColorChannelModel>?
    public let alphaModes: Set<AlphaMode>?
    public let transferFunctions: Set<TransferFunction>?
    public let colorSpaces: Set<ColorSpaceIdentifier>?
    public let channelRoles: Set<PixelChannelRole>?
    public let measurementUnits: Set<MeasurementUnitIdentifier>?

    public init(
        layouts: Set<PixelStorageLayoutKind>,
        interpretations: Set<PixelInterpretationKind>,
        colorModels: Set<ColorChannelModel>? = nil,
        alphaModes: Set<AlphaMode>? = nil,
        transferFunctions: Set<TransferFunction>? = nil,
        colorSpaces: Set<ColorSpaceIdentifier>? = nil,
        channelRoles: Set<PixelChannelRole>? = nil,
        measurementUnits: Set<MeasurementUnitIdentifier>? = nil
    ) {
        self.layouts = layouts
        self.interpretations = interpretations
        self.colorModels = colorModels
        self.alphaModes = alphaModes
        self.transferFunctions = transferFunctions
        self.colorSpaces = colorSpaces
        self.channelRoles = channelRoles
        self.measurementUnits = measurementUnits
    }

    public var isValid: Bool {
        guard !layouts.isEmpty, !interpretations.isEmpty else { return false }
        let hasColor = interpretations.contains(.color)
        let hasScientific = interpretations.contains(.scientific)
        if !hasColor,
           colorModels != nil || alphaModes != nil || transferFunctions != nil || colorSpaces != nil {
            return false
        }
        if !hasScientific, measurementUnits != nil {
            return false
        }
        return optionalSetIsValid(colorModels)
            && optionalSetIsValid(alphaModes)
            && optionalSetIsValid(transferFunctions)
            && optionalSetIsValid(colorSpaces)
            && optionalSetIsValid(channelRoles)
            && optionalSetIsValid(measurementUnits)
    }

    public func isSubset(of operationDomain: Self) -> Bool {
        guard isValid, operationDomain.isValid,
              layouts.isSubset(of: operationDomain.layouts),
              interpretations.isSubset(of: operationDomain.interpretations) else {
            return false
        }
        return optionalSetIsSubset(colorModels, of: operationDomain.colorModels)
            && optionalSetIsSubset(alphaModes, of: operationDomain.alphaModes)
            && optionalSetIsSubset(transferFunctions, of: operationDomain.transferFunctions)
            && optionalSetIsSubset(colorSpaces, of: operationDomain.colorSpaces)
            && optionalSetIsSubset(channelRoles, of: operationDomain.channelRoles)
            && optionalSetIsSubset(measurementUnits, of: operationDomain.measurementUnits)
    }

    private func optionalSetIsValid<Element>(_ values: Set<Element>?) -> Bool {
        values.map { !$0.isEmpty } ?? true
    }

    private func optionalSetIsSubset<Element: Hashable>(
        _ values: Set<Element>?,
        of operationValues: Set<Element>?
    ) -> Bool {
        guard let operationValues else { return true }
        guard let values else { return false }
        return values.isSubset(of: operationValues)
    }
}

public struct OperationPixelDataContract: Hashable, Sendable {
    public let input: PixelRepresentationDomain?
    public let output: PixelRepresentationDomain?

    public init(
        input: PixelRepresentationDomain? = nil,
        output: PixelRepresentationDomain? = nil
    ) {
        self.input = input
        self.output = output
    }

    public static let none = Self()
}

/// Static layer-kind subset supported by one implementation.
public struct ImplementationLayerSupport: Hashable, Sendable {
    public let inputKinds: Set<LayerKind>
    public let outputKinds: Set<LayerKind>

    public init(
        inputKinds: Set<LayerKind> = [],
        outputKinds: Set<LayerKind> = []
    ) {
        self.inputKinds = inputKinds
        self.outputKinds = outputKinds
    }
}

public enum OperationRoundingMode: String, Hashable, Sendable {
    case nearestEven
    case towardZero
    case towardPositive
    case towardNegative
    case implementationDefined
}

public enum OperationOverflowBehavior: String, Hashable, Sendable {
    case error
    case saturate
    case wrap
    case infinity
    case implementationDefined
}

public enum OperationOutputRangeBehavior: Hashable, Sendable {
    case preserve
    case clip(minimum: Double, maximum: Double)
    case normalize(minimum: Double, maximum: Double)

    public var isValid: Bool {
        switch self {
        case .preserve:
            return true
        case let .clip(minimum, maximum), let .normalize(minimum, maximum):
            return minimum.isFinite && maximum.isFinite && minimum <= maximum
        }
    }
}

public enum OperationDeterminismContract: String, Hashable, Sendable {
    /// Every conforming implementation must produce deterministic results.
    case required
    /// A conforming implementation may be deterministic or nondeterministic;
    /// the runtime and caller policy can select among those variants.
    case implementationSelectable
}

public struct OperationNumericalContract: Hashable, Sendable {
    public let rounding: OperationRoundingMode
    public let overflow: OperationOverflowBehavior
    public let outputRange: OperationOutputRangeBehavior
    public let determinism: OperationDeterminismContract
    public let absoluteErrorTolerance: Double?
    public let relativeErrorTolerance: Double?

    public init(
        rounding: OperationRoundingMode,
        overflow: OperationOverflowBehavior,
        outputRange: OperationOutputRangeBehavior = .preserve,
        determinism: OperationDeterminismContract = .required,
        absoluteErrorTolerance: Double? = nil,
        relativeErrorTolerance: Double? = nil
    ) {
        self.rounding = rounding
        self.overflow = overflow
        self.outputRange = outputRange
        self.determinism = determinism
        self.absoluteErrorTolerance = absoluteErrorTolerance
        self.relativeErrorTolerance = relativeErrorTolerance
    }

    public var isValid: Bool {
        outputRange.isValid
            && (absoluteErrorTolerance.map { $0.isFinite && $0 >= 0 } ?? true)
            && (relativeErrorTolerance.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public enum OperationInputMutationSemantics: String, Hashable, Sendable {
    case never
    case permitted
}

public enum OperationOutputAliasingSemantics: String, Hashable, Sendable {
    case distinctFromInputs
    case mayAliasInput
}

public enum OperationEffect: String, Hashable, Sendable {
    case randomness
    case clock
    case externalIO
    case deviceState
    case persistentState
    case acquisition
}

public struct OperationEffectContract: Hashable, Sendable {
    public let inputMutation: OperationInputMutationSemantics
    public let outputAliasing: OperationOutputAliasingSemantics
    public let effects: Set<OperationEffect>

    public init(
        inputMutation: OperationInputMutationSemantics = .never,
        outputAliasing: OperationOutputAliasingSemantics = .distinctFromInputs,
        effects: Set<OperationEffect> = []
    ) {
        self.inputMutation = inputMutation
        self.outputAliasing = outputAliasing
        self.effects = effects
    }

    public static let pure = Self()
    public var isPure: Bool { effects.isEmpty }
}
