public struct ChannelIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ColorSpaceIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct MeasurementUnitIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum PixelComponentType: String, Hashable, Sendable {
    case uint8
    case uint16
    case uint32
    case int16
    case int32
    case float16
    case float32
    case float64

    public var bytesPerComponent: UInt64 {
        switch self {
        case .uint8: 1
        case .uint16, .int16, .float16: 2
        case .uint32, .int32, .float32: 4
        case .float64: 8
        }
    }

    public var isInteger: Bool {
        switch self {
        case .uint8, .uint16, .uint32, .int16, .int32: true
        case .float16, .float32, .float64: false
        }
    }
}

public enum PixelChannelRole: Hashable, Sendable {
    case gray
    case red
    case green
    case blue
    case luma
    case chromaBlue
    case chromaRed
    case alpha
    case intensity
    case labelIdentifier
    case custom(String)
}

public struct NumericValueRange: Hashable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init?(minimum: Double, maximum: Double) {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        self.minimum = minimum
        self.maximum = maximum
    }

    public func isContained(in minimum: Double, maximum: Double) -> Bool {
        self.minimum >= minimum && self.maximum <= maximum
    }
}

public struct PixelChannelDescriptor: Hashable, Sendable {
    public let identifier: ChannelIdentifier
    public let role: PixelChannelRole
    /// Nil means the valid numerical range is not known at descriptor time.
    public let valueRange: NumericValueRange?

    public init(
        identifier: ChannelIdentifier,
        role: PixelChannelRole,
        valueRange: NumericValueRange? = nil
    ) {
        self.identifier = identifier
        self.role = role
        self.valueRange = valueRange
    }
}

public enum TransferFunction: String, Hashable, Sendable {
    case linear
    case sRGB
    case rec709
    case gamma22
    case gamma24
}

public enum AlphaMode: String, Hashable, Sendable {
    case none
    case straight
    case premultiplied
}

public enum ColorChannelModel: Hashable, Sendable {
    case gray
    case rgb
    case yCbCr
    /// A named model such as CMYK, XYZ, Lab, or a domain-defined color encoding.
    case custom(String)
}

public struct ColorDataInterpretation: Hashable, Sendable {
    public let colorSpace: ColorSpaceIdentifier
    public let channelModel: ColorChannelModel
    public let transferFunction: TransferFunction
    public let alphaMode: AlphaMode

    public init(
        colorSpace: ColorSpaceIdentifier,
        channelModel: ColorChannelModel,
        transferFunction: TransferFunction,
        alphaMode: AlphaMode
    ) {
        self.colorSpace = colorSpace
        self.channelModel = channelModel
        self.transferFunction = transferFunction
        self.alphaMode = alphaMode
    }
}

public struct ScientificDataInterpretation: Hashable, Sendable {
    public let unit: MeasurementUnitIdentifier?

    public init(unit: MeasurementUnitIdentifier? = nil) {
        self.unit = unit
    }
}

public enum PixelDataInterpretation: Hashable, Sendable {
    case color(ColorDataInterpretation)
    case scientific(ScientificDataInterpretation)
}

public struct PixelSubsampling: Hashable, Sendable {
    public let x: UInt64
    public let y: UInt64
    public let z: UInt64

