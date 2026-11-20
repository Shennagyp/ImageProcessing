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

    var capabilities: ExecutionCapabilities {
        (try? ExecutionCapabilities([
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceImport, value: .boolean(true))
        ])) ?? .init()
    }

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
    case invalidTarget
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
        let output = try await ExecutionProviderConformanceHarness.submit(
            work,
            using: context
        )

        #expect(output == 42)
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


private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor TaskBackedSubmission<Output: Sendable>: ExecutionSubmission {
    private let task: Task<Output, any Error>
    private var cancellationRequested = false

    init(task: Task<Output, any Error>) {
        self.task = task
    }

    func value() async throws -> Output {
        try await task.value
    }

    func cancel() async -> ExecutionCancellationResult {
        guard !cancellationRequested else { return .cancellationRequested }
        cancellationRequested = true
        task.cancel()
        return .cancellationRequested
    }
}

private struct TaskSubmittingContext: ExecutionWorkSubmittingContext {
    let target: ExecutionTargetReference

    var capabilities: ExecutionCapabilities {
        (try? ExecutionCapabilities([
            ExecutionCapability(identifier: .workSubmission, value: .boolean(true)),
            ExecutionCapability(identifier: .workDependencies, value: .boolean(true))
        ])) ?? .init()
    }

    func submit<Work: ExecutionWork>(
        _ work: Work
    ) async throws -> any ExecutionSubmission<Work.Output> {
        let task = Task<Work.Output, any Error> {
            for dependency in work.dependencies {
                try await dependency.wait()
            }
            return try await work.execute(on: self)
        }
        return TaskBackedSubmission(task: task)
    }
}

private struct GatedResourceWork: ExecutionWork {
    let gate: TestAsyncGate
    let result: Int
    let resourceAccesses: [ExecutionResourceAccess]

    func execute(on context: any ExecutionContext) async throws -> Int {
        await gate.wait()
        try Task.checkCancellation()
        return result
    }
}

private struct TestExecutionDevice: ExecutionDevice {
    let descriptor: ExecutionDeviceDescriptor

    func observeState() async throws -> ExecutionDeviceStateSnapshot {
        ExecutionDeviceStateSnapshot(availability: .available)
    }
}

private struct TestExecutionProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor
    let device: TestExecutionDevice

    init() throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.conformance"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.conformance"))
        let version = try #require(SemanticVersion(major: 1, minor: 0, patch: 0))
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .bufferResources, value: .boolean(true)),
            ExecutionCapability(identifier: .resourceAllocation, value: .boolean(true))
        ])
        self.descriptor = ExecutionProviderDescriptor(
            identifier: providerID,
            version: version,
            displayName: "Test provider",
            capabilities: capabilities
        )
        self.device = TestExecutionDevice(descriptor: ExecutionDeviceDescriptor(
            identifier: deviceID,
            providerID: providerID,
            displayName: "Test device"
        ))
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(availability: .available)
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        [device]
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        guard target.providerID == descriptor.identifier,
              target.deviceID == nil || target.deviceID == device.descriptor.identifier else {
            throw TestProviderError.invalidTarget
        }
        return TestAllocatingContext(target: target)
    }
}

extension ResourceLifecycleTests {
    @Test
    func capabilityConstraintsCanBeCheckedAgainstCreatedContext() throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.capabilities"))
        let context = TestAllocatingContext(target: ExecutionTargetReference(providerID: providerID))
        let requirement = ExecutionCapabilityConstraint(
            scope: .context,
            requirement: .exact(.resourceAllocation, .boolean(true))
        )
        let missing = ExecutionCapabilityConstraint(
            scope: .context,
            requirement: .exact(.workSubmission, .boolean(true))
        )

