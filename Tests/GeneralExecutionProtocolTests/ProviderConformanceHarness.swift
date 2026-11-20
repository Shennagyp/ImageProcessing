import GeneralExecutionProtocol

enum ExecutionProviderConformanceError: Error, Equatable, Sendable {
    case duplicateDeviceIdentifier(ExecutionDeviceID)
    case deviceBelongsToAnotherProvider(expected: ExecutionProviderID, actual: ExecutionProviderID)
    case noExecutionTargets
    case contextTargetMismatch(expected: ExecutionTargetReference, actual: ExecutionTargetReference)
    case contextAdvertisesCapabilityWithoutProtocol(ExecutionCapabilityID)
    case contextDoesNotSupportAllocation
    case contextDoesNotSupportWorkSubmission
    case contextDoesNotSupportSynchronization
    case allocationDoesNotMeetRequest
    case importedResourceDoesNotPreserveAllocation
}

/// Reusable provider checks for provider-owned test targets.
///
/// These checks validate generic contracts only. They do not inspect native
/// handles, image formats, provider-specific queues, or vendor API behavior.
enum ExecutionProviderConformanceHarness {
    static func discoverTargets(
        from provider: any ExecutionProvider,
        includeOpaqueProviderTarget: Bool = false
    ) async throws -> [ExecutionTargetReference] {
        _ = try await provider.observeState()
        let devices = try await provider.discoverDevices()
        var seen = Set<ExecutionDeviceID>()
        var targets: [ExecutionTargetReference] = []

        for device in devices {
            let descriptor = device.descriptor
            guard descriptor.providerID == provider.descriptor.identifier else {
                throw ExecutionProviderConformanceError.deviceBelongsToAnotherProvider(
                    expected: provider.descriptor.identifier,
                    actual: descriptor.providerID
                )
            }
            guard seen.insert(descriptor.identifier).inserted else {
                throw ExecutionProviderConformanceError.duplicateDeviceIdentifier(descriptor.identifier)
            }

            _ = try await device.observeState()
            targets.append(
                ExecutionTargetReference(
                    providerID: descriptor.providerID,
                    deviceID: descriptor.identifier
                )
            )
        }

        if includeOpaqueProviderTarget {
            targets.append(ExecutionTargetReference(providerID: provider.descriptor.identifier))
        }

        guard !targets.isEmpty else {
            throw ExecutionProviderConformanceError.noExecutionTargets
        }
        return targets
    }

    static func makeValidatedContexts(
        from provider: any ExecutionProvider,
        includeOpaqueProviderTarget: Bool = false
    ) async throws -> [any ExecutionContext] {
        let targets = try await discoverTargets(
            from: provider,
            includeOpaqueProviderTarget: includeOpaqueProviderTarget
        )
        var contexts: [any ExecutionContext] = []

        for target in targets {
            let context = try await provider.makeContext(for: target)
            try validate(context: context, for: target)
            contexts.append(context)
        }
        return contexts
    }

    static func validate(
        context: any ExecutionContext,
        for expectedTarget: ExecutionTargetReference
    ) throws {
        guard context.target == expectedTarget else {
            throw ExecutionProviderConformanceError.contextTargetMismatch(
                expected: expectedTarget,
                actual: context.target
            )
        }

        let capabilities = context.capabilities
        if advertisesTrue(.resourceAllocation, in: capabilities),
           !(context is any ExecutionResourceAllocatingContext) {
            throw ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
                .resourceAllocation
            )
        }
        if advertisesTrue(.resourceImport, in: capabilities),
           !(context is any ExecutionResourceAllocatingContext) {
            throw ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
                .resourceImport
            )
        }
        if advertisesTrue(.workSubmission, in: capabilities),
           !(context is any ExecutionWorkSubmittingContext) {
            throw ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
                .workSubmission
            )
        }
        if advertisesTrue(.workDependencies, in: capabilities),
           !(context is any ExecutionWorkSubmittingContext) {
            throw ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
                .workDependencies
            )
        }
        if advertisesTrue(.contextSynchronization, in: capabilities),
           !(context is any ExecutionSynchronizingContext) {
            throw ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
                .contextSynchronization
            )
        }
        if advertisesTrue(.resourceSynchronization, in: capabilities),
           !(context is any ExecutionSynchronizingContext) {
            throw ExecutionProviderConformanceError.contextAdvertisesCapabilityWithoutProtocol(
                .resourceSynchronization
            )
        }
    }

    static func allocate(
        _ request: ExecutionResourceRequest,
        using context: any ExecutionContext
    ) async throws -> any ExecutionResource {
        guard let allocator = context as? any ExecutionResourceAllocatingContext else {
            throw ExecutionProviderConformanceError.contextDoesNotSupportAllocation
        }
        let resource = try await allocator.allocateResource(request)
        guard request.isSatisfied(by: resource.descriptor, on: context.target) else {
            throw ExecutionProviderConformanceError.allocationDoesNotMeetRequest
        }
        return resource
    }

    static func importResource(
        _ source: any ExecutionResource,
        into context: any ExecutionContext,
        access: ExecutionResourceAccessMode
    ) async throws -> any ExecutionResource {
        guard let allocator = context as? any ExecutionResourceAllocatingContext else {
            throw ExecutionProviderConformanceError.contextDoesNotSupportAllocation
        }
        let imported = try await allocator.importResource(source, access: access)
        let sourceDescriptor = source.descriptor
        let importedDescriptor = imported.descriptor

        guard importedDescriptor.target == context.target,
              importedDescriptor.kind == sourceDescriptor.kind,
              importedDescriptor.capacityBytes >= sourceDescriptor.capacityBytes,
              importedDescriptor.alignmentBytes >= sourceDescriptor.alignmentBytes,
              importedDescriptor.alignmentBytes.isMultiple(of: sourceDescriptor.alignmentBytes) else {
            throw ExecutionProviderConformanceError.importedResourceDoesNotPreserveAllocation
        }
        return imported
    }

    static func submit<Work: ExecutionWork>(
        _ work: Work,
        using context: any ExecutionContext
    ) async throws -> Work.Output {
        guard let submitter = context as? any ExecutionWorkSubmittingContext else {
            throw ExecutionProviderConformanceError.contextDoesNotSupportWorkSubmission
        }
        let submission = try await submitter.submit(work)
        return try await submission.value()
    }

    static func synchronize(
        _ scope: ExecutionSynchronizationScope,
        using context: any ExecutionContext
    ) async throws {
        guard let synchronizer = context as? any ExecutionSynchronizingContext else {
            throw ExecutionProviderConformanceError.contextDoesNotSupportSynchronization
        }
        try await synchronizer.synchronize(scope)
    }

    private static func advertisesTrue(
        _ identifier: ExecutionCapabilityID,
        in capabilities: ExecutionCapabilities
    ) -> Bool {
        guard case .boolean(true)? = capabilities[identifier] else {
            return false
        }
        return true
    }
}
