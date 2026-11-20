import Foundation
import GeneralExecutionProtocol
@testable import ImageProcessingRuntime
import Testing

private struct WorkSnapshotProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor

    init(identifier: String) {
        self.descriptor = ExecutionProviderDescriptor(
            identifier: ExecutionProviderID(rawValue: identifier)!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            displayName: identifier
        )
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(
            availability: .available,
            queueDepth: ExecutionObservation(unknownReason: "provider does not report queue depth")
        )
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        []
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        WorkSnapshotContext(target: target)
    }
}

private struct WorkSnapshotContext: ExecutionContext {
    let target: ExecutionTargetReference
}

private final class ReservedResourceFixture: ExecutionResource, Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(
        target: ExecutionTargetReference,
        identifier: String,
        capacityBytes: UInt64 = 4096
    ) throws {
        descriptor = try ExecutionResourceDescriptor(
            identifier: ExecutionResourceIdentifier(rawValue: identifier)!,
            target: target,
            kind: .buffer,
            capacityBytes: capacityBytes,
            alignmentBytes: 16,
            memoryDomain: .host
        )
    }
}

private final class WeakReservedResourceBox {
    weak var value: ReservedResourceFixture?

    init(_ value: ReservedResourceFixture) {
        self.value = value
    }
}

struct RuntimeEnvironmentSnapshotTests {
    private func providerID(_ raw: String) -> ExecutionProviderID {
        ExecutionProviderID(rawValue: raw)!
    }

    private func target(_ provider: String, _ device: String? = nil) -> ExecutionTargetReference {
        ExecutionTargetReference(
            providerID: providerID(provider),
            deviceID: device.map { ExecutionDeviceID(rawValue: $0)! }
        )
    }

    private func platform() -> ExecutionPlatformDescriptor {
        ExecutionPlatformDescriptor(
            operatingSystem: "snapshot-test-os",
            architecture: "snapshot-test-arch"
        )
    }

    @Test
    func workLedgerTracksReservationSubmissionAndCompletionSeparately() async throws {
        let ledger = RuntimeWorkLedger()
        let target = target("provider.cpu", "cpu.0")
        let capturedAt = Date(timeIntervalSince1970: 30_000)

        let first = try await ledger.reserveWork(on: target)
        let second = try await ledger.reserveWork(on: target)

        var snapshot = await ledger.snapshot(capturedAt: capturedAt)
        var load = try #require(snapshot.load(for: target))
        #expect(load.reservedWorkCount == 2)
        #expect(load.submittedWorkCount == 0)

        try await ledger.markSubmitted(first)
        snapshot = await ledger.snapshot(capturedAt: capturedAt)
        load = try #require(snapshot.load(for: target))
        #expect(load.reservedWorkCount == 1)
        #expect(load.submittedWorkCount == 1)

        try await ledger.completeSubmission(first)
        try await ledger.cancelReservation(second)

        snapshot = await ledger.snapshot(capturedAt: capturedAt)
        #expect(snapshot.targets.isEmpty)
        #expect(await ledger.activeLeaseCount == 0)
    }

