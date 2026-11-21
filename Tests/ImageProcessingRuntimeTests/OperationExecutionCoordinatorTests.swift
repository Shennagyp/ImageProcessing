import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol
@testable import ImageProcessingRuntime
import Testing

private struct CoordinatedInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "execution-coordinator.input")!
    let value: Int
}

private struct CoordinatedOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "execution-coordinator.output")!
    let value: Int
}

private struct CoordinatedOperation: ImageOperation {
    typealias Input = CoordinatedInput
    typealias Output = CoordinatedOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "execution-coordinator.multiply")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!
    )
}

private struct CoordinatedImageInput: ImageOperationInputValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "execution-coordinator.image-input")!
    let imageOperationInputContext: ImageOperationInputContext
}

private struct CoordinatedImageOutput: ImageOperationOutputValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "execution-coordinator.image-output")!
    let imageOperationOutputDescriptor: ImageOperationOutputDescriptor
}

private struct CoordinatedImageOperation: ImageOperation {
    typealias Input = CoordinatedImageInput
    typealias Output = CoordinatedImageOutput

    static let outputPixelDomain = PixelRepresentationDomain(
        layouts: [.interleaved],
        interpretations: [.scientific]
    )

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "execution-coordinator.image-update")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        layerContract: OperationLayerContract(
            acceptedInputKinds: [.annotation],
            producedOutputKinds: [.raster]
        ),
        pixelDataContract: OperationPixelDataContract(
            output: outputPixelDomain
        )
    )

    func resourcePlan(for input: CoordinatedImageInput) throws -> OperationResourcePlan {
        guard let source = input.imageOperationInputContext.inputs.first else {
            throw OperationResourcePlanError.inputValueTypeMismatch
        }
        let pixels = try CoordinatedImageImplementation.outputPixels(
            extent: source.imageState.document.canvas.extent
        )
        return try OperationResourcePlan(resources: [
            OperationResourcePlanRequirement(
                role: .output(0),
                minimumCapacityBytes: pixels.minimumRequiredStorageBytes
            ),
            OperationResourcePlanRequirement(
                role: .temporary("scratch"),
                minimumCapacityBytes: 64,
                minimumAlignmentBytes: 16
            )
        ])
    }

    func validateOutput(
        _ output: CoordinatedImageOutput,
        for input: CoordinatedImageInput
    ) throws {
        guard let source = input.imageOperationInputContext.inputs.first else {
            throw OperationOutputValidationError.operationPostconditionFailed(
                "missing source image snapshot"
            )
        }
        let expectedRevision = try source.imageState.revision.next()
        guard output.imageOperationOutputDescriptor.imageState.identifier == source.imageState.identifier,
              output.imageOperationOutputDescriptor.imageState.revision == expectedRevision else {
            throw OperationOutputValidationError.operationPostconditionFailed(
                "output must advance the exact source image revision"
            )
        }
    }
}

private actor CoordinatorExecutionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSuspended = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isSuspended = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct CoordinatedImplementation: ImageOperationImplementation {
    typealias Operation = CoordinatedOperation

    let specification: ImplementationSpecification
    let factor: Int
    let gate: CoordinatorExecutionGate?

    init(factor: Int, gate: CoordinatorExecutionGate? = nil) {
        let lower = SemanticVersion(major: 1, minor: 0, patch: 0)!
        let upper = SemanticVersion(major: 2, minor: 0, patch: 0)!
        self.specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "execution-coordinator.multiply")!,
            version: lower,
            operationIdentifier: CoordinatedOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: lower,
                upperBound: upper
            )!,
            inputType: CoordinatedInput.typeIdentifier,
            outputType: CoordinatedOutput.typeIdentifier
        )
        self.factor = factor
        self.gate = gate
    }

    func execute(
        operation: CoordinatedOperation,
        input: CoordinatedInput,
        context: any ExecutionContext
    ) async throws -> CoordinatedOutput {
        if let gate {
            await gate.suspend()
        }
        return CoordinatedOutput(value: input.value * factor)
    }
}

private struct CoordinatedImageImplementation: ImageOperationImplementation {
    typealias Operation = CoordinatedImageOperation

    let specification: ImplementationSpecification

