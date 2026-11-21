import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol
@testable import ImageProcessingRuntime
import Testing

private struct RasterQualificationInput: ImageOperationInputValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "input-qualification.raster")!
    let imageOperationInputContext: ImageOperationInputContext
}

private struct WrongRasterQualificationInput: ImageOperationInputValue {
    // Deliberately reuses the semantic identifier while having another Swift type.
    static let typeIdentifier = RasterQualificationInput.typeIdentifier
    let imageOperationInputContext: ImageOperationInputContext
}

private struct PlainRasterQualificationInput: OperationValue {
    static let typeIdentifier = RasterQualificationInput.typeIdentifier
}

private struct GenericBufferInput: OperationResourceInputValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "input-qualification.generic-buffer")!
    let operationInputResourceBindings: [OperationInputResourceBinding]
}

private struct GenericBufferOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "input-qualification.generic-output")!
}

private struct GenericBufferOperation: ImageOperation {
    typealias Input = GenericBufferInput
    typealias Output = GenericBufferOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "input-qualification.generic-resource-operation")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!
    )
}

private struct GenericBufferImplementation: ImageOperationImplementation {
    typealias Operation = GenericBufferOperation

    let specification = ImplementationSpecification(
        identifier: OperationImplementationIdentifier(rawValue: "input-qualification.generic-resource-implementation")!,
        version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        operationIdentifier: GenericBufferOperation.specification.identifier,
        supportedOperationVersions: SemanticVersionRange(
            lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
        )!,
        inputType: GenericBufferInput.typeIdentifier,
        outputType: GenericBufferOutput.typeIdentifier,
        requiredProviderID: RasterQualificationFixture.providerID,
        resourceRequirements: [
            ImplementationResourceRequirement(
                role: .input(0),
                kind: .buffer,
                allowedMemoryDomains: [.host],
                minimumCapacityBytes: 64,
                minimumAlignmentBytes: 16,
                access: .read
            )
        ]
    )

    func execute(
        operation: GenericBufferOperation,
        input: GenericBufferInput,
        context: any ExecutionContext
    ) async throws -> GenericBufferOutput {
        GenericBufferOutput()
    }
}

private struct RasterQualificationOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "input-qualification.output")!
}

private enum RasterQualificationFixture {
    static let providerID = ExecutionProviderID(rawValue: "provider.input-qualification")!
    static let implementationID = OperationImplementationIdentifier(rawValue: "input-qualification.raster.cpu")!
    static let colorSpace = ColorSpaceIdentifier(rawValue: "input-qualification.srgb")!

    static let pixelDomain = PixelRepresentationDomain(
        layouts: [.interleaved],
        interpretations: [.color],
        colorModels: [.rgb],
        alphaModes: [.none],
        transferFunctions: [.sRGB],
        colorSpaces: [colorSpace],
        channelRoles: [.red, .green, .blue],
        channelOrders: [[.red, .green, .blue]],
        subsamplingFactors: [PixelSubsampling()!],
        sampleOrigins: [.zero]
    )
}

private struct RasterQualificationOperation: ImageOperation {
    typealias Input = RasterQualificationInput
    typealias Output = RasterQualificationOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "input-qualification.raster-operation")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        precisionContract: OperationPrecisionContract(
            inputStorage: [.uint8],
            computation: [.float32],
            outputStorage: [.uint8]
        ),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate
        ),
        layerContract: OperationLayerContract(
            acceptedInputKinds: [.raster],
            producedOutputKinds: [.raster]
        ),
        pixelDataContract: OperationPixelDataContract(
            input: RasterQualificationFixture.pixelDomain,
            output: RasterQualificationFixture.pixelDomain
        )
    )
}

private struct RasterQualificationImplementation: ImageOperationImplementation {
    typealias Operation = RasterQualificationOperation

    let specification: ImplementationSpecification

