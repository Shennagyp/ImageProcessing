import Foundation

public enum ObservationQuality: String, Hashable, Sendable {
    case reported
    case estimated
    case inferred
}

public enum ExecutionObservationError: Error, Equatable, Sendable {
    case emptySource
    case expirationPrecedesObservation
}

public enum ExecutionObservationState<Value: Sendable>: Sendable {
    case known(Value)
    case unknown(reason: String)
    case stale(Value)
}

/// A time-bounded observation. Every known value has an explicit expiry;
/// unknown and stale values can never be confused with zero-valued measurements.
public struct ExecutionObservation<Value: Sendable>: Sendable {
    private enum Storage: Sendable {
        case value(Value)
        case unknown(String)
    }

    private let storage: Storage
    public let observedAt: Date?
    public let validUntil: Date?
    public let source: String?
    public let quality: ObservationQuality?

    public init(
        value: Value,
        observedAt: Date,
        validUntil: Date,
        source: String,
        quality: ObservationQuality
    ) throws {
        guard !source.isEmpty else {
            throw ExecutionObservationError.emptySource
        }
        guard validUntil >= observedAt else {
            throw ExecutionObservationError.expirationPrecedesObservation
        }
        self.storage = .value(value)
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.source = source
        self.quality = quality
    }

    public init(unknownReason: String) {
        self.storage = .unknown(unknownReason)
        self.observedAt = nil
        self.validUntil = nil
        self.source = nil
        self.quality = nil
    }

    public func state(at date: Date = .now) -> ExecutionObservationState<Value> {
        switch storage {
        case let .unknown(reason):
            return .unknown(reason: reason)
        case let .value(value):
            guard let validUntil else {
                return .stale(value)
            }
            if date > validUntil {
                return .stale(value)
            }
            return .known(value)
        }
    }
}

/// A validated fraction in the inclusive range 0...1.
public struct ExecutionFraction: Hashable, Sendable {
    public let value: Double

    public init?(value: Double) {
        guard value.isFinite, (0.0...1.0).contains(value) else { return nil }
        self.value = value
    }
}

public enum ExecutionAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)
    case unknown(reason: String)
}

public struct ExecutionDeviceStateSnapshot: Sendable {
    public let capturedAt: Date
    public let availability: ExecutionAvailability
    public let availableMemoryBytes: ExecutionObservation<UInt64>
    public let queueDepth: ExecutionObservation<UInt64>
    public let estimatedQueueDelayNanoseconds: ExecutionObservation<UInt64>
    public let utilizationFraction: ExecutionObservation<ExecutionFraction>

    public init(
        capturedAt: Date = .now,
        availability: ExecutionAvailability,
        availableMemoryBytes: ExecutionObservation<UInt64> = .init(unknownReason: "not reported"),
        queueDepth: ExecutionObservation<UInt64> = .init(unknownReason: "not reported"),
        estimatedQueueDelayNanoseconds: ExecutionObservation<UInt64> = .init(unknownReason: "not reported"),
        utilizationFraction: ExecutionObservation<ExecutionFraction> = .init(unknownReason: "not reported")
    ) {
        self.capturedAt = capturedAt
        self.availability = availability
        self.availableMemoryBytes = availableMemoryBytes
        self.queueDepth = queueDepth
        self.estimatedQueueDelayNanoseconds = estimatedQueueDelayNanoseconds
        self.utilizationFraction = utilizationFraction
    }
}

public struct ExecutionPlatformDescriptor: Hashable, Sendable {
    public let operatingSystem: String
    public let architecture: String
    public let operatingSystemVersion: String?

    public init(
        operatingSystem: String,
        architecture: String,
        operatingSystemVersion: String? = nil
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.operatingSystemVersion = operatingSystemVersion
    }
}

public struct ExecutionDeviceSnapshot: Sendable {
    public let descriptor: ExecutionDeviceDescriptor
    public let state: ExecutionDeviceStateSnapshot

    public var target: ExecutionTargetReference {
        ExecutionTargetReference(
            providerID: descriptor.providerID,
            deviceID: descriptor.identifier
        )
    }

    public init(
        descriptor: ExecutionDeviceDescriptor,
        state: ExecutionDeviceStateSnapshot
    ) {
        self.descriptor = descriptor
        self.state = state
    }
}

public struct ExecutionProviderStateSnapshot: Sendable {
    public let capturedAt: Date
    public let availability: ExecutionAvailability
    public let queueDepth: ExecutionObservation<UInt64>
    public let estimatedQueueDelayNanoseconds: ExecutionObservation<UInt64>

    public init(
        capturedAt: Date = .now,
        availability: ExecutionAvailability,
        queueDepth: ExecutionObservation<UInt64> = .init(unknownReason: "not reported"),
        estimatedQueueDelayNanoseconds: ExecutionObservation<UInt64> = .init(unknownReason: "not reported")
    ) {
        self.capturedAt = capturedAt
        self.availability = availability
        self.queueDepth = queueDepth
        self.estimatedQueueDelayNanoseconds = estimatedQueueDelayNanoseconds
    }
}

public enum ExecutionProviderSnapshotError: Error, Equatable, Sendable {
    case deviceBelongsToAnotherProvider(
        expected: ExecutionProviderID,
        actual: ExecutionProviderID,
        device: ExecutionDeviceID
    )
    case duplicateDevice(ExecutionDeviceID)
}

public struct ExecutionProviderSnapshot: Sendable {
    public let descriptor: ExecutionProviderDescriptor
    public let state: ExecutionProviderStateSnapshot
    public let devices: [ExecutionDeviceSnapshot]

    public init(
        descriptor: ExecutionProviderDescriptor,
        state: ExecutionProviderStateSnapshot,
        devices: [ExecutionDeviceSnapshot]
    ) throws {
        var seen = Set<ExecutionDeviceID>()
        for device in devices {
            guard device.descriptor.providerID == descriptor.identifier else {
                throw ExecutionProviderSnapshotError.deviceBelongsToAnotherProvider(
                    expected: descriptor.identifier,
                    actual: device.descriptor.providerID,
                    device: device.descriptor.identifier
                )
            }
            guard seen.insert(device.descriptor.identifier).inserted else {
                throw ExecutionProviderSnapshotError.duplicateDevice(device.descriptor.identifier)
            }
        }
        self.descriptor = descriptor
        self.state = state
        self.devices = devices
    }
}

public enum ExecutionEnvironmentSnapshotError: Error, Equatable, Sendable {
    case duplicateProvider(ExecutionProviderID)
}

/// Snapshot of discovered execution providers and their devices. A provider may
/// expose no devices when it owns an opaque managed execution target.
public struct ExecutionEnvironmentSnapshot: Sendable {
    public let capturedAt: Date
    public let platform: ExecutionPlatformDescriptor
    public let providers: [ExecutionProviderSnapshot]

    public init(
        capturedAt: Date = .now,
        platform: ExecutionPlatformDescriptor,
        providers: [ExecutionProviderSnapshot]
    ) throws {
        var seen = Set<ExecutionProviderID>()
        for provider in providers {
            guard seen.insert(provider.descriptor.identifier).inserted else {
                throw ExecutionEnvironmentSnapshotError.duplicateProvider(provider.descriptor.identifier)
            }
        }
        self.capturedAt = capturedAt
        self.platform = platform
        self.providers = providers
    }
}
