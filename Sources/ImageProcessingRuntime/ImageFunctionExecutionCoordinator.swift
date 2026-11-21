import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol

public enum ImageFunctionExecutionCoordinatorError: Error, Sendable {
    case inputTypeMismatch(
        expected: OperationValueIdentifier,
        actual: OperationValueIdentifier
    )
    case outputConcreteTypeMismatch(
        expected: OperationValueIdentifier,
        actual: OperationValueIdentifier
    )
    case noQualifiedCandidate(
        stepIdentifier: OperationStepIdentifier,
        qualification: OperationImplementationQualificationReport
    )
    case memoryDomainSelectionsForUnknownStep(OperationStepIdentifier)
}

/// Compact record of the exact candidate executed for one function step.
/// It intentionally does not retain the candidate, input value, context, or
/// intermediate output resources.
public struct ImageFunctionStepExecutionSummary: Sendable {
    public let stepIdentifier: OperationStepIdentifier
    public let implementation: OperationImplementationKey
    public let target: ExecutionTargetReference
    public let environmentSnapshotIdentifier: RuntimeEnvironmentSnapshotIdentifier
    public let rank: Int

    fileprivate init(
        stepIdentifier: OperationStepIdentifier,
        implementation: OperationImplementationKey,
        target: ExecutionTargetReference,
        environmentSnapshotIdentifier: RuntimeEnvironmentSnapshotIdentifier,
        rank: Int
    ) {
        self.stepIdentifier = stepIdentifier
        self.implementation = implementation
        self.target = target
        self.environmentSnapshotIdentifier = environmentSnapshotIdentifier
        self.rank = rank
    }
}

/// A step failed after zero or more earlier steps completed. The underlying
/// error is preserved so callers can still inspect provider-specific failure
/// categories. Completed summaries contain no intermediate values or resources.
public struct ImageFunctionStepExecutionFailure: Error, Sendable {
    public let failedStepIdentifier: OperationStepIdentifier
    public let completedSteps: [ImageFunctionStepExecutionSummary]
    public let underlying: any Error

    fileprivate init(
        failedStepIdentifier: OperationStepIdentifier,
        completedSteps: [ImageFunctionStepExecutionSummary],
        underlying: any Error
    ) {
        self.failedStepIdentifier = failedStepIdentifier
        self.completedSteps = completedSteps
        self.underlying = underlying
    }
}

/// Final typed output plus compact per-step execution diagnostics.
/// No intermediate OperationValue or qualified candidate is retained.
public struct ImageFunctionExecutionResult<Output: OperationValue>: Sendable {
    public let output: Output
    public let steps: [ImageFunctionStepExecutionSummary]

    fileprivate init(
        output: Output,
        steps: [ImageFunctionStepExecutionSummary]
    ) {
        self.output = output
        self.steps = steps
    }
}

/// Executes an already-composed ImageFunction in its declared step order.
///
/// Each step is resolved against the value produced by the previous step and a
/// newly captured runtime environment. The runner executes only the top-ranked
/// qualified candidate. It does not retry another candidate, search implementation
/// sequences, optimize cross-step routes, or publish intermediate image revisions.
public actor ImageFunctionExecutionCoordinator {
    private let resolver: CommonQualificationResolver
    private let environments: RuntimeEnvironmentSnapshotCoordinator
    private let operations: OperationExecutionCoordinator

    public init(
        resolver: CommonQualificationResolver,
        environments: RuntimeEnvironmentSnapshotCoordinator,
        operations: OperationExecutionCoordinator
    ) {
        self.resolver = resolver
        self.environments = environments
        self.operations = operations
    }

    public func execute<Input: OperationValue, Output: OperationValue>(
        _ function: ImageFunction<Input, Output>,
        input: Input,
        platform: ExecutionPlatformDescriptor,
        freshness: QualificationFreshnessPolicy,
        memoryDomainSelections: [OperationStepIdentifier: [ImplementationResourceRole: ExecutionMemoryDomain]] = [:],
        now: Date? = nil
    ) async throws -> Output {
        let result = try await executeWithReport(
            function,
            input: input,
            platform: platform,
            freshness: freshness,
            memoryDomainSelections: memoryDomainSelections,
            now: now
        )
        return result.output
    }

    public func executeWithReport<Input: OperationValue, Output: OperationValue>(
        _ function: ImageFunction<Input, Output>,
        input: Input,
        platform: ExecutionPlatformDescriptor,
        freshness: QualificationFreshnessPolicy,
        memoryDomainSelections: [OperationStepIdentifier: [ImplementationResourceRole: ExecutionMemoryDomain]] = [:],
        now: Date? = nil
    ) async throws -> ImageFunctionExecutionResult<Output> {
        try function.validateParameters()

        guard input.valueTypeIdentifier == Input.typeIdentifier else {
            throw ImageFunctionExecutionCoordinatorError.inputTypeMismatch(
                expected: Input.typeIdentifier,
                actual: input.valueTypeIdentifier
            )
        }

        let knownStepIdentifiers = Set(function.steps.map(\\.identifier))
        for selectedStep in memoryDomainSelections.keys where !knownStepIdentifiers.contains(selectedStep) {
            throw ImageFunctionExecutionCoordinatorError.memoryDomainSelectionsForUnknownStep(
                selectedStep
            )
        }

        var currentValue: any OperationValue = input
        var summaries: [ImageFunctionStepExecutionSummary] = []
        summaries.reserveCapacity(function.steps.count)

        for step in function.steps {
            do {
                try Task.checkCancellation()
                let evaluationDate = now ?? Date()
                let environment = try await environments.capture(
                    platform: platform,
                    capturedAt: evaluationDate
                )
                let resolution = try await resolver.resolve(
                    step: step,
                    input: currentValue,
                    policy: function.qualificationPolicy,
                    environment: environment,
                    freshness: freshness,
                    now: evaluationDate
                )

                guard let selected = resolution.rankedCandidates.first else {
                    throw ImageFunctionExecutionCoordinatorError.noQualifiedCandidate(
                        stepIdentifier: step.identifier,
                        qualification: resolution.qualification
                    )
                }

                let candidate = selected.candidate
                let summary = ImageFunctionStepExecutionSummary(
                    stepIdentifier: step.identifier,
                    implementation: candidate.implementation.key,
                    target: candidate.target,
                    environmentSnapshotIdentifier: environment.identifier,
                    rank: selected.rank
                )

                let output = try await operations.execute(
                    candidate,
                    memoryDomains: memoryDomainSelections[step.identifier] ?? [:]
                )
                currentValue = output
                summaries.append(summary)
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ImageFunctionStepExecutionFailure(
                    failedStepIdentifier: step.identifier,
                    completedSteps: summaries,
                    underlying: error
                )
            }
        }

        try Task.checkCancellation()
        guard let typedOutput = currentValue as? Output,
              typedOutput.valueTypeIdentifier == Output.typeIdentifier else {
            throw ImageFunctionExecutionCoordinatorError.outputConcreteTypeMismatch(
                expected: Output.typeIdentifier,
                actual: currentValue.valueTypeIdentifier
            )
        }

        return ImageFunctionExecutionResult(
            output: typedOutput,
            steps: summaries
        )
    }
}
