import Foundation
import GeneralExecutionProtocol

public struct ExecutionWorkLeaseIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ExecutionWorkLeaseState: String, Hashable, Sendable {
    case reserved
    case submitted
}

public struct ExecutionResourceReservationAccess: Hashable, Sendable {
    public let reference: ExecutionResourceReference
    public let mode: ExecutionResourceAccessMode

    public init(reference: ExecutionResourceReference, mode: ExecutionResourceAccessMode) {
        self.reference = reference
        self.mode = mode
    }
}

public struct ExecutionWorkLease: Hashable, Sendable {
    public let identifier: ExecutionWorkLeaseIdentifier
    public let target: ExecutionTargetReference
    /// Exact generic resource handles retained by this lease until its terminal transition.
    public let resourceAccesses: [ExecutionResourceReservationAccess]

    fileprivate init(
        identifier: ExecutionWorkLeaseIdentifier,
        target: ExecutionTargetReference,
        resourceAccesses: [ExecutionResourceReservationAccess]
    ) {
        self.identifier = identifier
        self.target = target
        self.resourceAccesses = resourceAccesses
    }
}

public enum RuntimeWorkLedgerError: Error, Equatable, Sendable {
    case unknownLease(ExecutionWorkLeaseIdentifier)
    case targetMismatch(
        lease: ExecutionWorkLeaseIdentifier,
        expected: ExecutionTargetReference,
        actual: ExecutionTargetReference
    )
    case resourceTargetMismatch(
        expected: ExecutionTargetReference,
        actual: ExecutionTargetReference
    )
    case resourceDescriptorChanged(ExecutionResourceReference)
    case resourceAccessConflict(
        resource: ExecutionResourceReference,
        requested: ExecutionResourceAccessMode,
        active: ExecutionResourceAccessMode
    )
    case resourceAccessSetChanged(ExecutionWorkLeaseIdentifier)
    case submissionRequiresRevalidation(ExecutionWorkLeaseIdentifier)
    case invalidTransition(
        lease: ExecutionWorkLeaseIdentifier,
        expected: ExecutionWorkLeaseState,
        actual: ExecutionWorkLeaseState
    )
}

public struct ExecutionTargetWorkLoad: Hashable, Sendable {
    public let target: ExecutionTargetReference
    public let reservedWorkCount: UInt64
    public let submittedWorkCount: UInt64
}

public struct ExecutionResourceReservationLoad: Hashable, Sendable {
    public let resource: ExecutionResourceReference
    public let reservedReadCount: UInt64
    public let reservedWriteCount: UInt64
    public let submittedReadCount: UInt64
    public let submittedWriteCount: UInt64
}

public struct RuntimeWorkLoadSnapshot: Hashable, Sendable {
    public let capturedAt: Date
    public let targets: [ExecutionTargetWorkLoad]
    /// Runtime-owned resource access counts, separate from provider telemetry.
    public let resourceReservations: [ExecutionResourceReservationLoad]

    public init(
        capturedAt: Date,
        targets: [ExecutionTargetWorkLoad],
        resourceReservations: [ExecutionResourceReservationLoad] = []
    ) {
        self.capturedAt = capturedAt
        self.targets = targets.sorted { lhs, rhs in
            if lhs.target.providerID.rawValue != rhs.target.providerID.rawValue {
                return lhs.target.providerID.rawValue < rhs.target.providerID.rawValue
            }
            let leftDevice = lhs.target.deviceID?.rawValue ?? ""
            let rightDevice = rhs.target.deviceID?.rawValue ?? ""
            return leftDevice < rightDevice
        }
        self.resourceReservations = resourceReservations.sorted { lhs, rhs in
            if lhs.resource.target.providerID.rawValue != rhs.resource.target.providerID.rawValue {
                return lhs.resource.target.providerID.rawValue < rhs.resource.target.providerID.rawValue
            }
            let leftDevice = lhs.resource.target.deviceID?.rawValue ?? ""
            let rightDevice = rhs.resource.target.deviceID?.rawValue ?? ""
            if leftDevice != rightDevice { return leftDevice < rightDevice }
            if lhs.resource.identifier.rawValue != rhs.resource.identifier.rawValue {
                return lhs.resource.identifier.rawValue < rhs.resource.identifier.rawValue
            }
            let leftRegistration = lhs.resource.providerRegistrationIdentifier?.uuidString ?? ""
            let rightRegistration = rhs.resource.providerRegistrationIdentifier?.uuidString ?? ""
            return leftRegistration < rightRegistration
        }
    }

