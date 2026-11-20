import Foundation
import Testing
@testable import GeneralExecutionProtocol

struct ExecutionContractsTests {
    @Test
    func capabilityRequirementsAreEvaluatedAgainstReportedValues() throws {
        let coreCount = try #require(ExecutionCapabilityID(rawValue: "compute.logical-units"))
        let deviceType = try #require(ExecutionCapabilityID(rawValue: "compute.device-class"))
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: coreCount, value: .integer(24)),
            ExecutionCapability(identifier: deviceType, value: .stringSet(["gpu", "compute"]))
        ])

        #expect(capabilities.satisfies(.integerAtLeast(coreCount, 16)))
        #expect(capabilities.satisfies(.stringSetContains(deviceType, "gpu")))
        #expect(!capabilities.satisfies(.integerAtLeast(coreCount, 32)))
    }

    @Test
    func duplicateCapabilityIdentifiersAreRejected() throws {
        let identifier = try #require(ExecutionCapabilityID(rawValue: "memory.shared"))
        let capability = ExecutionCapability(identifier: identifier, value: .boolean(true))

        #expect(throws: ExecutionCapabilitiesError.duplicateIdentifier(identifier)) {
            try ExecutionCapabilities([capability, capability])
        }
    }

    @Test
    func unknownAndStaleObservationsRemainDistinct() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = try ExecutionObservation(
            value: UInt64(0),
            observedAt: now,
            validUntil: now.addingTimeInterval(5),
            source: "provider.telemetry",
            quality: .reported
        )
        let unknown = ExecutionObservation<Int>(unknownReason: "provider does not expose queue depth")

        #expect({
            if case .known(0) = fresh.state(at: now.addingTimeInterval(1)) { return true }
            return false
        }())
        #expect({
            if case .stale(0) = fresh.state(at: now.addingTimeInterval(6)) { return true }
            return false
        }())
        #expect({
            if case .unknown = unknown.state(at: now) { return true }
            return false
        }())
    }

    @Test
    func invalidObservationExpiryIsRejected() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(throws: ExecutionObservationError.expirationPrecedesObservation) {
            try ExecutionObservation(
                value: 3,
                observedAt: now,
                validUntil: now.addingTimeInterval(-1),
                source: "provider.telemetry",
                quality: .reported
            )
        }
    }

    @Test
    func deviceSnapshotCanRepresentUnavailableDeviceWithoutInventingMetrics() throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.cpu"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "cpu.default"))
        let target = ExecutionTargetReference(providerID: providerID, deviceID: deviceID)
        let descriptor = ExecutionDeviceDescriptor(
            identifier: deviceID,
            providerID: providerID,
            displayName: "CPU"
        )
        let state = ExecutionDeviceStateSnapshot(
            availability: .unavailable(reason: "runtime shut down")
        )
        let snapshot = ExecutionDeviceSnapshot(descriptor: descriptor, state: state)

        #expect(snapshot.target == target)
        #expect(snapshot.state.availability == .unavailable(reason: "runtime shut down"))
        #expect({
            if case .unknown = snapshot.state.queueDepth.state() { return true }
            return false
        }())
    }
}

struct ProviderSnapshotTests {
    @Test
    func deviceCapabilityRequirementRespectsItsDeclaredScope() throws {
        let capabilityID = try #require(ExecutionCapabilityID(rawValue: "compute.fp64"))
        let providerCapabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: capabilityID, value: .boolean(false))
        ])
        let deviceCapabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: capabilityID, value: .boolean(true))
        ])
        let requirement = ExecutionCapabilityRequirement.exact(capabilityID, .boolean(true))
        let constraint = ExecutionCapabilityConstraint(scope: .device, requirement: requirement)

        #expect(constraint.isSatisfied(
            providerCapabilities: providerCapabilities,
            deviceCapabilities: deviceCapabilities
        ))
        #expect(!ExecutionCapabilityConstraint(scope: .provider, requirement: requirement)
            .isSatisfied(providerCapabilities: providerCapabilities, deviceCapabilities: deviceCapabilities))
    }

    @Test
    func providerCanRepresentOpaqueManagedExecutionWithoutDeviceEnumeration() throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "runtime.onnx"))
        let version = try #require(SemanticVersion(major: 1, minor: 0, patch: 0))
        let descriptor = ExecutionProviderDescriptor(
            identifier: providerID,
            version: version,
            displayName: "Managed model runtime"
        )
        let provider = try ExecutionProviderSnapshot(
            descriptor: descriptor,
            state: ExecutionProviderStateSnapshot(availability: .available),
            devices: []
        )
        let environment = try ExecutionEnvironmentSnapshot(
            platform: ExecutionPlatformDescriptor(operatingSystem: "linux", architecture: "x86_64"),
            providers: [provider]
        )

        #expect(environment.providers.count == 1)
        #expect(environment.providers[0].devices.isEmpty)
    }

    @Test
    func providerSnapshotRejectsDeviceFromAnotherProvider() throws {
        let providerA = try #require(ExecutionProviderID(rawValue: "provider.a"))
        let providerB = try #require(ExecutionProviderID(rawValue: "provider.b"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.0"))
        let version = try #require(SemanticVersion(major: 1, minor: 0, patch: 0))
        let descriptor = ExecutionProviderDescriptor(
            identifier: providerA,
            version: version,
            displayName: "Provider A"
        )
        let device = ExecutionDeviceDescriptor(
            identifier: deviceID,
            providerID: providerB,
            displayName: "Foreign device"
        )
        let deviceSnapshot = ExecutionDeviceSnapshot(
            descriptor: device,
            state: ExecutionDeviceStateSnapshot(availability: .available)
        )

        #expect(throws: ExecutionProviderSnapshotError.deviceBelongsToAnotherProvider(
            expected: providerA,
            actual: providerB,
            device: deviceID
        )) {
            try ExecutionProviderSnapshot(
                descriptor: descriptor,
                state: ExecutionProviderStateSnapshot(availability: .available),
                devices: [deviceSnapshot]
            )
        }
    }
}
