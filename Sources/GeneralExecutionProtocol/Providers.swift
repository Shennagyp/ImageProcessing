import Foundation

public struct ExecutionProviderDescriptor: Hashable, Sendable {
    public let identifier: ExecutionProviderID
    public let version: SemanticVersion
    public let displayName: String
    public let capabilities: ExecutionCapabilities

    public init(
        identifier: ExecutionProviderID,
        version: SemanticVersion,
        displayName: String,
        capabilities: ExecutionCapabilities = .init()
    ) {
        self.identifier = identifier
        self.version = version
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public struct ExecutionDeviceDescriptor: Hashable, Sendable {
    public let identifier: ExecutionDeviceID
    public let providerID: ExecutionProviderID
    public let displayName: String
    public let capabilities: ExecutionCapabilities

    public init(
        identifier: ExecutionDeviceID,
        providerID: ExecutionProviderID,
        displayName: String,
        capabilities: ExecutionCapabilities = .init()
    ) {
        self.identifier = identifier
        self.providerID = providerID
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// Opaque generic execution context. Provider-specific packages may refine this
/// protocol with native context access without exposing those types to the core.
public protocol ExecutionContext: Sendable {
    var target: ExecutionTargetReference { get }
    var capabilities: ExecutionCapabilities { get }
}

/// Optional context identity for providers whose resources are scoped to one
/// runtime registration. Resource-producing contexts should implement this
/// protocol and stamp the same identifier on every resource they create.
public protocol ExecutionProviderRegistrationBoundContext: ExecutionContext {
    var providerRegistrationIdentifier: UUID { get }
}

public extension ExecutionContext {
    /// Context-specific capabilities default to empty for providers that do not
    /// expose them. Optional context protocols remain the executable proof.
    var capabilities: ExecutionCapabilities { .init() }
}

public protocol ExecutionDevice: Sendable {
    var descriptor: ExecutionDeviceDescriptor { get }

    func observeState() async throws -> ExecutionDeviceStateSnapshot
}

public protocol ExecutionProvider: Sendable {
    var descriptor: ExecutionProviderDescriptor { get }

    func observeState() async throws -> ExecutionProviderStateSnapshot
    func discoverDevices() async throws -> [any ExecutionDevice]
    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext
    func makeContext(
        for target: ExecutionTargetReference,
        registrationIdentifier: UUID
    ) async throws -> any ExecutionContext
}

public extension ExecutionProvider {
    /// Registration-aware context creation. Providers that allocate or import
    /// resources should capture this identity and place it on each resulting
    /// ExecutionResourceDescriptor. The default preserves legacy providers;
    /// their resources cannot prove registration-local device residency.
    func makeContext(
        for target: ExecutionTargetReference,
        registrationIdentifier: UUID
    ) async throws -> any ExecutionContext {
        try await makeContext(for: target)
    }
}
