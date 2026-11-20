import Foundation
import GeneralExecutionProtocol

public struct RegisteredExecutionProvider: Hashable, Sendable {
    public let descriptor: ExecutionProviderDescriptor
}

public enum ExecutionProviderRegistryError: Error, Equatable, Sendable {
    case duplicateProvider(ExecutionProviderID)
    case providerNotRegistered(ExecutionProviderID)
    case targetProviderMismatch(expected: ExecutionProviderID, actual: ExecutionProviderID)
    case providerDescriptorChanged(ExecutionProviderID)
}

/// One discovery attempt can succeed partially. Provider/device failures are
/// retained alongside the environment snapshot; one failed backend does not
/// erase healthy providers from the same discovery pass.
public struct ExecutionEnvironmentDiscoverySnapshot: Sendable {
    public let environment: ExecutionEnvironmentSnapshot
    public let failures: [ExecutionProviderFailure]

    public init(
        environment: ExecutionEnvironmentSnapshot,
        failures: [ExecutionProviderFailure]
    ) {
        self.environment = environment
        self.failures = failures
    }
}

private struct RegisteredProviderEntry: Sendable {
    let descriptor: ExecutionProviderDescriptor
    let provider: any ExecutionProvider
}

/// Runtime-owned registry for provider packages selected by the consuming
/// application. Provider registration is separate from operation-implementation
/// registration and does not imply current availability.
public actor ExecutionProviderRegistry {
    private var entries: [ExecutionProviderID: RegisteredProviderEntry] = [:]

    public init() {}

    public var count: Int { entries.count }

    public func register(_ provider: any ExecutionProvider) throws {
        let descriptor = provider.descriptor
        guard entries[descriptor.identifier] == nil else {
            throw ExecutionProviderRegistryError.duplicateProvider(descriptor.identifier)
        }
        entries[descriptor.identifier] = RegisteredProviderEntry(
            descriptor: descriptor,
            provider: provider
        )
    }

    @discardableResult
    public func unregister(_ identifier: ExecutionProviderID) -> Bool {
        entries.removeValue(forKey: identifier) != nil
    }

    public func registeredProviders() -> [RegisteredExecutionProvider] {
        entries.values
            .map { RegisteredExecutionProvider(descriptor: $0.descriptor) }
            .sorted { $0.descriptor.identifier.rawValue < $1.descriptor.identifier.rawValue }
    }

    /// Creates a context only for a provider registration whose immutable
    /// descriptor still matches the descriptor used by the environment snapshot.
    public func makeContext(
        for target: ExecutionTargetReference,
        expecting expectedProvider: ExecutionProviderDescriptor
    ) async throws -> any ExecutionContext {
        guard target.providerID == expectedProvider.identifier else {
            throw ExecutionProviderRegistryError.targetProviderMismatch(
                expected: expectedProvider.identifier,
                actual: target.providerID
            )
        }
        guard let entry = entries[target.providerID] else {
            throw ExecutionProviderRegistryError.providerNotRegistered(target.providerID)
        }
        guard entry.descriptor == expectedProvider,
              entry.provider.descriptor == expectedProvider else {
            throw ExecutionProviderRegistryError.providerDescriptorChanged(target.providerID)
        }
        return try await entry.provider.makeContext(for: target)
    }

    /// Discovers all registered providers in deterministic provider order.
    ///
    /// Failures are partial: failed provider state/discovery is reported in the
    /// failures collection; known descriptors remain represented, and unknown
    /// state is never converted to available or zero load. A provider may
    /// legitimately return an empty device list for an opaque managed target.
    public func discoverEnvironment(
        platform: ExecutionPlatformDescriptor,
        capturedAt: Date = Date()
    ) async throws -> ExecutionEnvironmentDiscoverySnapshot {
        let registered = entries.values.sorted {
            $0.descriptor.identifier.rawValue < $1.descriptor.identifier.rawValue
        }

        var providerSnapshots: [ExecutionProviderSnapshot] = []
        var failures: [ExecutionProviderFailure] = []

        for entry in registered {
            let providerID = entry.descriptor.identifier
            let currentDescriptor = entry.provider.descriptor

            guard currentDescriptor == entry.descriptor else {
                failures.append(try Self.failure(
                    providerID: providerID,
                    target: nil,
                    error: nil,
                    kind: .providerContractViolation,
                    recovery: .permanent,
                    message: "Provider descriptor changed after registration."
                ))
                providerSnapshots.append(
                    try ExecutionProviderSnapshot(
                        descriptor: entry.descriptor,
                        state: ExecutionProviderStateSnapshot(
                            availability: .unknown(reason: "registered provider descriptor changed")
                        ),
                        devices: []
                    )
                )
                continue
            }

            let providerState: ExecutionProviderStateSnapshot
            do {
                providerState = try await entry.provider.observeState()
            } catch {
                failures.append(try Self.failure(
                    providerID: providerID,
                    target: nil,
                    error: error,
                    kind: .providerUnavailable,
                    recovery: .refreshEnvironment,
                    message: "Provider state observation failed."
                ))
                providerState = ExecutionProviderStateSnapshot(
                    availability: .unknown(reason: "provider state observation failed")
                )
            }

            let discoveredDevices: [any ExecutionDevice]
            do {
                discoveredDevices = try await entry.provider.discoverDevices()
            } catch {
                failures.append(try Self.failure(
                    providerID: providerID,
                    target: nil,
                    error: error,
                    kind: .deviceDiscoveryFailed,
                    recovery: .refreshEnvironment,
                    message: "Provider device discovery failed."
                ))
                discoveredDevices = []
            }

            let orderedDevices = discoveredDevices.sorted {
                $0.descriptor.identifier.rawValue < $1.descriptor.identifier.rawValue
            }
            var seenDeviceIDs = Set<ExecutionDeviceID>()
            var deviceSnapshots: [ExecutionDeviceSnapshot] = []

            for device in orderedDevices {
                let deviceDescriptor = device.descriptor
                let deviceTarget = ExecutionTargetReference(
                    providerID: providerID,
                    deviceID: deviceDescriptor.identifier
                )

                guard deviceDescriptor.providerID == providerID else {
                    failures.append(try Self.failure(
                        providerID: providerID,
                        target: nil,
                        error: nil,
                        kind: .providerContractViolation,
                        recovery: .permanent,
                        message: "Discovered device \(deviceDescriptor.identifier.rawValue) belongs to provider \(deviceDescriptor.providerID.rawValue)."
                    ))
                    continue
                }

                guard seenDeviceIDs.insert(deviceDescriptor.identifier).inserted else {
                    failures.append(try Self.failure(
                        providerID: providerID,
                        target: deviceTarget,
                        error: nil,
                        kind: .providerContractViolation,
                        recovery: .permanent,
                        message: "Provider returned a duplicate device identifier."
                    ))
                    continue
                }

                let deviceState: ExecutionDeviceStateSnapshot
                do {
                    deviceState = try await device.observeState()
                } catch {
                    failures.append(try Self.failure(
                        providerID: providerID,
                        target: deviceTarget,
                        error: error,
                        kind: .deviceUnavailable,
                        recovery: .refreshEnvironment,
                        message: "Device state observation failed."
                    ))
                    deviceState = ExecutionDeviceStateSnapshot(
                        availability: .unknown(reason: "device state observation failed")
                    )
                }

                deviceSnapshots.append(
                    ExecutionDeviceSnapshot(
                        descriptor: deviceDescriptor,
                        state: deviceState
                    )
                )
            }

            providerSnapshots.append(
                try ExecutionProviderSnapshot(
                    descriptor: entry.descriptor,
                    state: providerState,
                    devices: deviceSnapshots
                )
            )
        }

        let environment = try ExecutionEnvironmentSnapshot(
            capturedAt: capturedAt,
            platform: platform,
            providers: providerSnapshots
        )
        failures.sort {
            let lhsTarget = $0.target?.deviceID?.rawValue ?? ""
            let rhsTarget = $1.target?.deviceID?.rawValue ?? ""
            if $0.providerID.rawValue != $1.providerID.rawValue {
                return $0.providerID.rawValue < $1.providerID.rawValue
            }
            if lhsTarget != rhsTarget { return lhsTarget < rhsTarget }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return ExecutionEnvironmentDiscoverySnapshot(
            environment: environment,
            failures: failures
        )
    }

    private static func failure(
        providerID: ExecutionProviderID,
        target: ExecutionTargetReference?,
        error: (any Error)?,
        kind: ExecutionProviderFailureKind,
        recovery: ExecutionProviderRecovery,
        message: String
    ) throws -> ExecutionProviderFailure {
        if let reported = error as? ExecutionProviderFailure,
           reported.providerID == providerID {
            let resolvedTarget = reported.target ?? target
            if resolvedTarget == nil || resolvedTarget?.providerID == providerID {
                return try ExecutionProviderFailure(
                    providerID: providerID,
                    target: resolvedTarget,
                    kind: reported.kind,
                    recovery: reported.recovery,
                    message: reported.message ?? message,
                    nativeCode: reported.nativeCode
                )
            }
        }

        return try ExecutionProviderFailure(
            providerID: providerID,
            target: target,
            kind: kind,
            recovery: recovery,
            message: error.map { "\(message) \($0)" } ?? message
        )
    }
}
