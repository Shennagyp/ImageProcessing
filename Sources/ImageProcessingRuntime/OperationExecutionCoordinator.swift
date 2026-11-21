import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol

public enum OperationExecutionCoordinatorError: Error, Equatable, Sendable {
    case operationDoesNotDeclareImageOutput
    case sourceImageSnapshotMissing(ImageIdentifier)
    case ambiguousSourceImageRevisions(ImageIdentifier, [ImageRevision])
    case imageOutputValueRequired
    case completionAccountingFailed(executionFailure: String?, accountingFailure: String)
    case reservationCancellationFailed(primaryFailure: String, cleanupFailure: String)
}

/// Executes one already-qualified operation occurrence.
///
/// Qualification and ranking remain separate. This coordinator does not choose
/// a candidate, allocate planned output/temporary resources, import inputs, or
/// plan a multi-step function. It reserves the candidate's declared input
/// accesses, revalidates those exact handles, pins the provider instance for the
/// dispatch, invokes the exact implementation registration, and releases the
/// lease only after execute returns or throws.
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
    /// output. Image output values carry their exact storage-owning snapshot.
    public func execute(
        _ candidate: QualifiedOperationImplementation
    ) async throws -> any OperationValue {
        try await dispatch(candidate)
    }

    /// Executes an image-producing operation and atomically publishes its output
    /// snapshot into an existing Image. The source revision is taken from the
    /// exact input snapshot captured during qualification; a concurrent edit
    /// causes Image.replace to reject publication without overwriting newer state.
    public func execute(
        _ candidate: QualifiedOperationImplementation,
        updating image: Image
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

        let output = try await dispatch(candidate)
        guard let imageOutput = output as? any ImageOperationOutputValue else {
            throw OperationExecutionCoordinatorError.imageOutputValueRequired
        }

        // Image.replace validates identity, next revision, and current revision
        // under its compare-and-swap boundary. No Image lock is held during work.
        _ = try image.replace(
            expectedRevision: expectedRevision,
            with: imageOutput.imageOperationOutputDescriptor.imageState
        )
        return output
    }

    private func dispatch(
        _ candidate: QualifiedOperationImplementation
    ) async throws -> any OperationValue {
        guard candidate.context.target == candidate.target else {
            throw ExecutionProviderRegistryError.contextTargetMismatch(
                expected: candidate.target,
                actual: candidate.context.target
            )
        }

        let lease = try await workLedger.reserveWork(
            on: candidate.target,
            accessing: candidate.inputResourceAccesses
        )

        let providerUse: ExecutionProviderUseLease
        do {
            try await workLedger.revalidate(
                lease,
                accessing: candidate.inputResourceAccesses
            )
            providerUse = try await providers.retainUse(
                for: candidate.target,
                registrationIdentifier: candidate.providerRegistrationIdentifier,
                context: candidate.context
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
            executionResult = .success(try await implementations.execute(using: candidate))
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
            withExtendedLifetime(providerUse) {}
            throw OperationExecutionCoordinatorError.completionAccountingFailed(
                executionFailure: executionFailure,
                accountingFailure: String(describing: error)
            )
        }

        // Keep the original provider instance alive until the operation has
        // reached its completion boundary, even if it was unregistered meanwhile.
        withExtendedLifetime(providerUse) {}

        switch executionResult {
        case let .success(output):
            return output
        case let .failure(error):
            throw error
        }
    }
}
