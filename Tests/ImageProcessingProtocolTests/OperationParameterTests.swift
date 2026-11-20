import ImageProcessingProtocol
import GeneralExecutionProtocol
import Testing

private struct ParameterInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "parameters.input")!
}

private struct ParameterOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "parameters.output")!
}

private enum ParameterFixture {
    static let radius = OperationParameterIdentifier(rawValue: "radius")!
    static let border = OperationParameterIdentifier(rawValue: "border")!
    static let reflect = OperationOptionIdentifier(rawValue: "reflect")!
    static let clamp = OperationOptionIdentifier(rawValue: "clamp")!
    static let wrap = OperationOptionIdentifier(rawValue: "wrap")!
}

private struct ParameterizedOperation: ImageOperation {
    typealias Input = ParameterInput
    typealias Output = ParameterOutput

    let parameterValues: [OperationParameterValueRecord]

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "parameters.sample")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        parameterSpecifications: [
            OperationParameterSpecification(
                identifier: ParameterFixture.radius,
                domain: .real(minimum: 0.1, maximum: 20)
            ),
            OperationParameterSpecification(
                identifier: ParameterFixture.border,
                domain: .options([ParameterFixture.reflect, ParameterFixture.clamp])
            )
        ]
    )
}

private struct ChainedParameterizedOperation: ImageOperation {
    typealias Input = ParameterOutput
    typealias Output = ParameterOutput

    let parameterValues: [OperationParameterValueRecord]

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "parameters.chained")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        parameterSpecifications: [
            OperationParameterSpecification(
                identifier: ParameterFixture.radius,
                domain: .real(minimum: 0.1, maximum: 20)
            ),
            OperationParameterSpecification(
                identifier: ParameterFixture.border,
                domain: .options([ParameterFixture.reflect, ParameterFixture.clamp])
            )
        ]
    )
}

struct OperationParameterTests {
    private func entry(
        _ identifier: OperationParameterIdentifier,
        _ value: OperationParameterValue
    ) -> OperationParameterValueRecord {
        OperationParameterValueRecord(identifier: identifier, value: value)
    }

    @Test
    func validatesRequiredRealAndOptionParameters() throws {
        let operation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(1.5)),
            entry(ParameterFixture.border, .option(ParameterFixture.reflect))
        ])
        let function = ImageFunction(operation: operation)

        try function.validateParameters()
    }

    @Test
    func rejectsRequiredParameterMissingFromOperationInstance() throws {
        let operation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(1.5))
        ])

        #expect(throws: OperationParameterValidationError.missingRequiredValue(ParameterFixture.border)) {
            try ImageFunction(operation: operation).validateParameters()
        }
    }

    @Test
    func rejectsUnknownAndDuplicateParameterValues() throws {
        let unknown = OperationParameterIdentifier(rawValue: "unknown")!
        let unknownOperation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(1.5)),
            entry(ParameterFixture.border, .option(ParameterFixture.reflect)),
            entry(unknown, .boolean(true))
        ])
        #expect(throws: OperationParameterValidationError.unknownValue(unknown)) {
            try ImageFunction(operation: unknownOperation).validateParameters()
        }

        let duplicateOperation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(1.5)),
            entry(ParameterFixture.radius, .real(2)),
            entry(ParameterFixture.border, .option(ParameterFixture.reflect))
        ])
        #expect(throws: OperationParameterValidationError.duplicateValue(ParameterFixture.radius)) {
            try ImageFunction(operation: duplicateOperation).validateParameters()
        }
    }

    @Test
    func rejectsParameterValueOutsideItsDeclaredDomain() throws {
        let operation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(0)),
            entry(ParameterFixture.border, .option(ParameterFixture.reflect))
        ])

        #expect(throws: OperationParameterValidationError.valueOutsideDomain(ParameterFixture.radius)) {
            try ImageFunction(operation: operation).validateParameters()
        }
    }

    @Test
    func rejectsUnsupportedSemanticOption() throws {
        let operation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(1.5)),
            entry(ParameterFixture.border, .option(ParameterFixture.wrap))
        ])

        #expect(throws: OperationParameterValidationError.valueOutsideDomain(ParameterFixture.border)) {
            try ImageFunction(operation: operation).validateParameters()
        }
    }

    @Test
    func rejectsNonFiniteRealParameterValuesAndDomains() throws {
        let operation = ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(.nan)),
            entry(ParameterFixture.border, .option(ParameterFixture.reflect))
        ])

        #expect(throws: OperationParameterValidationError.valueOutsideDomain(ParameterFixture.radius)) {
            try ImageFunction(operation: operation).validateParameters()
        }

        let invalidDomain = OperationParameterDomain.real(minimum: .infinity, maximum: 10)
        #expect(!invalidDomain.isValid)
    }

    @Test
    func rejectsDuplicateAndInvalidParameterSpecifications() {
        let duplicate = [
            OperationParameterSpecification(
                identifier: ParameterFixture.radius,
                domain: .real(minimum: 0, maximum: 10)
            ),
            OperationParameterSpecification(
                identifier: ParameterFixture.radius,
                domain: .real(minimum: 0, maximum: 20)
            )
        ]
        #expect(throws: OperationParameterValidationError.duplicateSpecification(ParameterFixture.radius)) {
            try OperationParameterValidation.validate(
                specifications: duplicate,
                values: []
            )
        }

        let invalid = [
            OperationParameterSpecification(
                identifier: ParameterFixture.radius,
                domain: .integer(minimum: 10, maximum: 0)
            )
        ]
        #expect(throws: OperationParameterValidationError.invalidDomain(ParameterFixture.radius)) {
            try OperationParameterValidation.validate(
                specifications: invalid,
                values: []
            )
        }
    }

    @Test
    func parameterDomainsCanBeComparedForImplementationSubsetSupport() {
        let operationDomain = OperationParameterDomain.real(minimum: 0.1, maximum: 20)
        let implementationDomain = OperationParameterDomain.real(minimum: 0.1, maximum: 8)
        let broaderImplementationDomain = OperationParameterDomain.real(minimum: 0, maximum: 30)

        #expect(implementationDomain.isSubset(of: operationDomain))
        #expect(!broaderImplementationDomain.isSubset(of: operationDomain))
        #expect(OperationParameterDomain.options([ParameterFixture.reflect]).isSubset(
            of: .options([ParameterFixture.reflect, ParameterFixture.clamp])
        ))
        #expect(!OperationParameterDomain.options([ParameterFixture.wrap]).isSubset(
            of: .options([ParameterFixture.reflect, ParameterFixture.clamp])
        ))
    }

    @Test
    func functionCompositionValidatesBothOperationParameterSets() throws {
        let first = ImageFunction(operation: ParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(1)),
            entry(ParameterFixture.border, .option(ParameterFixture.reflect))
        ]))
        let second = ImageFunction(operation: ChainedParameterizedOperation(parameterValues: [
            entry(ParameterFixture.radius, .real(2)),
            entry(ParameterFixture.border, .option(ParameterFixture.clamp))
        ]))

        let composed = try first.followed(by: second)
        try composed.validateParameters()
        #expect(composed.stepCount == 2)
    }
}
