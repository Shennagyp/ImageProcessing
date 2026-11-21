import GeneralExecutionProtocol
import ImageProcessingCPUProvider
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
        let bytes: [UInt8] = Array(0..<16)

        try buffer.writeBytes(bytes)

        #expect(buffer.descriptor.target == CPUExecutionProvider.target)
        #expect(buffer.descriptor.providerRegistrationIdentifier == registration.registrationIdentifier)
        #expect(buffer.descriptor.memoryDomain == .host)
        #expect(buffer.descriptor.capacityBytes == 16)
        #expect(try buffer.readBytes(atByteOffset: 0, count: 16) == bytes)
        #expect(buffer.copyBytes() == bytes)
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
