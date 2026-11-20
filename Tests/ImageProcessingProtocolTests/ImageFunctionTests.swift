import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

private struct NumberValue: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "test.number")!
    let value: Int
}

private struct TextValue: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "test.text")!
    let value: String
}

private struct SummaryValue: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "test.summary")!
    let value: String
}

private struct AddNumberOperation: ImageOperation {
    typealias Input = NumberValue
    typealias Output = NumberValue

    let amount: Int

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "test.number.add")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
    )
}

private struct FormatNumberOperation: ImageOperation {
    typealias Input = NumberValue
    typealias Output = TextValue

    let prefix: String

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "test.number.format")!,
        semanticVersion: SemanticVersion(major: 2, minor: 1, patch: 0)!
    )
}

private struct SummarizeTextOperation: ImageOperation {
    typealias Input = TextValue
    typealias Output = SummaryValue

    let suffix: String

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "test.text.summarize")!,
        semanticVersion: SemanticVersion(major: 1, minor: 3, patch: 0)!
    )
}

struct ImageFunctionTests {
    @Test
    func composingTypedOperationsPreservesTheInputOutputTypeChain() throws {
        let addStep = try #require(OperationStepIdentifier(rawValue: "step.add"))
        let formatStep = try #require(OperationStepIdentifier(rawValue: "step.format"))
        let add = ImageFunction(
            operation: AddNumberOperation(amount: 7),
            stepIdentifier: addStep
        )
        let format = ImageFunction(
            operation: FormatNumberOperation(prefix: "value="),
            stepIdentifier: formatStep
        )

        let composed: ImageFunction<NumberValue, TextValue> = try add.followed(by: format)

        #expect(composed.stepCount == 2)
        #expect(composed.steps[0].specification.identifier == AddNumberOperation.specification.identifier)
        #expect(composed.steps[1].specification.identifier == FormatNumberOperation.specification.identifier)
        #expect(composed.steps[0].identifier == addStep)
        #expect(composed.steps[0].sourceIdentifier == addStep)
        #expect(composed.steps[1].identifier != formatStep)
        #expect(composed.steps[1].sourceIdentifier == formatStep)
        #expect(composed.steps[0].operation is AddNumberOperation)
        #expect(composed.steps[1].operation is FormatNumberOperation)
    }

    @Test
    func operationCanBeAppendedDirectlyToAnExistingFunction() throws {
        let firstID = try #require(OperationStepIdentifier(rawValue: "step.first"))
        let secondID = try #require(OperationStepIdentifier(rawValue: "step.second"))
        let first = ImageFunction(
            operation: AddNumberOperation(amount: 1),
            stepIdentifier: firstID
        )
        let composed = try first.followed(
            by: FormatNumberOperation(prefix: "n="),
            stepIdentifier: secondID
        )

        #expect(composed.stepCount == 2)
        #expect(composed.steps.map(\.identifier) == [firstID, secondID])
        #expect(composed.steps.map(\.sourceIdentifier) == [firstID, secondID])
    }

    @Test
    func identityFunctionHasNoStepsAndComposesOnEitherSide() throws {
        let identity = ImageFunction<NumberValue, NumberValue>.identity()
        let operation = ImageFunction(operation: AddNumberOperation(amount: 4))
        let left = try identity.followed(by: operation)
        let right = try operation.followed(by: identity)

        #expect(identity.stepCount == 0)
        #expect(left.stepCount == 1)
        #expect(right.stepCount == 1)
        #expect(left.steps[0].specification.identifier == AddNumberOperation.specification.identifier)
        #expect(right.steps[0].specification.identifier == AddNumberOperation.specification.identifier)
    }

    @Test
    func reusingTheSameFunctionCreatesDistinctStepOccurrences() throws {
        let originalID = try #require(OperationStepIdentifier(rawValue: "step.repeat"))
        let add = ImageFunction(
            operation: AddNumberOperation(amount: 1),
            stepIdentifier: originalID
        )
        let repeated: ImageFunction<NumberValue, NumberValue> = try add.followed(by: add)

        #expect(repeated.stepCount == 2)
        #expect(repeated.steps[0].identifier != repeated.steps[1].identifier)
        #expect(repeated.steps[0].sourceIdentifier == originalID)
        #expect(repeated.steps[1].sourceIdentifier == originalID)
    }

    @Test
    func compositionPreservesOrderAcrossMultipleFunctions() throws {
        let add = ImageFunction(operation: AddNumberOperation(amount: 1))
        let format = ImageFunction(operation: FormatNumberOperation(prefix: "value="))
        let summarize = ImageFunction(operation: SummarizeTextOperation(suffix: "!"))

        let composed: ImageFunction<NumberValue, SummaryValue> =
            try add.followed(by: format).followed(by: summarize)

        #expect(composed.stepCount == 3)
        #expect(composed.steps.map(\.specification.identifier) == [
            AddNumberOperation.specification.identifier,
            FormatNumberOperation.specification.identifier,
            SummarizeTextOperation.specification.identifier
        ])
    }

    @Test
    func operationStepIdentityCannotBeEmpty() {
        #expect(OperationStepIdentifier(rawValue: "") == nil)
    }
}


extension ImageFunctionTests {
    @Test
    func appendingAnOperationCannotDuplicateAnExistingStepIdentifier() throws {
        let identifier = try #require(OperationStepIdentifier(rawValue: "step.duplicate"))
        let first = ImageFunction(
            operation: AddNumberOperation(amount: 1),
            stepIdentifier: identifier
        )

        #expect(throws: QualificationPolicyValidationError.duplicateStepIdentifier(identifier)) {
            try first.followed(
                by: AddNumberOperation(amount: 2),
                stepIdentifier: identifier
            )
        }
    }
}