    init(
        minimumInputCapacity: UInt64 = 1,
        requiresImport: Bool = false
    ) {
        specification = ImplementationSpecification(
            identifier: RasterQualificationFixture.implementationID,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: RasterQualificationOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: RasterQualificationInput.typeIdentifier,
            outputType: RasterQualificationOutput.typeIdentifier,
            requiredProviderID: RasterQualificationFixture.providerID,
            precisionSupport: OperationPrecisionContract(
                inputStorage: [.uint8],
                computation: [.float32],
                outputStorage: [.uint8]
            ),
            determinism: .deterministic,
            numericalSupport: ImplementationNumericalSupport(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve]
            ),
            layerSupport: ImplementationLayerSupport(
                inputKinds: [.raster],
                outputKinds: [.raster]
            ),
            pixelDataSupport: OperationPixelDataContract(
                input: RasterQualificationFixture.pixelDomain,
                output: RasterQualificationFixture.pixelDomain
            ),
            resourceRequirements: [
                ImplementationResourceRequirement(
                    role: .input(0),
                    kind: .buffer,
                    allowedMemoryDomains: [.host],
                    minimumCapacityBytes: minimumInputCapacity,
                    minimumAlignmentBytes: 16,
                    access: .read,
                    requiresImport: requiresImport
                )
            ]
        )
    }

    func execute(
        operation: RasterQualificationOperation,
        input: RasterQualificationInput,
        context: any ExecutionContext
    ) async throws -> RasterQualificationOutput {
        RasterQualificationOutput()
    }
}

private final class InputQualificationResource: ExecutionResource, Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(
        target: ExecutionTargetReference,
        identifier: String,
        capacityBytes: UInt64,
        memoryDomain: ExecutionMemoryDomain = .host,
        kind: ExecutionResourceKind = .buffer,
        alignmentBytes: UInt64 = 16
    ) throws {
        descriptor = try ExecutionResourceDescriptor(
            identifier: ExecutionResourceIdentifier(rawValue: identifier)!,
            target: target,
            kind: kind,
            capacityBytes: capacityBytes,
            alignmentBytes: alignmentBytes,
            memoryDomain: memoryDomain
        )
    }
}

private struct InputQualificationDevice: ExecutionDevice {
    let descriptor: ExecutionDeviceDescriptor
    let capturedAt: Date

    func observeState() async throws -> ExecutionDeviceStateSnapshot {
        ExecutionDeviceStateSnapshot(capturedAt: capturedAt, availability: .available)
    }
}

private struct InputQualificationContext: ExecutionContext {
    let target: ExecutionTargetReference
}

private struct InputQualificationProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor
    let device: InputQualificationDevice
    let capturedAt: Date

    init(target: ExecutionTargetReference, capturedAt: Date) {
        let version = SemanticVersion(major: 1, minor: 0, patch: 0)!
        descriptor = ExecutionProviderDescriptor(
            identifier: target.providerID,
            version: version,
            displayName: "Input qualification provider"
        )
        device = InputQualificationDevice(
            descriptor: ExecutionDeviceDescriptor(
                identifier: target.deviceID!,
                providerID: target.providerID,
                displayName: "Input qualification device"
            ),
            capturedAt: capturedAt
        )
        self.capturedAt = capturedAt
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(capturedAt: capturedAt, availability: .available)
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        [device]
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        InputQualificationContext(target: target)
    }
}

private struct ImageInputFixture {
    let context: ImageOperationInputContext
    let resource: InputQualificationResource?
    let reference: LayerReference
    let descriptor: PixelDataDescriptor
}

struct OperationInputQualificationTests {
    private let now = Date(timeIntervalSince1970: 500_000)

    private func target(
        provider: ExecutionProviderID = RasterQualificationFixture.providerID,
        device: String = "device.input-qualification"
    ) -> ExecutionTargetReference {
        ExecutionTargetReference(
            providerID: provider,
            deviceID: ExecutionDeviceID(rawValue: device)!
        )
    }