    init() {
        let lower = SemanticVersion(major: 1, minor: 0, patch: 0)!
        let upper = SemanticVersion(major: 2, minor: 0, patch: 0)!
        specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "execution-coordinator.image-update")!,
            version: lower,
            operationIdentifier: CoordinatedImageOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: lower,
                upperBound: upper
            )!,
            inputType: CoordinatedImageInput.typeIdentifier,
            outputType: CoordinatedImageOutput.typeIdentifier,
            layerSupport: ImplementationLayerSupport(
                inputKinds: [.annotation],
                outputKinds: [.raster]
            ),
            pixelDataSupport: OperationPixelDataContract(
                output: CoordinatedImageOperation.outputPixelDomain
            ),
            resourceRequirements: [
                ImplementationResourceRequirement(
                    role: .output(0),
                    kind: .buffer,
                    allowedMemoryDomains: [.host, .shared],
                    minimumCapacityBytes: 1,
                    access: .write
                ),
                ImplementationResourceRequirement(
                    role: .temporary("scratch"),
                    kind: .buffer,
                    allowedMemoryDomains: [.host, .shared],
                    minimumCapacityBytes: 1,
                    minimumAlignmentBytes: 16,
                    access: .readWrite
                )
            ]
        )
    }

    static func outputPixels(extent: ImageExtent) throws -> PixelDataDescriptor {
        let channel = PixelChannelDescriptor(
            identifier: ChannelIdentifier(rawValue: "intensity")!,
            role: .intensity
        )
        let bytesPerComponent = PixelComponentType.float32.bytesPerComponent
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: extent.width * bytesPerComponent,
            sliceStrideBytes: extent.width * extent.height * bytesPerComponent,
            pixelStrideBytes: bytesPerComponent,
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

    func execute(
        operation: CoordinatedImageOperation,
        input: CoordinatedImageInput,
        context: any ExecutionContext
    ) async throws -> CoordinatedImageOutput {
        try await execute(
            operation: operation,
            input: input,
            context: context,
            resources: OperationExecutionResources()
        )
    }

    func execute(
        operation: CoordinatedImageOperation,
        input: CoordinatedImageInput,
        context: any ExecutionContext,
        resources: OperationExecutionResources
    ) async throws -> CoordinatedImageOutput {
        guard let source = input.imageOperationInputContext.inputs.first else {
            throw OperationOutputValidationError.operationPostconditionFailed("missing source image")
        }
        guard let resource = resources.resource(for: .output(0)),
              resources.resource(for: .temporary("scratch")) != nil else {
            throw OperationOutputValidationError.operationPostconditionFailed(
                "missing output or temporary allocation slot"
            )
        }

        let sourceDocument = source.imageState.document
        let imageID = source.imageState.identifier
        let nextRevision = try source.imageState.revision.next()
        let pixels = try Self.outputPixels(extent: sourceDocument.canvas.extent)
        let planeIndices = Array(pixels.layout.planes.indices)
        let storage = try PixelStorageBinding(
            descriptor: pixels,
            planeBindings: [
                PixelPlaneResourceBinding(
                    resource: resource,
                    planeIndices: planeIndices,
                    access: .read
                )
            ]
        )
        let outputLayer = LayerDescriptor(
            identifier: LayerIdentifier(rawValue: "layer.generated.raster")!,
            content: .raster(pixels)
        )
        let document = try ImageDocumentSnapshot(
            identifier: imageID,
            revision: nextRevision,
            canvas: sourceDocument.canvas,
            layers: [outputLayer]
        )
        let bindings = try ImageStorageBindingSet(
            snapshot: document,
            bindings: [
                LayerPixelStorageBinding(
                    reference: outputLayer.reference(in: imageID),
                    storage: storage
                )
            ]
        )
        let imageState = try ImageStateSnapshot(
            document: document,
            storageBindings: bindings
        )
        let descriptor = try ImageOperationOutputDescriptor(
            imageState: imageState,
            producedLayers: [outputLayer.reference(in: imageID)]
        )
        return CoordinatedImageOutput(imageOperationOutputDescriptor: descriptor)
    }
}

private final class CoordinatedResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(_ descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

private enum CoordinatedContextError: Error {
    case importUnsupported
}

private struct CoordinatedContext: ExecutionResourceAllocatingContext, ExecutionProviderRegistrationBoundContext {
    let target: ExecutionTargetReference
    let providerRegistrationIdentifier: UUID

    var capabilities: ExecutionCapabilities {
        (try? ExecutionCapabilities([
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceMemoryDomains, value: .stringSet(["host", "shared"]))
        ])) ?? .init()
    }

    func allocateResource(_ request: ExecutionResourceRequest) async throws -> any ExecutionResource {
        let descriptor = try ExecutionResourceDescriptor(
            identifier: ExecutionResourceIdentifier(rawValue: "coordinator.allocated.\(UUID().uuidString)")!,
            target: target,
            kind: request.kind,
            capacityBytes: request.minimumCapacityBytes,
            alignmentBytes: request.minimumAlignmentBytes,
            memoryDomain: request.memoryDomain,
            providerRegistrationIdentifier: providerRegistrationIdentifier
        )
        return CoordinatedResource(descriptor)
    }

    func importResource(
        _ resource: any ExecutionResource,
        access: ExecutionResourceAccessMode
    ) async throws -> any ExecutionResource {
        throw CoordinatedContextError.importUnsupported
    }
}

