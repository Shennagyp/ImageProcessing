import GeneralExecutionProtocol
@testable import ImageProcessingProtocol
import Testing

private struct OutputValidationInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "output-validation.input")!
    let expectedWidth: UInt64
}

private struct OutputValidationOutput: ImageOperationOutputValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "output-validation.image")!
    let imageOperationOutputDescriptor: ImageOperationOutputDescriptor
}

private struct MissingDescriptorOutput: OperationValue {
    static let typeIdentifier = OutputValidationOutput.typeIdentifier
}

private final class OutputValidationResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(_ descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

private struct OutputValidationOperation: ImageOperation {
    typealias Input = OutputValidationInput
    typealias Output = OutputValidationOutput

    static let outputDomain = PixelRepresentationDomain(
        layouts: [.interleaved],
        interpretations: [.color]
    )

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "output-validation.operation")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        precisionContract: OperationPrecisionContract(outputStorage: [.uint8, .uint16]),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate
        ),
        layerContract: OperationLayerContract(producedOutputKinds: [.raster]),
        pixelDataContract: OperationPixelDataContract(output: outputDomain)
    )

    func validateOutput(
        _ output: Output,
        for input: Input
    ) throws {
        guard output.imageOperationOutputDescriptor.document.canvas.extent.width == input.expectedWidth else {
            throw OperationOutputValidationError.operationPostconditionFailed("width mismatch")
        }
    }
}

private enum OutputValidationFixture {
    static let implementation = ImplementationSpecification(
        identifier: OperationImplementationIdentifier(rawValue: "output-validation.implementation")!,
        version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        operationIdentifier: OutputValidationOperation.specification.identifier,
        supportedOperationVersions: SemanticVersionRange(
            lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
        )!,
        inputType: OutputValidationInput.typeIdentifier,
        outputType: OutputValidationOutput.typeIdentifier,
        precisionSupport: OperationPrecisionContract(outputStorage: [.uint8]),
        determinism: .deterministic,
        numericalSupport: .init(
            roundingModes: [.nearestEven],
            overflowBehaviors: [.saturate],
            outputRangeBehaviors: [.preserve]
        ),
        layerSupport: ImplementationLayerSupport(outputKinds: [.raster]),
        pixelDataSupport: OperationPixelDataContract(
            output: OutputValidationOperation.outputDomain
        )
    )

    static func output(
        componentType: PixelComponentType = .uint8,
        layerKind: LayerKind = .raster,
        bindStorage: Bool = true
    ) throws -> OutputValidationOutput {
        let imageID = try #require(ImageIdentifier(rawValue: "output-validation.image"))
        let layerID = try #require(LayerIdentifier(rawValue: "output-validation.layer"))
        let extent = try #require(ImageExtent(width: 1, height: 1))
        let content: LayerContentDescriptor

        if layerKind == .annotation {
            content = .annotation(
                AnnotationDataDescriptor(
                    schema: try #require(AnnotationSchemaIdentifier(rawValue: "output-validation.annotation")),
                    coordinateSpace: .pixel
                )
            )
        } else {
            let channels = [
                PixelChannelDescriptor(
                    identifier: try #require(ChannelIdentifier(rawValue: "red")),
                    role: .red
                ),
                PixelChannelDescriptor(
                    identifier: try #require(ChannelIdentifier(rawValue: "green")),
                    role: .green
                ),
                PixelChannelDescriptor(
                    identifier: try #require(ChannelIdentifier(rawValue: "blue")),
                    role: .blue
                )
            ]
            let bytesPerComponent = componentType.bytesPerComponent
            let plane = PixelPlaneLayout(
                byteOffset: 0,
                rowStrideBytes: 3 * bytesPerComponent,
                sliceStrideBytes: 3 * bytesPerComponent,
                pixelStrideBytes: 3 * bytesPerComponent,
                subsampling: try #require(PixelSubsampling()),
                channelIndices: [0, 1, 2]
            )
            let pixels = try PixelDataDescriptor(
                extent: extent,
                componentType: componentType,
                channels: channels,
                interpretation: .color(
                    ColorDataInterpretation(
                        colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                        channelModel: .rgb,
                        transferFunction: .sRGB,
                        alphaMode: .none
                    )
                ),
                layout: .interleaved(plane)
            )
            content = .raster(pixels)
        }

        let layer = LayerDescriptor(identifier: layerID, content: content)
        let document = try ImageDocumentSnapshot(
            identifier: imageID,
            canvas: ImageCanvasDescriptor(extent: extent),
            layers: [layer]
        )

        var layerBindings: [LayerPixelStorageBinding] = []
        if bindStorage, case let .raster(pixelDescriptor) = content {
            let providerID = try #require(ExecutionProviderID(rawValue: "output-validation.provider"))
            let deviceID = try #require(ExecutionDeviceID(rawValue: "output-validation.device"))
            let resourceDescriptor = try ExecutionResourceDescriptor(
                identifier: try #require(ExecutionResourceIdentifier(rawValue: "output-validation.resource")),
                target: ExecutionTargetReference(providerID: providerID, deviceID: deviceID),
                kind: .buffer,
                capacityBytes: pixelDescriptor.minimumRequiredStorageBytes,
                alignmentBytes: 256,
                memoryDomain: .host
            )
            let resource = OutputValidationResource(resourceDescriptor)
            let storage = try PixelStorageBinding(
                descriptor: pixelDescriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(
                        resource: resource,
                        planeIndices: [0],
                        access: .readWrite
                    )
                ]
            )
            layerBindings.append(
                LayerPixelStorageBinding(
                    reference: layer.reference(in: imageID),
                    storage: storage
                )
            )
        }

