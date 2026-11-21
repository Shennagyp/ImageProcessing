import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol
@testable import ImageProcessingRuntime
import Testing

private struct QualificationInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "qualification.input")!
}

private struct QualificationOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "qualification.output")!
}

private struct QualificationOperation: ImageOperation {
    typealias Input = QualificationInput
    typealias Output = QualificationOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "qualification.transform")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        precisionContract: OperationPrecisionContract(
            computation: [.float32, .float64]
        ),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate
        )
    )
}

private struct QualificationImplementation: ImageOperationImplementation {
    typealias Operation = QualificationOperation

    let specification: ImplementationSpecification

    init(
        identifier: String = "qualification.transform.reference",
        providerID: ExecutionProviderID? = nil,
        requiredCapabilities: [ExecutionCapabilityConstraint] = [],
        precision: OperationPrecisionContract = .init(computation: [.float32]),
        resourceRequirements: [ImplementationResourceRequirement] = [],
        performanceHints: ImplementationPerformanceHints? = nil
    ) {
        specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: identifier)!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: QualificationOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: QualificationInput.typeIdentifier,
            outputType: QualificationOutput.typeIdentifier,
            requiredProviderID: providerID,
            requiredCapabilities: requiredCapabilities,
            precisionSupport: precision,
            determinism: .deterministic,
            performanceHints: performanceHints,
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve]
            ),
            resourceRequirements: resourceRequirements
        )
    }

    func execute(
        operation: QualificationOperation,
        input: QualificationInput,
        context: any ExecutionContext
    ) async throws -> QualificationOutput {
        QualificationOutput()
    }
}

private struct OutputPlanningOperation: ImageOperation {
    typealias Input = QualificationInput
    typealias Output = QualificationOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "qualification.output-plan")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        precisionContract: OperationPrecisionContract(computation: [.float32, .float64]),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate
        )
    )

    func resourcePlan(
        for input: QualificationInput
    ) throws -> OperationResourcePlan {
        let output = try OperationResourcePlanRequirement(
            role: .output(0),
            minimumCapacityBytes: 4_096,
            minimumAlignmentBytes: 256
        )
        let temporary = try OperationResourcePlanRequirement(
            role: .temporary("scratch"),
            minimumCapacityBytes: 2_048,
            minimumAlignmentBytes: 128
        )
        return try OperationResourcePlan(resources: [output, temporary])
    }
}

private struct OutputPlanningImplementation: ImageOperationImplementation {
    typealias Operation = OutputPlanningOperation

    let specification: ImplementationSpecification

    init(
        identifier: String = "qualification.output-plan.buffer",
        minimumOutputCapacityBytes: UInt64 = 512,
        minimumTemporaryCapacityBytes: UInt64 = 256,
        allowedMemoryDomains: Set<ExecutionMemoryDomain> = [.host],
        performanceHints: ImplementationPerformanceHints? = nil
    ) {
        specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: identifier)!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: OutputPlanningOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: QualificationInput.typeIdentifier,
            outputType: QualificationOutput.typeIdentifier,
            precisionSupport: OperationPrecisionContract(computation: [.float32]),
            determinism: .deterministic,
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve]
            ),
            performanceHints: performanceHints,
            resourceRequirements: [
                ImplementationResourceRequirement(
                    role: .output(0),
                    kind: .buffer,
                    allowedMemoryDomains: allowedMemoryDomains,
                    minimumCapacityBytes: minimumOutputCapacityBytes,
                    minimumAlignmentBytes: 64,
                    access: .write
                ),
                ImplementationResourceRequirement(
                    role: .temporary("scratch"),
                    kind: .buffer,
                    allowedMemoryDomains: allowedMemoryDomains,
                    minimumCapacityBytes: minimumTemporaryCapacityBytes,
                    minimumAlignmentBytes: 32,
                    access: .write
                )
            ]
        )
    }

    func execute(
        operation: OutputPlanningOperation,
        input: QualificationInput,
        context: any ExecutionContext
    ) async throws -> QualificationOutput {
        QualificationOutput()
    }
}

private enum QualificationProviderFixtureError: Error {
    case discovery
    case context
}

private struct QualificationTestDevice: ExecutionDevice {
    let descriptor: ExecutionDeviceDescriptor
    let availability: ExecutionAvailability
    let capturedAt: Date
    let state: ExecutionDeviceStateSnapshot?