private final class CoordinatedProvider: ExecutionProvider, @unchecked Sendable {
    let descriptor: ExecutionProviderDescriptor

    init(identifier: ExecutionProviderID) {
        descriptor = ExecutionProviderDescriptor(
            identifier: identifier,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            displayName: identifier.rawValue
        )
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(availability: .available)
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        []
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        CoordinatedContext(
            target: target,
            providerRegistrationIdentifier: UUID()
        )
    }

    func makeContext(
        for target: ExecutionTargetReference,
        registrationIdentifier: UUID
    ) async throws -> any ExecutionContext {
        CoordinatedContext(
            target: target,
            providerRegistrationIdentifier: registrationIdentifier
        )
    }
}

private final class WeakCoordinatedProviderBox {
    weak var value: CoordinatedProvider?

    init(_ value: CoordinatedProvider) {
        self.value = value
    }
}

private struct CoordinatorTestSetup {
    let implementations: OperationImplementationRegistry
    let providers: ExecutionProviderRegistry
    let ledger: RuntimeWorkLedger
    let coordinator: OperationExecutionCoordinator
    let providerID: ExecutionProviderID
    let candidate: QualifiedOperationImplementation
    let weakProvider: WeakCoordinatedProviderBox
}

struct OperationExecutionCoordinatorTests {
    private func setup(
        gate: CoordinatorExecutionGate? = nil
    ) async throws -> CoordinatorTestSetup {
        let providerID = ExecutionProviderID(rawValue: "provider.execution-coordinator")!
        let target = ExecutionTargetReference(providerID: providerID)
        let providers = ExecutionProviderRegistry()
        let provider = CoordinatedProvider(identifier: providerID)
        let weakProvider = WeakCoordinatedProviderBox(provider)
        try await providers.register(provider)
        let registeredProvider = try #require(await providers.registeredProviders().first)
        let context = try await providers.makeContext(
            for: target,
            expecting: registeredProvider.descriptor,
            registrationIdentifier: registeredProvider.registrationIdentifier
        )

        let implementations = OperationImplementationRegistry()
        try await implementations.register(CoordinatedImplementation(factor: 3, gate: gate))
        let registeredImplementation = try #require(
            await implementations.registeredImplementations().first
        )

        let now = Date()
        let candidate = QualifiedOperationImplementation(
            implementation: registeredImplementation,
            providerRegistrationIdentifier: registeredProvider.registrationIdentifier,
            operationStep: AnyImageOperationStep(operation: CoordinatedOperation()),
            input: CoordinatedInput(value: 7),
            target: target,
            context: context,
            imageInputContext: nil,
            environmentObservations: CandidateEnvironmentObservations(
                environmentSnapshotIdentifier: RuntimeEnvironmentSnapshotIdentifier(),
                providerState: ExecutionProviderStateSnapshot(availability: .available),
                deviceState: nil,
                assessedAt: now
            ),
            resourceAllocations: [],
            inputResourceAccesses: []
        )

        let ledger = RuntimeWorkLedger()
        let coordinator = OperationExecutionCoordinator(
            implementations: implementations,
            providers: providers,
            workLedger: ledger
        )