    public func load(for target: ExecutionTargetReference) -> ExecutionTargetWorkLoad? {
        targets.first { $0.target == target }
    }

    public func reservationLoad(
        for resource: ExecutionResourceReference
    ) -> ExecutionResourceReservationLoad? {
        resourceReservations.first { $0.resource == resource }
    }
}

private struct RuntimeLeaseResourceRecord: Sendable {
    let resource: any ExecutionResource
    let descriptor: ExecutionResourceDescriptor
    var mode: ExecutionResourceAccessMode
}

private struct RuntimeWorkLeaseRecord: Sendable {
    let target: ExecutionTargetReference
    let resources: [ExecutionResourceReference: RuntimeLeaseResourceRecord]
    var state: ExecutionWorkLeaseState
    var hasBeenRevalidated: Bool
}

/// One runtime-owned lease accounts for both outstanding work and the exact
/// resources accessed by that work. Keeping both in one actor makes acquisition,
/// submission, cancellation-before-submit, and completion transitions atomic.
///
/// The ledger coordinates only resources known to this runtime. It does not
/// allocate memory, infer residency, or replace provider allocation/validation.
/// Provider queue/load observations remain separate from these runtime counts.
public actor RuntimeWorkLedger {
    private var leases: [ExecutionWorkLeaseIdentifier: RuntimeWorkLeaseRecord] = [:]
    private var reservationsByResource: [ExecutionResourceReference: [ExecutionWorkLeaseIdentifier: ExecutionResourceAccessMode]] = [:]

    public init() {}

    public var activeLeaseCount: Int { leases.count }

    /// Reserves a work slot without declaring resource accesses.
    public func reserveWork(on target: ExecutionTargetReference) throws -> ExecutionWorkLease {
        try reserveWork(on: target, accessing: [])
    }

    /// Atomically reserves a work slot and its complete resource-access set.
    /// Concurrent readers may coexist; any write or read-write access is exclusive.
    /// No partial resource reservation remains when one access conflicts.
    public func reserveWork(
        on target: ExecutionTargetReference,
        accessing accesses: [ExecutionResourceAccess]
    ) throws -> ExecutionWorkLease {
        let resources = try normalizedResourceAccesses(accesses, on: target)

        for reference in resources.keys.sorted(by: Self.referencePrecedes) {
            guard let requested = resources[reference] else { continue }
            if let activeReservations = reservationsByResource[reference] {
                for active in activeReservations.values {
                    guard requested.mode == .read, active == .read else {
                        throw RuntimeWorkLedgerError.resourceAccessConflict(
                            resource: reference,
                            requested: requested.mode,
                            active: active
                        )
                    }
                }
            }
        }

        let identifier = ExecutionWorkLeaseIdentifier()
        guard leases[identifier] == nil else {
            throw RuntimeWorkLedgerError.unknownLease(identifier)
        }

        let record = RuntimeWorkLeaseRecord(
            target: target,
            resources: resources,
            state: .reserved,
            hasBeenRevalidated: false
        )
        leases[identifier] = record

        for (reference, access) in resources {
            reservationsByResource[reference, default: [:]][identifier] = access.mode
        }

        return ExecutionWorkLease(
            identifier: identifier,
            target: target,
            resourceAccesses: publicAccesses(from: resources)
        )
    }

    /// Revalidates current immutable input-snapshot resource bindings immediately
    /// before provider submission. The lease must still be in the reserved state.
    public func revalidate(
        _ lease: ExecutionWorkLease,
        accessing accesses: [ExecutionResourceAccess]
    ) throws {
        let record = try record(for: lease)
        guard record.state == .reserved else {
            throw RuntimeWorkLedgerError.invalidTransition(
                lease: lease.identifier,
                expected: .reserved,
                actual: record.state
            )
        }

        // A failed refresh must not leave an earlier validation usable.
        leases[lease.identifier] = RuntimeWorkLeaseRecord(
            target: record.target,
            resources: record.resources,
            state: .reserved,
            hasBeenRevalidated: false
        )

        let current = try normalizedResourceAccesses(accesses, on: record.target)
        guard Set(current.keys) == Set(record.resources.keys),
              current.allSatisfy({ reference, access in
                  record.resources[reference]?.mode == access.mode
              }) else {
            throw RuntimeWorkLedgerError.resourceAccessSetChanged(lease.identifier)
        }

        for (reference, access) in current {
            guard record.resources[reference]?.descriptor == access.descriptor else {
                throw RuntimeWorkLedgerError.resourceDescriptorChanged(reference)
            }
        }

        leases[lease.identifier] = RuntimeWorkLeaseRecord(
            target: record.target,
            resources: record.resources,
            state: .reserved,
            hasBeenRevalidated: true
        )
    }

    public func markSubmitted(_ lease: ExecutionWorkLease) throws {
        let record = try record(for: lease)
        guard record.state == .reserved else {
            throw RuntimeWorkLedgerError.invalidTransition(
                lease: lease.identifier,
                expected: .reserved,
                actual: record.state
            )
        }
        guard record.resources.isEmpty || record.hasBeenRevalidated else {
            throw RuntimeWorkLedgerError.submissionRequiresRevalidation(lease.identifier)
        }
        leases[lease.identifier] = RuntimeWorkLeaseRecord(
            target: record.target,
            resources: record.resources,
            state: .submitted,
            hasBeenRevalidated: record.hasBeenRevalidated
        )
    }

    /// Releases work and its reserved resource accesses only when provider
    /// submission has not occurred.
    public func cancelReservation(_ lease: ExecutionWorkLease) throws {
        let record = try record(for: lease)
        guard record.state == .reserved else {
            throw RuntimeWorkLedgerError.invalidTransition(
                lease: lease.identifier,
                expected: .reserved,
                actual: record.state
            )
        }
        release(lease.identifier, record: record)
    }

    /// Releases submitted work and retained resource handles only after the
    /// provider completion boundary has been observed. A cancellation request
    /// alone does not release either reservation.
    public func completeSubmission(_ lease: ExecutionWorkLease) throws {
        let record = try record(for: lease)
        guard record.state == .submitted else {
            throw RuntimeWorkLedgerError.invalidTransition(
                lease: lease.identifier,
                expected: .submitted,
                actual: record.state
            )
        }
        release(lease.identifier, record: record)
    }

    public func snapshot(capturedAt: Date = Date()) -> RuntimeWorkLoadSnapshot {
        struct WorkCounts {
            var reserved: UInt64 = 0
            var submitted: UInt64 = 0
        }
        struct ResourceCounts {
            var reservedRead: UInt64 = 0
            var reservedWrite: UInt64 = 0
            var submittedRead: UInt64 = 0
            var submittedWrite: UInt64 = 0
        }

        var countsByTarget: [ExecutionTargetReference: WorkCounts] = [:]
        var countsByResource: [ExecutionResourceReference: ResourceCounts] = [:]

        for record in leases.values {
            var workCounts = countsByTarget[record.target] ?? WorkCounts()
            switch record.state {
            case .reserved:
                workCounts.reserved += 1
            case .submitted:
                workCounts.submitted += 1
            }
            countsByTarget[record.target] = workCounts

            for (reference, access) in record.resources {
                var resourceCounts = countsByResource[reference] ?? ResourceCounts()
                let isReadOnly = access.mode == .read
                switch (record.state, isReadOnly) {
                case (.reserved, true):
                    resourceCounts.reservedRead += 1
                case (.reserved, false):
                    resourceCounts.reservedWrite += 1
                case (.submitted, true):
                    resourceCounts.submittedRead += 1
                case (.submitted, false):
                    resourceCounts.submittedWrite += 1
                }
                countsByResource[reference] = resourceCounts
            }
        }

        let targets = countsByTarget.map { target, counts in
            ExecutionTargetWorkLoad(
                target: target,
                reservedWorkCount: counts.reserved,
                submittedWorkCount: counts.submitted
            )
        }
        let resourceReservations = countsByResource.map { reference, counts in
            ExecutionResourceReservationLoad(
                resource: reference,
                reservedReadCount: counts.reservedRead,
                reservedWriteCount: counts.reservedWrite,
                submittedReadCount: counts.submittedRead,
                submittedWriteCount: counts.submittedWrite
            )
        }

        return RuntimeWorkLoadSnapshot(
            capturedAt: capturedAt,
            targets: targets,
            resourceReservations: resourceReservations
        )
    }

    private func normalizedResourceAccesses(
        _ accesses: [ExecutionResourceAccess],
        on target: ExecutionTargetReference
    ) throws -> [ExecutionResourceReference: RuntimeLeaseResourceRecord] {
        var normalized: [ExecutionResourceReference: RuntimeLeaseResourceRecord] = [:]

        for access in accesses {
            let descriptor = access.resource.descriptor
            guard descriptor.target == target else {
                throw RuntimeWorkLedgerError.resourceTargetMismatch(
                    expected: target,
                    actual: descriptor.target
                )
            }

            let reference = descriptor.reference
            if var existing = normalized[reference] {
                guard existing.descriptor == descriptor else {
                    throw RuntimeWorkLedgerError.resourceDescriptorChanged(reference)
                }
                existing.mode = Self.merged(existing.mode, access.mode)
                normalized[reference] = existing
            } else {
                normalized[reference] = RuntimeLeaseResourceRecord(
                    resource: access.resource,
                    descriptor: descriptor,
                    mode: access.mode
                )
            }
        }
        return normalized
    }

    private func publicAccesses(
        from resources: [ExecutionResourceReference: RuntimeLeaseResourceRecord]
    ) -> [ExecutionResourceReservationAccess] {
        resources.map { reference, access in
            ExecutionResourceReservationAccess(reference: reference, mode: access.mode)
        }.sorted { lhs, rhs in
            if lhs.reference.target.providerID.rawValue != rhs.reference.target.providerID.rawValue {
                return lhs.reference.target.providerID.rawValue < rhs.reference.target.providerID.rawValue
            }
            let leftDevice = lhs.reference.target.deviceID?.rawValue ?? ""
            let rightDevice = rhs.reference.target.deviceID?.rawValue ?? ""
            if leftDevice != rightDevice { return leftDevice < rightDevice }
            if lhs.reference.identifier.rawValue != rhs.reference.identifier.rawValue {
            return lhs.reference.identifier.rawValue < rhs.reference.identifier.rawValue
        }
        let leftRegistration = lhs.reference.providerRegistrationIdentifier?.uuidString ?? ""
        let rightRegistration = rhs.reference.providerRegistrationIdentifier?.uuidString ?? ""
        return leftRegistration < rightRegistration
        }
    }

    private func record(for lease: ExecutionWorkLease) throws -> RuntimeWorkLeaseRecord {
        guard let record = leases[lease.identifier] else {
            throw RuntimeWorkLedgerError.unknownLease(lease.identifier)
        }
        guard record.target == lease.target else {
            throw RuntimeWorkLedgerError.targetMismatch(
                lease: lease.identifier,
                expected: record.target,
                actual: lease.target
            )
        }
        guard lease.resourceAccesses == publicAccesses(from: record.resources) else {
            throw RuntimeWorkLedgerError.resourceAccessSetChanged(lease.identifier)
        }
        return record
    }

    private func release(
        _ identifier: ExecutionWorkLeaseIdentifier,
        record: RuntimeWorkLeaseRecord
    ) {
        leases.removeValue(forKey: identifier)
        for reference in record.resources.keys {
            reservationsByResource[reference]?.removeValue(forKey: identifier)
            if reservationsByResource[reference]?.isEmpty == true {
                reservationsByResource.removeValue(forKey: reference)
            }
        }
    }

    private static func referencePrecedes(
        _ lhs: ExecutionResourceReference,
        _ rhs: ExecutionResourceReference
    ) -> Bool {
        if lhs.target.providerID.rawValue != rhs.target.providerID.rawValue {
            return lhs.target.providerID.rawValue < rhs.target.providerID.rawValue
        }
        let leftDevice = lhs.target.deviceID?.rawValue ?? ""
        let rightDevice = rhs.target.deviceID?.rawValue ?? ""
        if leftDevice != rightDevice { return leftDevice < rightDevice }
        if lhs.identifier.rawValue != rhs.identifier.rawValue {
            return lhs.identifier.rawValue < rhs.identifier.rawValue
        }
        let leftRegistration = lhs.providerRegistrationIdentifier?.uuidString ?? ""
        let rightRegistration = rhs.providerRegistrationIdentifier?.uuidString ?? ""
        return leftRegistration < rightRegistration
    }

    private static func merged(
        _ lhs: ExecutionResourceAccessMode,
        _ rhs: ExecutionResourceAccessMode
    ) -> ExecutionResourceAccessMode {
        if lhs == rhs { return lhs }
        if lhs == .read && rhs == .read { return .read }
        if lhs == .write && rhs == .write { return .write }
        return .readWrite
    }
}

public struct RuntimeEnvironmentSnapshotIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct RuntimeEnvironmentSnapshot: Sendable {
    public let identifier: RuntimeEnvironmentSnapshotIdentifier
    /// Monotonically increasing for snapshots captured by one coordinator.
    public let generation: UInt64
    public let capturedAt: Date
    public let discovery: ExecutionEnvironmentDiscoverySnapshot
    public let runtimeWorkLoad: RuntimeWorkLoadSnapshot

    public var environment: ExecutionEnvironmentSnapshot { discovery.environment }
    public var failures: [ExecutionProviderFailure] { discovery.failures }
    public var providerRegistrationIdentifiers: [ExecutionProviderID: UUID] {
        discovery.providerRegistrationIdentifiers
    }
}

public enum RuntimeEnvironmentSnapshotCoordinatorError: Error, Equatable, Sendable {
    case generationExhausted
}

/// Creates one identity-bearing snapshot from provider observations and the
/// runtime's own outstanding-work ledger. Provider telemetry and runtime counts
/// remain separate fields in the result.
public actor RuntimeEnvironmentSnapshotCoordinator {
    private let providers: ExecutionProviderRegistry
    private let workLedger: RuntimeWorkLedger
    private var generation: UInt64 = 0

    public init(
        providers: ExecutionProviderRegistry,
        workLedger: RuntimeWorkLedger
    ) {
        self.providers = providers
        self.workLedger = workLedger
    }

    public func capture(
        platform: ExecutionPlatformDescriptor,
        capturedAt: Date = Date()
    ) async throws -> RuntimeEnvironmentSnapshot {
        guard generation < UInt64.max else {
            throw RuntimeEnvironmentSnapshotCoordinatorError.generationExhausted
        }
        generation += 1
        let snapshotGeneration = generation

        async let discovery = providers.discoverEnvironment(
            platform: platform,
            capturedAt: capturedAt
        )
        async let runtimeWorkLoad = workLedger.snapshot(capturedAt: capturedAt)

        return RuntimeEnvironmentSnapshot(
            identifier: RuntimeEnvironmentSnapshotIdentifier(),
            generation: snapshotGeneration,
            capturedAt: capturedAt,
            discovery: try await discovery,
            runtimeWorkLoad: await runtimeWorkLoad
        )
    }
}
