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

public struct ExecutionWorkLease: Hashable, Sendable {
    public let identifier: ExecutionWorkLeaseIdentifier
    public let target: ExecutionTargetReference

    fileprivate init(
        identifier: ExecutionWorkLeaseIdentifier,
        target: ExecutionTargetReference
    ) {
        self.identifier = identifier
        self.target = target
    }
}

public enum RuntimeWorkLedgerError: Error, Equatable, Sendable {
    case unknownLease(ExecutionWorkLeaseIdentifier)
    case targetMismatch(
        lease: ExecutionWorkLeaseIdentifier,
        expected: ExecutionTargetReference,
        actual: ExecutionTargetReference
    )
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

public struct RuntimeWorkLoadSnapshot: Hashable, Sendable {
    public let capturedAt: Date
    public let targets: [ExecutionTargetWorkLoad]

    public init(capturedAt: Date, targets: [ExecutionTargetWorkLoad]) {
        self.capturedAt = capturedAt
        self.targets = targets.sorted { lhs, rhs in
            if lhs.target.providerID.rawValue != rhs.target.providerID.rawValue {
                return lhs.target.providerID.rawValue < rhs.target.providerID.rawValue
            }
            let leftDevice = lhs.target.deviceID?.rawValue ?? ""
            let rightDevice = rhs.target.deviceID?.rawValue ?? ""
            return leftDevice < rightDevice
        }
    }

    public func load(for target: ExecutionTargetReference) -> ExecutionTargetWorkLoad? {
        targets.first { $0.target == target }
    }
}

private struct RuntimeWorkLeaseRecord: Sendable {
    let target: ExecutionTargetReference
    var state: ExecutionWorkLeaseState
}

/// Runtime-owned accounting of work reservations and submitted operations.
///
/// The ledger does not replace provider queue/load observations. It reports only
/// work known to this runtime, allowing a resolver to use both sources without
/// treating unknown provider telemetry as zero or conflating distinct counters.
public actor RuntimeWorkLedger {
    private var leases: [ExecutionWorkLeaseIdentifier: RuntimeWorkLeaseRecord] = [:]

    public init() {}

    public var activeLeaseCount: Int { leases.count }

    public func reserveWork(on target: ExecutionTargetReference) throws -> ExecutionWorkLease {
        let identifier = ExecutionWorkLeaseIdentifier()
        guard leases[identifier] == nil else {
            throw RuntimeWorkLedgerError.unknownLease(identifier)
        }
        leases[identifier] = RuntimeWorkLeaseRecord(target: target, state: .reserved)
        return ExecutionWorkLease(identifier: identifier, target: target)
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
        leases[lease.identifier] = RuntimeWorkLeaseRecord(
            target: record.target,
            state: .submitted
        )
    }

    /// Releases a reservation only when no provider submission was created.
    public func cancelReservation(_ lease: ExecutionWorkLease) throws {
        let record = try record(for: lease)
        guard record.state == .reserved else {
            throw RuntimeWorkLedgerError.invalidTransition(
                lease: lease.identifier,
                expected: .reserved,
                actual: record.state
            )
        }
        leases.removeValue(forKey: lease.identifier)
    }

    /// A submitted lease remains active, including after a cancellation request,
    /// until the provider completion boundary has been observed.
    public func completeSubmission(_ lease: ExecutionWorkLease) throws {
        let record = try record(for: lease)
        guard record.state == .submitted else {
            throw RuntimeWorkLedgerError.invalidTransition(
                lease: lease.identifier,
                expected: .submitted,
                actual: record.state
            )
        }
        leases.removeValue(forKey: lease.identifier)
    }

    public func snapshot(capturedAt: Date = Date()) -> RuntimeWorkLoadSnapshot {
        struct Counts {
            var reserved: UInt64 = 0
            var submitted: UInt64 = 0
        }

        var countsByTarget: [ExecutionTargetReference: Counts] = [:]
        for record in leases.values {
            var counts = countsByTarget[record.target] ?? Counts()
            switch record.state {
            case .reserved:
                counts.reserved += 1
            case .submitted:
                counts.submitted += 1
            }
            countsByTarget[record.target] = counts
        }

        let targets = countsByTarget.map { target, counts in
            ExecutionTargetWorkLoad(
                target: target,
                reservedWorkCount: counts.reserved,
                submittedWorkCount: counts.submitted
            )
        }
        return RuntimeWorkLoadSnapshot(capturedAt: capturedAt, targets: targets)
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
        return record
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
