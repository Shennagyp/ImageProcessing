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
}
