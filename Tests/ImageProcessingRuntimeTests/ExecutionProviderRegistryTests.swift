import Foundation
import GeneralExecutionProtocol
@testable import ImageProcessingRuntime
import Testing

private enum ProviderRegistryFixtureError: Error {
    case state
    case discovery
}

private actor ProviderContextGate {
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


private struct RegistryTestDevice: ExecutionDevice {
    let descriptor: ExecutionDeviceDescriptor
    let failsStateObservation: Bool

    init(
        identifier: String,
        providerID: ExecutionProviderID,
        failsStateObservation: Bool = false
    ) {
        self.descriptor = ExecutionDeviceDescriptor(
            identifier: ExecutionDeviceID(rawValue: identifier)!,
            providerID: providerID,
            displayName: identifier
        )
        self.failsStateObservation = failsStateObservation
    }

    func observeState() async throws -> ExecutionDeviceStateSnapshot {
        if failsStateObservation {
            throw ProviderRegistryFixtureError.state
        }
        return ExecutionDeviceStateSnapshot(availability: .available)
    }
}

private struct RegistryTestProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor
    let devices: [RegistryTestDevice]
    let failsStateObservation: Bool
    let failsDiscovery: Bool
    let contextRegistrationIdentifierOverride: UUID?
    let contextGate: ProviderContextGate?

    init(
        identifier: String,
        devices: [RegistryTestDevice] = [],
        failsStateObservation: Bool = false,
        failsDiscovery: Bool = false,
        contextRegistrationIdentifierOverride: UUID? = nil,
        contextGate: ProviderContextGate? = nil
    ) {
        let providerID = ExecutionProviderID(rawValue: identifier)!
        self.descriptor = ExecutionProviderDescriptor(
            identifier: providerID,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            displayName: identifier
        )
        self.devices = devices
        self.failsStateObservation = failsStateObservation
        self.failsDiscovery = failsDiscovery
        self.contextRegistrationIdentifierOverride = contextRegistrationIdentifierOverride
        self.contextGate = contextGate
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        if failsStateObservation {
            throw ProviderRegistryFixtureError.state
        }
        return ExecutionProviderStateSnapshot(availability: .available)
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        if failsDiscovery {
            throw ProviderRegistryFixtureError.discovery
        }
        return devices
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        guard target.providerID == descriptor.identifier,
              target.deviceID == nil || devices.contains(where: {
                  $0.descriptor.identifier == target.deviceID
              }) else {
            throw ProviderRegistryFixtureError.discovery
        }
        return RegistryTestContext(target: target)
    }

    func makeContext(
        for target: ExecutionTargetReference,
        registrationIdentifier: UUID
    ) async throws -> any ExecutionContext {
        guard target.providerID == descriptor.identifier,
              target.deviceID == nil || devices.contains(where: {
                  $0.descriptor.identifier == target.deviceID
              }) else {
            throw ProviderRegistryFixtureError.discovery
        }
        if let contextGate {
            await contextGate.suspend()
        }
        return RegistryBoundTestContext(
            target: target,
            providerRegistrationIdentifier: contextRegistrationIdentifierOverride ?? registrationIdentifier
        )
    }
}

private struct RegistryTestContext: ExecutionContext {
    let target: ExecutionTargetReference
}

private struct RegistryBoundTestContext: ExecutionProviderRegistrationBoundContext {
    let target: ExecutionTargetReference
    let providerRegistrationIdentifier: UUID
}

struct ExecutionProviderRegistryTests {
    private func platform() -> ExecutionPlatformDescriptor {
        ExecutionPlatformDescriptor(
            operatingSystem: "test-os",
            architecture: "test-arch",
            operatingSystemVersion: "1"
        )
    }

    private func providerID(_ raw: String) -> ExecutionProviderID {
        ExecutionProviderID(rawValue: raw)!
    }

