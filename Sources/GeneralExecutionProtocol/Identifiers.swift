public struct ExecutionProviderID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ExecutionDeviceID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ExecutionCapabilityID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Standard generic execution capability identifiers. Providers may publish
/// additional namespaced capabilities without changing the protocol library.
public extension ExecutionCapabilityID {
    static let bufferResources = Self(rawValue: "execution.resource.buffer")!
    static let textureResources = Self(rawValue: "execution.resource.texture")!
    /// String-set capability containing exact opaque resource-kind identifiers.
    static let opaqueResourceKinds = Self(rawValue: "execution.resource.opaque-kinds")!
    /// String-set capability containing ExecutionMemoryDomain.rawValue entries
    /// that the context can allocate. This is support, not free-capacity telemetry.
    static let resourceMemoryDomains = Self(rawValue: "execution.resource.memory-domains")!
    static let resourceAllocation = Self(rawValue: "execution.resource.allocation")!
    static let resourceImport = Self(rawValue: "execution.resource.import")!
    static let workSubmission = Self(rawValue: "execution.work.submission")!
    static let workDependencies = Self(rawValue: "execution.work.dependencies")!
    static let contextSynchronization = Self(rawValue: "execution.synchronization.context")!
    static let resourceSynchronization = Self(rawValue: "execution.synchronization.resource")!
    static let peerResourceTransfer = Self(rawValue: "execution.transfer.peer-resource")!
}

/// A provider-scoped device reference. Device identifiers need only be unique
/// within their provider; the pair is the stable execution-target identity.
public struct ExecutionTargetReference: Hashable, Sendable {
    public let providerID: ExecutionProviderID
    public let deviceID: ExecutionDeviceID?

    /// A nil device identifies a provider-managed execution target whose internal
    /// device partitioning is intentionally opaque to the caller.
    public init(providerID: ExecutionProviderID, deviceID: ExecutionDeviceID? = nil) {
        self.providerID = providerID
        self.deviceID = deviceID
    }
}

/// A semantic version shared by provider, operation, and implementation metadata.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(major: Int, minor: Int, patch: Int) {
        guard major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// A half-open semantic-version interval: lower bound inclusive, upper bound exclusive.
public struct SemanticVersionRange: Hashable, Sendable {
    public let lowerBound: SemanticVersion
    public let upperBound: SemanticVersion?

    public init?(lowerBound: SemanticVersion, upperBound: SemanticVersion? = nil) {
        if let upperBound, upperBound <= lowerBound {
            return nil
        }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public func contains(_ version: SemanticVersion) -> Bool {
        guard version >= lowerBound else { return false }
        guard let upperBound else { return true }
        return version < upperBound
    }
}
