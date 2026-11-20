import GeneralExecutionProtocol

public struct LayerPixelStorageBinding: Sendable {
    public let reference: LayerReference
    public let storage: PixelStorageBinding

    public init(reference: LayerReference, storage: PixelStorageBinding) {
        self.reference = reference
        self.storage = storage
    }
}

public enum ImageStorageBindingSetError: Error, Equatable, Sendable {
    case snapshotIdentityMismatch
    case foreignLayerReference(expectedImage: ImageIdentifier, actualImage: ImageIdentifier)
    case unknownLayer(LayerReference)
    case annotationLayerHasNoPixelStorage(LayerReference)
    case pixelDescriptorMismatch(LayerReference)
    case duplicateLayerBinding(LayerReference)
}

/// Resource bindings scoped to one immutable image document revision.
///
/// The set may be partial: a layer can be described in the document but not
/// currently resident/bound to an execution resource. Runtime qualification
/// must treat that as an explicit missing-resource condition when an
/// implementation requires the layer's pixels.
public struct ImageStorageBindingSet: Sendable {
    public let imageID: ImageIdentifier
    public let revision: ImageRevision

    private let bindings: [LayerIdentifier: PixelStorageBinding]

    public init(
        snapshot: ImageDocumentSnapshot,
        bindings layerBindings: [LayerPixelStorageBinding]
    ) throws {
        var indexed: [LayerIdentifier: PixelStorageBinding] = [:]

        for layerBinding in layerBindings {
            let reference = layerBinding.reference
            guard reference.imageID == snapshot.identifier else {
                throw ImageStorageBindingSetError.foreignLayerReference(
                    expectedImage: snapshot.identifier,
                    actualImage: reference.imageID
                )
            }
            guard let layer = try snapshot.layer(for: reference) else {
                throw ImageStorageBindingSetError.unknownLayer(reference)
            }
            guard let expectedPixels = Self.pixelDescriptor(for: layer.content) else {
                throw ImageStorageBindingSetError.annotationLayerHasNoPixelStorage(reference)
            }
            guard expectedPixels == layerBinding.storage.descriptor else {
                throw ImageStorageBindingSetError.pixelDescriptorMismatch(reference)
            }
            guard indexed[layer.identifier] == nil else {
                throw ImageStorageBindingSetError.duplicateLayerBinding(reference)
            }
            indexed[layer.identifier] = layerBinding.storage
        }

        self.imageID = snapshot.identifier
        self.revision = snapshot.revision
        self.bindings = indexed
    }

    public func binding(for reference: LayerReference) throws -> PixelStorageBinding? {
        guard reference.imageID == imageID else {
            throw ImageStorageBindingSetError.foreignLayerReference(
                expectedImage: imageID,
                actualImage: reference.imageID
            )
        }
        return bindings[reference.layerID]
    }

    /// Returns pixel-backed layers without an execution-resource binding.
    /// The supplied snapshot must be the exact revision this set describes.
    public func unboundPixelLayers(
        in snapshot: ImageDocumentSnapshot
    ) throws -> [LayerReference] {
        guard snapshot.identifier == imageID, snapshot.revision == revision else {
            throw ImageStorageBindingSetError.snapshotIdentityMismatch
        }

        return snapshot.layers.compactMap { layer in
            guard Self.pixelDescriptor(for: layer.content) != nil,
                  bindings[layer.identifier] == nil else {
                return nil
            }
            return layer.reference(in: imageID)
        }
    }

    public var boundLayerCount: Int { bindings.count }

    private static func pixelDescriptor(
        for content: LayerContentDescriptor
    ) -> PixelDataDescriptor? {
        switch content {
        case let .raster(pixels):
            pixels
        case let .mask(mask):
            mask.pixels
        case let .labelMap(labelMap):
            labelMap.pixels
        case .annotation:
            nil
        }
    }
}