    @Test
    func registersProvidersByStableIdentityAndRejectsDuplicates() async throws {
        let registry = ExecutionProviderRegistry()
        let first = RegistryTestProvider(identifier: "provider.b")
        let second = RegistryTestProvider(identifier: "provider.a")

        try await registry.register(first)
        try await registry.register(second)

        #expect(await registry.count == 2)
        let registered = await registry.registeredProviders()
        #expect(registered.map(\.descriptor.identifier.rawValue) == [
            "provider.a",
            "provider.b"
        ])

        await #expect(throws: ExecutionProviderRegistryError.duplicateProvider(providerID("provider.a"))) {
            try await registry.register(second)
        }
    }

    @Test
    func discoveryBuildsDeterministicSnapshotWithDeviceStates() async throws {
        let registry = ExecutionProviderRegistry()
        let providerID = providerID("provider.gpu")
        let device = RegistryTestDevice(identifier: "gpu.0", providerID: providerID)
        try await registry.register(
            RegistryTestProvider(identifier: "provider.gpu", devices: [device])
        )

        let capturedAt = Date(timeIntervalSince1970: 10_000)
        let discovery = try await registry.discoverEnvironment(
            platform: platform(),
            capturedAt: capturedAt
        )

        #expect(discovery.environment.capturedAt == capturedAt)
        #expect(discovery.environment.platform == platform())
        #expect(discovery.environment.providers.count == 1)
        #expect(discovery.environment.providers[0].devices.count == 1)
        #expect(discovery.environment.providers[0].devices[0].target.deviceID == device.descriptor.identifier)
        #expect(discovery.failures.isEmpty)
    }

    @Test
    func providerStateFailurePreservesProviderWithUnknownStateAndKeepsOtherProviders() async throws {
        let registry = ExecutionProviderRegistry()
        try await registry.register(
            RegistryTestProvider(
                identifier: "provider.failed-state",
                devices: [RegistryTestDevice(
                    identifier: "gpu.failed-state",
                    providerID: providerID("provider.failed-state")
                )],
                failsStateObservation: true
            )
        )
        try await registry.register(
            RegistryTestProvider(
                identifier: "provider.healthy",
                devices: [RegistryTestDevice(
                    identifier: "gpu.healthy",
                    providerID: providerID("provider.healthy")
                )]
            )
        )

        let result = try await registry.discoverEnvironment(platform: platform())
        #expect(result.environment.providers.count == 2)
        #expect(result.environment.providers[0].descriptor.identifier == providerID("provider.failed-state"))
        #expect(result.environment.providers[0].state.availability == .unknown(
            reason: "provider state observation failed"
        ))
        #expect(result.environment.providers[0].devices.count == 1)
        #expect(result.environment.providers[1].state.availability == .available)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].kind == .providerUnavailable)
        #expect(result.failures[0].providerID == providerID("provider.failed-state"))
    }

    @Test
    func deviceStateFailureKeepsDeviceWithUnknownStateAndTargetFailure() async throws {
        let registry = ExecutionProviderRegistry()
        let providerID = providerID("provider.device-state")
        let device = RegistryTestDevice(
            identifier: "gpu.unknown",
            providerID: providerID,
            failsStateObservation: true
        )
        try await registry.register(
            RegistryTestProvider(identifier: providerID.rawValue, devices: [device])
        )

        let result = try await registry.discoverEnvironment(platform: platform())
        let snapshot = try #require(result.environment.providers.first?.devices.first)

        #expect(snapshot.state.availability == .unknown(reason: "device state observation failed"))
        #expect(result.failures.count == 1)
        #expect(result.failures[0].kind == .deviceUnavailable)
        #expect(result.failures[0].target?.deviceID == device.descriptor.identifier)
    }

    @Test
    func providerDiscoveryFailureDoesNotEraseOtherRegisteredProviders() async throws {
        let registry = ExecutionProviderRegistry()
        try await registry.register(
            RegistryTestProvider(identifier: "provider.discovery-fails", failsDiscovery: true)
        )
        let healthyID = providerID("provider.healthy")
        try await registry.register(
            RegistryTestProvider(
                identifier: healthyID.rawValue,
                devices: [RegistryTestDevice(identifier: "cpu.0", providerID: healthyID)]
            )
        )

        let result = try await registry.discoverEnvironment(platform: platform())
        #expect(result.environment.providers.count == 2)
        #expect(result.environment.providers[0].descriptor.identifier == providerID("provider.discovery-fails"))
        #expect(result.environment.providers[0].devices.isEmpty)
        #expect(result.environment.providers[1].devices.count == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].kind == .deviceDiscoveryFailed)
    }

    @Test
    func opaqueProviderManagedTargetCanHaveNoDiscoveredDevices() async throws {
        let registry = ExecutionProviderRegistry()
        try await registry.register(RegistryTestProvider(identifier: "provider.opaque"))

        let result = try await registry.discoverEnvironment(platform: platform())
        #expect(result.environment.providers.count == 1)
        #expect(result.environment.providers[0].devices.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test
    func duplicateDeviceIdentifiersAreReportedAndOnlyOneSnapshotIsKept() async throws {
        let registry = ExecutionProviderRegistry()
        let providerID = providerID("provider.duplicates")
        let devices = [
            RegistryTestDevice(identifier: "gpu.0", providerID: providerID),
            RegistryTestDevice(identifier: "gpu.0", providerID: providerID)
        ]
        try await registry.register(
            RegistryTestProvider(identifier: providerID.rawValue, devices: devices)
        )

        let result = try await registry.discoverEnvironment(platform: platform())
        #expect(result.environment.providers[0].devices.count == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].kind == .providerContractViolation)
        #expect(result.failures[0].target?.deviceID == ExecutionDeviceID(rawValue: "gpu.0"))
    }

    @Test
    func deviceReportedByForeignProviderIsExcludedAndReported() async throws {
        let registry = ExecutionProviderRegistry()
        let expectedProvider = providerID("provider.expected")
        let foreignDevice = RegistryTestDevice(
            identifier: "foreign.0",
            providerID: providerID("provider.foreign")
        )
        try await registry.register(
            RegistryTestProvider(
                identifier: expectedProvider.rawValue,
                devices: [foreignDevice]
            )
        )

        let result = try await registry.discoverEnvironment(platform: platform())
        #expect(result.environment.providers[0].devices.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].kind == .providerContractViolation)
        #expect(result.failures[0].providerID == expectedProvider)
    }

    @Test
    func environmentSnapshotPinsProviderRegistrationIdentity() async throws {
        let registry = ExecutionProviderRegistry()
        let identifier = providerID("provider.replaceable")
        let first = RegistryTestProvider(identifier: identifier.rawValue)
        try await registry.register(first)

        let firstRegistrations = await registry.registeredProviders()
        let firstRegistration = try #require(firstRegistrations.first)
        let firstSnapshot = try await registry.discoverEnvironment(platform: platform())
        #expect(
            firstSnapshot.providerRegistrationIdentifiers[identifier]
                == firstRegistration.registrationIdentifier
        )

        #expect(await registry.unregister(identifier))
        let replacement = RegistryTestProvider(identifier: identifier.rawValue)
        try await registry.register(replacement)
        let replacementRegistrations = await registry.registeredProviders()
        let replacementRegistration = try #require(replacementRegistrations.first)
        #expect(replacementRegistration.registrationIdentifier != firstRegistration.registrationIdentifier)

        let secondSnapshot = try await registry.discoverEnvironment(platform: platform())
        #expect(
            secondSnapshot.providerRegistrationIdentifiers[identifier]
                == replacementRegistration.registrationIdentifier
        )

        let target = ExecutionTargetReference(providerID: identifier)
        await #expect(throws: ExecutionProviderRegistryError.providerRegistrationChanged(identifier)) {
            try await registry.makeContext(
                for: target,
                expecting: first.descriptor,
                registrationIdentifier: firstRegistration.registrationIdentifier
            )
        }

        let context = try await registry.makeContext(
            for: target,
            expecting: replacement.descriptor,
            registrationIdentifier: replacementRegistration.registrationIdentifier
        )
        #expect(context.target == target)
        #expect((context as? any ExecutionProviderRegistrationBoundContext)?.providerRegistrationIdentifier == replacementRegistration.registrationIdentifier)
    }

    @Test
    func rejectsContextCreatedForAnotherProviderRegistration() async throws {
        let registry = ExecutionProviderRegistry()
        let identifier = providerID("provider.context-registration-mismatch")
        let provider = RegistryTestProvider(
            identifier: identifier.rawValue,
            contextRegistrationIdentifierOverride: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        try await registry.register(provider)
        let registrations = await registry.registeredProviders()
        let registered = try #require(registrations.first)

        await #expect(throws: ExecutionProviderRegistryError.contextRegistrationMismatch(identifier)) {
            try await registry.makeContext(
                for: ExecutionTargetReference(providerID: identifier),
                expecting: provider.descriptor,
                registrationIdentifier: registered.registrationIdentifier
            )
        }
    }

    @Test
    func contextCreatedByProviderRemovedDuringFactoryAwaitIsRejected() async throws {
        let registry = ExecutionProviderRegistry()
        let identifier = providerID("provider.context-factory-race")
        let gate = ProviderContextGate()
        let firstProvider = RegistryTestProvider(
            identifier: identifier.rawValue,
            contextGate: gate
        )
        try await registry.register(firstProvider)
        let registrations = await registry.registeredProviders()
        let firstRegistration = try #require(registrations.first)
        let target = ExecutionTargetReference(providerID: identifier)

        let contextTask = Task {
            try await registry.makeContext(
                for: target,
                expecting: firstProvider.descriptor,
                registrationIdentifier: firstRegistration.registrationIdentifier
            )
        }

        await gate.waitUntilSuspended()
        #expect(await registry.unregister(identifier))
        try await registry.register(RegistryTestProvider(identifier: identifier.rawValue))
        await gate.resume()

        await #expect(throws: ExecutionProviderRegistryError.providerRegistrationChanged(identifier)) {
            _ = try await contextTask.value
        }
    }

    @Test
    func unregisterRemovesOnlyTheNamedProvider() async throws {
        let registry = ExecutionProviderRegistry()
        try await registry.register(RegistryTestProvider(identifier: "provider.a"))
        try await registry.register(RegistryTestProvider(identifier: "provider.b"))

        #expect(await registry.unregister(providerID("provider.a")))
        #expect(!(await registry.unregister(providerID("provider.a"))))
        #expect(await registry.count == 1)
        #expect(await registry.registeredProviders().first?.descriptor.identifier == providerID("provider.b"))
    }
}
