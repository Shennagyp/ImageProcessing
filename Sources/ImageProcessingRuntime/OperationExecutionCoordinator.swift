import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol

public enum OperationExecutionCoordinatorError: Error, Equatable, Sendable {
    case operationDoesNotDeclareImageOutput
    case sourceImageSnapshotMissing(ImageIdentifier)
    case ambiguousSourceImageRevisions(ImageIdentifier, [ImageRevision])
    case imageOutputValueRequired
    case unexpectedMemoryDomainSelection(ImplementationResourceRole)
    case memoryDomainSelectionRequired(ImplementationResourceRole)
    case noAllocatableMemoryDomain(ImplementationResourceRole)
    case memoryDomainNotAllocatable(ImplementationResourceRole, ExecutionMemoryDomain)
    case resourceAllocationContextUnavailable(ImplementationResourceRole)
    case resourceAllocationFailed(ImplementationResourceRole, reason: String)
    case providerResourceAllocationFailed(ImplementationResourceRole, ExecutionProviderFailure)
    case invalidResourceRequest(ImplementationResourceRole)
    case allocatedResourceDoesNotSatisfyRequest(ImplementationResourceRole, ExecutionResourceDescriptor)
    case allocatedResourceRegistrationMismatch(ImplementationResourceRole, expected: UUID, actual: UUID?)
    case allocatedResourceIdentityReused(ExecutionResourceReference)
    case allocatedResourceAliasingForbidden(ImplementationResourceRole, ExecutionResourceReference)
    case unsupportedAllocatedResourceRole(ImplementationResourceRole)
    case allocatedOutputResourceNotBound(ImplementationResourceRole, ExecutionResourceReference)
    case allocatedOutputResourceBoundOutsideProducedLayers(ImplementationResourceRole, ExecutionResourceReference)
    case allocatedOutputResourceBoundAmbiguously(ImplementationResourceRole, ExecutionResourceReference)
    case temporaryResourceEscapedInvocation(ImplementationResourceRole, ExecutionResourceReference)
    case completionAccountingFailed(executionFailure: String?, accountingFailure: String)
    case reservationCancellationFailed(primaryFailure: String, cleanupFailure: String)
    case inputResourceBindingMissing(Int)
    case inputResourceBindingsChanged
    case inputResourceAccessInsufficient(Int, ExecutionResourceReference, actual: ExecutionResourceAccessMode, required: ExecutionResourceAccessMode)
    case inputResourceImportContextUnavailable(Int)
    case inputResourceImportDescriptorMismatch(Int, ExecutionResourceReference, ExecutionResourceDescriptor)
    case inputResourceImportRegistrationMismatch(Int, expected: UUID, actual: UUID?)
    case inputResourceImportAliasesWritableSource(Int, ExecutionResourceReference)
    case inputResourceImportIdentityCollision(ExecutionResourceReference)
    case inputResourceImportAliasesAllocation(ImplementationResourceRole, ExecutionResourceReference)
    case importedInputResourceEscapedInvocation(Int, ExecutionResourceReference)
    case inputResourceImportCleanupFailed(String)
}

private struct AllocatedOperationResourceSet: Sendable {
    let resources: OperationExecutionResources
    let accesses: [ExecutionResourceAccess]
}

private struct InputResourceImportRequest: Sendable {
    let inputIndex: Int
    let source: any ExecutionResource
    let requirement: ImplementationResourceRequirement
}

private struct RetainedSourceResourceLease: Sendable {
    let workLease: ExecutionWorkLease
    /// Keeps the package that owns a registered source allocation available
    /// until the imported resource no longer depends on that source.
    let providerUse: ExecutionProviderUseLease?
}

private struct PreparedOperationInputResources: Sendable {
    let accesses: [ExecutionResourceAccess]
    let importedBindings: [OperationInputResourceBinding]
    let sourceLeases: [RetainedSourceResourceLease]
}

private struct InputResourceAccessSignature: Hashable {
    let objectIdentifier: ObjectIdentifier
    let reference: ExecutionResourceReference
    let descriptor: ExecutionResourceDescriptor
    let mode: ExecutionResourceAccessMode
}