    public init?(x: UInt64 = 1, y: UInt64 = 1, z: UInt64 = 1) {
        guard x > 0, y > 0, z > 0 else { return nil }
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct PixelPlaneLayout: Hashable, Sendable {
    public let byteOffset: UInt64
    public let rowStrideBytes: UInt64
    public let sliceStrideBytes: UInt64
    public let pixelStrideBytes: UInt64
    public let subsampling: PixelSubsampling
    public let channelIndices: [Int]

    public init(
        byteOffset: UInt64,
        rowStrideBytes: UInt64,
        sliceStrideBytes: UInt64,
        pixelStrideBytes: UInt64,
        subsampling: PixelSubsampling,
        channelIndices: [Int]
    ) {
        self.byteOffset = byteOffset
        self.rowStrideBytes = rowStrideBytes
        self.sliceStrideBytes = sliceStrideBytes
        self.pixelStrideBytes = pixelStrideBytes
        self.subsampling = subsampling
        self.channelIndices = channelIndices
    }
}

public enum PixelStorageLayout: Hashable, Sendable {
    /// All channels are stored in one plane with a common pixel stride.
    case interleaved(PixelPlaneLayout)
    /// Channels are divided among one or more storage planes.
    case planar([PixelPlaneLayout])
}

public enum PixelDataDescriptorError: Error, Equatable, Sendable {
    case noChannels
    case duplicateChannelIdentifier(ChannelIdentifier)
    case invalidCustomChannelRole(ChannelIdentifier)
    case invalidColorChannelRoles
    case invalidCustomColorModel
    case alphaModeMismatch
    case invalidScientificChannelRole(ChannelIdentifier)
    case noPlanes
    case invalidChannelIndex(Int)
    case duplicateChannelMapping(Int)
    case missingChannelMapping(Int)
    case emptyPlaneChannelMapping
    case pixelStrideTooSmall(plane: Int, minimum: UInt64)
    case rowStrideTooSmall(plane: Int, minimum: UInt64)
    case sliceStrideTooSmall(plane: Int, minimum: UInt64)
    case arithmeticOverflow
    case storageCapacityTooSmall(required: UInt64, actual: UInt64)
}

/// Image-domain interpretation of sample values and memory layout.
/// It contains no provider-native allocation or pointer.
public struct PixelDataDescriptor: Hashable, Sendable {
    public let extent: ImageExtent
    public let componentType: PixelComponentType
    public let channels: [PixelChannelDescriptor]
    public let interpretation: PixelDataInterpretation
    public let layout: PixelStorageLayout
    public let minimumRequiredStorageBytes: UInt64

    public init(
        extent: ImageExtent,
        componentType: PixelComponentType,
        channels: [PixelChannelDescriptor],
        interpretation: PixelDataInterpretation,
        layout: PixelStorageLayout
    ) throws {
        guard !channels.isEmpty else { throw PixelDataDescriptorError.noChannels }
        var identifiers = Set<ChannelIdentifier>()
        for channel in channels {
            guard identifiers.insert(channel.identifier).inserted else {
                throw PixelDataDescriptorError.duplicateChannelIdentifier(channel.identifier)
            }
            if case let .custom(name) = channel.role, name.isEmpty {
                throw PixelDataDescriptorError.invalidCustomChannelRole(channel.identifier)
            }
        }
        try Self.validateInterpretation(interpretation, channels: channels)
        let requiredBytes = try Self.validateLayout(
            layout,
            extent: extent,
            componentType: componentType,
            channelCount: channels.count
        )

        self.extent = extent
        self.componentType = componentType
        self.channels = channels
        self.interpretation = interpretation
        self.layout = layout
        self.minimumRequiredStorageBytes = requiredBytes
    }

    public func validateStorageCapacity(_ capacityBytes: UInt64) throws {
        guard capacityBytes >= minimumRequiredStorageBytes else {
            throw PixelDataDescriptorError.storageCapacityTooSmall(
                required: minimumRequiredStorageBytes,
                actual: capacityBytes
            )
        }
    }

    private static func validateInterpretation(
        _ interpretation: PixelDataInterpretation,
        channels: [PixelChannelDescriptor]
    ) throws {
        let roles = channels.map(\.role)
        switch interpretation {
        case let .color(color):
            let alphaCount = roles.filter { $0 == .alpha }.count
            guard alphaCount <= 1 else { throw PixelDataDescriptorError.invalidColorChannelRoles }
            let baseRoles = roles.filter { $0 != .alpha }
            let validModel: Bool
            switch color.channelModel {
            case .rgb:
                validModel = baseRoles.count == 3
                    && Set(baseRoles) == Set([PixelChannelRole.red, .green, .blue])
            case .gray:
                validModel = baseRoles == [.gray]
            case .yCbCr:
                validModel = baseRoles.count == 3
                    && Set(baseRoles) == Set([PixelChannelRole.luma, .chromaBlue, .chromaRed])
            case let .custom(identifier):
                guard !identifier.isEmpty else {
                    throw PixelDataDescriptorError.invalidCustomColorModel
                }
                validModel = !baseRoles.isEmpty && baseRoles.allSatisfy {
                    if case .custom = $0 { return true }
                    return false
                }
            }
            guard validModel else { throw PixelDataDescriptorError.invalidColorChannelRoles }
            switch color.alphaMode {
            case .none:
                guard alphaCount == 0 else { throw PixelDataDescriptorError.alphaModeMismatch }
            case .straight, .premultiplied:
                guard alphaCount == 1 else { throw PixelDataDescriptorError.alphaModeMismatch }
            }
        case .scientific:
            for channel in channels {
                switch channel.role {
                case .intensity, .labelIdentifier, .custom:
                    break
                default:
                    throw PixelDataDescriptorError.invalidScientificChannelRole(channel.identifier)
                }
            }
        }
    }

    private static func validateLayout(
        _ layout: PixelStorageLayout,
        extent: ImageExtent,
        componentType: PixelComponentType,
        channelCount: Int
    ) throws -> UInt64 {
        let planes: [PixelPlaneLayout]
        switch layout {
        case let .interleaved(plane):
            planes = [plane]
        case let .planar(items):
            planes = items
        }
        guard !planes.isEmpty else { throw PixelDataDescriptorError.noPlanes }

        var mappedChannels = Set<Int>()
        var minimumStorageBytes: UInt64 = 0
        for (planeIndex, plane) in planes.enumerated() {
            guard !plane.channelIndices.isEmpty else {
                throw PixelDataDescriptorError.emptyPlaneChannelMapping
            }
            let bytesPerPixel = try checkedMultiply(
                UInt64(plane.channelIndices.count),
                componentType.bytesPerComponent
            )
            guard plane.pixelStrideBytes >= bytesPerPixel else {
                throw PixelDataDescriptorError.pixelStrideTooSmall(plane: planeIndex, minimum: bytesPerPixel)
            }

            for channelIndex in plane.channelIndices {
                guard channelIndex >= 0, channelIndex < channelCount else {
                    throw PixelDataDescriptorError.invalidChannelIndex(channelIndex)
                }
                guard mappedChannels.insert(channelIndex).inserted else {
                    throw PixelDataDescriptorError.duplicateChannelMapping(channelIndex)
                }
            }

            let planeWidth = ceilDivide(extent.width, by: plane.subsampling.x)
            let planeHeight = ceilDivide(extent.height, by: plane.subsampling.y)
            let planeDepth = ceilDivide(extent.depth, by: plane.subsampling.z)
            let minimumRowStride = try checkedMultiply(planeWidth, plane.pixelStrideBytes)
            guard plane.rowStrideBytes >= minimumRowStride else {
                throw PixelDataDescriptorError.rowStrideTooSmall(plane: planeIndex, minimum: minimumRowStride)
            }
            let minimumSliceStride = try checkedMultiply(plane.rowStrideBytes, planeHeight)
            guard plane.sliceStrideBytes >= minimumSliceStride else {
                throw PixelDataDescriptorError.sliceStrideTooSmall(plane: planeIndex, minimum: minimumSliceStride)
            }

            let lastSlice = try checkedMultiply(planeDepth - 1, plane.sliceStrideBytes)
            let lastRow = try checkedMultiply(planeHeight - 1, plane.rowStrideBytes)
            let lastPixel = try checkedMultiply(planeWidth - 1, plane.pixelStrideBytes)
            var end = try checkedAdd(plane.byteOffset, lastSlice)
            end = try checkedAdd(end, lastRow)
            end = try checkedAdd(end, lastPixel)
            end = try checkedAdd(end, bytesPerPixel)
            minimumStorageBytes = max(minimumStorageBytes, end)
        }

        for channelIndex in 0..<channelCount where !mappedChannels.contains(channelIndex) {
            throw PixelDataDescriptorError.missingChannelMapping(channelIndex)
        }
        return minimumStorageBytes
    }

    private static func ceilDivide(_ value: UInt64, by divisor: UInt64) -> UInt64 {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw PixelDataDescriptorError.arithmeticOverflow }
        return value
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PixelDataDescriptorError.arithmeticOverflow }
        return value
    }
}
