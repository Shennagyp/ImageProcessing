import GeneralExecutionProtocol
import ImageProcessingCPUProvider
import ImageProcessingRuntime
import Testing

struct CPUExecutionProviderTests {
    @Test
    func allocatesRegistrationBoundHostBufferAndCopiesBytesSafely() async throws {
        let provider = CPUExecutionProvider()
        let registry = ExecutionProviderRegistry()
        try await registry.register(provider)
        let registration = try #require(await registry.registeredProviders().first)
        let context = try await registry.makeContext(
            for: CPUExecutionProvider.target,
            expecting: registration.descriptor,
            registrationIdentifier: registration.registrationIdentifier
        )
        let allocator = try #require(context as? any ExecutionResourceAllocatingContext)
        let request = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 16,
            minimumAlignmentBytes: 16,
            memoryDomain: .host
        ))
        let resource = try await allocator.allocateResource(request)
        let buffer = try #require(resource as? CPUBufferResource)
        let bytes: [UInt8] = (0..<16).map { UInt8($0) }

        try buffer.writeBytes(bytes)

        #expect(buffer.descriptor.target == CPUExecutionProvider.target)
        #expect(buffer.descriptor.providerRegistrationIdentifier == registration.registrationIdentifier)
        #expect(buffer.descriptor.memoryDomain == .host)
        #expect(buffer.descriptor.capacityBytes == 16)
        #expect(try buffer.readBytes(atByteOffset: 0, count: 16) == bytes)
        #expect(buffer.copyBytes() == bytes)
    }

    @Test
    func readOnlyImportCreatesIndependentCPUBufferStorage() async throws {
        let provider = CPUExecutionProvider()
        let registry = ExecutionProviderRegistry()
        try await registry.register(provider)
        let registration = try #require(await registry.registeredProviders().first)
        let context = try await registry.makeContext(
            for: CPUExecutionProvider.target,
            expecting: registration.descriptor,
            registrationIdentifier: registration.registrationIdentifier
        )
        let allocator = try #require(context as? any ExecutionResourceAllocatingContext)
        let request = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 4,
            minimumAlignmentBytes: 4,
            memoryDomain: .host
        ))
        let sourceValue = try await allocator.allocateResource(request)
        let source = try #require(sourceValue as? CPUBufferResource)
        try source.writeBytes([10, 20, 30, 40])

        let importedValue = try await allocator.importResource(source, access: .read)
        let imported = try #require(importedValue as? CPUBufferResource)
        try source.writeBytes([1, 2, 3, 4])

        #expect(imported.descriptor.reference != source.descriptor.reference)
        #expect(imported.descriptor.providerRegistrationIdentifier == registration.registrationIdentifier)
        #expect(imported.copyBytes() == [10, 20, 30, 40])
        #expect(source.copyBytes() == [1, 2, 3, 4])
    }

    @Test
    func rejectsWritableCPUResourceImports() async throws {
        let provider = CPUExecutionProvider()
        let registry = ExecutionProviderRegistry()
        try await registry.register(provider)
        let registration = try #require(await registry.registeredProviders().first)
        let context = try await registry.makeContext(
            for: CPUExecutionProvider.target,
            expecting: registration.descriptor,
            registrationIdentifier: registration.registrationIdentifier
        )
        let allocator = try #require(context as? any ExecutionResourceAllocatingContext)
        let request = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 4,
            memoryDomain: .host
        ))
        let source = try await allocator.allocateResource(request)
        let expected = try ExecutionProviderFailure(
            providerID: CPUExecutionProvider.identifier,
            target: CPUExecutionProvider.target,
            kind: .resourceImportFailed,
            recovery: .permanent,
            message: "The CPU provider supports read-only imports in the MVP."
        )

        await #expect(throws: expected) {
            _ = try await allocator.importResource(source, access: .write)
        }
    }

    @Test
    func rejectsOutOfBoundsBufferAccess() async throws {
        let provider = CPUExecutionProvider()
        let registry = ExecutionProviderRegistry()
        try await registry.register(provider)
        let registration = try #require(await registry.registeredProviders().first)
        let context = try await registry.makeContext(
            for: CPUExecutionProvider.target,
            expecting: registration.descriptor,
            registrationIdentifier: registration.registrationIdentifier
        )
        let allocator = try #require(context as? any ExecutionResourceAllocatingContext)
        let request = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 8,
            memoryDomain: .host
        ))
        let resource = try await allocator.allocateResource(request)
        let buffer = try #require(resource as? CPUBufferResource)

        #expect(throws: CPUBufferResourceError.outOfBounds(
            offset: 7,
            byteCount: 2,
            capacity: 8
        )) {
            try buffer.writeBytes([1, 2], atByteOffset: 7)
        }
    }
}
