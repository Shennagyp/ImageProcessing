/// A typed sequential composition of immutable image operation objects.
///
/// Input and output value types are preserved in the public generic signature.
/// Heterogeneous operation steps are stored in order for later runtime
/// qualification and dispatch. Composition does not execute processing.
public struct ImageFunction<Input: OperationValue, Output: OperationValue>: Sendable {
    public let steps: [AnyImageOperationStep]

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
    }

    private init(steps: [AnyImageOperationStep]) {
        self.steps = steps
    }

    /// The identity function for any operation value type.
    public static func identity() -> Self where Input == Output {
        Self(steps: [])
    }

    /// Compose this function followed by another function whose input type is
    /// exactly this function's output type. The right-hand step occurrences
    /// receive fresh identifiers so reusing a function does not duplicate
    /// occurrence identity in the resulting sequence.
    public func followed<NextOutput: OperationValue>(
        by next: ImageFunction<Output, NextOutput>
    ) -> ImageFunction<Input, NextOutput> {
        let rebasedRightHandSteps = next.steps.map { $0.reidentifiedForComposition() }
        return ImageFunction<Input, NextOutput>(
            steps: steps + rebasedRightHandSteps
        )
    }

    /// Append one typed operation occurrence.
    public func followed<Next: ImageOperation>(
        by operation: Next,
        stepIdentifier: OperationStepIdentifier = .generate()
    ) -> ImageFunction<Input, Next.Output> where Next.Input == Output {
        let step = AnyImageOperationStep(
            operation: operation,
            identifier: stepIdentifier
        )
        return ImageFunction<Input, Next.Output>(steps: steps + [step])
    }
}
