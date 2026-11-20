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
        precision: OperationPrecisionContract = .init(computation: [.float32])
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
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve]
            )
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

private enum QualificationProviderFixtureError: Error {
    case discovery
    case context
}

private struct QualificationTestDevice: ExecutionDevice {
    let descriptor: ExecutionDeviceDescriptor
    let availability: ExecutionAvailability
    let capturedAt: Date

    init(
        identifier: String,
        providerID: ExecutionProviderID,
        availability: ExecutionAvailability = .available,
        capabilities: ExecutionCapabilities = .init(),
        capturedAt: Date
    ) {
        descriptor = ExecutionDeviceDescriptor(
            identifier: ExecutionDeviceID(rawValue: identifier)!,
            providerID: providerID,
            displayName: identifier,
            capabilities: capabilities
        )
        self.availability = availability
        self.capturedAt = capturedAt
    }

    func observeState() async throws -> ExecutionDeviceStateSnapshot {
        ExecutionDeviceStateSnapshot(
            capturedAt: capturedAt,
            availability: availability
        )
    }
}

private struct QualificationTestContext: ExecutionContext {
    let target: ExecutionTargetReference
    let capabilities: ExecutionCapabilities
}

private struct QualificationTestProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor
    let devices: [QualificationTestDevice]
    let availability: ExecutionAvailability
    let capturedAt: Date
    let contextCapabilities: ExecutionCapabilities
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
        capturedAt: Date
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
        self.failsDiscovery = failsDiscovery
        self.failsContextCreation = failsContextCreation
        self.returnsWrongContextTarget = returnsWrongContextTarget
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(
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
            capturedAt: now
        )
        let resolver = CommonQualificationResolver(
            implementations: implementationRegistry,
            providers: providerRegistry
        )
        return try await resolver.evaluate(
            step: AnyImageOperationStep(operation: QualificationOperation()),
            policy: policy,
            environment: environment,
            freshness: freshness ?? self.freshness(),
            now: now
        )
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
}
