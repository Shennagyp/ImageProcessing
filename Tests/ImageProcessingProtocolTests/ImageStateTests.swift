import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

private final class ImageStateTestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(_ descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

struct ImageStateTests {
    private func pixels() throws -> PixelDataDescriptor {
        let channel = PixelChannelDescriptor(
            identifier: try #require(ChannelIdentifier(rawValue: "intensity")),
            role: .intensity
        )
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: 8,
            sliceStrideBytes: 16,
            pixelStrideBytes: 4,
            subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        return try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 2, height: 2)),
            componentType: .float32,
            channels: [channel],
            interpretation: .scientific(ScientificDataInterpretation()),
            layout: .interleaved(plane)
        )
    }

    private func layer(
        id: String,
        pixels: PixelDataDescriptor
    ) throws -> LayerDescriptor {
        LayerDescriptor(
            identifier: try #require(LayerIdentifier(rawValue: id)),
            content: .raster(pixels)
        )
    }

    private func canvas() throws -> ImageCanvasDescriptor {
        ImageCanvasDescriptor(extent: try #require(ImageExtent(width: 2, height: 2)))
    }

    private func binding(
        pixels: PixelDataDescriptor,
        id: String
    ) throws -> PixelStorageBinding {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.image-state"))
        let device = try #require(ExecutionDeviceID(rawValue: "device.image-state"))
        let resourceDescriptor = try ExecutionResourceDescriptor(
            identifier: try #require(ExecutionResourceIdentifier(rawValue: id)),
            target: ExecutionTargetReference(providerID: provider, deviceID: device),
            kind: .buffer,
            capacityBytes: pixels.minimumRequiredStorageBytes,
            alignmentBytes: 4,
            memoryDomain: .host
        )
        let resource = ImageStateTestResource(resourceDescriptor)
        return try PixelStorageBinding(
            descriptor: pixels,
            planeBindings: [PixelPlaneResourceBinding(resource: resource, planeIndices: [0])]
        )
    }

    @Test
    func newImageHasStableIdentityAndInitialRevision() throws {
        let image = try Image(canvas: canvas(), layers: [])
        let first = image.snapshot()
        let second = image.snapshot()

        #expect(image.identifier == first.document.identifier)
        #expect(first.identifier == second.identifier)
        #expect(first.revision == .initial)
        #expect(first.document.layers.isEmpty)
        #expect(first.storageBindings.boundLayerCount == 0)
    }

    @Test
    func explicitImageIdentityAllowsInitialLayerStorageBindings() throws {
        let pixels = try pixels()
        let imageID = try #require(ImageIdentifier(rawValue: "image.initial-bound"))
        let raster = try layer(id: "layer.initial-bound", pixels: pixels)
        let reference = raster.reference(in: imageID)
        let storage = try binding(pixels: pixels, id: "resource.initial-bound")
        let image = try Image(
            identifier: imageID,
            canvas: canvas(),
            layers: [raster],
            storageBindings: [LayerPixelStorageBinding(reference: reference, storage: storage)]
        )

        let captured = image.snapshot()
        #expect(captured.identifier == imageID)
        #expect(captured.revision == .initial)
        #expect(try captured.storageBindings.binding(for: reference).map { _ in true } == true)
        #expect(try captured.storageBindings.unboundPixelLayers(in: captured.document).isEmpty)
    }

    @Test
    func replacementKeepsIdentityAndAtomicallyAdvancesRevision() throws {
        let pixels = try pixels()
        let initialLayer = try layer(id: "layer.initial", pixels: pixels)
        let replacementLayer = try layer(id: "layer.replacement", pixels: pixels)
        let image = try Image(canvas: canvas(), layers: [initialLayer])
        let oldSnapshot = image.snapshot()

        let newSnapshot = try image.replace(
            expectedRevision: .initial,
            canvas: canvas(),
            layers: [replacementLayer]
        )

        #expect(newSnapshot.identifier == oldSnapshot.identifier)
        #expect(newSnapshot.revision == ImageRevision(rawValue: 1))
        #expect(newSnapshot.document.layers == [replacementLayer])
        #expect(oldSnapshot.revision == .initial)
        #expect(oldSnapshot.document.layers == [initialLayer])
        #expect(image.snapshot().revision == ImageRevision(rawValue: 1))
    }

    @Test
    func staleReplacementIsRejectedWithoutOverwritingCurrentState() throws {
        let pixels = try pixels()
        let first = try layer(id: "layer.first", pixels: pixels)
        let second = try layer(id: "layer.second", pixels: pixels)
        let image = try Image(canvas: canvas(), layers: [first])
        _ = try image.replace(expectedRevision: .initial, canvas: canvas(), layers: [second])

        #expect(throws: ImageError.revisionConflict(
            expected: .initial,
            actual: ImageRevision(rawValue: 1)
        )) {
            try image.replace(expectedRevision: .initial, canvas: canvas(), layers: [first])
        }

        #expect(image.snapshot().document.layers == [second])
        #expect(image.snapshot().revision == ImageRevision(rawValue: 1))
    }

    @Test
    func candidateValidationFailureLeavesPublishedStateUnchanged() throws {
        let pixels = try pixels()
        let existing = try layer(id: "layer.existing", pixels: pixels)
        let duplicate = try layer(id: "layer.existing", pixels: pixels)
        let image = try Image(canvas: canvas(), layers: [existing])
        let before = image.snapshot()

        #expect(throws: ImageDocumentSnapshotError.duplicateLayerIdentifier(existing.identifier)) {
            try image.replace(
                expectedRevision: .initial,
                canvas: canvas(),
                layers: [existing, duplicate]
            )
        }

        let after = image.snapshot()
        #expect(after.document == before.document)
        #expect(after.revision == before.revision)
        #expect(after.storageBindings.boundLayerCount == before.storageBindings.boundLayerCount)
    }

    @Test
    func concurrentReplacementsFromOneRevisionCommitAtMostOnce() async throws {
        let pixels = try pixels()
        let image = try Image(canvas: canvas(), layers: [])
        let layerA = try layer(id: "layer.a", pixels: pixels)
        let layerB = try layer(id: "layer.b", pixels: pixels)
        let canvas = try canvas()

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask {
                do {
                    _ = try image.replace(expectedRevision: .initial, canvas: canvas, layers: [layerA])
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    _ = try image.replace(expectedRevision: .initial, canvas: canvas, layers: [layerB])
                    return true
                } catch {
                    return false
                }
            }

            var count = 0
            for await success in group where success {
                count += 1
            }
            return count
        }

        #expect(successes == 1)
        #expect(image.snapshot().revision == ImageRevision(rawValue: 1))
        #expect(image.snapshot().document.layers.count == 1)
    }

    @Test
    func replacementPublishesDocumentAndMatchingStorageBindingsTogether() throws {
        let pixels = try pixels()
        let image = try Image(canvas: canvas(), layers: [])
        let raster = try layer(id: "layer.raster", pixels: pixels)
        let pixelBinding = try binding(pixels: pixels, id: "resource.raster")
        let reference = raster.reference(in: image.identifier)

        let committed = try image.replace(
            expectedRevision: .initial,
            canvas: canvas(),
            layers: [raster],
            storageBindings: [
                LayerPixelStorageBinding(reference: reference, storage: pixelBinding)
            ]
        )

        #expect(committed.identifier == image.identifier)
        #expect(committed.revision == ImageRevision(rawValue: 1))
        #expect(committed.storageBindings.imageID == committed.identifier)
        #expect(committed.storageBindings.revision == committed.revision)
        #expect(try committed.storageBindings.binding(for: reference).map { _ in true } == true)
        #expect(try committed.storageBindings.unboundPixelLayers(in: committed.document).isEmpty)
    }

    @Test
    func capturedOldSnapshotRetainsResourcesAfterReplacement() throws {
        let pixels = try pixels()
        let raster = try layer(id: "layer.retained", pixels: pixels)
        let document = try ImageDocumentSnapshot(
            identifier: try #require(ImageIdentifier(rawValue: "image.retained")),
            canvas: canvas(),
            layers: [raster]
        )
        var resource: ImageStateTestResource? = try makeResource(pixels: pixels)
        weak var weakResource = resource
        let storage = try PixelStorageBinding(
            descriptor: pixels,
            planeBindings: [PixelPlaneResourceBinding(
                resource: try #require(resource),
                planeIndices: [0]
            )]
        )
        let image = try Image(
            snapshot: document,
            storageBindings: [LayerPixelStorageBinding(
                reference: raster.reference(in: document.identifier),
                storage: storage
            )]
        )
        var captured: ImageStateSnapshot? = image.snapshot()
        resource = nil

        _ = try image.replace(
            expectedRevision: .initial,
            canvas: canvas(),
            layers: []
        )
        #expect(weakResource != nil)
        #expect(captured?.storageBindings.boundLayerCount == 1)

        captured = nil
        #expect(weakResource.map { _ in true } == nil)
    }

    private func makeResource(pixels: PixelDataDescriptor) throws -> ImageStateTestResource {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.image-retain"))
        let device = try #require(ExecutionDeviceID(rawValue: "device.image-retain"))
        let descriptor = try ExecutionResourceDescriptor(
            identifier: try #require(ExecutionResourceIdentifier(rawValue: "resource.retained")),
            target: ExecutionTargetReference(providerID: provider, deviceID: device),
            kind: .buffer,
            capacityBytes: pixels.minimumRequiredStorageBytes,
            alignmentBytes: 4,
            memoryDomain: .host
        )
        return ImageStateTestResource(descriptor)
    }

    @Test
    func stateSnapshotRejectsDocumentAndBindingSetRevisionMismatch() throws {
        let imageID = try #require(ImageIdentifier(rawValue: "image.mismatch"))
        let document = try ImageDocumentSnapshot(
            identifier: imageID,
            revision: ImageRevision(rawValue: 1),
            canvas: canvas(),
            layers: []
        )
        let olderDocument = try ImageDocumentSnapshot(
            identifier: imageID,
            revision: .initial,
            canvas: canvas(),
            layers: []
        )
        let oldBindings = try ImageStorageBindingSet(snapshot: olderDocument, bindings: [])

        #expect(throws: ImageStateSnapshotError.storageBindingSetMismatch) {
            try ImageStateSnapshot(document: document, storageBindings: oldBindings)
        }
    }
}
