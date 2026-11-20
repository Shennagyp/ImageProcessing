import Foundation
import Testing
@testable import GeneralExecutionProtocol

private final class TestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor
    init(_ descriptor: ExecutionResourceDescriptor) { self.descriptor = descriptor }
}

private final class ImportedTestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor
    private let retainedSource: any ExecutionResource

    init(_ descriptor: ExecutionResourceDescriptor, retaining source: any ExecutionResource) {
        self.descriptor = descriptor
        self.retainedSource = source
    }
}

private struct TestAllocatingContext: ExecutionResourceAllocatingContext {
    let target: ExecutionTargetReference

    func allocateResource(_ request: ExecutionResourceRequest) async throws -> any ExecutionResource {
        let descriptor = try ExecutionResourceDescriptor(
            identifier: #require(ExecutionResourceIdentifier(rawValue: "allocated.buffer")),
            target: target,
            kind: request.kind,
            capacityBytes: request.minimumCapacityBytes,
            alignmentBytes: request.minimumAlignmentBytes,
            memoryDomain: request.memoryDomain
        )
        guard request.isSatisfied(by: descriptor, on: target) else {
            throw TestProviderError.invalidAllocation
        }
        return TestResource(descriptor)
    }

    func importResource(
        _ resource: any ExecutionResource,
        access: ExecutionResourceAccessMode
    ) async throws -> any ExecutionResource {
        let source = resource.descriptor
        let descriptor = try ExecutionResourceDescriptor(
            identifier: #require(ExecutionResourceIdentifier(rawValue: "imported.\(source.identifier.rawValue)")),
            target: target,
            kind: source.kind,
            capacityBytes: source.capacityBytes,
            alignmentBytes: source.alignmentBytes,
            memoryDomain: .shared
        )
        return ImportedTestResource(descriptor, retaining: resource)
    }
}

private enum TestProviderError: Error {
    case invalidAllocation
}

private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

private struct CompletedSubmission<Output: Sendable>: ExecutionSubmission {
    let output: Output
    func value() async throws -> Output { output }
    func cancel() async -> ExecutionCancellationResult { .tooLate }
}

private struct ImmediateSubmittingContext: ExecutionWorkSubmittingContext {
    let target: ExecutionTargetReference

    func submit<Work: ExecutionWork>(
        _ work: Work
    ) async throws -> any ExecutionSubmission<Work.Output> {
        for dependency in work.dependencies {
            try await dependency.wait()
        }
        let output = try await work.execute(on: self)
        return CompletedSubmission(output: output)
    }
}

private struct IncrementWork: ExecutionWork {
    let input: Int
    let resourceAccesses: [ExecutionResourceAccess]
    let dependencies: [any ExecutionCompletion]

    func execute(on context: any ExecutionContext) async throws -> Int {
        input + 1
    }
}

