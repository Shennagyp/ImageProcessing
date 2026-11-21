import Foundation
import GeneralExecutionProtocol

public enum CPUBufferResourceError: Error, Equatable, Sendable {
    case capacityNotRepresentable(UInt64)
    case alignmentNotRepresentable(UInt64)
    case outOfBounds(offset: UInt64, byteCount: UInt64, capacity: UInt64)
}

/// Host-memory buffer owned by the CPU provider. The descriptor is immutable;
/// byte access is synchronized and never exposes the native pointer.
public final class CPUBufferResource: ExecutionResource, @unchecked Sendable {
    public let descriptor: ExecutionResourceDescriptor

    private let storage: UnsafeMutableRawPointer
    private let capacity: Int
    private let accessLock = NSLock()

    init(
        target: ExecutionTargetReference,
        registrationIdentifier: UUID,
        capacityBytes: UInt64,
        alignmentBytes: UInt64
    ) throws {
        guard let capacity = Int(exactly: capacityBytes), capacity > 0 else {
            throw CPUBufferResourceError.capacityNotRepresentable(capacityBytes)
        }
        guard let alignment = Int(exactly: alignmentBytes),
              alignment > 0,
              alignment.nonzeroBitCount == 1 else {
            throw CPUBufferResourceError.alignmentNotRepresentable(alignmentBytes)
        }

        let descriptor = try ExecutionResourceDescriptor(
            identifier: ExecutionResourceIdentifier(
                rawValue: "cpu.buffer.\\(UUID().uuidString.lowercased())"
            )!,
            target: target,
            kind: .buffer,
            capacityBytes: capacityBytes,
            alignmentBytes: alignmentBytes,
            memoryDomain: .host,
            providerRegistrationIdentifier: registrationIdentifier
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)

        self.descriptor = descriptor
        self.storage = storage
        self.capacity = capacity
    }

    deinit {
        storage.deallocate()
    }

    /// Copies the complete allocation into ordinary Swift-owned bytes.
    public func copyBytes() -> [UInt8] {
        accessLock.lock()
        defer { accessLock.unlock() }
        let pointer = storage.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: capacity))
    }

    /// Reads a bounded byte range without exposing or retaining the native pointer.
    public func readBytes(
        atByteOffset offset: UInt64,
        count: UInt64
    ) throws -> [UInt8] {
        try validateRange(offset: offset, count: count)
        let offsetValue = Int(offset)
        let countValue = Int(count)

        accessLock.lock()
        defer { accessLock.unlock() }
        let pointer = storage.assumingMemoryBound(to: UInt8.self).advanced(by: offsetValue)
        return Array(UnsafeBufferPointer(start: pointer, count: countValue))
    }

    /// Replaces a bounded byte range. The provider resource remains the sole owner
    /// of its allocation; callers provide only the bytes to copy into it.
    public func writeBytes(
        _ bytes: [UInt8],
        atByteOffset offset: UInt64 = 0
    ) throws {
        let count = UInt64(bytes.count)
        try validateRange(offset: offset, count: count)
        guard !bytes.isEmpty else { return }

        accessLock.lock()
        defer { accessLock.unlock() }
        bytes.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                storage.advanced(by: Int(offset)).copyMemory(
                    from: baseAddress,
                    byteCount: bytes.count
                )
            }
        }
    }

    private func validateRange(offset: UInt64, count: UInt64) throws {
        let capacityBytes = descriptor.capacityBytes
        guard offset <= capacityBytes, count <= capacityBytes - offset,
              Int(exactly: offset) != nil,
              Int(exactly: count) != nil else {
            throw CPUBufferResourceError.outOfBounds(
                offset: offset,
                byteCount: count,
                capacity: capacityBytes
            )
        }
    }
}