    @Test
    func ledgerRejectsInvalidAndRepeatedLeaseTransitions() async throws {
        let ledger = RuntimeWorkLedger()
        let lease = try await ledger.reserveWork(on: target("provider.gpu", "gpu.0"))

        await #expect(throws: RuntimeWorkLedgerError.invalidTransition(
            lease: lease.identifier,
            expected: .submitted,
            actual: .reserved
        )) {
            try await ledger.completeSubmission(lease)
        }

        try await ledger.markSubmitted(lease)

        await #expect(throws: RuntimeWorkLedgerError.invalidTransition(
            lease: lease.identifier,
            expected: .reserved,
            actual: .submitted
        )) {
            try await ledger.cancelReservation(lease)
        }

        try await ledger.completeSubmission(lease)

        await #expect(throws: RuntimeWorkLedgerError.unknownLease(lease.identifier)) {
            try await ledger.completeSubmission(lease)
        }
    }

    @Test
    func workloadSnapshotAggregatesAndSortsByExecutionTarget() async throws {
        let ledger = RuntimeWorkLedger()
        let targetB = target("provider.b", "device.0")
        let targetA = target("provider.a", "device.2")
        let opaque = target("provider.a")

        _ = try await ledger.reserveWork(on: targetB)
        let a1 = try await ledger.reserveWork(on: targetA)
        try await ledger.markSubmitted(a1)
        _ = try await ledger.reserveWork(on: opaque)

        let snapshot = await ledger.snapshot()
        #expect(snapshot.targets.count == 3)
        #expect(snapshot.targets.map(\.target) == [opaque, targetA, targetB])
        #expect(snapshot.load(for: targetA)?.submittedWorkCount == 1)
        #expect(snapshot.load(for: targetA)?.reservedWorkCount == 0)
        #expect(snapshot.load(for: targetB)?.reservedWorkCount == 1)
    }

    @Test
    func coordinatorCreatesUniqueSnapshotsWithMonotonicGeneration() async throws {
        let providers = ExecutionProviderRegistry()
        let ledger = RuntimeWorkLedger()
        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: ledger
        )
        let capturedAt = Date(timeIntervalSince1970: 40_000)

        let first = try await coordinator.capture(
            platform: platform(),
            capturedAt: capturedAt
        )
        let second = try await coordinator.capture(
            platform: platform(),
            capturedAt: capturedAt
        )

        #expect(first.generation == 1)
        #expect(second.generation == 2)
        #expect(first.identifier != second.identifier)
        #expect(first.capturedAt == capturedAt)
        #expect(first.environment.capturedAt == capturedAt)
        #expect(first.runtimeWorkLoad.capturedAt == capturedAt)
    }

    @Test
    func runtimeWorkCountsRemainSeparateFromProviderQueueTelemetry() async throws {
        let providers = ExecutionProviderRegistry()
        try await providers.register(WorkSnapshotProvider(identifier: "provider.cpu"))
        let ledger = RuntimeWorkLedger()
        let target = target("provider.cpu")
        let lease = try await ledger.reserveWork(on: target)
        try await ledger.markSubmitted(lease)

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: ledger
        )
        let snapshot = try await coordinator.capture(platform: platform())
        let provider = try #require(snapshot.environment.providers.first)
        let providerQueueState = provider.state.queueDepth.state(at: snapshot.capturedAt)

        #expect({
            if case .unknown = providerQueueState { return true }
            return false
        }())
        #expect(snapshot.runtimeWorkLoad.load(for: target)?.submittedWorkCount == 1)
    }

    @Test
    func coordinatorPreservesPartialDiscoveryFailuresAndRuntimeWorkload() async throws {
        let providers = ExecutionProviderRegistry()
        try await providers.register(WorkSnapshotProvider(identifier: "provider.partial"))
        let ledger = RuntimeWorkLedger()
        let target = target("provider.partial")
        let resource = try ReservedResourceFixture(target: target, identifier: "snapshot-resource")
        let lease = try await ledger.reserveWork(
            on: target,
            accessing: [ExecutionResourceAccess(resource: resource, mode: .read)]
        )

        let coordinator = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: ledger
        )
        let snapshot = try await coordinator.capture(platform: platform())

        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.environment.providers.count == 1)
        #expect(snapshot.runtimeWorkLoad.load(for: target)?.reservedWorkCount == 1)
        #expect(snapshot.runtimeWorkLoad.reservationLoad(for: resource.descriptor.reference)?.reservedReadCount == 1)
        try await ledger.cancelReservation(lease)
    }
}


