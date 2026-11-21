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
}

private struct AllocatedOperationResourceSet: Sendable {
    let resources: OperationExecutionResources
    let accesses: [ExecutionResourceAccess]
}

/// Executes one already-qualified operation occurrence.
///
/// Qualification and ranking remain separate. The coordinator does not choose
/// a candidate or memory domain. It reserves the candidate's declared input
/// accesses plus its allocated output/temporary resources, revalidates those
/// exact handles, pins the provider instance, and invokes the exact implementation.
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

        // Pin the exact provider before any asynchronous allocation. A provider
        // removed after this point remains alive for this invocation only.
        let providerUse = try await providers.retainUse(
            for: candidate.target,
            registrationIdentifier: candidate.providerRegistrationIdentifier,
            context: candidate.context
        )

        let allocated = try await allocateResources(
            for: candidate,
            memoryDomains: memoryDomains
        )
        let completeAccessSet = candidate.inputResourceAccesses + allocated.accesses

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
                resources: allocated.resources
            )
            try validateAllocatedResourceBindings(
                allocated,
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
            withExtendedLifetime((providerUse, allocated)) {}
            throw OperationExecutionCoordinatorError.completionAccountingFailed(
                executionFailure: executionFailure,
                accountingFailure: String(describing: error)
            )
        }

        // Output bindings retain output resources beyond this point. Temporary
        // resources remain held here until execution completion, then fall out
        // of scope with the invocation resource set.
        withExtendedLifetime((providerUse, allocated)) {}

        switch executionResult {
        case let .success(output):
            return output
        case let .failure(error):
            throw error
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

            let resource = try await allocator.allocateResource(request)
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
