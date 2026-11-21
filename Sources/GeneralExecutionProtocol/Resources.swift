import Foundation

public struct ExecutionResourceIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ExecutionResourceKind: Hashable, Sendable {
    case buffer
    case texture
    case opaque(String)
}

/// A generic storage domain. These cases describe access/residency classes,
/// not a promise that two providers use identical native allocation mechanisms.
public enum ExecutionMemoryDomain: String, Hashable, Sendable, CaseIterable {
    case host
    case deviceLocal
    case shared
    case managed
    case external
}

public enum ExecutionResourceDescriptorError: Error, Equatable, Sendable {
    case zeroCapacity
    case invalidAlignment
    case emptyOpaqueKind
}

/// Provider-owned resource metadata. No image, pixel format, channel, or tensor
/// semantics are represented here; those belong to the consuming domain.
public struct ExecutionResourceDescriptor: Hashable, Sendable {
    public let identifier: ExecutionResourceIdentifier
    public let target: ExecutionTargetReference
    public let kind: ExecutionResourceKind
    public let capacityBytes: UInt64
    public let alignmentBytes: UInt64
    public let memoryDomain: ExecutionMemoryDomain
    /// Runtime registration that created this handle. Nil is permitted for
    /// externally owned or legacy resources, but cannot prove same-registration
    /// device-local residency.
    public let providerRegistrationIdentifier: UUID?

    public init(
        identifier: ExecutionResourceIdentifier,
        target: ExecutionTargetReference,
        kind: ExecutionResourceKind,
        capacityBytes: UInt64,
        alignmentBytes: UInt64,
        memoryDomain: ExecutionMemoryDomain,
        providerRegistrationIdentifier: UUID? = nil
    ) throws {
        guard capacityBytes > 0 else {
            throw ExecutionResourceDescriptorError.zeroCapacity
        }
        guard alignmentBytes > 0, alignmentBytes.nonzeroBitCount == 1 else {
            throw ExecutionResourceDescriptorError.invalidAlignment
        }
        if case let .opaque(name) = kind, name.isEmpty {
            throw ExecutionResourceDescriptorError.emptyOpaqueKind
        }
        self.identifier = identifier
        self.target = target
        self.kind = kind
        self.capacityBytes = capacityBytes
        self.alignmentBytes = alignmentBytes
        self.memoryDomain = memoryDomain
        self.providerRegistrationIdentifier = providerRegistrationIdentifier
    }
}

public struct ExecutionResourceRequest: Hashable, Sendable {
    public let kind: ExecutionResourceKind
    public let minimumCapacityBytes: UInt64
    public let minimumAlignmentBytes: UInt64
    public let memoryDomain: ExecutionMemoryDomain

    public init?(
        kind: ExecutionResourceKind,
        minimumCapacityBytes: UInt64,
        minimumAlignmentBytes: UInt64 = 1,
        memoryDomain: ExecutionMemoryDomain
    ) {
        guard minimumCapacityBytes > 0,
              minimumAlignmentBytes > 0,
              minimumAlignmentBytes.nonzeroBitCount == 1 else {
            return nil
        }
        if case let .opaque(name) = kind, name.isEmpty { return nil }
        self.kind = kind
        self.minimumCapacityBytes = minimumCapacityBytes
        self.minimumAlignmentBytes = minimumAlignmentBytes
        self.memoryDomain = memoryDomain
    }

    public func isSatisfied(by descriptor: ExecutionResourceDescriptor) -> Bool {
        descriptor.kind == kind
            && descriptor.capacityBytes >= minimumCapacityBytes
            && descriptor.alignmentBytes >= minimumAlignmentBytes
            && descriptor.alignmentBytes.isMultiple(of: minimumAlignmentBytes)
            && descriptor.memoryDomain == memoryDomain
    }

    public func isSatisfied(
        by descriptor: ExecutionResourceDescriptor,
        on target: ExecutionTargetReference
    ) -> Bool {
        descriptor.target == target && isSatisfied(by: descriptor)
    }
}

/// A resource is a reference-counted opaque provider allocation. Its descriptor
/// is immutable for the lifetime of the handle and identifies that exact allocation.
/// Implementations release native storage when the resource handle and all
/// submission-retained references are released.
public protocol ExecutionResource: AnyObject, Sendable {
    var descriptor: ExecutionResourceDescriptor { get }
}