struct ResourceLifecycleTests {
    private func resourceDescriptor(
        id: String = "buffer.1",
        target: ExecutionTargetReference? = nil,
        capacity: UInt64 = 1024,
        alignment: UInt64 = 64,
        domain: ExecutionMemoryDomain = .deviceLocal
    ) throws -> ExecutionResourceDescriptor {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.test"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.0"))
        return try ExecutionResourceDescriptor(
            identifier: #require(ExecutionResourceIdentifier(rawValue: id)),
            target: target ?? ExecutionTargetReference(providerID: providerID, deviceID: deviceID),
            kind: .buffer,
            capacityBytes: capacity,
            alignmentBytes: alignment,
            memoryDomain: domain
        )
    }

    @Test
    func resourceRequestsValidateCapacityAlignmentKindAndDomain() throws {
        let descriptor = try resourceDescriptor()
        let valid = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 512,
            minimumAlignmentBytes: 16,
            memoryDomain: .deviceLocal
        ))
        let wrongKind = try #require(ExecutionResourceRequest(
            kind: .texture,
            minimumCapacityBytes: 512,
            memoryDomain: .deviceLocal
        ))
        let wrongDomain = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 512,
            memoryDomain: .host
        ))
        let tooLarge = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 2048,
            memoryDomain: .deviceLocal
        ))
        let tooAligned = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 512,
            minimumAlignmentBytes: 128,
            memoryDomain: .deviceLocal
        ))

        #expect(valid.isSatisfied(by: descriptor))
        #expect(valid.isSatisfied(by: descriptor, on: descriptor.target))
        let otherProvider = try #require(ExecutionProviderID(rawValue: "provider.other"))
        #expect(!valid.isSatisfied(
            by: descriptor,
            on: ExecutionTargetReference(providerID: otherProvider)
        ))
        #expect(!wrongKind.isSatisfied(by: descriptor))
        #expect(!wrongDomain.isSatisfied(by: descriptor))
        #expect(!tooLarge.isSatisfied(by: descriptor))
        #expect(!tooAligned.isSatisfied(by: descriptor))
    }

    @Test
    func invalidResourceDescriptorsAreRejected() throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.test"))
        let target = ExecutionTargetReference(providerID: providerID)
        let id = try #require(ExecutionResourceIdentifier(rawValue: "resource"))

        #expect(throws: ExecutionResourceDescriptorError.zeroCapacity) {
            try ExecutionResourceDescriptor(
                identifier: id, target: target, kind: .buffer,
                capacityBytes: 0, alignmentBytes: 1, memoryDomain: .host
            )
        }
        #expect(throws: ExecutionResourceDescriptorError.invalidAlignment) {
            try ExecutionResourceDescriptor(
                identifier: id, target: target, kind: .buffer,
                capacityBytes: 10, alignmentBytes: 3, memoryDomain: .host
            )
        }
    }

    @Test
    func importedResourceRetainsItsSourceAllocation() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.importer"))
        let target = ExecutionTargetReference(providerID: providerID)
        let context = TestAllocatingContext(target: target)
        var source: TestResource? = TestResource(try resourceDescriptor())
        let weakSource = WeakBox(try #require(source))
        let imported = try await context.importResource(try #require(source), access: .read)
        source = nil

        #expect(imported.descriptor.target == target)
        #expect(weakSource.value != nil)
        withExtendedLifetime(imported) {
            #expect(weakSource.value != nil)
        }
    }

    @Test
    func allocatorReturnsAResourceMeetingTheRequestAndContextTarget() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.allocator"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.1"))
        let target = ExecutionTargetReference(providerID: providerID, deviceID: deviceID)
        let context = TestAllocatingContext(target: target)
        let request = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 4096,
            minimumAlignmentBytes: 256,
            memoryDomain: .deviceLocal
        ))
        let resource = try await context.allocateResource(request)

        #expect(request.isSatisfied(by: resource.descriptor, on: target))
    }

    @Test
    func resourceReferenceIncludesOwningTarget() throws {
        let id = try #require(ExecutionResourceIdentifier(rawValue: "buffer.1"))
        let a = try resourceDescriptor(id: id.rawValue)
        let providerB = try #require(ExecutionProviderID(rawValue: "provider.other"))
        let deviceB = try #require(ExecutionDeviceID(rawValue: "device.0"))
        let b = try ExecutionResourceDescriptor(
            identifier: id,
            target: ExecutionTargetReference(providerID: providerB, deviceID: deviceB),
            kind: .buffer, capacityBytes: 1024, alignmentBytes: 64,
            memoryDomain: .deviceLocal
        )

        #expect(a.identifier == b.identifier)
        #expect(a.reference != b.reference)
    }

    @Test
    func resourceAccessRetainsHandleThroughReferenceLifetime() throws {
        var resource: TestResource? = TestResource(try resourceDescriptor())
        let weakResource = WeakBox(try #require(resource))
        let access = ExecutionResourceAccess(resource: try #require(resource), mode: .readWrite)
        resource = nil

        #expect(weakResource.value != nil)
        withExtendedLifetime(access) {
            #expect(weakResource.value != nil)
        }
    }

    @Test
    func typedWorkSubmissionReturnsOutputOnlyAfterCompletion() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.test"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.0"))
        let context = ImmediateSubmittingContext(
            target: ExecutionTargetReference(providerID: providerID, deviceID: deviceID)
        )
        let work = IncrementWork(input: 41, resourceAccesses: [], dependencies: [])
        let submission = try await context.submit(work)

        #expect(try await submission.value() == 42)
        #expect(try await submission.wait() == ())
        #expect(await submission.cancel() == .tooLate)
    }

    @Test
    func submittedWorkWaitsForDeclaredDependencies() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.test"))
        let context = ImmediateSubmittingContext(target: ExecutionTargetReference(providerID: providerID))
        let dependency = CompletedSubmission(output: 10)
        let work = IncrementWork(input: 1, resourceAccesses: [], dependencies: [dependency])
        let submission = try await context.submit(work)

        #expect(try await submission.value() == 2)
    }
}