/// Minimal host-memory execution provider.
///
/// It exposes one opaque provider-managed target and allocates only generic
/// buffer resources in the host memory domain. It has no image or algorithm
/// knowledge and can be registered independently of implementation packs.
public struct CPUExecutionProvider: ExecutionProvider, Sendable {
    public static let identifier = ExecutionProviderID(
        rawValue: "image-processing.cpu"
    )!

    public static let target = ExecutionTargetReference(
        providerID: identifier
    )

    public let descriptor: ExecutionProviderDescriptor

    public init() {
        descriptor = ExecutionProviderDescriptor(
            identifier: Self.identifier,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            displayName: "CPU",
            capabilities: Self.capabilities
        )
    }

    public func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(availability: .available)
    }

    public func discoverDevices() async throws -> [any ExecutionDevice] {
        []
    }

    public func makeContext(
        for target: ExecutionTargetReference
    ) async throws -> any ExecutionContext {
        try await makeContext(
            for: target,
            registrationIdentifier: UUID()
        )
    }

    public func makeContext(
        for target: ExecutionTargetReference,
        registrationIdentifier: UUID
    ) async throws -> any ExecutionContext {
        guard target == Self.target else {
            throw try ExecutionProviderFailure(
                providerID: Self.identifier,
                kind: .providerContractViolation,
                recovery: .permanent,
                message: "The CPU provider exposes only its provider-managed target."
            )
        }
        return CPUExecutionContext(
            target: target,
            registrationIdentifier: registrationIdentifier
        )
    }

    fileprivate static let capabilities: ExecutionCapabilities = {
        (try? ExecutionCapabilities([
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceImport, value: .boolean(true)),
            ExecutionCapability(
                identifier: .resourceMemoryDomains,
                value: .stringSet([ExecutionMemoryDomain.host.rawValue])
            )
        ])) ?? .init()
    }()
}

private struct CPUExecutionContext:
    ExecutionResourceAllocatingContext,
    ExecutionProviderRegistrationBoundContext
{
    let target: ExecutionTargetReference
    let registrationIdentifier: UUID

    var providerRegistrationIdentifier: UUID { registrationIdentifier }
    var capabilities: ExecutionCapabilities { CPUExecutionProvider.capabilities }

    func allocateResource(
        _ request: ExecutionResourceRequest
    ) async throws -> any ExecutionResource {
        guard request.kind == .buffer,
              request.memoryDomain == .host else {
            throw try ExecutionProviderFailure(
                providerID: CPUExecutionProvider.identifier,
                target: target,
                kind: .resourceAllocationFailed,
                recovery: .permanent,
                message: "The CPU provider allocates host-memory buffers only."
            )
        }

        return try CPUBufferResource(
            target: target,
            registrationIdentifier: registrationIdentifier,
            capacityBytes: request.minimumCapacityBytes,
            alignmentBytes: request.minimumAlignmentBytes
        )
    }

    func importResource(
        _ resource: any ExecutionResource,
        access: ExecutionResourceAccessMode
    ) async throws -> any ExecutionResource {
        guard access == .read else {
            throw try ExecutionProviderFailure(
                providerID: CPUExecutionProvider.identifier,
                target: target,
                kind: .resourceImportFailed,
                recovery: .permanent,
                message: "The CPU provider supports read-only imports in the MVP."
            )
        }
        guard let source = resource as? CPUBufferResource,
              source.descriptor.kind == .buffer,
              source.descriptor.memoryDomain == .host else {
            throw try ExecutionProviderFailure(
                providerID: CPUExecutionProvider.identifier,
                target: target,
                kind: .resourceImportFailed,
                recovery: .permanent,
                message: "The CPU provider can import only CPU-owned host buffers."
            )
        }

        let destination = try CPUBufferResource(
            target: target,
            registrationIdentifier: registrationIdentifier,
            capacityBytes: source.descriptor.capacityBytes,
            alignmentBytes: source.descriptor.alignmentBytes
        )
        try destination.writeBytes(source.copyBytes())
        return destination
    }
}