private struct SourceLeaseReleaseReport: Sendable {
    let remaining: [RetainedSourceResourceLease]
    let failures: [String]
}

/// Executes one already-qualified operation occurrence.
///
/// Qualification and ranking remain separate. The coordinator does not choose
/// a candidate or memory domain. It verifies the exact qualified input bindings,
/// imports only input roles that explicitly declare read-only import, retains
/// source-target read leases through completion, and reserves/revalidates the
/// destination-context input and allocated output/temporary resources before
/// invoking the exact implementation.
public actor OperationExecutionCoordinator {
    private let implementations: OperationImplementationRegistry
    private let providers: ExecutionProviderRegistry
    private let workLedger: RuntimeWorkLedger

    public init(
        implementations: OperationImplementationRegistry,
        providers: ExecutionProviderRegistry,
        workLedger: RuntimeWorkLedger
    ) {
        self.implementations = implementations
        self.providers = providers
        self.workLedger = workLedger
    }

    /// Executes the candidate captured by qualification and returns its validated
    /// output. Each planned output/temporary role requires an explicit memory-domain
    /// selection; no default domain is inferred.
    public func execute(
        _ candidate: QualifiedOperationImplementation,
        memoryDomains: [ImplementationResourceRole: ExecutionMemoryDomain] = [:]
    ) async throws -> any OperationValue {
        try await dispatch(candidate, memoryDomains: memoryDomains)
    }

    /// Executes an image-producing operation and atomically publishes its output
    /// snapshot into an existing Image. The source revision is taken from the
    /// exact input snapshot captured during qualification; a concurrent edit
    /// causes Image.replace to reject publication without overwriting newer state.
    public func execute(
        _ candidate: QualifiedOperationImplementation,
        updating image: Image,
        memoryDomains: [ImplementationResourceRole: ExecutionMemoryDomain] = [:]
    ) async throws -> any OperationValue {
        let specification = candidate.operationStep.specification
        let declaresImageOutput = !specification.layerContract.producedOutputKinds.isEmpty
            || specification.pixelDataContract.output != nil
            || !specification.precisionContract.outputStorage.isEmpty
        guard declaresImageOutput else {
            throw OperationExecutionCoordinatorError.operationDoesNotDeclareImageOutput
        }

        let sourceRevisions = Set(
            candidate.imageInputContext?.inputs
                .filter { $0.imageState.identifier == image.identifier }
                .map(\.imageState.revision) ?? []
        )
        guard !sourceRevisions.isEmpty else {
            throw OperationExecutionCoordinatorError.sourceImageSnapshotMissing(image.identifier)
        }
        let orderedSourceRevisions = sourceRevisions.sorted()
        guard orderedSourceRevisions.count == 1,
              let expectedRevision = orderedSourceRevisions.first else {
            throw OperationExecutionCoordinatorError.ambiguousSourceImageRevisions(
                image.identifier,
                orderedSourceRevisions
            )
        }

        let currentState = image.snapshot()
        guard currentState.revision == expectedRevision else {
            throw ImageError.revisionConflict(
                expected: expectedRevision,
                actual: currentState.revision
            )
        }

        let output = try await dispatch(candidate, memoryDomains: memoryDomains)
        guard let imageOutput = output as? any ImageOperationOutputValue else {
            throw OperationExecutionCoordinatorError.imageOutputValueRequired
        }

        _ = try image.replace(
            expectedRevision: expectedRevision,
            with: imageOutput.imageOperationOutputDescriptor.imageState
        )
        return output
    }

    private func dispatch(
        _ candidate: QualifiedOperationImplementation,
        memoryDomains: [ImplementationResourceRole: ExecutionMemoryDomain]
    ) async throws -> any OperationValue {
        guard candidate.context.target == candidate.target else {
            throw ExecutionProviderRegistryError.contextTargetMismatch(
                expected: candidate.target,
                actual: candidate.context.target
            )
        }

        // Pin the exact provider before any asynchronous allocation or import.
        // A provider removed after this point remains alive for this invocation.
        let providerUse = try await providers.retainUse(
            for: candidate.target,
            registrationIdentifier: candidate.providerRegistrationIdentifier,
            context: candidate.context
        )

        let allocated = try await allocateResources(
            for: candidate,
            memoryDomains: memoryDomains
        )
        let preparedInputs = try await prepareInputResources(
            for: candidate,
            allocated: allocated
        )
        var sourceLeasesToRelease = preparedInputs.sourceLeases

        do {
            // Only handles that are accessible on this exact target enter the
            // destination lease. Foreign source handles remain under their own
            // source-target read leases while an imported handle can depend on them.
            let executionResources = try OperationExecutionResources(
                bindings: allocated.resources.bindings,
                importedInputBindings: preparedInputs.importedBindings
            )
            let completeAccessSet = preparedInputs.accesses + allocated.accesses
            let lease = try await workLedger.reserveWork(
                on: candidate.target,
                accessing: completeAccessSet
            )

            do {
                try await workLedger.revalidate(
                    lease,
                    accessing: completeAccessSet
                )
                try await workLedger.markSubmitted(lease)
            } catch let primaryError {
                do {
                    try await workLedger.cancelReservation(lease)
                } catch let cleanupError {
                    throw OperationExecutionCoordinatorError.reservationCancellationFailed(
                        primaryFailure: String(describing: primaryError),
                        cleanupFailure: String(describing: cleanupError)
                    )
                }
                throw primaryError
            }

            let executionResult: Result<any OperationValue, Error>
            do {
                let output = try await implementations.execute(
                    using: candidate,
                    resources: executionResources
                )
                try validateAllocatedResourceBindings(
                    allocated,
                    in: output
                )
                try validateImportedInputResourcesDidNotEscape(
                    preparedInputs.importedBindings,
                    in: output
                )
                executionResult = .success(output)
            } catch {
                executionResult = .failure(error)
            }

            do {
                try await workLedger.completeSubmission(lease)
            } catch {
                let executionFailure: String?
                if case let .failure(executionError) = executionResult {
                    executionFailure = String(describing: executionError)
                } else {
                    executionFailure = nil
                }
                withExtendedLifetime((providerUse, allocated, preparedInputs, executionResources)) {}
                throw OperationExecutionCoordinatorError.completionAccountingFailed(
                    executionFailure: executionFailure,
                    accountingFailure: String(describing: error)
                )
            }

            let sourceRelease = await releaseSubmittedSourceLeases(sourceLeasesToRelease)
            sourceLeasesToRelease = sourceRelease.remaining
            if !sourceRelease.failures.isEmpty {
                let executionFailure: String?
                if case let .failure(executionError) = executionResult {
                    executionFailure = String(describing: executionError)
                } else {
                    executionFailure = nil
                }
                withExtendedLifetime((providerUse, allocated, preparedInputs, executionResources)) {}
                throw OperationExecutionCoordinatorError.completionAccountingFailed(
                    executionFailure: executionFailure,
                    accountingFailure: sourceRelease.failures.joined(separator: "; ")
                )
            }

            // Output bindings retain output resources beyond this point. Imported
            // handles and temporary resources remain alive through the implementation
            // completion boundary; source leases are released only after that boundary.
            withExtendedLifetime((providerUse, allocated, preparedInputs, executionResources)) {}

            switch executionResult {
            case let .success(output):
                return output
            case let .failure(error):
                throw error
            }
        } catch {
            let sourceRelease = await releaseSubmittedSourceLeases(sourceLeasesToRelease)
            sourceLeasesToRelease = sourceRelease.remaining
            if !sourceRelease.failures.isEmpty {
                throw OperationExecutionCoordinatorError.completionAccountingFailed(
                    executionFailure: String(describing: error),
                    accountingFailure: sourceRelease.failures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    private func prepareInputResources(
        for candidate: QualifiedOperationImplementation,
        allocated: AllocatedOperationResourceSet
    ) async throws -> PreparedOperationInputResources {
        let inputRequirements = candidate.implementation.specification.resourceRequirements
            .compactMap { requirement -> (index: Int, requirement: ImplementationResourceRequirement)? in
                guard case let .input(index) = requirement.role else { return nil }
                return (index, requirement)
            }
            .sorted { $0.index < $1.index }

        if inputRequirements.isEmpty {
            guard candidate.inputResourceAccesses.isEmpty else {
                throw OperationExecutionCoordinatorError.inputResourceBindingsChanged
            }
            return PreparedOperationInputResources(
                accesses: [],
                importedBindings: [],
                sourceLeases: []
            )
        }

        guard let inputValue = candidate.input as? any OperationResourceInputValue else {
            throw OperationExecutionCoordinatorError.inputResourceBindingMissing(
                inputRequirements[0].index
            )
        }

        let currentBindings = inputValue.operationInputResourceBindings
        var qualifiedAccesses: [ExecutionResourceAccess] = []
        var directAccesses: [ExecutionResourceAccess] = []
        var importRequests: [InputResourceImportRequest] = []

        for entry in inputRequirements {
            let bindings = currentBindings.filter { $0.inputIndex == entry.index }
            guard !bindings.isEmpty else {
                throw OperationExecutionCoordinatorError.inputResourceBindingMissing(entry.index)
            }

            for binding in bindings {
                let descriptor = binding.resource.descriptor
                guard descriptor.kind == entry.requirement.kind,
                      descriptor.capacityBytes >= entry.requirement.minimumCapacityBytes,
                      descriptor.alignmentBytes >= entry.requirement.minimumAlignmentBytes,
                      descriptor.alignmentBytes.isMultiple(of: entry.requirement.minimumAlignmentBytes),
                      entry.requirement.allowedMemoryDomains.contains(descriptor.memoryDomain) else {
                    throw OperationExecutionCoordinatorError.inputResourceBindingsChanged
                }

                let requiredSourceAccess: ExecutionResourceAccessMode =
                    entry.requirement.requiresImport ? .read : entry.requirement.access
                guard Self.bindingAccess(binding.access, satisfies: requiredSourceAccess) else {
                    throw OperationExecutionCoordinatorError.inputResourceAccessInsufficient(
                        entry.index,
                        descriptor.reference,
                        actual: binding.access,
                        required: requiredSourceAccess
                    )
                }

                qualifiedAccesses.append(
                    ExecutionResourceAccess(
                        resource: binding.resource,
                        mode: entry.requirement.access
                    )
                )

                let registrationMismatch = descriptor.memoryDomain == .deviceLocal
                    && descriptor.providerRegistrationIdentifier != candidate.providerRegistrationIdentifier
                if (descriptor.target != candidate.target || registrationMismatch),
                   !entry.requirement.requiresImport {
                    throw OperationExecutionCoordinatorError.inputResourceBindingsChanged
                }
                let mustImport = entry.requirement.requiresImport

                if mustImport {
                    guard candidate.context is any ExecutionResourceAllocatingContext,
                          case .boolean(true)? = candidate.context.capabilities[.resourceImport] else {
                        throw OperationExecutionCoordinatorError.inputResourceImportContextUnavailable(
                            entry.index
                        )
                    }
                    importRequests.append(
                        InputResourceImportRequest(
                            inputIndex: entry.index,
                            source: binding.resource,
                            requirement: entry.requirement
                        )
                    )
                } else {
                    guard descriptor.target == candidate.target else {
                        throw OperationExecutionCoordinatorError.inputResourceBindingsChanged
                    }
                    directAccesses.append(
                        ExecutionResourceAccess(
                            resource: binding.resource,
                            mode: entry.requirement.access
                        )
                    )
                }
            }
        }

        guard Self.accessSignatures(qualifiedAccesses) ==
              Self.accessSignatures(candidate.inputResourceAccesses) else {
            throw OperationExecutionCoordinatorError.inputResourceBindingsChanged
        }

        guard !importRequests.isEmpty else {
            return PreparedOperationInputResources(
                accesses: directAccesses,
                importedBindings: [],
                sourceLeases: []
            )
        }

        guard let allocator = candidate.context as? any ExecutionResourceAllocatingContext else {
            throw OperationExecutionCoordinatorError.inputResourceImportContextUnavailable(
                importRequests[0].inputIndex
            )
        }

        let allocatedReferences = Set(
            allocated.resources.bindings.map { $0.resource.descriptor.reference }
        )
        let directReferences = Set(
            directAccesses.map { $0.resource.descriptor.reference }
        )
        let sourceReferences = Set(
            importRequests.map { $0.source.descriptor.reference }
        )
        var importedSourceByDestination: [ExecutionResourceReference: ExecutionResourceReference] = [:]
        var importedBindings: [OperationInputResourceBinding] = []
        var importedAccesses: [ExecutionResourceAccess] = []
        var sourceLeases: [RetainedSourceResourceLease] = []

        do {
            for request in importRequests {
                let sourceDescriptor = request.source.descriptor
                let sourceReference = sourceDescriptor.reference
                let sourceProviderUse: ExecutionProviderUseLease?
                if sourceDescriptor.providerRegistrationIdentifier != nil {
                    sourceProviderUse = try await providers.retainResourceOwner(
                        for: request.source
                    )
                } else {
                    sourceProviderUse = nil
                }
                let sourceAccess = ExecutionResourceAccess(resource: request.source, mode: .read)
                let sourceLease = try await workLedger.reserveWork(
                    on: sourceDescriptor.target,
                    accessing: [sourceAccess]
                )
                do {
                    try await workLedger.revalidate(
                        sourceLease,
                        accessing: [sourceAccess]
                    )
                    try await workLedger.markSubmitted(sourceLease)
                } catch let primaryError {
                    do {
                        try await workLedger.cancelReservation(sourceLease)
                    } catch let cleanupError {
                        throw OperationExecutionCoordinatorError.inputResourceImportCleanupFailed(
                            "Source reservation failed: \\(primaryError). Reservation cancellation failed: \\(cleanupError)."
                        )
                    }
                    throw primaryError
                }
                sourceLeases.append(
                    RetainedSourceResourceLease(
                        workLease: sourceLease,
                        providerUse: sourceProviderUse
                    )
                )

                let imported = try await allocator.importResource(
                    request.source,
                    access: request.requirement.access
                )
                let importedDescriptor = imported.descriptor
                let importedReference = importedDescriptor.reference

                guard importedDescriptor.target == candidate.target,
                      importedDescriptor.kind == request.requirement.kind,
                      importedDescriptor.capacityBytes >= request.requirement.minimumCapacityBytes,
                      importedDescriptor.alignmentBytes >= request.requirement.minimumAlignmentBytes,
                      importedDescriptor.alignmentBytes.isMultiple(of: request.requirement.minimumAlignmentBytes),
                      request.requirement.allowedMemoryDomains.contains(importedDescriptor.memoryDomain) else {
                    throw OperationExecutionCoordinatorError.inputResourceImportDescriptorMismatch(
                        request.inputIndex,
                        sourceReference,
                        importedDescriptor
                    )
                }
                guard importedDescriptor.providerRegistrationIdentifier == candidate.providerRegistrationIdentifier else {
                    throw OperationExecutionCoordinatorError.inputResourceImportRegistrationMismatch(
                        request.inputIndex,
                        expected: candidate.providerRegistrationIdentifier,
                        actual: importedDescriptor.providerRegistrationIdentifier
                    )
                }
                if importedReference == sourceReference, request.requirement.access != .read {
                    throw OperationExecutionCoordinatorError.inputResourceImportAliasesWritableSource(
                        request.inputIndex,
                        sourceReference
                    )
                }
                if sourceReferences.contains(importedReference), importedReference != sourceReference {
                    throw OperationExecutionCoordinatorError.inputResourceImportIdentityCollision(
                        importedReference
                    )
                }
                if directReferences.contains(importedReference) {
                    throw OperationExecutionCoordinatorError.inputResourceImportIdentityCollision(
                        importedReference
                    )
                }
                if let existingSource = importedSourceByDestination[importedReference],
                   existingSource != sourceReference {
                    throw OperationExecutionCoordinatorError.inputResourceImportIdentityCollision(
                        importedReference
                    )
                }
                importedSourceByDestination[importedReference] = sourceReference

                if allocatedReferences.contains(importedReference) {
                    throw OperationExecutionCoordinatorError.inputResourceImportAliasesAllocation(
                        .input(request.inputIndex),
                        importedReference
                    )
                }

                // importResource's return is already a readiness boundary. When a
                // provider also exposes explicit synchronization, use the narrow
                // imported-resource scope before making the handle visible to the
                // implementation.
                if let synchronizer = candidate.context as? any ExecutionSynchronizingContext {
                    try await synchronizer.synchronize(.resource(importedReference))
                }

                guard let binding = OperationInputResourceBinding(
                    inputIndex: request.inputIndex,
                    resource: imported,
                    access: request.requirement.access
                ) else {
                    throw OperationExecutionCoordinatorError.inputResourceBindingsChanged
                }
                importedBindings.append(binding)
                importedAccesses.append(
                    ExecutionResourceAccess(
                        resource: imported,
                        mode: request.requirement.access
                    )
                )
            }

            return PreparedOperationInputResources(
                accesses: directAccesses + importedAccesses,
                importedBindings: importedBindings,
                sourceLeases: sourceLeases
            )
        } catch {
            let cleanup = await releaseSubmittedSourceLeases(sourceLeases)
            if !cleanup.failures.isEmpty {
                throw OperationExecutionCoordinatorError.inputResourceImportCleanupFailed(
                    "Import failed: \(error). Source-lease cleanup failed: \(cleanup.failures.joined(separator: "; "))."
                )
            }
            throw error
        }
    }

    private func releaseSubmittedSourceLeases(
        _ leases: [RetainedSourceResourceLease]
    ) async -> SourceLeaseReleaseReport {
        var remaining: [RetainedSourceResourceLease] = []
        var failures: [String] = []
        for lease in leases {
            do {
                try await workLedger.completeSubmission(lease.workLease)
            } catch {
                remaining.append(lease)
                failures.append(String(describing: error))
            }
        }
        return SourceLeaseReleaseReport(remaining: remaining, failures: failures)
    }

    private static func accessSignatures(
        _ accesses: [ExecutionResourceAccess]
    ) -> [InputResourceAccessSignature: Int] {
        var counts: [InputResourceAccessSignature: Int] = [:]
        for access in accesses {
            let signature = InputResourceAccessSignature(
                objectIdentifier: ObjectIdentifier(access.resource),
                reference: access.resource.descriptor.reference,
                descriptor: access.resource.descriptor,
                mode: access.mode
            )
            counts[signature, default: 0] += 1
        }
        return counts
    }

    private static func bindingAccess(
        _ available: ExecutionResourceAccessMode,
        satisfies required: ExecutionResourceAccessMode
    ) -> Bool {
        switch (available, required) {
        case (.read, .read), (.write, .write), (.readWrite, .read),
             (.readWrite, .write), (.readWrite, .readWrite):
            true
        default:
            false
        }
    }

    private func allocateResources(
        for candidate: QualifiedOperationImplementation,
        memoryDomains: [ImplementationResourceRole: ExecutionMemoryDomain]
    ) async throws -> AllocatedOperationResourceSet {
        let allocations = candidate.resourceAllocations.sorted {
            Self.rolePrecedes($0.role, $1.role)
        }
        let roles = Set(allocations.map(\.role))

        for selectedRole in memoryDomains.keys where !roles.contains(selectedRole) {
            throw OperationExecutionCoordinatorError.unexpectedMemoryDomainSelection(selectedRole)
        }

        guard allocations.isEmpty || candidate.context is any ExecutionResourceAllocatingContext else {
            let role = allocations.first?.role ?? .temporary("unavailable")
            throw OperationExecutionCoordinatorError.resourceAllocationContextUnavailable(role)
        }
        let allocator = candidate.context as? any ExecutionResourceAllocatingContext

        var resourceBindings: [OperationExecutionResourceBinding] = []
        var accesses: [ExecutionResourceAccess] = []
        var allocatedReferences = Set<ExecutionResourceReference>()
        let inputReferences = Set(candidate.inputResourceAccesses.map { $0.resource.descriptor.reference })

        for allocation in allocations {
            switch allocation.role {
            case .output(_), .temporary(_):
                break
            case .input(_):
                throw OperationExecutionCoordinatorError.unsupportedAllocatedResourceRole(allocation.role)
            }

            let memoryDomain: ExecutionMemoryDomain
            if let selected = memoryDomains[allocation.role] {
                memoryDomain = selected
            } else if allocation.allocatableMemoryDomains.count == 1,
                      let onlyDomain = allocation.allocatableMemoryDomains.first {
                memoryDomain = onlyDomain
            } else if allocation.allocatableMemoryDomains.isEmpty {
                throw OperationExecutionCoordinatorError.noAllocatableMemoryDomain(
                    allocation.role
                )
            } else {
                throw OperationExecutionCoordinatorError.memoryDomainSelectionRequired(
                    allocation.role
                )
            }

            guard allocation.allowedMemoryDomains.contains(memoryDomain),
                  allocation.allocatableMemoryDomains.contains(memoryDomain) else {
                throw OperationExecutionCoordinatorError.memoryDomainNotAllocatable(
                    allocation.role,
                    memoryDomain
                )
            }
            guard let request = ExecutionResourceRequest(
                kind: allocation.kind,
                minimumCapacityBytes: allocation.minimumCapacityBytes,
                minimumAlignmentBytes: allocation.minimumAlignmentBytes,
                memoryDomain: memoryDomain
            ) else {
                throw OperationExecutionCoordinatorError.invalidResourceRequest(allocation.role)
            }
            guard let allocator else {
                throw OperationExecutionCoordinatorError.resourceAllocationContextUnavailable(
                    allocation.role
                )
            }

            let resource: any ExecutionResource
            do {
                resource = try await allocator.allocateResource(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as ExecutionProviderFailure {
                if failure.kind == .resourceAllocationFailed {
                    throw OperationExecutionCoordinatorError.providerResourceAllocationFailed(
                        allocation.role,
                        failure
                    )
                }
                throw failure
            } catch {
                throw OperationExecutionCoordinatorError.resourceAllocationFailed(
                    allocation.role,
                    reason: String(describing: error)
                )
            }
            let descriptor = resource.descriptor
            guard request.isSatisfied(by: descriptor, on: candidate.target) else {
                throw OperationExecutionCoordinatorError.allocatedResourceDoesNotSatisfyRequest(
                    allocation.role,
                    descriptor
                )
            }
            guard descriptor.providerRegistrationIdentifier == candidate.providerRegistrationIdentifier else {
                throw OperationExecutionCoordinatorError.allocatedResourceRegistrationMismatch(
                    allocation.role,
                    expected: candidate.providerRegistrationIdentifier,
                    actual: descriptor.providerRegistrationIdentifier
                )
            }

            let reference = descriptor.reference
            guard allocatedReferences.insert(reference).inserted else {
                throw OperationExecutionCoordinatorError.allocatedResourceIdentityReused(reference)
            }
            if inputReferences.contains(reference) {
                let mayShareUnmodifiedInput: Bool
                switch allocation.role {
                case .output(_):
                    mayShareUnmodifiedInput =
                        allocation.access == .read
                        && candidate.operationStep.specification.effectContract.outputAliasing == .mayAliasInput
                        && candidate.operationStep.specification.effectContract.inputMutation == .never
                case .temporary(_), .input(_):
                    mayShareUnmodifiedInput = false
                }
                guard mayShareUnmodifiedInput else {
                    throw OperationExecutionCoordinatorError.allocatedResourceAliasingForbidden(
                        allocation.role,
                        reference
                    )
                }
            }

            resourceBindings.append(
                OperationExecutionResourceBinding(
                    role: allocation.role,
                    resource: resource,
                    access: allocation.access
                )
            )
            accesses.append(
                ExecutionResourceAccess(resource: resource, mode: allocation.access)
            )
        }

        let resources: OperationExecutionResources
        do {
            resources = try OperationExecutionResources(bindings: resourceBindings)
        } catch {
            throw error
        }

        return AllocatedOperationResourceSet(
            resources: resources,
            accesses: accesses
        )
    }

    private func validateAllocatedResourceBindings(
        _ allocated: AllocatedOperationResourceSet,
        in output: any OperationValue
    ) throws {
        guard !allocated.resources.isEmpty else { return }
        guard let imageOutput = output as? any ImageOperationOutputValue else {
            if let binding = allocated.resources.bindings.first(where: { $0.role.isOutputRole }) {
                throw OperationExecutionCoordinatorError.allocatedOutputResourceNotBound(
                    binding.role,
                    binding.resource.descriptor.reference
                )
            }
            return
        }

        let descriptor = imageOutput.imageOperationOutputDescriptor
        let allLayerBindings = descriptor.storageBindings.layerBindings
        let producedLayerIDs = Set(descriptor.producedLayers.map(\.layerID))
        let producedBindings = allLayerBindings.filter {
            producedLayerIDs.contains($0.reference.layerID)
        }

        for binding in allocated.resources.bindings {
            let reference = binding.resource.descriptor.reference
            let allOccurrences = allLayerBindings.reduce(into: 0) { count, layerBinding in
                count += layerBinding.storage.planeBindings.filter {
                    $0.resource.descriptor.reference == reference
                }.count
            }
            let producedOccurrences = producedBindings.reduce(into: 0) { count, layerBinding in
                count += layerBinding.storage.planeBindings.filter {
                    $0.resource.descriptor.reference == reference
                }.count
            }

            switch binding.role {
            case .output(_):
                guard allOccurrences > 0 else {
                    throw OperationExecutionCoordinatorError.allocatedOutputResourceNotBound(
                        binding.role,
                        reference
                    )
                }
                guard producedOccurrences == allOccurrences else {
                    throw OperationExecutionCoordinatorError.allocatedOutputResourceBoundOutsideProducedLayers(
                        binding.role,
                        reference
                    )
                }
                guard producedOccurrences == 1 else {
                    throw OperationExecutionCoordinatorError.allocatedOutputResourceBoundAmbiguously(
                        binding.role,
                        reference
                    )
                }
            case .temporary(_):
                guard allOccurrences == 0 else {
                    throw OperationExecutionCoordinatorError.temporaryResourceEscapedInvocation(
                        binding.role,
                        reference
                    )
                }
            case .input(_):
                throw OperationExecutionCoordinatorError.unsupportedAllocatedResourceRole(binding.role)
            }
        }
    }

    private func validateImportedInputResourcesDidNotEscape(
        _ importedBindings: [OperationInputResourceBinding],
        in output: any OperationValue
    ) throws {
        guard !importedBindings.isEmpty,
              let imageOutput = output as? any ImageOperationOutputValue else {
            return
        }

        let outputReferences = Set(
            imageOutput.imageOperationOutputDescriptor.storageBindings.layerBindings.flatMap {
                $0.storage.planeBindings.map { $0.resource.descriptor.reference }
            }
        )
        for binding in importedBindings {
            let reference = binding.resource.descriptor.reference
            guard !outputReferences.contains(reference) else {
                throw OperationExecutionCoordinatorError.importedInputResourceEscapedInvocation(
                    binding.inputIndex,
                    reference
                )
            }
        }
    }

    private static func rolePrecedes(
        _ lhs: ImplementationResourceRole,
        _ rhs: ImplementationResourceRole
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.input(left), .input(right)):
            return left < right
        case (.input(_), _):
            return true
        case (_, .input(_)):
            return false
        case let (.output(left), .output(right)):
            return left < right
        case (.output(_), .temporary(_)):
            return true
        case (.temporary(_), .output(_)):
            return false
        case let (.temporary(left), .temporary(right)):
            return left < right
        }
    }
}

private extension ImplementationResourceRole {
    var isOutputRole: Bool {
        if case .output(_) = self { return true }
        return false
    }
}
