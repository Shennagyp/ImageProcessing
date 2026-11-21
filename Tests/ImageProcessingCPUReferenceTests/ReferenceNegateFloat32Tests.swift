import GeneralExecutionProtocol
import ImageProcessingProtocol
import ImageProcessingRuntime
import ImageProcessingCPUProvider
import ImageProcessingReferenceOperations
import Testing

struct ReferenceNegateFloat32Tests {
    @Test
    func resolvesExecutesAndReturnsNewFloat32ImageRevision() async throws {
        let provider = CPUExecutionProvider()
        let providers = ExecutionProviderRegistry()
        try await providers.register(provider)
        let registration = try #require(await providers.registeredProviders().first)
        let context = try await providers.makeContext(
            for: CPUExecutionProvider.target,
            expecting: registration.descriptor,
            registrationIdentifier: registration.registrationIdentifier
        )
        let allocator = try #require(context as? any ExecutionResourceAllocatingContext)

        let extent = try #require(ImageExtent(width: 2, height: 2))
        let pixels = try makePixels(extent: extent)
        let inputRequest = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: pixels.minimumRequiredStorageBytes,
            minimumAlignmentBytes: 4,
            memoryDomain: .host
        ))
        let inputResourceValue = try await allocator.allocateResource(inputRequest)
        let inputResource = try #require(inputResourceValue as? CPUBufferResource)
        let inputSamples: [Float] = [1.5, -2.0, 0.0, 4.0]
        try inputResource.writeBytes(encode(inputSamples))

        let imageID = ImageIdentifier.generate()
        let layer = LayerDescriptor(
            identifier: LayerIdentifier.generate(),
            content: .raster(pixels)
        )
        let layerReference = layer.reference(in: imageID)
        let inputStorage = try PixelStorageBinding(
            descriptor: pixels,
            planeBindings: [
                PixelPlaneResourceBinding(
                    resource: inputResource,
                    planeIndices: [0],
                    access: .read
                )
            ]
        )
        let image = try Image(
            identifier: imageID,
            canvas: ImageCanvasDescriptor(extent: extent),
            layers: [layer],
            storageBindings: [
                LayerPixelStorageBinding(
                    reference: layerReference,
                    storage: inputStorage
                )
            ]
        )
        let inputState = image.snapshot()
        let inputContext = try ImageOperationInputContext(inputs: [
            ImageOperationInputBinding(
                inputIndex: 0,
                imageState: inputState,
                target: .layer(layerReference)
            )
        ])
        let input = ReferenceNegateFloat32Input(
            imageOperationInputContext: inputContext
        )

        let implementations = OperationImplementationRegistry()
        try await implementations.register(CPUReferenceNegateFloat32Implementation())
        let workLedger = RuntimeWorkLedger()
        let environments = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: workLedger
        )
        let resolver = CommonQualificationResolver(
            implementations: implementations,
            providers: providers
        )
        let operationCoordinator = OperationExecutionCoordinator(
            implementations: implementations,
            providers: providers,
            workLedger: workLedger
        )
        let functionCoordinator = ImageFunctionExecutionCoordinator(
            resolver: resolver,
            environments: environments,
            operations: operationCoordinator
        )
        let function = ImageFunction(operation: ReferenceNegateFloat32())
        let freshness = try #require(QualificationFreshnessPolicy(
            maximumSnapshotAge: 60,
            maximumProviderStateAge: 60,
            maximumDeviceStateAge: 60
        ))

        let result = try await functionCoordinator.executeWithReport(
            function,
            input: input,
            platform: ExecutionPlatformDescriptor(
                operatingSystem: "testOS",
                architecture: "testArchitecture"
            ),
            freshness: freshness
        )

        #expect(result.steps.count == 1)
        #expect(result.steps[0].implementation.identifier.rawValue
            == "image-processing.reference.cpu.negate-float32")
        #expect(result.steps[0].target == CPUExecutionProvider.target)

        let outputState = result.output.imageOperationOutputDescriptor.imageState
        #expect(outputState.identifier == imageID)
        #expect(outputState.revision.rawValue == inputState.revision.rawValue + 1)
        #expect(outputState.document.layers.map(\.identifier) == [layer.identifier])
        #expect(inputResource.copyBytes() == encode(inputSamples))

        let outputBinding = try #require(
            try outputState.storageBindings.binding(for: layerReference)
        )
        let outputResource = try #require(
            outputBinding.planeBindings.first?.resource as? CPUBufferResource
        )
        #expect(decode(outputResource.copyBytes(), count: 4) == [-1.5, 2.0, 0.0, -4.0])
        #expect(outputResource.descriptor.providerRegistrationIdentifier
            == registration.registrationIdentifier)
        #expect(await workLedger.activeLeaseCount == 0)
    }

    private func makePixels(extent: ImageExtent) throws -> PixelDataDescriptor {
        let channel = PixelChannelDescriptor(
            identifier: try #require(ChannelIdentifier(rawValue: "intensity")),
            role: .intensity
        )
        let bytesPerPixel = PixelComponentType.float32.bytesPerComponent
        let rowStride = extent.width * bytesPerPixel
        let sliceStride = rowStride * extent.height
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: rowStride,
            sliceStrideBytes: sliceStride,
            pixelStrideBytes: bytesPerPixel,
            requiredAlignmentBytes: 4,
            subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        return try PixelDataDescriptor(
            extent: extent,
            componentType: .float32,
            channels: [channel],
            interpretation: .scientific(ScientificDataInterpretation()),
            layout: .interleaved(plane)
        )
    }

    private func encode(_ values: [Float]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * MemoryLayout<Float>.size)
        for value in values {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    private func decode(_ bytes: [UInt8], count: Int) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            var bits: UInt32 = 0
            let offset = index * MemoryLayout<Float>.size
            withUnsafeMutableBytes(of: &bits) { destination in
                for byte in 0..<MemoryLayout<Float>.size {
                    destination[byte] = bytes[offset + byte]
                }
            }
            values.append(Float(bitPattern: bits))
        }
        return values
    }
}