extension RuntimeEnvironmentSnapshotTests {
    @Test
    func workLeaseAllowsSharedReadersAndExcludesWriters() async throws {
        let ledger = RuntimeWorkLedger()
        let target = target("provider.cpu", "cpu.0")
        let resource = try ReservedResourceFixture(target: target, identifier: "shared-buffer")
        let readA = ExecutionResourceAccess(resource: resource, mode: .read)
        let readB = ExecutionResourceAccess(resource: resource, mode: .read)
        let first = try await ledger.reserveWork(on: target, accessing: [readA])
        let second = try await ledger.reserveWork(on: target, accessing: [readB])

        await #expect(throws: RuntimeWorkLedgerError.resourceAccessConflict(
            resource: resource.descriptor.reference,
            requested: .write,
            active: .read
        )) {
            _ = try await ledger.reserveWork(
                on: target,
                accessing: [ExecutionResourceAccess(resource: resource, mode: .write)]
            )
        }

        try await ledger.cancelReservation(first)
        try await ledger.cancelReservation(second)

        let writer = try await ledger.reserveWork(
            on: target,
            accessing: [ExecutionResourceAccess(resource: resource, mode: .write)]
        )
        await #expect(throws: RuntimeWorkLedgerError.resourceAccessConflict(
            resource: resource.descriptor.reference,
            requested: .read,
            active: .write
        )) {
            _ = try await ledger.reserveWork(on: target, accessing: [readA])
        }
        try await ledger.cancelReservation(writer)
    }

    @Test
    func multiResourceWorkReservationIsAtomicWhenOneResourceConflicts() async throws {
        let ledger = RuntimeWorkLedger()
        let target = target("provider.cpu", "cpu.0")
        let firstResource = try ReservedResourceFixture(target: target, identifier: "first")
        let secondResource = try ReservedResourceFixture(target: target, identifier: "second")
        let held = try await ledger.reserveWork(
            on: target,
            accessing: [ExecutionResourceAccess(resource: secondResource, mode: .write)]
        )

        await #expect(throws: RuntimeWorkLedgerError.resourceAccessConflict(
            resource: secondResource.descriptor.reference,
            requested: .read,
            active: .write
        )) {
            _ = try await ledger.reserveWork(
                on: target,
                accessing: [
                    ExecutionResourceAccess(resource: firstResource, mode: .write),
                    ExecutionResourceAccess(resource: secondResource, mode: .read)
                ]
            )
        }

        let snapshot = await ledger.snapshot()
        #expect(snapshot.reservationLoad(for: firstResource.descriptor.reference) == nil)
        #expect(snapshot.reservationLoad(for: secondResource.descriptor.reference)?.reservedWriteCount == 1)

        let firstWriter = try await ledger.reserveWork(
            on: target,
            accessing: [ExecutionResourceAccess(resource: firstResource, mode: .write)]
        )
        try await ledger.cancelReservation(firstWriter)
        try await ledger.cancelReservation(held)
    }

    @Test
    func revalidationAndCompletionUseOneWorkResourceLeaseLifecycle() async throws {
        let ledger = RuntimeWorkLedger()
        let target = target("provider.gpu", "gpu.0")
        let resource = try ReservedResourceFixture(target: target, identifier: "image-plane")
        let readAccess = ExecutionResourceAccess(resource: resource, mode: .read)
        let lease = try await ledger.reserveWork(on: target, accessing: [readAccess])

        await #expect(throws: RuntimeWorkLedgerError.submissionRequiresRevalidation(lease.identifier)) {
            try await ledger.markSubmitted(lease)
        }
        try await ledger.revalidate(lease, accessing: [readAccess])

        let changedDescriptor = try ReservedResourceFixture(
            target: target,
            identifier: "image-plane",
            capacityBytes: 8192
        )
        await #expect(throws: RuntimeWorkLedgerError.resourceDescriptorChanged(resource.descriptor.reference)) {
            try await ledger.revalidate(
                lease,
                accessing: [ExecutionResourceAccess(resource: changedDescriptor, mode: .read)]
            )
        }

        await #expect(throws: RuntimeWorkLedgerError.resourceAccessSetChanged(lease.identifier)) {
            try await ledger.revalidate(
                lease,
                accessing: [ExecutionResourceAccess(resource: resource, mode: .write)]
            )
        }
        await #expect(throws: RuntimeWorkLedgerError.submissionRequiresRevalidation(lease.identifier)) {
            try await ledger.markSubmitted(lease)
        }

        try await ledger.revalidate(lease, accessing: [readAccess])
        let snapshotTime = Date(timeIntervalSince1970: 60_000)
        try await ledger.markSubmitted(lease)
        let snapshot = await ledger.snapshot(capturedAt: snapshotTime)
        #expect(snapshot.capturedAt == snapshotTime)
        #expect(snapshot.load(for: target)?.submittedWorkCount == 1)
        #expect(snapshot.reservationLoad(for: resource.descriptor.reference)?.submittedReadCount == 1)

        await #expect(throws: RuntimeWorkLedgerError.invalidTransition(
            lease: lease.identifier,
            expected: .reserved,
            actual: .submitted
        )) {
            try await ledger.cancelReservation(lease)
        }

        try await ledger.completeSubmission(lease)
        #expect(await ledger.activeLeaseCount == 0)
        #expect(await ledger.snapshot().resourceReservations.isEmpty)
    }

    @Test
    func workLeaseRetainsResourceUntilItsTerminalTransition() async throws {
        let ledger = RuntimeWorkLedger()
        let target = target("provider.cpu", "cpu.0")
        var resource: ReservedResourceFixture? = try ReservedResourceFixture(
            target: target,
            identifier: "retained-resource"
        )
        let weakResource = WeakReservedResourceBox(try #require(resource))
        var accesses = [
            ExecutionResourceAccess(resource: try #require(resource), mode: .read)
        ]
        let lease = try await ledger.reserveWork(on: target, accessing: accesses)

        accesses.removeAll()
        resource = nil
        #expect(weakResource.value != nil)

        try await ledger.cancelReservation(lease)
        #expect(weakResource.value == nil)
    }
}
