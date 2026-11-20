public struct LabelSetIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct AnnotationSchemaIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct CoordinateSystemIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public enum MaskValueSemantics: String, Hashable, Sendable {
    case binary
    case coverage
    case probability
}

public enum LayerContentDescriptorError: Error, Equatable, Sendable {
    case maskRequiresOneScientificChannel
    case maskRangeMustBeUnitInterval
    case labelMapRequiresOneIntegerChannel
}

public struct MaskDataDescriptor: Hashable, Sendable {
    public let pixels: PixelDataDescriptor
    public let semantics: MaskValueSemantics

    public init(pixels: PixelDataDescriptor, semantics: MaskValueSemantics) throws {
        guard pixels.channels.count == 1 else {
            throw LayerContentDescriptorError.maskRequiresOneScientificChannel
        }
        guard case .scientific = pixels.interpretation else {
            throw LayerContentDescriptorError.maskRequiresOneScientificChannel
        }
        if semantics == .coverage || semantics == .probability {
            if let range = pixels.channels[0].valueRange,
               !range.isContained(in: 0, maximum: 1) {
                throw LayerContentDescriptorError.maskRangeMustBeUnitInterval
            }
        }
        self.pixels = pixels
        self.semantics = semantics
    }
}

public struct LabelMapDataDescriptor: Hashable, Sendable {
    public let pixels: PixelDataDescriptor
    public let labelSet: LabelSetIdentifier

    public init(pixels: PixelDataDescriptor, labelSet: LabelSetIdentifier) throws {
        guard pixels.channels.count == 1,
              pixels.channels[0].role == .labelIdentifier,
              pixels.componentType.isInteger else {
            throw LayerContentDescriptorError.labelMapRequiresOneIntegerChannel
        }
        guard case .scientific = pixels.interpretation else {
            throw LayerContentDescriptorError.labelMapRequiresOneIntegerChannel
        }
        self.pixels = pixels
        self.labelSet = labelSet
    }
}

public enum AnnotationCoordinateSpace: Hashable, Sendable {
    case pixel
    case normalizedCanvas
    case world(CoordinateSystemIdentifier)
}

public struct AnnotationDataDescriptor: Hashable, Sendable {
    public let schema: AnnotationSchemaIdentifier
    public let coordinateSpace: AnnotationCoordinateSpace

    public init(schema: AnnotationSchemaIdentifier, coordinateSpace: AnnotationCoordinateSpace) {
        self.schema = schema
        self.coordinateSpace = coordinateSpace
    }
}

public enum LayerContentDescriptor: Hashable, Sendable {
    case raster(PixelDataDescriptor)
    case mask(MaskDataDescriptor)
    case labelMap(LabelMapDataDescriptor)
    case annotation(AnnotationDataDescriptor)

    public var kind: LayerKind {
        switch self {
        case .raster: .raster
        case .mask: .mask
        case .labelMap: .labelMap
        case .annotation: .annotation
        }
    }
}

public struct LayerProperties: Hashable, Sendable {
    public let displayName: String?
    public let isVisible: Bool
    public let opacity: Double

    public init?(displayName: String? = nil, isVisible: Bool = true, opacity: Double = 1) {
        guard opacity.isFinite, (0...1).contains(opacity) else { return nil }
        guard displayName.map({ !$0.isEmpty }) ?? true else { return nil }
        self.displayName = displayName
        self.isVisible = isVisible
        self.opacity = opacity
    }

    public static let defaultValue = LayerProperties()!
}

public struct LayerDescriptor: Hashable, Sendable {
    public let identifier: LayerIdentifier
    public let properties: LayerProperties
    public let content: LayerContentDescriptor
    /// Required when raster/mask/label-map sample extents differ from the image
    /// canvas extent. A nil mapping means identical sample grids.
    public let spatialMapping: LayerSpatialMapping?

    public var kind: LayerKind { content.kind }

    /// The transform used after the containing snapshot has validated that an
    /// omitted transform is valid (pixel extent equals canvas extent).
    public var effectiveSpatialMapping: LayerSpatialMapping {
        spatialMapping ?? .identity
    }

    public init(
        identifier: LayerIdentifier,
        properties: LayerProperties = .defaultValue,
        content: LayerContentDescriptor,
        spatialMapping: LayerSpatialMapping? = nil
    ) {
        self.identifier = identifier
        self.properties = properties
        self.content = content
        self.spatialMapping = spatialMapping
    }

    public func reference(in imageID: ImageIdentifier) -> LayerReference {
        LayerReference(imageID: imageID, layerID: identifier)
    }
}

public enum ImageDocumentSnapshotError: Error, Equatable, Sendable {
    case duplicateLayerIdentifier(LayerIdentifier)
    case foreignLayerReference(expectedImage: ImageIdentifier, actualImage: ImageIdentifier)
    case layerExtentMismatch(
        layer: LayerIdentifier,
        expectedCanvas: ImageExtent,
        actualLayer: ImageExtent
    )
}

/// Immutable revision of a logical image document. Mutating Image ownership and
/// concurrent commit policy are deliberately separate from this value descriptor.
public struct ImageDocumentSnapshot: Hashable, Sendable {
    public let identifier: ImageIdentifier
    public let revision: ImageRevision
    public let canvas: ImageCanvasDescriptor
    public let layers: [LayerDescriptor]

    public init(
        identifier: ImageIdentifier,
        revision: ImageRevision = .initial,
        canvas: ImageCanvasDescriptor,
        layers: [LayerDescriptor]
    ) throws {
        var seen = Set<LayerIdentifier>()
        for layer in layers {
            guard seen.insert(layer.identifier).inserted else {
                throw ImageDocumentSnapshotError.duplicateLayerIdentifier(layer.identifier)
            }

            let pixelExtent: ImageExtent?
            switch layer.content {
            case let .raster(pixels):
                pixelExtent = pixels.extent
            case let .mask(mask):
                pixelExtent = mask.pixels.extent
            case let .labelMap(labelMap):
                pixelExtent = labelMap.pixels.extent
            case .annotation:
                pixelExtent = nil
            }

            if let pixelExtent,
               pixelExtent != canvas.extent,
               layer.spatialMapping == nil {
                throw ImageDocumentSnapshotError.layerExtentMismatch(
                    layer: layer.identifier,
                    expectedCanvas: canvas.extent,
                    actualLayer: pixelExtent
                )
            }
        }
        self.identifier = identifier
        self.revision = revision
        self.canvas = canvas
        self.layers = layers
    }

    public func layer(for reference: LayerReference) throws -> LayerDescriptor? {
        guard reference.imageID == identifier else {
            throw ImageDocumentSnapshotError.foreignLayerReference(
                expectedImage: identifier,
                actualImage: reference.imageID
            )
        }
        return layers.first { $0.identifier == reference.layerID }
    }
}