        #expect(requirement.isSatisfied(
            providerCapabilities: .init(),
            deviceCapabilities: nil,
            contextCapabilities: context.capabilities
        ))
        #expect(!missing.isSatisfied(
            providerCapabilities: .init(),
            deviceCapabilities: nil,
            contextCapabilities: context.capabilities
        ))
    }

    @Test
    func submittingProviderRetainsDeclaredResourcesUntilCompletion() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.async-test"))
        let target = ExecutionTargetReference(providerID: providerID)
        let context = TaskSubmittingContext(target: target)
        let gate = TestAsyncGate()
        var resource: TestResource? = TestResource(try resourceDescriptor())
        let weakResource = WeakBox(try #require(resource))
        var work: GatedResourceWork? = GatedResourceWork(
            gate: gate,
            result: 73,
            resourceAccesses: [ExecutionResourceAccess(resource: try #require(resource), mode: .read)]
        )
        let submission = try await context.submit(try #require(work))

        resource = nil
        work = nil
        #expect(weakResource.value != nil)

        await gate.open()
        #expect(try await submission.value() == 73)
    }

    @Test
    func cancellationIsRequestedWithoutReleasingInFlightResourcesEarly() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.cancel-test"))
        let target = ExecutionTargetReference(providerID: providerID)
        let context = TaskSubmittingContext(target: target)
        let gate = TestAsyncGate()
        var resource: TestResource? = TestResource(try resourceDescriptor())
        let weakResource = WeakBox(try #require(resource))
        let work = GatedResourceWork(
            gate: gate,
            result: 99,
            resourceAccesses: [ExecutionResourceAccess(resource: try #require(resource), mode: .read)]
        )
        let submission = try await context.submit(work)

        resource = nil
        #expect(weakResource.value != nil)
        #expect(await submission.cancel() == .cancellationRequested)
        #expect(weakResource.value != nil)

        await gate.open()
        await #expect(throws: CancellationError.self) {
            try await submission.value()
        }
    }

    @Test
    func providerDiscoveryAndContextCreationPreserveTargetIdentity() async throws {
        let provider = try TestExecutionProvider()
        let devices = try await provider.discoverDevices()
        #expect(devices.count == 1)
        #expect(devices[0].descriptor.providerID == provider.descriptor.identifier)

        let target = ExecutionTargetReference(
            providerID: provider.descriptor.identifier,
            deviceID: devices[0].descriptor.identifier
        )
        let context = try await provider.makeContext(for: target)
        #expect(context.target == target)
        #expect(context is any ExecutionResourceAllocatingContext)

        let foreignProvider = try #require(ExecutionProviderID(rawValue: "provider.foreign"))
        await #expect(throws: TestProviderError.invalidTarget) {
            try await provider.makeContext(for: ExecutionTargetReference(providerID: foreignProvider))
        }
    }
}


extension ResourceLifecycleTests {
    @Test
    func providerConformanceHarnessValidatesDiscoveryAndContextTargets() async throws {
        let provider = try TestExecutionProvider()
        let contexts = try await ExecutionProviderConformanceHarness.makeValidatedContexts(
            from: provider
        )

        #expect(contexts.count == 1)
        #expect(contexts[0].target.providerID == provider.descriptor.identifier)
        #expect(contexts[0].target.deviceID == provider.device.descriptor.identifier)
    }

    @Test
    func providerConformanceHarnessSupportsOpaqueProviderManagedTargets() async throws {
        let provider = try TestExecutionProvider()
        let contexts = try await ExecutionProviderConformanceHarness.makeValidatedContexts(
            from: provider,
            includeOpaqueProviderTarget: true
        )

        #expect(contexts.count == 2)
        #expect(contexts.contains { $0.target.deviceID == nil })
    }

    @Test
    func providerConformanceHarnessChecksAllocationAndImportDescriptors() async throws {
        let provider = try TestExecutionProvider()
        let contexts = try await ExecutionProviderConformanceHarness.makeValidatedContexts(
            from: provider
        )
        let context = try #require(contexts.first)
        let request = try #require(ExecutionResourceRequest(
            kind: .buffer,
            minimumCapacityBytes: 4096,
            minimumAlignmentBytes: 256,
            memoryDomain: .deviceLocal
        ))

        let source = try await ExecutionProviderConformanceHarness.allocate(
            request,
            using: context
        )
        let imported = try await ExecutionProviderConformanceHarness.importResource(
            source,
            into: context,
            access: .readWrite
        )

        #expect(imported.descriptor.target == context.target)
        #expect(imported.descriptor.kind == source.descriptor.kind)
        #expect(imported.descriptor.capacityBytes >= source.descriptor.capacityBytes)
        #expect(imported.descriptor.alignmentBytes >= source.descriptor.alignmentBytes)
    }

    @Test
    func providerConformanceHarnessRejectsCapabilityClaimsWithoutOptionalProtocols() throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.overclaim"))
        let target = ExecutionTargetReference(providerID: providerID)
        let capabilities = try ExecutionCapabilities([
            ExecutionCapability(identifier: .workSubmission, value: .boolean(true))
        ])
        let context = CapabilityOnlyContext(target: target, capabilities: capabilities)

        #expect(throws: ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
            .workSubmission
        )) {
            try ExecutionProviderConformanceHarness.validate(context: context, for: target)
        }
    }
}

private struct CapabilityOnlyContext: ExecutionContext {
    let target: ExecutionTargetReference
    let capabilities: ExecutionCapabilities
}


private struct TestSynchronizingContext: ExecutionSynchronizingContext {
    let target: ExecutionTargetReference
    func synchronize(_ scope: ExecutionSynchronizationScope) async throws {}
}

extension ResourceLifecycleTests {
    @Test
    func providerConformanceHarnessExercisesOptionalSubmissionAndSynchronization() async throws {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.harness-runtime"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.harness-runtime"))
        let target = ExecutionTargetReference(providerID: providerID, deviceID: deviceID)
        let submitter = ImmediateSubmittingContext(target: target)
        let output = try await ExecutionProviderConformanceHarness.submit(
            IncrementWork(input: 10, resourceAccesses: [], dependencies: []),
            using: submitter
        )
        #expect(output == 11)

        let synchronizer = TestSynchronizingContext(target: target)
        try await ExecutionProviderConformanceHarness.synchronize(.context, using: synchronizer)

        #expect(throws: ExecutionProviderConformanceError.contextDoesNotSupportSynchronization) {
            try await ExecutionProviderConformanceHarness.synchronize(.context, using: submitter)
        }
    }
}
