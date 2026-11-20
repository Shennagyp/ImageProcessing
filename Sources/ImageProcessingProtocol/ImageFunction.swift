/// A typed sequential composition of immutable image operation objects.
///
/// Input and output value types are preserved in the public generic signature.
/// Heterogeneous operation steps are stored in order for later runtime
/// qualification and dispatch. Composition does not execute processing.
public struct ImageFunction<Input: OperationValue, Output: OperationValue>: Sendable {
    public let steps: [AnyImageOperationStep]
    public let qualificationPolicy: QualificationPolicy

    public var stepCount: Int { steps.count }
    public var stepIdentifiers: [OperationStepIdentifier] {
        steps.map(\.identifier)
    }

    public init<Operation: ImageOperation>(
        operation: Operation,
        stepIdentifier: OperationStepIdentifier = .generate()
    ) where Operation.Input == Input, Operation.Output == Output {
        self.steps = [
            AnyImageOperationStep(operation: operation, identifier: stepIdentifier)
        ]
        self.qualificationPolicy = .unrestricted
    }

    private init(
        steps: [AnyImageOperationStep],
        qualificationPolicy: QualificationPolicy
    ) {
        self.steps = steps
        self.qualificationPolicy = qualificationPolicy
    }

    /// The identity function for any operation value type.
    public static func identity() -> Self where Input == Output {
        Self(steps: [], qualificationPolicy: .unrestricted)
    }

    /// Compose this function followed by another function whose input type is
    /// exactly this function's output type. The right-hand step occurrences
    /// receive fresh identifiers so reusing a function does not duplicate
    /// occurrence identity in the resulting sequence.
    public func followed<NextOutput: OperationValue>(
        by next: ImageFunction<Output, NextOutput>
    ) throws -> ImageFunction<Input, NextOutput> {
        var stepIdentifierMap: [OperationStepIdentifier: OperationStepIdentifier] = [:]
        let rebasedRightHandSteps = next.steps.map { step in
            let rebased = step.reidentifiedForComposition()
            stepIdentifierMap[step.identifier] = rebased.identifier
            return rebased
        }
        let combinedSteps = steps + rebasedRightHandSteps
        let rebasedPolicy = try next.qualificationPolicy.reidentified(
            stepIdentifiers: stepIdentifierMap
        )
        let combinedPolicy = try qualificationPolicy.combined(
            with: rebasedPolicy,
            for: combinedSteps
        )
        return ImageFunction<Input, NextOutput>(
            steps: combinedSteps,
            qualificationPolicy: combinedPolicy
        )
    }

    /// Append one typed operation occurrence.
    public func followed<Next: ImageOperation>(
        by operation: Next,
        stepIdentifier: OperationStepIdentifier = .generate()
    ) throws -> ImageFunction<Input, Next.Output> where Next.Input == Output {
        guard !steps.contains(where: { $0.identifier == stepIdentifier }) else {
            throw QualificationPolicyValidationError.duplicateStepIdentifier(stepIdentifier)
        }
        let step = AnyImageOperationStep(
            operation: operation,
            identifier: stepIdentifier
        )
        let combinedSteps = steps + [step]
        let combinedPolicy = try qualificationPolicy.combined(
            with: .unrestricted,
            for: combinedSteps
        )
        return ImageFunction<Input, Next.Output>(
            steps: combinedSteps,
            qualificationPolicy: combinedPolicy
        )
    }

    /// Attaches validated declarative requirements and preferences to this function.
    /// Step-scoped declarations are checked against this function's occurrence IDs.
    public func qualifying(
        _ configure: (inout QualificationPolicyBuilder) -> Void
    ) throws -> Self {
        var builder = QualificationPolicyBuilder()
        configure(&builder)
        let addition = try builder.build(for: steps)
        let combined = try qualificationPolicy.combined(with: addition, for: steps)
        return Self(steps: steps, qualificationPolicy: combined)
    }
}