public enum ExecutionResourceAccessMode: String, Hashable, Sendable {
    case read
    case write
    case readWrite
}

public struct ExecutionResourceAccess: Sendable {
    public let resource: any ExecutionResource
    public let mode: ExecutionResourceAccessMode

    public init(resource: any ExecutionResource, mode: ExecutionResourceAccessMode) {
        self.resource = resource
        self.mode = mode
    }
}

/// Optional context capability for providers that can allocate generic resources.
public protocol ExecutionResourceAllocatingContext: ExecutionContext {
    func allocateResource(_ request: ExecutionResourceRequest) async throws -> any ExecutionResource

    /// Imports a resource into this context. The asynchronous return is the
    /// import-completion boundary: the returned handle must be immediately usable
    /// on this context's exact target, and any provider-internal transfer/barrier
    /// work required before the declared access must already be complete.
    ///
    /// The returned descriptor must identify this context's target and the exact
    /// provider registration that created the destination handle. The imported
    /// handle must retain the source allocation for as long as the imported handle
    /// or dependent submitted work can still access it. The provider is responsible
    /// for any source-side synchronization required to perform the import.
    func importResource(
        _ resource: any ExecutionResource,
        access: ExecutionResourceAccessMode
    ) async throws -> any ExecutionResource
}

public enum ExecutionCancellationResult: String, Hashable, Sendable {
    case cancelledBeforeExecution
    case cancellationRequested
    case tooLate
}

public enum ExecutionSubmissionError: Error, Equatable, Sendable {
    case cancelled
}

/// Completion without a typed result. It can be used as a dependency of later
/// work while preserving the dependency's failure/cancellation semantics.
public protocol ExecutionCompletion: Sendable {
    func wait() async throws
    func cancel() async -> ExecutionCancellationResult
}

/// A typed handle for submitted work. value() is the completion boundary:
/// it returns only after the work has completed and its output is valid.
public protocol ExecutionSubmission<Output>: ExecutionCompletion {
    associatedtype Output: Sendable
    func value() async throws -> Output
}

public extension ExecutionSubmission {
    func wait() async throws {
        _ = try await value()
    }
}

/// Work is provider-neutral at the scheduling boundary but may use an optional,
/// provider-specific context protocol inside execute to access native APIs.
public protocol ExecutionWork: Sendable {
    associatedtype Output: Sendable
    var resourceAccesses: [ExecutionResourceAccess] { get }
    var dependencies: [any ExecutionCompletion] { get }
    func execute(on context: any ExecutionContext) async throws -> Output
}

public extension ExecutionWork {
    var dependencies: [any ExecutionCompletion] { [] }
}

/// Optional capability. A provider must retain the work item and every resource
/// declared in resourceAccesses until completion, even if the caller drops its
/// local references. Dependencies must complete successfully before work starts.
public protocol ExecutionWorkSubmittingContext: ExecutionContext {
    func submit<Work: ExecutionWork>(
        _ work: Work
    ) async throws -> any ExecutionSubmission<Work.Output>
}

/// Resource identity is scoped by its stable provider/execution target and, when
/// known, the provider registration generation that created the allocation.
public struct ExecutionResourceReference: Hashable, Sendable {
    public let target: ExecutionTargetReference
    public let identifier: ExecutionResourceIdentifier
    /// Distinguishes allocations created by different registrations that reuse
    /// the same stable provider/device and resource identifiers.
    public let providerRegistrationIdentifier: UUID?

    public init(
        target: ExecutionTargetReference,
        identifier: ExecutionResourceIdentifier,
        providerRegistrationIdentifier: UUID? = nil
    ) {
        self.target = target
        self.identifier = identifier
        self.providerRegistrationIdentifier = providerRegistrationIdentifier
    }
}

public extension ExecutionResourceDescriptor {
    var reference: ExecutionResourceReference {
        ExecutionResourceReference(
            target: target,
            identifier: identifier,
            providerRegistrationIdentifier: providerRegistrationIdentifier
        )
    }
}

public enum ExecutionSynchronizationScope: Hashable, Sendable {
    case context
    case resource(ExecutionResourceReference)
}

/// Optional explicit synchronization capability. Per-submission waiting remains
/// the preferred narrow completion boundary when a submission handle is available.
public protocol ExecutionSynchronizingContext: ExecutionContext {
    func synchronize(_ scope: ExecutionSynchronizationScope) async throws
}