        let storageBindings = try ImageStorageBindingSet(
            snapshot: document,
            bindings: layerBindings
        )
        let imageState = try ImageStateSnapshot(
            document: document,
            storageBindings: storageBindings
        )
        let descriptor = try ImageOperationOutputDescriptor(
            imageState: imageState,
            producedLayers: [layer.reference(in: imageID)]
        )
        return OutputValidationOutput(imageOperationOutputDescriptor: descriptor)
    }
}

struct OperationOutputValidationTests {
    private func step() -> AnyImageOperationStep {
        AnyImageOperationStep(operation: OutputValidationOperation())
    }

    @Test
    func producedImageLayerMatchesOperationAndImplementationOutputContracts() throws {
        let output = try OutputValidationFixture.output()
        try step().validateOutput(
            output,
            for: OutputValidationInput(expectedWidth: 1),
            implementation: OutputValidationFixture.implementation
        )
    }

    @Test
    func producedPixelLayerMustRetainItsStorageBinding() throws {
        let output = try OutputValidationFixture.output(bindStorage: false)
        let reference = output.imageOperationOutputDescriptor.producedLayers[0]

        #expect(throws: OperationOutputValidationError.producedPixelLayerStorageBindingRequired(
            reference
        )) {
            try step().validateOutput(
                output,
                for: OutputValidationInput(expectedWidth: 1),
                implementation: OutputValidationFixture.implementation
            )
        }
    }

    @Test
    func outputDescriptorRetainsStorageInItsExactImageRevision() throws {
        let output = try OutputValidationFixture.output()

        #expect(output.imageOperationOutputDescriptor.imageState.revision == .initial)
        #expect(output.imageOperationOutputDescriptor.storageBindings.boundLayerCount == 1)
    }

    @Test
    func producedLayerKindMustMatchOperationContract() throws {
        let output = try OutputValidationFixture.output(layerKind: .annotation)

        #expect(throws: OperationOutputValidationError.producedLayerKindUnsupported(
            output.imageOperationOutputDescriptor.producedLayers[0],
            .annotation
        )) {
            try step().validateOutput(
                output,
                for: OutputValidationInput(expectedWidth: 1),
                implementation: OutputValidationFixture.implementation
            )
        }
    }

    @Test
    func outputStoragePrecisionMustMatchImplementationSupport() throws {
        let output = try OutputValidationFixture.output(componentType: .uint16)

        #expect(throws: OperationOutputValidationError.implementationOutputStoragePrecisionUnsupported(
            output.imageOperationOutputDescriptor.producedLayers[0],
            .uint16
        )) {
            try step().validateOutput(
                output,
                for: OutputValidationInput(expectedWidth: 1),
                implementation: OutputValidationFixture.implementation
            )
        }
    }

    @Test
    func operationTypedPostconditionRunsAfterDescriptorValidation() throws {
        let output = try OutputValidationFixture.output()

        #expect(throws: OperationOutputValidationError.operationPostconditionFailed("width mismatch")) {
            try step().validateOutput(
                output,
                for: OutputValidationInput(expectedWidth: 2),
                implementation: OutputValidationFixture.implementation
            )
        }
    }

    @Test
    func outputDescriptorIsRequiredWhenOperationDeclaresImageOutput() throws {
        #expect(throws: OperationOutputValidationError.imageOutputDescriptorRequired) {
            try step().validateOutput(
                MissingDescriptorOutput(),
                for: OutputValidationInput(expectedWidth: 1),
                implementation: OutputValidationFixture.implementation
            )
        }
    }
}