    init(
        identifier: String,
        providerID: ExecutionProviderID,
        availability: ExecutionAvailability = .available,
        capabilities: ExecutionCapabilities = .init(),
        capturedAt: Date,
        state: ExecutionDeviceStateSnapshot? = nil
    ) {
        descriptor = ExecutionDeviceDescriptor(
            identifier: ExecutionDeviceID(rawValue: identifier)!,
            providerID: providerID,
            displayName: identifier,
            capabilities: capabilities
        )
        self.availability = availability
        self.capturedAt = capturedAt
        self.state = state
    }

    func observeState() async throws -> ExecutionDeviceStateSnapshot {
        state ?? ExecutionDeviceStateSnapshot(
            capturedAt: capturedAt,
            availability: availability
        )
    }
}

private final class QualificationTestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

private struct QualificationTestContext: ExecutionContext {
    let target: ExecutionTargetReference
    let capabilities: ExecutionCapabilities
}

private struct QualificationAllocatingTestContext: ExecutionResourceAllocatingContext {
    let target: ExecutionTargetReference
    let capabilities: ExecutionCapabilities

    func allocateResource(
        _ request: ExecutionResourceRequest
    ) async throws -> any ExecutionResource {
        let descriptor = try ExecutionResourceDescriptor(
            identifier: ExecutionResourceIdentifier(rawValue: UUID().uuidString)!,
            target: target,
            kind: request.kind,
            capacityBytes: request.minimumCapacityBytes,
            alignmentBytes: request.minimumAlignmentBytes,
            memoryDomain: request.memoryDomain
        )
        return QualificationTestResource(descriptor: descriptor)
    }

    func importResource(
        _ resource: any ExecutionResource,
        access: ExecutionResourceAccessMode
    ) async throws -> any ExecutionResource {
        let source = resource.descriptor
        let descriptor = try ExecutionResourceDescriptor(
            identifier: ExecutionResourceIdentifier(rawValue: UUID().uuidString)!,
            target: target,
            kind: source.kind,
            capacityBytes: source.capacityBytes,
            alignmentBytes: source.alignmentBytes,
            memoryDomain: source.memoryDomain
        )
        return QualificationTestResource(descriptor: descriptor)
    }
}

private struct QualificationTestProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor
    let devices: [QualificationTestDevice]
    let availability: ExecutionAvailability
    let capturedAt: Date
    let contextCapabilities: ExecutionCapabilities
    let allocatesResources: Bool
    let state: ExecutionProviderStateSnapshot?
    let failsDiscovery: Bool
    let failsContextCreation: Bool
    let returnsWrongContextTarget: Bool

    init(
        identifier: String = "provider.qualification-test",
        devices: [QualificationTestDevice]? = nil,
        availability: ExecutionAvailability = .available,
        capabilities: ExecutionCapabilities = .init(),
        contextCapabilities: ExecutionCapabilities = .init(),
        failsDiscovery: Bool = false,
        failsContextCreation: Bool = false,
        returnsWrongContextTarget: Bool = false,
        capturedAt: Date,
        state: ExecutionProviderStateSnapshot? = nil,
        allocatesResources: Bool = false
    ) {
        let providerID = ExecutionProviderID(rawValue: identifier)!
        descriptor = ExecutionProviderDescriptor(
            identifier: providerID,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            displayName: identifier,
            capabilities: capabilities
        )
        self.devices = devices ?? [
            QualificationTestDevice(
                identifier: "device.0",
                providerID: providerID,
                capturedAt: capturedAt
            )
        ]
        self.availability = availability
        self.capturedAt = capturedAt
        self.contextCapabilities = contextCapabilities
        self.allocatesResources = allocatesResources
        self.state = state
        self.failsDiscovery = failsDiscovery
        self.failsContextCreation = failsContextCreation
        self.returnsWrongContextTarget = returnsWrongContextTarget
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        state ?? ExecutionProviderStateSnapshot(
            capturedAt: capturedAt,
            availability: availability
        )
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        if failsDiscovery { throw QualificationProviderFixtureError.discovery }
        return devices
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        if failsContextCreation { throw QualificationProviderFixtureError.context }
        let actualTarget: ExecutionTargetReference
        if returnsWrongContextTarget {
            actualTarget = ExecutionTargetReference(
                providerID: ExecutionProviderID(rawValue: "provider.wrong-context")!
            )
        } else {
            actualTarget = target
        }
        if allocatesResources {
            return QualificationAllocatingTestContext(
                target: actualTarget,
                capabilities: contextCapabilities
            )
        }
        return QualificationTestContext(
            target: actualTarget,
            capabilities: contextCapabilities
        )
    }
}

struct CommonQualificationResolverTests {
    private func platform() -> ExecutionPlatformDescriptor {
        ExecutionPlatformDescriptor(
            operatingSystem: "qualification-test-os",
            architecture: "qualification-test-arch"
        )
    }

