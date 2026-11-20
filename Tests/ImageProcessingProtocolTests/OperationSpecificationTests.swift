import ImageProcessingProtocol
import GeneralExecutionProtocol
import Testing

private struct SpecificationInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "specification.input")!
}

private struct SpecificationOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "specification.output")!
}

struct OperationSpecificationTests {
    private func identifier() -> OperationIdentifier {
        OperationIdentifier(rawValue: "specification.test")!
    }

    private func version() -> SemanticVersion {
        SemanticVersion(major: 1, minor: 0, patch: 0)!
    }

    @Test
    func validPrecisionDomainsAutomaticallyDeclareTheirQualificationDimensions() throws {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            precisionContract: OperationPrecisionContract(
                inputStorage: [.uint8, .uint16],
                computation: [.float32],
                accumulation: [.float32, .float64],
                outputStorage: [.float32]
            ),
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate
            )
        )

        try specification.validateContract()
        #expect(specification.qualificationDimensions == [
            .inputStoragePrecision,
            .computationPrecision,
            .accumulationPrecision,
            .outputPrecision
        ])
        #expect(specification.erased.precisionContract == specification.precisionContract)
    }

    @Test
    func explicitlyDeclaredPrecisionDimensionRequiresADeclaredPrecisionDomain() {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            qualificationDimensions: [.computationPrecision],
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate
            )
        )

        #expect(throws: OperationSpecificationValidationError.undeclaredPrecisionDomain(.computationPrecision)) {
            try specification.validateContract()
        }
    }

    @Test
    func precisionDomainRequiresNumericalContract() {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            precisionContract: OperationPrecisionContract(computation: [.float32])
        )

        #expect(throws: OperationSpecificationValidationError.missingNumericalContract) {
            try specification.validateContract()
        }
    }

    @Test
    func invalidNumericalErrorToleranceIsRejected() {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate,
                absoluteErrorTolerance: -.infinity
            )
        )

        #expect(throws: OperationSpecificationValidationError.invalidNumericalContract) {
            try specification.validateContract()
        }
    }

    @Test
    func implementationSelectableDeterminismDeclaresTheDeterminismDimension() throws {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate,
                determinism: .implementationSelectable
            )
        )

        try specification.validateContract()
        #expect(specification.qualificationDimensions.contains(.deterministicResults))
        #expect(specification.erased.qualificationDimensions.contains(.deterministicResults))
    }

    @Test
    func deterministicDimensionCannotConflictWithRequiredDeterminismContract() {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            qualificationDimensions: [.deterministicResults],
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate,
                determinism: .required
            )
        )

        #expect(throws: OperationSpecificationValidationError.deterministicDimensionRequiresSelectableContract) {
            try specification.validateContract()
        }
    }

    @Test
    func duplicateOrInvalidParameterSchemaIsRejectedByOperationContract() {
        let parameter = OperationParameterIdentifier(rawValue: "scale")!
        let duplicateSpecification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            parameterSpecifications: [
                .init(identifier: parameter, domain: .real(minimum: 0, maximum: 2)),
                .init(identifier: parameter, domain: .real(minimum: 0, maximum: 3))
            ]
        )

        #expect(throws: OperationSpecificationValidationError.invalidParameterSchema(
            .duplicateSpecification(parameter)
        )) {
            try duplicateSpecification.validateContract()
        }
    }

    @Test
    func effectAndLayerContractsArePreservedByTypeErasure() throws {
        let specification = OperationSpecification<SpecificationInput, SpecificationOutput>(
            identifier: identifier(),
            semanticVersion: version(),
            effectContract: OperationEffectContract(
                inputMutation: .never,
                outputAliasing: .distinctFromInputs,
                effects: [.randomness]
            ),
            layerContract: OperationLayerContract(
                acceptedInputKinds: [.raster, .mask],
                producedOutputKinds: [.labelMap]
            )
        )

        try specification.validateContract()
        let erased = specification.erased
        #expect(erased.effectContract == specification.effectContract)
        #expect(erased.layerContract == specification.layerContract)
    }
}
