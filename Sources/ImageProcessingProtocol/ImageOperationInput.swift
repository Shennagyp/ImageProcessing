import Foundation

public enum ImageOperationInputTarget: Sendable {
    /// One explicitly selected layer.
    case layer(LayerReference)
    /// An explicitly ordered composite of multiple layers into one operation input.
    case composite([LayerReference])

    public var layerReferences: [LayerReference] {
        switch self {
        case let .layer(reference):
            [reference]
        case let .composite(references):
            references
        }
    }
}

public struct ImageOperationInputBinding: Sendable {
    /// Zero-based position in the operation's typed input value.
    /// This index corresponds to ImplementationResourceRole.input(index).
    public let inputIndex: Int
    public let imageState: ImageStateSnapshot
    public let target: ImageOperationInputTarget

    public init(
        inputIndex: Int,
        imageState: ImageStateSnapshot,
        target: ImageOperationInputTarget
    ) {
        self.inputIndex = inputIndex
        self.imageState = imageState
        self.target = target
    }
}

public enum ImageOperationInputContextError: Error, Equatable, Sendable {
    case emptyInputs
    case negativeInputIndex(Int)
    case duplicateInputIndex(Int)
    case emptyComposite
    case duplicateLayerReference(LayerReference)
    case foreignLayerReference(LayerReference)
    case unknownLayerReference(LayerReference)
}

/// Explicit immutable mapping from an operation's logical input positions to
/// one layer or an ordered composite of layers in exact image-state revisions.
///
/// The context deliberately does not infer a target from "the first raster
/// layer", visible layers, layer order, or a current mutable Image owner.
public struct ImageOperationInputContext: Sendable {
    public let inputs: [ImageOperationInputBinding]

    public init(inputs: [ImageOperationInputBinding]) throws {
        guard !inputs.isEmpty else {
            throw ImageOperationInputContextError.emptyInputs
        }

        var seenIndices = Set<Int>()
        for input in inputs {
            guard input.inputIndex >= 0 else {
                throw ImageOperationInputContextError.negativeInputIndex(input.inputIndex)
            }
            guard seenIndices.insert(input.inputIndex).inserted else {
                throw ImageOperationInputContextError.duplicateInputIndex(input.inputIndex)
            }

            let references = input.target.layerReferences
            if case .composite = input.target, references.isEmpty {
                throw ImageOperationInputContextError.emptyComposite
            }

            var seenReferences = Set<LayerReference>()
            for reference in references {
                guard seenReferences.insert(reference).inserted else {
                    throw ImageOperationInputContextError.duplicateLayerReference(reference)
                }
                guard reference.imageID == input.imageState.identifier else {
                    throw ImageOperationInputContextError.foreignLayerReference(reference)
                }
                do {
                    guard try input.imageState.document.layer(for: reference) != nil else {
                        throw ImageOperationInputContextError.unknownLayerReference(reference)
                    }
                } catch let error as ImageDocumentSnapshotError {
                    switch error {
                    case .foreignLayerReference:
                        throw ImageOperationInputContextError.foreignLayerReference(reference)
                    case .duplicateLayerIdentifier, .layerExtentMismatch:
                        throw ImageOperationInputContextError.unknownLayerReference(reference)
                    }
                }
            }
        }

        self.inputs = inputs.sorted { $0.inputIndex < $1.inputIndex }
    }

    public func input(at index: Int) -> ImageOperationInputBinding? {
        inputs.first { $0.inputIndex == index }
    }
}

/// An operation input that identifies the exact image snapshots and layer
/// targets represented by its typed value. Non-image OperationValue types do
/// not need to conform to this protocol.
public protocol ImageOperationInputValue: OperationResourceInputValue {
    var imageOperationInputContext: ImageOperationInputContext { get }
}

public extension ImageOperationInputValue {
    var operationInputResourceBindings: [OperationInputResourceBinding] {
        imageOperationInputContext.inputs.flatMap { input in
            input.target.layerReferences.flatMap { reference in
                let storage: PixelStorageBinding?
                do {
                    storage = try input.imageState.storageBindings.binding(for: reference)
                } catch {
                    return []
                }
                guard let storage else { return [] }
                return storage.planeBindings.compactMap {
                    OperationInputResourceBinding(
                        inputIndex: input.inputIndex,
                        resource: $0.resource,
                        access: $0.access
                    )
                }
            }
        }
    }
}