    private func freshness(
        snapshot: TimeInterval = 60,
        provider: TimeInterval = 60,
        device: TimeInterval = 60
    ) -> QualificationFreshnessPolicy {
        QualificationFreshnessPolicy(
            maximumSnapshotAge: snapshot,
            maximumProviderStateAge: provider,
            maximumDeviceStateAge: device
        )!
    }

    private func makeReport(
        provider: QualificationTestProvider?,
        implementation: QualificationImplementation = QualificationImplementation(),
        policy: QualificationPolicy = .unrestricted,
        now: Date,
        snapshotCapturedAt: Date? = nil,
        freshness: QualificationFreshnessPolicy? = nil
    ) async throws -> OperationImplementationQualificationReport {
        let implementationRegistry = OperationImplementationRegistry()
        try await implementationRegistry.register(implementation)

        let providerRegistry = ExecutionProviderRegistry()
        if let provider {
            try await providerRegistry.register(provider)
        }

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: platform(),
            capturedAt: snapshotCapturedAt ?? now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        return try await resolver.evaluate(
            step: AnyImageOperationStep(operation: QualificationOperation()),
            input: QualificationInput(),
            policy: policy,
            environment: environment,
            freshness: freshness ?? self.freshness(),
            now: now
        )
    }


    private func makeResolution(
        providers: [QualificationTestProvider],
        implementation: QualificationImplementation = QualificationImplementation(),
        policy: QualificationPolicy,
        now: Date
    ) async throws -> OperationImplementationResolutionReport {
        let implementationRegistry = OperationImplementationRegistry()
        try await implementationRegistry.register(implementation)

        let providerRegistry = ExecutionProviderRegistry()
        for provider in providers {
            try await providerRegistry.register(provider)
        }

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: platform(),
            capturedAt: now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        return try await resolver.resolve(
            step: AnyImageOperationStep(operation: QualificationOperation()),
            input: QualificationInput(),
            policy: policy,
            environment: environment,
            freshness: freshness(),
            now: now
        )
    }

    private func makeQueueProvider(
        identifier: String,
        delay: ExecutionObservation<UInt64>,
        capturedAt: Date
    ) -> QualificationTestProvider {
        let providerID = ExecutionProviderID(rawValue: identifier)!
        let deviceState = ExecutionDeviceStateSnapshot(
            capturedAt: capturedAt,
            availability: .available,
            estimatedQueueDelayNanoseconds: delay
        )
        let device = QualificationTestDevice(
            identifier: "device.0",
            providerID: providerID,
            capturedAt: capturedAt,
            state: deviceState
        )
        return QualificationTestProvider(
            identifier: identifier,
            devices: [device],
            capturedAt: capturedAt
        )
    }

    private func makeOutputResolution(
        provider: QualificationTestProvider,
        implementations: [OutputPlanningImplementation],
        policy: QualificationPolicy,
        now: Date
    ) async throws -> OperationImplementationResolutionReport {
        let implementationRegistry = OperationImplementationRegistry()
        for implementation in implementations {
            try await implementationRegistry.register(implementation)
        }

        let providerRegistry = ExecutionProviderRegistry()
        try await providerRegistry.register(provider)

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: platform(),
            capturedAt: now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        return try await resolver.resolve(
            step: AnyImageOperationStep(operation: OutputPlanningOperation()),
            input: QualificationInput(),
            policy: policy,
            environment: environment,
            freshness: freshness(),
            now: now
        )
    }

    private func makeOutputReport(
        provider: QualificationTestProvider,
        now: Date
    ) async throws -> OperationImplementationQualificationReport {
        let implementationRegistry = OperationImplementationRegistry()
        try await implementationRegistry.register(OutputPlanningImplementation())

        let providerRegistry = ExecutionProviderRegistry()
        try await providerRegistry.register(provider)

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: platform(),
            capturedAt: now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        return try await resolver.evaluate(
            step: AnyImageOperationStep(operation: OutputPlanningOperation()),
            input: QualificationInput(),
            policy: .unrestricted,
            environment: environment,
            freshness: freshness(),
            now: now
        )
    }