    private func pixelDescriptor(
        componentType: PixelComponentType = .uint8,
        colorSpace: ColorSpaceIdentifier = RasterQualificationFixture.colorSpace
    ) throws -> PixelDataDescriptor {
        let extent = try #require(ImageExtent(width: 2, height: 2))
        let pixelStride = 3 * componentType.bytesPerComponent
        let rowStride = 2 * pixelStride
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: rowStride,
            sliceStrideBytes: 2 * rowStride,
            pixelStrideBytes: pixelStride,
            requiredAlignmentBytes: 1,
            subsampling: try #require(PixelSubsampling()),
            sampleOrigin: .zero,
            channelIndices: [0, 1, 2]
        )
        let channels = [
            PixelChannelDescriptor(identifier: ChannelIdentifier(rawValue: "red")!, role: .red),
            PixelChannelDescriptor(identifier: ChannelIdentifier(rawValue: "green")!, role: .green),
            PixelChannelDescriptor(identifier: ChannelIdentifier(rawValue: "blue")!, role: .blue)
        ]
        return try PixelDataDescriptor(
            extent: extent,
            componentType: componentType,
            channels: channels,
            interpretation: .color(ColorDataInterpretation(
                colorSpace: colorSpace,
                channelModel: .rgb,
                transferFunction: .sRGB,
                alphaMode: .none
            )),
            layout: .interleaved(plane)
        )
    }

    private func imageInput(
        componentType: PixelComponentType = .uint8,
        colorSpace: ColorSpaceIdentifier = RasterQualificationFixture.colorSpace,
        resourceTarget: ExecutionTargetReference? = nil,
        bindResource: Bool = true,
        resourceCapacity: UInt64? = nil,
        resourceKind: ExecutionResourceKind = .buffer,
        resourceMemoryDomain: ExecutionMemoryDomain = .host
    ) throws -> ImageInputFixture {
        let descriptor = try pixelDescriptor(
            componentType: componentType,
            colorSpace: colorSpace
        )
        let imageID = ImageIdentifier.generate()
        let layerID = LayerIdentifier.generate()
        let reference = LayerReference(imageID: imageID, layerID: layerID)
        let currentTarget = resourceTarget ?? target()

        var resource: InputQualificationResource?
        var storageBindings: [LayerPixelStorageBinding] = []
        if bindResource {
            let actualResource = try InputQualificationResource(
                target: currentTarget,
                identifier: "pixels.\(imageID.rawValue)",
                capacityBytes: resourceCapacity ?? descriptor.minimumRequiredStorageBytesByPlane[0],
                memoryDomain: resourceMemoryDomain,
                kind: resourceKind
            )
            resource = actualResource
            let storage = try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(
                        resource: actualResource,
                        planeIndices: [0],
                        access: .read
                    )
                ]
            )
            storageBindings = [
                LayerPixelStorageBinding(reference: reference, storage: storage)
            ]
        }

        let image = try Image(
            identifier: imageID,
            canvas: ImageCanvasDescriptor(extent: descriptor.extent),
            layers: [
                LayerDescriptor(
                    identifier: layerID,
                    content: .raster(descriptor)
                )
            ],
            storageBindings: storageBindings
        )
        let inputContext = try ImageOperationInputContext(inputs: [
            ImageOperationInputBinding(
                inputIndex: 0,
                imageState: image.snapshot(),
                target: .layer(reference)
            )
        ])
        return ImageInputFixture(
            context: inputContext,
            resource: resource,
            reference: reference,
            descriptor: descriptor
        )
    }

    private func makeReport(
        input: any OperationValue,
        implementation: RasterQualificationImplementation = RasterQualificationImplementation(),
        candidateTarget: ExecutionTargetReference? = nil
    ) async throws -> OperationImplementationQualificationReport {
        let target = candidateTarget ?? target()
        let implementationRegistry = OperationImplementationRegistry()
        try await implementationRegistry.register(implementation)

        let providerRegistry = ExecutionProviderRegistry()
        try await providerRegistry.register(InputQualificationProvider(target: target, capturedAt: now))

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: ExecutionPlatformDescriptor(
                operatingSystem: "input-qualification-os",
                architecture: "input-qualification-arch"
            ),
            capturedAt: now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        return try await resolver.evaluate(
            step: AnyImageOperationStep(operation: RasterQualificationOperation()),
            input: input,
            policy: .unrestricted,
            environment: environment,
            freshness: QualificationFreshnessPolicy(
                maximumSnapshotAge: 60,
                maximumProviderStateAge: 60,
                maximumDeviceStateAge: 60
            )!,
            now: now
        )
    }

    @Test
    func actualImageInputAndBoundPixelResourceQualifyTogether() async throws {
        let inputFixture = try imageInput()
        let input = RasterQualificationInput(imageOperationInputContext: inputFixture.context)
        let report = try await makeReport(input: input)

        let candidate = try #require(report.qualifiedCandidates.first)
        #expect(candidate.imageInputContext?.inputs.first?.imageState.revision == .initial)
        #expect(candidate.imageInputContext?.inputs.first?.target.layerReferences == [inputFixture.reference])
        #expect(candidate.inputResourceAccesses.count == 1)
        #expect(candidate.inputResourceAccesses.first?.resource.descriptor.reference == inputFixture.resource?.descriptor.reference)
    }

    @Test
    func imageInputContextPreservesSparseLogicalInputIndices() throws {
        let inputFixture = try imageInput()
        let input = try #require(inputFixture.context.inputs.first)
        let sparse = try ImageOperationInputContext(inputs: [
            ImageOperationInputBinding(
                inputIndex: 3,
                imageState: input.imageState,
                target: input.target
            )
        ])

        #expect(sparse.input(at: 0) == nil)
        #expect(sparse.input(at: 3)?.target.layerReferences == [inputFixture.reference])
    }

    @Test
    func operationPixelRepresentationIsCheckedAgainstActualInput() async throws {
        let displayP3 = ColorSpaceIdentifier(rawValue: "display-p3")!
        let inputFixture = try imageInput(colorSpace: displayP3)
        let report = try await makeReport(
            input: RasterQualificationInput(imageOperationInputContext: inputFixture.context)
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations.count == 1)
        #expect(report.evaluations[0].rejections.contains(
            .operationInputPixelRepresentationUnsupported(0, inputFixture.reference)
        ))
    }

    @Test
    func implementationResourceCapacityIsCheckedAgainstBoundResource() async throws {
        let inputFixture = try imageInput(resourceCapacity: 64)
        let implementation = RasterQualificationImplementation(minimumInputCapacity: 128)
        let report = try await makeReport(
            input: RasterQualificationInput(imageOperationInputContext: inputFixture.context),
            implementation: implementation
        )

        #expect(report.qualifiedCandidates.isEmpty)
        let resource = try #require(inputFixture.resource)
        #expect(report.evaluations[0].rejections.contains(
            .inputResourceCapacityInsufficient(
                0,
                resource.descriptor.reference,
                required: 128,
                actual: 64
            )
        ))
    }

    @Test
    func requiredInputBindingCannotBeInferredFromUnboundImageLayer() async throws {
        let inputFixture = try imageInput(bindResource: false)
        let report = try await makeReport(
            input: RasterQualificationInput(imageOperationInputContext: inputFixture.context)
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .inputResourceBindingMissing(0, inputFixture.reference)
        ))
    }

    @Test
    func compositeInputCannotHideAnUnboundPixelBackedLayer() async throws {
        let descriptor = try pixelDescriptor()
        let imageID = ImageIdentifier.generate()
        let firstID = LayerIdentifier.generate()
        let secondID = LayerIdentifier.generate()
        let firstReference = LayerReference(imageID: imageID, layerID: firstID)
        let secondReference = LayerReference(imageID: imageID, layerID: secondID)
        let firstResource = try InputQualificationResource(
            target: target(),
            identifier: "composite.bound.first",
            capacityBytes: descriptor.minimumRequiredStorageBytesByPlane[0],
            memoryDomain: .host
        )
        let firstStorage = try PixelStorageBinding(
            descriptor: descriptor,
            planeBindings: [
                PixelPlaneResourceBinding(
                    resource: firstResource,
                    planeIndices: [0],
                    access: .read
                )
            ]
        )
        let image = try Image(
            identifier: imageID,
            canvas: ImageCanvasDescriptor(extent: descriptor.extent),
            layers: [
                LayerDescriptor(identifier: firstID, content: .raster(descriptor)),
                LayerDescriptor(identifier: secondID, content: .raster(descriptor))
            ],
            storageBindings: [
                LayerPixelStorageBinding(reference: firstReference, storage: firstStorage)
            ]
        )
        let context = try ImageOperationInputContext(inputs: [
            ImageOperationInputBinding(
                inputIndex: 0,
                imageState: image.snapshot(),
                target: .composite([firstReference, secondReference])
            )
        ])

        let report = try await makeReport(
            input: RasterQualificationInput(imageOperationInputContext: context)
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .inputResourceBindingMissing(0, secondReference)
        ))
    }

    @Test
    func resourceOnAnotherExecutionTargetRequiresDeclaredImport() async throws {
        let sourceTarget = target(device: "device.source")
        let inputFixture = try imageInput(resourceTarget: sourceTarget)
        let report = try await makeReport(
            input: RasterQualificationInput(imageOperationInputContext: inputFixture.context)
        )

        #expect(report.qualifiedCandidates.isEmpty)
        let resource = try #require(inputFixture.resource)
        #expect(report.evaluations[0].rejections.contains(
            .inputResourceNotAccessibleFromTarget(
                0,
                resource.descriptor.reference,
                target()
            )
        ))
    }

    @Test
    func inputStoragePrecisionIsCheckedAgainstActualPixelComponentType() async throws {
        let inputFixture = try imageInput(componentType: .float32)
        let report = try await makeReport(
            input: RasterQualificationInput(imageOperationInputContext: inputFixture.context)
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .operationInputStoragePrecisionUnsupported(0, inputFixture.reference, .float32)
        ))
    }

    @Test
    func genericInputResourceBindingRejectsNegativeInputIndex() throws {
        let resource = try InputQualificationResource(
            target: target(),
            identifier: "invalid-index",
            capacityBytes: 128
        )
        #expect(OperationInputResourceBinding(
            inputIndex: -1,
            resource: resource,
            access: .read
        )?.inputIndex == nil)
    }

    @Test
    func nonImageOperationInputCanDeclareGenericExecutionResources() async throws {
        let candidateTarget = target()
        let resource = try InputQualificationResource(
            target: candidateTarget,
            identifier: "generic.input.buffer",
            capacityBytes: 128
        )
        let resourceBinding = try #require(OperationInputResourceBinding(
            inputIndex: 0,
            resource: resource,
            access: .read
        ))
        let input = GenericBufferInput(
            operationInputResourceBindings: [resourceBinding]
        )

        let implementationRegistry = OperationImplementationRegistry()
        try await implementationRegistry.register(GenericBufferImplementation())
        let providerRegistry = ExecutionProviderRegistry()
        try await providerRegistry.register(
            InputQualificationProvider(target: candidateTarget, capturedAt: now)
        )
        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: ExecutionPlatformDescriptor(
                operatingSystem: "input-qualification-os",
                architecture: "input-qualification-arch"
            ),
            capturedAt: now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        let report = try await resolver.evaluate(
            step: AnyImageOperationStep(operation: GenericBufferOperation()),
            input: input,
            policy: .unrestricted,
            environment: environment,
            freshness: QualificationFreshnessPolicy(
                maximumSnapshotAge: 60,
                maximumProviderStateAge: 60,
                maximumDeviceStateAge: 60
            )!,
            now: now
        )

        let candidate = try #require(report.qualifiedCandidates.first)
        #expect(candidate.imageInputContext == nil)
        #expect(candidate.inputResourceAccesses.count == 1)
        #expect(candidate.inputResourceAccesses[0].resource.descriptor.reference == resource.descriptor.reference)
    }

    @Test
    func imageOperationMustSupplyExplicitImageInputContext() async throws {
        await #expect(throws: OperationImplementationQualificationError.imageInputContextRequired) {
            try await makeReport(input: PlainRasterQualificationInput())
        }
    }

    @Test
    func concreteSwiftInputTypeIsCheckedEvenWhenSemanticIdentifierMatches() async throws {
        let inputFixture = try imageInput()
        let report = try await makeReport(
            input: WrongRasterQualificationInput(imageOperationInputContext: inputFixture.context)
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations.count == 1)
        #expect(report.evaluations[0].rejections == [.inputConcreteTypeMismatch])
    }
}
