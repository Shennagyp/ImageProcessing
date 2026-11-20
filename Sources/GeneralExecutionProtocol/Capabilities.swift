public enum ExecutionCapabilityValue: Hashable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case decimal(Double)
    case string(String)
    case stringSet(Set<String>)
}

public struct ExecutionCapability: Hashable, Sendable {
    public let identifier: ExecutionCapabilityID
    public let value: ExecutionCapabilityValue

    public init(identifier: ExecutionCapabilityID, value: ExecutionCapabilityValue) {
        self.identifier = identifier
        self.value = value
    }
}

public enum ExecutionCapabilitiesError: Error, Equatable, Sendable {
    case duplicateIdentifier(ExecutionCapabilityID)
}

/// Immutable generic capability facts reported by a provider or device.
/// This type deliberately contains no image-specific or vendor-specific fields.
public struct ExecutionCapabilities: Hashable, Sendable {
    private let values: [ExecutionCapabilityID: ExecutionCapabilityValue]

    public init() {
        self.values = [:]
    }

    public init(_ capabilities: [ExecutionCapability]) throws {
        var values: [ExecutionCapabilityID: ExecutionCapabilityValue] = [:]
        for capability in capabilities {
            guard values[capability.identifier] == nil else {
                throw ExecutionCapabilitiesError.duplicateIdentifier(capability.identifier)
            }
            values[capability.identifier] = capability.value
        }
        self.values = values
    }

    public subscript(_ identifier: ExecutionCapabilityID) -> ExecutionCapabilityValue? {
        values[identifier]
    }

    public var identifiers: Set<ExecutionCapabilityID> {
        Set(values.keys)
    }

    public func satisfies(_ requirement: ExecutionCapabilityRequirement) -> Bool {
        requirement.isSatisfied(by: self)
    }

    public func satisfiesAll(_ requirements: [ExecutionCapabilityRequirement]) -> Bool {
        requirements.allSatisfy { satisfies($0) }
    }
}

/// Declarative, image-agnostic requirements against provider/device capabilities.
public enum ExecutionCapabilityRequirement: Hashable, Sendable {
    case exact(ExecutionCapabilityID, ExecutionCapabilityValue)
    case integerAtLeast(ExecutionCapabilityID, Int64)
    case decimalAtLeast(ExecutionCapabilityID, Double)
    case stringSetContains(ExecutionCapabilityID, String)

    public func isSatisfied(by capabilities: ExecutionCapabilities) -> Bool {
        switch self {
        case let .exact(identifier, expected):
            return capabilities[identifier] == expected
        case let .integerAtLeast(identifier, minimum):
            guard case let .integer(value)? = capabilities[identifier] else { return false }
            return value >= minimum
        case let .decimalAtLeast(identifier, minimum):
            guard minimum.isFinite,
                  case let .decimal(value)? = capabilities[identifier],
                  value.isFinite else { return false }
            return value >= minimum
        case let .stringSetContains(identifier, expected):
            guard case let .stringSet(values)? = capabilities[identifier] else { return false }
            return values.contains(expected)
        }
    }
}

public enum ExecutionCapabilityScope: String, Hashable, Sendable {
    case provider
    case device
    case providerOrDevice
    case context
}

/// States where a required capability must be reported. This prevents the
/// resolver from conflating provider features with hardware-device features.
public struct ExecutionCapabilityConstraint: Hashable, Sendable {
    public let scope: ExecutionCapabilityScope
    public let requirement: ExecutionCapabilityRequirement

    public init(
        scope: ExecutionCapabilityScope,
        requirement: ExecutionCapabilityRequirement
    ) {
        self.scope = scope
        self.requirement = requirement
    }

    public func isSatisfied(
        providerCapabilities: ExecutionCapabilities,
        deviceCapabilities: ExecutionCapabilities?,
        contextCapabilities: ExecutionCapabilities? = nil
    ) -> Bool {
        switch scope {
        case .provider:
            return providerCapabilities.satisfies(requirement)
        case .device:
            return deviceCapabilities?.satisfies(requirement) ?? false
        case .providerOrDevice:
            return providerCapabilities.satisfies(requirement)
                || (deviceCapabilities?.satisfies(requirement) ?? false)
        case .context:
            return contextCapabilities?.satisfies(requirement) ?? false
        }
    }
}