    @Test
    func candidateCombinesOperationOutputSizeWithImplementationMinimum() async throws {
        let now = Date(timeIntervalSince1970: 50_025)
        let allocationCapabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(
                identifier: .resourceMemoryDomains,
                value: .stringSet(["host"])
            )
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: allocationCapabilities,
            capturedAt: now,
            allocatesResources: true
        )
        let report = try await makeOutputReport(provider: provider, now: now)
        let candidate = try #require(report.qualifiedCandidates.first)
        let outputAllocation = try #require(
            candidate.resourceAllocations.first { $0.role == .output(0) }
        )
        let temporaryAllocation = try #require(
            candidate.resourceAllocations.first { $0.role == .temporary("scratch") }
        )

        #expect(outputAllocation.kind == .buffer)
        #expect(outputAllocation.allowedMemoryDomains == [.host])
        #expect(outputAllocation.minimumCapacityBytes == 4_096)
        #expect(outputAllocation.minimumAlignmentBytes == 256)
        #expect(outputAllocation.access == .write)
        #expect(outputAllocation.allocatableMemoryDomains == [.host])
        #expect(temporaryAllocation.kind == .buffer)
        #expect(temporaryAllocation.minimumCapacityBytes == 2_048)
        #expect(temporaryAllocation.minimumAlignmentBytes == 128)
        #expect(temporaryAllocation.allocatableMemoryDomains == [.host])
    }

    @Test
    func implementationTemporaryResourceWithoutOperationPlanIsRejected() async throws {
        let now = Date(timeIntervalSince1970: 50_027)
        let requirement = ImplementationResourceRequirement(
            role: .temporary("scratch"),
            kind: .buffer,
            allowedMemoryDomains: [.host],
            minimumCapacityBytes: 16,
            access: .write
        )
        let implementation = QualificationImplementation(
            resourceRequirements: [requirement]
        )
        let report = try await makeReport(
            provider: QualificationTestProvider(capturedAt: now),
            implementation: implementation,
            now: now
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .implementationResourceNotPlanned(.temporary("scratch"))
        ))
    }

    @Test
    func outputResourceKindMustBeAdvertisedByPreparedContext() async throws {
        let now = Date(timeIntervalSince1970: 50_028)
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(
                identifier: .resourceMemoryDomains,
                value: .stringSet(["host"])
            )
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: capabilities,
            capturedAt: now,
            allocatesResources: true
        )
        let report = try await makeOutputReport(provider: provider, now: now)

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .contextCapabilityMissing(.bufferResources)
        ))
    }

    @Test
    func outputMemoryDomainMustIntersectContextAllocationDomains() async throws {
        let now = Date(timeIntervalSince1970: 50_029)
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(
                identifier: .resourceMemoryDomains,
                value: .stringSet(["deviceLocal"])
            )
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: capabilities,
            capturedAt: now,
            allocatesResources: true
        )
        let report = try await makeOutputReport(provider: provider, now: now)

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .contextResourceMemoryDomainsUnsupported(.output(0), [.host])
        ))
    }

    @Test
    func implementationOutputResourceWithoutOperationPlanIsRejected() async throws {
        let now = Date(timeIntervalSince1970: 50_030)
        let requirement = ImplementationResourceRequirement(
            role: .output(0),
            kind: .buffer,
            allowedMemoryDomains: [.host],
            minimumCapacityBytes: 16,
            access: .write
        )
        let implementation = QualificationImplementation(
            resourceRequirements: [requirement]
        )
        let provider = QualificationTestProvider(capturedAt: now)
        let report = try await makeReport(
            provider: provider,
            implementation: implementation,
            now: now
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].disposition == .rejected)
        #expect(report.evaluations[0].rejections.contains(
            .implementationResourceNotPlanned(.output(0))
        ))
    }

    @Test
    func availableProviderDeviceAndPreparedContextProduceQualifiedCandidate() async throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let provider = QualificationTestProvider(capturedAt: now)
        let report = try await makeReport(
            provider: provider,
            now: now
        )

        let candidate = try #require(report.qualifiedCandidates.first)
        #expect(report.evaluations.count == 1)
        #expect(candidate.target.providerID == provider.descriptor.identifier)
        #expect(candidate.target.deviceID == provider.devices[0].descriptor.identifier)
        #expect(candidate.context.target == candidate.target)
    }

    @Test
    func candidateRetainsPerMetricFreshnessAndQualityWithoutChangingEligibility() async throws {
        let now = Date(timeIntervalSince1970: 50_050)
        let freshZero = try ExecutionObservation(
            value: UInt64(0),
            observedAt: now.addingTimeInterval(-1),
            validUntil: now.addingTimeInterval(10),
            source: "driver.queue",
            quality: .reported
        )
        let staleMemory = try ExecutionObservation(
            value: UInt64(0),
            observedAt: now.addingTimeInterval(-30),
            validUntil: now.addingTimeInterval(-1),
            source: "driver.memory",
            quality: .estimated
        )
        let unknownQueue = ExecutionObservation<UInt64>(
            unknownReason: "provider does not expose queue depth"
        )
        let providerID = ExecutionProviderID(rawValue: "provider.qualification-test")!
        let deviceState = ExecutionDeviceStateSnapshot(
            capturedAt: now,
            availability: .available,
            availableMemoryBytes: staleMemory,
            queueDepth: freshZero,
            estimatedQueueDelayNanoseconds: .init(unknownReason: "not reported"),
            utilizationFraction: .init(unknownReason: "not reported")
        )
        let device = QualificationTestDevice(
            identifier: "device.0",
            providerID: providerID,
            capturedAt: now,
            state: deviceState
        )
        let providerState = ExecutionProviderStateSnapshot(
            capturedAt: now,
            availability: .available,
            queueDepth: unknownQueue,
            estimatedQueueDelayNanoseconds: freshZero
        )
        let provider = QualificationTestProvider(
            devices: [device],
            capturedAt: now,
            state: providerState
        )

        let report = try await makeReport(provider: provider, now: now)
        let candidate = try #require(report.qualifiedCandidates.first)
        let observations = candidate.environmentObservations

        #expect(report.evaluations.first?.disposition == .qualified)
        #expect(observations.environmentSnapshotIdentifier == report.environmentSnapshot)
        #expect(observations.assessedAt == now)
        #expect(observations.deviceState?.availableMemoryBytes.source == "driver.memory")
        #expect(observations.deviceState?.availableMemoryBytes.quality == .estimated)
        #expect({
            guard let state = observations.deviceAvailableMemoryState,
                  case .stale(0) = state else { return false }
            return true
        }())
        #expect({
            guard let state = observations.deviceQueueDepthState,
                  case .known(0) = state else { return false }
            return true
        }())
        #expect({
            guard case .unknown(reason: "provider does not expose queue depth") =
                observations.providerQueueDepthState else { return false }
            return true
        }())
    }

    @Test
    func unavailableProviderIsRejectedRatherThanTreatedAsUnknown() async throws {
        let now = Date(timeIntervalSince1970: 50_100)
        let provider = QualificationTestProvider(
            availability: .unavailable(reason: "provider intentionally disabled"),
            capturedAt: now
        )
        let report = try await makeReport(provider: provider, now: now)

        #expect(report.evaluations.count == 1)
        #expect(report.evaluations[0].disposition == .rejected)
        #expect(report.evaluations[0].rejections.contains(
            .providerUnavailable(provider.descriptor.identifier, "provider intentionally disabled")
        ))
    }

    @Test
    func unknownProviderStateProducesIndeterminateCandidate() async throws {
        let now = Date(timeIntervalSince1970: 50_200)
        let provider = QualificationTestProvider(
            availability: .unknown(reason: "state not reported"),
            capturedAt: now
        )
        let report = try await makeReport(provider: provider, now: now)

        #expect(report.evaluations[0].disposition == .indeterminate)
        #expect(report.evaluations[0].uncertainties.contains(
            .providerStateUnknown(provider.descriptor.identifier, "state not reported")
        ))
        #expect(report.qualifiedCandidates.isEmpty)
    }

    @Test
    func staleEnvironmentSnapshotIsIndeterminate() async throws {
        let now = Date(timeIntervalSince1970: 50_300)
        let old = now.addingTimeInterval(-120)
        let provider = QualificationTestProvider(capturedAt: old)
        let report = try await makeReport(
            provider: provider,
            now: now,
            snapshotCapturedAt: old,
            freshness: freshness(snapshot: 5, provider: 5, device: 5)
        )

        #expect(report.evaluations[0].disposition == .indeterminate)
        #expect(report.evaluations[0].uncertainties.contains(.environmentSnapshotStale))
        #expect(report.qualifiedCandidates.isEmpty)
    }

    @Test
    func failedDeviceDiscoveryDoesNotCreateAnOpaqueTargetCandidate() async throws {
        let now = Date(timeIntervalSince1970: 50_400)
        let provider = QualificationTestProvider(
            devices: [],
            failsDiscovery: true,
            capturedAt: now
        )
        let report = try await makeReport(provider: provider, now: now)

        #expect(report.evaluations.count == 1)
        #expect(report.evaluations[0].target == nil)
        #expect(report.evaluations[0].disposition == .indeterminate)
        #expect(report.evaluations[0].uncertainties.contains(
            .providerDiscoveryIncomplete(provider.descriptor.identifier)
        ))
    }

    @Test
    func successfullyDiscoveredOpaqueProviderTargetCanQualify() async throws {
        let now = Date(timeIntervalSince1970: 50_500)
        let provider = QualificationTestProvider(
            devices: [],
            capturedAt: now
        )
        let report = try await makeReport(provider: provider, now: now)

        let candidate = try #require(report.qualifiedCandidates.first)
        #expect(candidate.target.providerID == provider.descriptor.identifier)
        #expect(candidate.target.deviceID == nil)
    }

    @Test
    func hardProviderAndPrecisionRequirementsRejectUnsupportedBinding() async throws {
        let now = Date(timeIntervalSince1970: 50_600)
        let provider = QualificationTestProvider(capturedAt: now)
        let otherProvider = ExecutionProviderID(rawValue: "provider.required")!
        let function = try ImageFunction(operation: QualificationOperation()).qualifying {
            $0.require(.provider(otherProvider))
            $0.require(.precision(.computation, .float32))
        }
        let implementation = QualificationImplementation(
            precision: .init(computation: [.float64])
        )
        let report = try await makeReport(
            provider: provider,
            implementation: implementation,
            policy: function.qualificationPolicy,
            now: now
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations[0].rejections.contains(
            .providerNotAllowed(provider.descriptor.identifier)
        ))
        #expect(report.evaluations[0].rejections.contains(
            .precisionUnsupported(.computation, .float32)
        ))
    }

    @Test
    func missingDeviceCapabilityRejectsCandidate() async throws {
        let now = Date(timeIntervalSince1970: 50_700)
        let capability = ExecutionCapabilityID(rawValue: "device.numeric.fp64")!
        let implementation = QualificationImplementation(
            requiredCapabilities: [
                .init(
                    scope: .device,
                    requirement: .integerAtLeast(capability, 1)
                )
            ]
        )
        let provider = QualificationTestProvider(capturedAt: now)
        let report = try await makeReport(
            provider: provider,
            implementation: implementation,
            now: now
        )

        #expect(report.evaluations[0].disposition == .rejected)
        #expect(report.evaluations[0].rejections.contains(
            .deviceCapabilityMissing(capability)
        ))
    }

    @Test
    func providerRegistrationReplacementInvalidatesSnapshotCandidateBinding() async throws {
        let now = Date(timeIntervalSince1970: 50_750)
        let provider = QualificationTestProvider(capturedAt: now)
        let implementationRegistry = OperationImplementationRegistry()
        try await implementationRegistry.register(QualificationImplementation())

        let providerRegistry = ExecutionProviderRegistry()
        try await providerRegistry.register(provider)
        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providerRegistry,
            workLedger: RuntimeWorkLedger()
        )
        let environment = try await coordinator.capture(
            platform: platform(),
            capturedAt: now
        )

        #expect(await providerRegistry.unregister(provider.descriptor.identifier))
        let replacement = QualificationTestProvider(capturedAt: now)
        try await providerRegistry.register(replacement)

        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        let report = try await resolver.evaluate(
            step: AnyImageOperationStep(operation: QualificationOperation()),
            input: QualificationInput(),
            policy: .unrestricted,
            environment: environment,
            freshness: freshness(),
            now: now
        )

        #expect(report.qualifiedCandidates.isEmpty)
        #expect(report.evaluations.count == 1)
        #expect(report.evaluations[0].rejections.contains(
            .providerRegistrationChanged(provider.descriptor.identifier)
        ))
    }

    @Test
    func contextRequirementsAreCheckedAfterContextPreparation() async throws {
        let now = Date(timeIntervalSince1970: 50_800)
        let capability = ExecutionCapabilityID(rawValue: "context.work.mode")!
        let contextCapabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: capability, value: .boolean(true))
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: contextCapabilities,
            capturedAt: now
        )
        let implementation = QualificationImplementation(
            requiredCapabilities: [
                .init(
                    scope: .context,
                    requirement: .exact(capability, .boolean(true))
                )
            ]
        )
        let report = try await makeReport(
            provider: provider,
            implementation: implementation,
            now: now
        )

        #expect(report.qualifiedCandidates.count == 1)
    }

    @Test
    func contextCapabilityClaimWithoutRequiredOptionalProtocolRejectsCandidate() async throws {
        let now = Date(timeIntervalSince1970: 50_900)
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .workSubmission, value: .boolean(true))
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: capabilities,
            capturedAt: now
        )
        let report = try await makeReport(provider: provider, now: now)

        #expect(report.evaluations[0].disposition == .rejected)
        #expect(report.evaluations[0].rejections.contains(
            .contextProtocolMismatch(.workSubmission)
        ))
    }

    @Test
    func contextCreationFailureAndTargetMismatchAreRejected() async throws {
        let now = Date(timeIntervalSince1970: 51_000)
        let failedProvider = QualificationTestProvider(
            failsContextCreation: true,
            capturedAt: now
        )
        let failed = try await makeReport(provider: failedProvider, now: now)
        #expect(failed.evaluations[0].rejections.contains {
            if case .contextCreationFailed = $0 { return true }
            return false
        })

        let mismatchedProvider = QualificationTestProvider(
            returnsWrongContextTarget: true,
            capturedAt: now
        )
        let mismatched = try await makeReport(provider: mismatchedProvider, now: now)
        #expect(mismatched.evaluations[0].rejections.contains(.contextTargetMismatch))
    }

    @Test
    func noDiscoveredProvidersProducesExplicitRejection() async throws {
        let now = Date(timeIntervalSince1970: 51_100)
        let report = try await makeReport(provider: nil, now: now)

        #expect(report.evaluations.count == 1)
        #expect(report.evaluations[0].disposition == .rejected)
        #expect(report.evaluations[0].rejections.contains(.noExecutionProviderDiscovered))
    }

    @Test
    func lowLatencyRanksCandidatesUsingFreshComparableQueueDelay() async throws {
        let now = Date(timeIntervalSince1970: 52_000)
        let slowDelay = try ExecutionObservation(
            value: UInt64(90_000),
            observedAt: now.addingTimeInterval(-1),
            validUntil: now.addingTimeInterval(10),
            source: "qualification.device.queue",
            quality: .reported
        )
        let fastDelay = try ExecutionObservation(
            value: UInt64(10_000),
            observedAt: now.addingTimeInterval(-1),
            validUntil: now.addingTimeInterval(10),
            source: "qualification.device.queue",
            quality: .reported
        )
        let policy = try ImageFunction(operation: QualificationOperation()).qualifying {
            $0.prefer(.lowLatency)
        }.qualificationPolicy
        let resolution = try await makeResolution(
            providers: [
                makeQueueProvider(
                    identifier: "provider.queue.slow",
                    delay: slowDelay,
                    capturedAt: now
                ),
                makeQueueProvider(
                    identifier: "provider.queue.fast",
                    delay: fastDelay,
                    capturedAt: now
                )
            ],
            policy: policy,
            now: now
        )

        #expect(resolution.qualification.qualifiedCandidates.count == 2)
        #expect(resolution.rankedCandidates.count == 2)
        #expect(resolution.rankedCandidates[0].candidate.target.providerID.rawValue == "provider.queue.fast")
        let queueEstimate = resolution.rankedCandidates[0].costEstimate.estimate(for: .deviceQueueDelay)
        #expect({
            guard let queueEstimate,
                  case let .estimated(value: .integer(nanoseconds), evidence) = queueEstimate.state else {
                return false
            }
            return nanoseconds == 10_000
                && evidence.first?.quality == .reported
                && evidence.first?.source == "qualification.device.queue"
        }())
    }

    @Test
    func unknownQueueTelemetryDoesNotBecomeZeroOrCreateAPreference() async throws {
        let now = Date(timeIntervalSince1970: 52_100)
        let knownDelay = try ExecutionObservation(
            value: UInt64(10),
            observedAt: now.addingTimeInterval(-1),
            validUntil: now.addingTimeInterval(10),
            source: "qualification.device.queue",
            quality: .reported
        )
        let unknownDelay = ExecutionObservation<UInt64>(
            unknownReason: "device queue delay is not reported"
        )
        let policy = try ImageFunction(operation: QualificationOperation()).qualifying {
            $0.prefer(.lowLatency)
        }.qualificationPolicy
        let resolution = try await makeResolution(
            providers: [
                makeQueueProvider(
                    identifier: "provider.a-known",
                    delay: knownDelay,
                    capturedAt: now
                ),
                makeQueueProvider(
                    identifier: "provider.z-unknown",
                    delay: unknownDelay,
                    capturedAt: now
                )
            ],
            policy: policy,
            now: now
        )

        #expect(resolution.rankedCandidates.count == 2)
        #expect(resolution.rankedCandidates[0].candidate.target.providerID.rawValue == "provider.a-known")
        #expect(resolution.rankedCandidates.allSatisfy {
            $0.preferenceContributions.first?.comparablePairCount == 0
        })
        let unknownEstimate = resolution.rankedCandidates.first {
            $0.candidate.target.providerID.rawValue == "provider.z-unknown"
        }?.costEstimate.estimate(for: .deviceQueueDelay)
        #expect({
            guard let unknownEstimate,
                  case let .unknown(reason) = unknownEstimate.state else {
                return false
            }
            return reason == "device queue delay is not reported"
        }())
    }

    @Test
    func lowMemoryRanksDeclaredAllocationMinimumAndPreservesDomainAlternatives() async throws {
        let now = Date(timeIntervalSince1970: 52_200)
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceMemoryDomains, value: .stringSet(["host", "deviceLocal"]))
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: capabilities,
            capturedAt: now,
            allocatesResources: true
        )
        let policy = try ImageFunction(operation: OutputPlanningOperation()).qualifying {
            $0.prefer(.lowMemory)
        }.qualificationPolicy
        let resolution = try await makeOutputResolution(
            provider: provider,
            implementations: [
                OutputPlanningImplementation(
                    identifier: "qualification.output-plan.small",
                    allowedMemoryDomains: [.host, .deviceLocal]
                ),
                OutputPlanningImplementation(
                    identifier: "qualification.output-plan.large",
                    minimumOutputCapacityBytes: 8_192,
                    minimumTemporaryCapacityBytes: 4_096,
                    allowedMemoryDomains: [.host, .deviceLocal]
                )
            ],
            policy: policy,
            now: now
        )

        #expect(resolution.rankedCandidates.count == 2)
        #expect(resolution.rankedCandidates[0].candidate.implementation.specification.identifier.rawValue == "qualification.output-plan.small")
        let allocationEstimate = resolution.rankedCandidates[0].costEstimate.estimate(for: .minimumPlannedResourceCapacityBytes)
        #expect({
            guard let allocationEstimate,
                  case let .estimated(value: .integer(bytes), _) = allocationEstimate.state else {
                return false
            }
            return bytes == 6_144
        }())
        #expect(resolution.rankedCandidates[0].resourceMemoryDomainOptions.count == 2)
        #expect(resolution.rankedCandidates[0].resourceMemoryDomainOptions.allSatisfy {
            $0.domains == [.deviceLocal, .host]
        })
    }

    @Test
    func higherPriorityObjectivePrecedesLowerPriorityLatencyPreference() async throws {
        let now = Date(timeIntervalSince1970: 52_300)
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(
                identifier: .resourceMemoryDomains,
                value: .stringSet(["host"])
            )
        ])
        let provider = QualificationTestProvider(
            contextCapabilities: capabilities,
            capturedAt: now,
            allocatesResources: true
        )
        let policy = try ImageFunction(operation: OutputPlanningOperation()).qualifying {
            $0.prefer(.lowLatency, priority: 1)
            $0.prefer(.lowMemory, priority: 10)
        }.qualificationPolicy
        let resolution = try await makeOutputResolution(
            provider: provider,
            implementations: [
                OutputPlanningImplementation(
                    identifier: "qualification.output-plan.small-slower",
                    performanceHints: .init(fixedOverheadNanoseconds: 10_000)
                ),
                OutputPlanningImplementation(
                    identifier: "qualification.output-plan.large-faster",
                    minimumOutputCapacityBytes: 8_192,
                    minimumTemporaryCapacityBytes: 4_096,
                    performanceHints: .init(fixedOverheadNanoseconds: 1_000)
                )
            ],
            policy: policy,
            now: now
        )

        #expect(resolution.rankedCandidates.count == 2)
        #expect(resolution.rankedCandidates[0].candidate.implementation.specification.identifier.rawValue == "qualification.output-plan.small-slower")
        #expect(resolution.rankedCandidates[0].priorityScores.map(\.priority) == [10, 1])
        #expect(resolution.rankedCandidates[0].priorityScores[0].weightedScore == 1)
        #expect(resolution.rankedCandidates[0].priorityScores[1].weightedScore == 0)
    }

}


    @Test
    func precisionPreferenceRanksImplementationsThatSupportThePreferredMode() async throws {
        let now = Date(timeIntervalSince1970: 52_400)
        let unknownDelay = ExecutionObservation<UInt64>(
            unknownReason: "queue delay is not reported"
        )
        let policy = try ImageFunction(operation: QualificationOperation()).qualifying {
            $0.prefer(.precision(.computation, .float64), priority: 5)
        }.qualificationPolicy

        let resolution = try await makePrecisionResolution(
            providers: [
                makeQueueProvider(
                    identifier: "provider.precision",
                    delay: unknownDelay,
                    capturedAt: now
                )
            ],
            implementations: [
                QualificationImplementation(
                    identifier: "qualification.precision.float32",
                    precision: .init(computation: [.float32])
                ),
                QualificationImplementation(
                    identifier: "qualification.precision.float64",
                    precision: .init(computation: [.float64])
                )
            ],
            policy: policy,
            now: now
        )

        #expect(resolution.qualification.qualifiedCandidates.count == 2)
        #expect(resolution.rankedCandidates.count == 2)
        #expect(
            resolution.rankedCandidates[0].candidate.implementation.specification.identifier.rawValue
                == "qualification.precision.float64"
        )
        #expect(resolution.rankedCandidates[0].preferenceContributions.first?.weightedWinRate == 1)
        #expect(resolution.rankedCandidates[1].preferenceContributions.first?.weightedWinRate == 0)
    }