        return CoordinatorTestSetup(
            implementations: implementations,
            providers: providers,
            ledger: ledger,
            coordinator: coordinator,
            providerID: providerID,
            candidate: candidate,
            weakProvider: weakProvider
        )
    }

    @Test
    func executesTheQualifiedImplementationAndReleasesItsWorkLease() async throws {
        let setup = try await setup()

        let output = try await setup.coordinator.execute(setup.candidate) as? CoordinatedOutput

        #expect(output?.value == 21)
        #expect(await setup.ledger.activeLeaseCount == 0)
        #expect(setup.weakProvider.value != nil)
    }

    @Test
    func imageOutputIsPublishedOnlyAfterSuccessfulDispatch() async throws {
        let providerID = ExecutionProviderID(rawValue: "provider.execution-coordinator.image")!
        let target = ExecutionTargetReference(providerID: providerID)
        let providers = ExecutionProviderRegistry()
        try await providers.register(CoordinatedProvider(identifier: providerID))
        let registeredProvider = try #require(await providers.registeredProviders().first)
        let context = try await providers.makeContext(
            for: target,
            expecting: registeredProvider.descriptor,
            registrationIdentifier: registeredProvider.registrationIdentifier
        )

        let image = try Image(
            canvas: ImageCanvasDescriptor(extent: try #require(ImageExtent(width: 4, height: 4))),
            layers: [
                LayerDescriptor(
                    identifier: try #require(LayerIdentifier(rawValue: "layer.source.annotation")),
                    content: .annotation(
                        AnnotationDataDescriptor(
                            schema: try #require(AnnotationSchemaIdentifier(rawValue: "annotation.source.v1")),
                            coordinateSpace: .pixel
                        )
                    )
                )
            ]
        )
        let source = image.snapshot()
        let sourceLayer = try #require(source.document.layers.first)
        let imageInputContext = try ImageOperationInputContext(
            inputs: [
                ImageOperationInputBinding(
                    inputIndex: 0,
                    imageState: source,
                    target: .layer(sourceLayer.reference(in: source.identifier))
                )
            ]
        )
        let input = CoordinatedImageInput(imageOperationInputContext: imageInputContext)
        let pixels = try CoordinatedImageImplementation.outputPixels(
            extent: source.document.canvas.extent
        )

        let implementations = OperationImplementationRegistry()
        try await implementations.register(CoordinatedImageImplementation())
        let registeredImplementation = try #require(
            await implementations.registeredImplementations().first
        )
        let step = AnyImageOperationStep(operation: CoordinatedImageOperation())
        let candidate = QualifiedOperationImplementation(
            implementation: registeredImplementation,
            providerRegistrationIdentifier: registeredProvider.registrationIdentifier,
            operationStep: step,
            input: input,
            target: target,
            context: context,
            imageInputContext: imageInputContext,
            environmentObservations: CandidateEnvironmentObservations(
                environmentSnapshotIdentifier: RuntimeEnvironmentSnapshotIdentifier(),
                providerState: ExecutionProviderStateSnapshot(availability: .available),
                deviceState: nil,
                assessedAt: Date()
            ),
            resourceAllocations: [
                QualifiedResourceAllocation(
                    role: .output(0),
                    kind: .buffer,
                    allowedMemoryDomains: [.host, .shared],
                    minimumCapacityBytes: pixels.minimumRequiredStorageBytes,
                    minimumAlignmentBytes: 1,
                    access: .write,
                    allocatableMemoryDomains: [.host, .shared]
                ),
                QualifiedResourceAllocation(
                    role: .temporary("scratch"),
                    kind: .buffer,
                    allowedMemoryDomains: [.host, .shared],
                    minimumCapacityBytes: 64,
                    minimumAlignmentBytes: 16,
                    access: .readWrite,
                    allocatableMemoryDomains: [.host, .shared]
                )
            ],
            inputResourceAccesses: []
        )
        let ledger = RuntimeWorkLedger()
        let coordinator = OperationExecutionCoordinator(
            implementations: implementations,
            providers: providers,
            workLedger: ledger
        )

        await #expect(throws: OperationExecutionCoordinatorError.memoryDomainSelectionRequired(.output(0))) {
            try await coordinator.execute(candidate, updating: image)
        }
        #expect(image.snapshot().revision == source.revision)
        #expect(await ledger.activeLeaseCount == 0)

        let output = try await coordinator.execute(
            candidate,
            updating: image,
            memoryDomains: [
                .output(0): .host,
                .temporary("scratch"): .host
            ]
        ) as? CoordinatedImageOutput
        let committed = image.snapshot()

        #expect(output != nil)
        #expect(committed.identifier == source.identifier)
        #expect(committed.revision == (try source.revision.next()))
        #expect(committed.document.layers.map(\.identifier) == [
            LayerIdentifier(rawValue: "layer.generated.raster")!
        ])
        #expect(committed.storageBindings.boundLayerCount == 1)
        #expect(try committed.storageBindings.unboundPixelLayers(in: committed.document).isEmpty)
        #expect(await ledger.activeLeaseCount == 0)
    }

    @Test
    func providerRemovedBeforeDispatchRejectsCandidateAndCancelsReservation() async throws {
        let setup = try await setup()
        #expect(await setup.providers.unregister(setup.providerID))

        await #expect(throws: ExecutionProviderRegistryError.providerNotRegistered(
            setup.providerID
        )) {
            try await setup.coordinator.execute(setup.candidate)
        }

        #expect(await setup.ledger.activeLeaseCount == 0)
    }

    @Test
    func providerInstanceRemainsRetainedUntilInFlightExecutionCompletes() async throws {
        let gate = CoordinatorExecutionGate()
        let setup = try await setup(gate: gate)

        let execution = Task {
            try await setup.coordinator.execute(setup.candidate)
        }
        await gate.waitUntilSuspended()

        #expect(setup.weakProvider.value != nil)
        #expect(await setup.providers.unregister(setup.providerID))
        #expect(setup.weakProvider.value != nil)

        await gate.resume()
        let output = try await execution.value as? CoordinatedOutput

        #expect(output?.value == 21)
        #expect(setup.weakProvider.value == nil)
        #expect(await setup.ledger.activeLeaseCount == 0)
    }
}
