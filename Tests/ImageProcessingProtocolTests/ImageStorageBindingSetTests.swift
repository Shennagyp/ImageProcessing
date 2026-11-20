import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

private final class ImageBindingTestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(_ descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

struct ImageStorageBindingSetTests {
    private func pixels(
        width: UInt64 = 2,
        height: UInt64 = 2,
        component: PixelComponentType = .float32
    ) throws -> PixelDataDescriptor {
        let channel = PixelChannelDescriptor(
            identifier: try #require(ChannelIdentifier(rawValue: "intensity")),
            role: .intensity
        )
        let rowBytes = width * component.bytesPerComponent
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: rowBytes,
            sliceStrideBytes: rowBytes * height,
            pixelStrideBytes: component.bytesPerComponent,
            subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        return try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: width, height: height)),
            componentType: component,
            channels: [channel],
            interpretation: .scientific(ScientificDataInterpretation()),
            layout: .interleaved(plane)
        )
    }

    private func storage(for descriptor: PixelDataDescriptor, id: String) throws -> PixelStorageBinding {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.image-storage"))
        let device = try #require(ExecutionDeviceID(rawValue: "device.image-storage"))
        let target = ExecutionTargetReference(providerID: provider, deviceID: device)
        let resourceDescriptor = try ExecutionResourceDescriptor(
            identifier: try #require(ExecutionResourceIdentifier(rawValue: id)),
            target: target,
            kind: .buffer,
            capacityBytes: descriptor.minimumRequiredStorageBytes,
            alignmentBytes: 4,
            memoryDomain: .host
        )
        let resource = ImageBindingTestResource(resourceDescriptor)
        return try PixelStorageBinding(
            descriptor: descriptor,
            planeBindings: [PixelPlaneResourceBinding(resource: resource, planeIndices: [0])]
        )
    }

    private func snapshot(
        revision: UInt64 = 0,
        layers: [LayerDescriptor]
    ) throws -> ImageDocumentSnapshot {
        try ImageDocumentSnapshot(
            identifier: try #require(ImageIdentifier(rawValue: "image.document")),
            revision: ImageRevision(rawValue: revision),
            canvas: ImageCanvasDescriptor(extent: try #require(ImageExtent(width: 2, height: 2))),
            layers: layers
        )
    }

    private func rasterLayer(
        id: String = "layer.raster",
        pixels: PixelDataDescriptor
    ) throws -> LayerDescriptor {
        LayerDescriptor(
            identifier: try #require(LayerIdentifier(rawValue: id)),
            content: .raster(pixels)
        )
    }

    @Test
    func setBindsStorageToTheExactLayerAndDescriptor() throws {
        let pixels = try pixels()
        let layer = try rasterLayer(pixels: pixels)
        let snapshot = try snapshot(layers: [layer])
        let reference = layer.reference(in: snapshot.identifier)
        let storage = try storage(for: pixels, id: "resource.raster")
        let set = try ImageStorageBindingSet(
            snapshot: snapshot,
            bindings: [LayerPixelStorageBinding(reference: reference, storage: storage)]
        )

        #expect(try set.binding(for: reference).map { _ in true } == true)
        #expect(set.boundLayerCount == 1)
        #expect(try set.unboundPixelLayers(in: snapshot).isEmpty)
    }

    @Test
    func partialSetReportsUnboundPixelLayersButNotAnnotations() throws {
        let pixels = try pixels()
        let bound = try rasterLayer(id: "layer.bound", pixels: pixels)
        let unbound = try rasterLayer(id: "layer.unbound", pixels: pixels)
        let annotation = LayerDescriptor(
            identifier: try #require(LayerIdentifier(rawValue: "layer.annotations")),
            content: .annotation(AnnotationDataDescriptor(
                schema: try #require(AnnotationSchemaIdentifier(rawValue: "annotations.v1")),
                coordinateSpace: .pixel
            ))
        )
        let snapshot = try snapshot(layers: [bound, unbound, annotation])
        let storage = try storage(for: pixels, id: "resource.bound")
        let set = try ImageStorageBindingSet(
            snapshot: snapshot,
            bindings: [LayerPixelStorageBinding(
                reference: bound.reference(in: snapshot.identifier),
                storage: storage
            )]
        )

        #expect(set.boundLayerCount == 1)
        #expect(try set.unboundPixelLayers(in: snapshot) == [unbound.reference(in: snapshot.identifier)])
    }

    @Test
    func setRejectsStorageDescriptorThatDiffersFromLayerSemantics() throws {
        let layerPixels = try pixels(width: 2)
        let differentPixels = try pixels(width: 3)
        let layer = try rasterLayer(pixels: layerPixels)
        let snapshot = try snapshot(layers: [layer])
        let wrongStorage = try storage(for: differentPixels, id: "resource.wrong-descriptor")

        #expect(throws: ImageStorageBindingSetError.pixelDescriptorMismatch(
            layer.reference(in: snapshot.identifier)
        )) {
            try ImageStorageBindingSet(
                snapshot: snapshot,
                bindings: [LayerPixelStorageBinding(
                    reference: layer.reference(in: snapshot.identifier),
                    storage: wrongStorage
                )]
            )
        }
    }

    @Test
    func setRejectsForeignAndUnknownLayerReferences() throws {
        let pixels = try pixels()
        let layer = try rasterLayer(pixels: pixels)
        let snapshot = try snapshot(layers: [layer])
        let storage = try storage(for: pixels, id: "resource.foreign")
        let foreignImage = try #require(ImageIdentifier(rawValue: "image.foreign"))
        let foreign = LayerReference(imageID: foreignImage, layerID: layer.identifier)

        #expect(throws: ImageStorageBindingSetError.foreignLayerReference(
            expectedImage: snapshot.identifier,
            actualImage: foreignImage
        )) {
            try ImageStorageBindingSet(
                snapshot: snapshot,
                bindings: [LayerPixelStorageBinding(reference: foreign, storage: storage)]
            )
        }

        let missingLayer = try #require(LayerIdentifier(rawValue: "layer.missing"))
        let missing = LayerReference(imageID: snapshot.identifier, layerID: missingLayer)
        #expect(throws: ImageStorageBindingSetError.unknownLayer(missing)) {
            try ImageStorageBindingSet(
                snapshot: snapshot,
                bindings: [LayerPixelStorageBinding(reference: missing, storage: storage)]
            )
        }
    }

    @Test
    func setRejectsTryingToBindStorageToAnnotationLayer() throws {
        let pixels = try pixels()
        let annotation = LayerDescriptor(
            identifier: try #require(LayerIdentifier(rawValue: "layer.annotations")),
            content: .annotation(AnnotationDataDescriptor(
                schema: try #require(AnnotationSchemaIdentifier(rawValue: "contours.v1")),
                coordinateSpace: .normalizedCanvas
            ))
        )
        let snapshot = try snapshot(layers: [annotation])
        let storage = try storage(for: pixels, id: "resource.annotation-invalid")

        #expect(throws: ImageStorageBindingSetError.annotationLayerHasNoPixelStorage(
            annotation.reference(in: snapshot.identifier)
        )) {
            try ImageStorageBindingSet(
                snapshot: snapshot,
                bindings: [LayerPixelStorageBinding(
                    reference: annotation.reference(in: snapshot.identifier),
                    storage: storage
                )]
            )
        }
    }

    @Test
    func setIsBoundToOneExactRevision() throws {
        let pixels = try pixels()
        let layer = try rasterLayer(pixels: pixels)
        let revisionOne = try snapshot(revision: 1, layers: [layer])
        let revisionZero = try snapshot(revision: 0, layers: [layer])
        let storage = try storage(for: pixels, id: "resource.revision")
        let set = try ImageStorageBindingSet(
            snapshot: revisionOne,
            bindings: [LayerPixelStorageBinding(
                reference: layer.reference(in: revisionOne.identifier),
                storage: storage
            )]
        )

        #expect(throws: ImageStorageBindingSetError.snapshotIdentityMismatch) {
            try set.unboundPixelLayers(in: revisionZero)
        }
    }

    @Test
    func duplicateLayerBindingsAreRejected() throws {
        let pixels = try pixels()
        let layer = try rasterLayer(pixels: pixels)
        let snapshot = try snapshot(layers: [layer])
        let reference = layer.reference(in: snapshot.identifier)
        let storageA = try storage(for: pixels, id: "resource.duplicate.a")
        let storageB = try storage(for: pixels, id: "resource.duplicate.b")

        #expect(throws: ImageStorageBindingSetError.duplicateLayerBinding(reference)) {
            try ImageStorageBindingSet(
                snapshot: snapshot,
                bindings: [
                    LayerPixelStorageBinding(reference: reference, storage: storageA),
                    LayerPixelStorageBinding(reference: reference, storage: storageB)
                ]
            )
        }
    }
}
