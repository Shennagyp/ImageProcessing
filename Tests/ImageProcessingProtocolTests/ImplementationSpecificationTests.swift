import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

private struct BlurInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "blur.input")!
}

private struct BlurOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "blur.output")!
}

private enum BlurFixture {
    static let radius = OperationParameterIdentifier(rawValue: "radius")!
    static let border = OperationParameterIdentifier(rawValue: "border")!
    static let reflect = OperationOptionIdentifier(rawValue: "reflect")!
    static let clamp = OperationOptionIdentifier(rawValue: "clamp")!
    static let wrap = OperationOptionIdentifier(rawValue: "wrap")!
}

private struct BlurOperation: ImageOperation {
    typealias Input = BlurInput
    typealias Output = BlurOutput

    let radius: Double
    let border: OperationOptionIdentifier

    var parameterValues: [OperationParameterValueRecord] {
        [
            .init(identifier: BlurFixture.radius, value: .real(radius)),
            .init(identifier: BlurFixture.border, value: .option(border))
        ]
    }

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "image.gaussian-blur")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        parameterSpecifications: [
            .init(identifier: BlurFixture.radius, domain: .real(minimum: 0.1, maximum: 100)),
            .init(identifier: BlurFixture.border, domain: .options([
                BlurFixture.reflect, BlurFixture.clamp, BlurFixture.wrap
            ]))
        ],
        precisionContract: OperationPrecisionContract(
            computation: [.float32, .float64]
        ),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate,
            determinism: .implementationSelectable,
            absoluteErrorTolerance: 0.0001
        ),
        layerContract: OperationLayerContract(
            acceptedInputKinds: [.raster],
            producedOutputKinds: [.raster]
        )
    )
}

private struct BlurImplementationFixture {
    static let provider = ExecutionProviderID(rawValue: "provider.cpu")!

    static func specification(
        parameterSupport: [OperationParameterSupport] = [
            .init(identifier: BlurFixture.radius, domain: .real(minimum: 0.1, maximum: 5)),
            .init(identifier: BlurFixture.border, domain: .options([BlurFixture.reflect]))
        ],
        precision: OperationPrecisionContract = .init(computation: [.float32]),
        determinism: ImplementationDeterminism = .deterministic,
        effects: OperationEffectContract = .pure,
        layerSupport: ImplementationLayerSupport = .init(
            inputKinds: [.raster],
            outputKinds: [.raster]
        ),
        resources: [ImplementationResourceRequirement] = [
            .init(
                role: .input(0),
                kind: .buffer,
                allowedMemoryDomains: [.host, .shared],
                minimumAlignmentBytes: 16,
                access: .read
            ),
            .init(
                role: .output(0),
                kind: .buffer,
                allowedMemoryDomains: [.host],
                minimumAlignmentBytes: 16,
                access: .write
            )
        ]
    ) -> ImplementationSpecification {
        ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "image.gaussian-blur.cpu")!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: BlurOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: BlurInput.typeIdentifier,
            outputType: BlurOutput.typeIdentifier,
            requiredProviderID: provider,
            parameterSupport: parameterSupport,
            precisionSupport: precision,
            determinism: determinism,
            effectContract: effects,
            layerSupport: layerSupport,
            resourceRequirements: resources,
            performanceHints: .init(
                fixedOverheadNanoseconds: 500,
                operationsPerElement: 24,
                temporaryBytesPerElement: 8
            )
        )
    }
}

struct ImplementationSpecificationTests {
    @Test
    func acceptsNarrowerParameterPrecisionAndLayerSupport() throws {
        let implementation = BlurImplementationFixture.specification()
        let operation = BlurOperation(radius: 2, border: BlurFixture.reflect)
        let step = AnyImageOperationStep(operation: operation)

        try implementation.validate(implements: step.specification)
        #expect(implementation.implements(step.specification))
        #expect(implementation.supports(step))
        #expect(implementation.precisionSupport.computation == [.float32])
        #expect(implementation.resourceRequirements.count == 2)
    }

    @Test
    func rejectsAnOperationParameterValueOutsideImplementationSupport() throws {
        let implementation = BlurImplementationFixture.specification()
        let step = AnyImageOperationStep(
            operation: BlurOperation(radius: 8, border: BlurFixture.reflect)
        )

        #expect(implementation.implements(step.specification))
        #expect(!implementation.supports(step))
    }

    @Test
    func rejectsAnOperationOptionOutsideImplementationSupport() throws {
        let implementation = BlurImplementationFixture.specification()
        let step = AnyImageOperationStep(
            operation: BlurOperation(radius: 2, border: BlurFixture.clamp)
        )

        #expect(implementation.implements(step.specification))
        #expect(!implementation.supports(step))
    }

    @Test
    func rejectsParameterSupportBroaderThanTheOperationContract() throws {
        let implementation = BlurImplementationFixture.specification(
            parameterSupport: [
                .init(identifier: BlurFixture.radius, domain: .real(minimum: 0, maximum: 200)),
                .init(identifier: BlurFixture.border, domain: .options([BlurFixture.reflect]))
            ]
        )

        #expect(throws: ImplementationSpecificationValidationError.parameterSupport(
            .supportOutsideOperationDomain(BlurFixture.radius)
        )) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsMissingRequiredParameterSupport() throws {
        let implementation = BlurImplementationFixture.specification(
            parameterSupport: [
                .init(identifier: BlurFixture.radius, domain: .real(minimum: 0.1, maximum: 5))
            ]
        )

        #expect(throws: ImplementationSpecificationValidationError.parameterSupport(
            .missingRequiredSupport(BlurFixture.border)
        )) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsPrecisionSupportOutsideOperationContract() throws {
        let implementation = BlurImplementationFixture.specification(
            precision: .init(computation: [.float16])
        )

        #expect(throws: ImplementationSpecificationValidationError.precisionSupportMismatch(.computation)) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsUnsupportedOutputPrecisionAndExtraPrecisionDimensions() throws {
        let implementation = BlurImplementationFixture.specification(
            precision: .init(
                computation: [.float32],
                outputStorage: [.uint8]
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.precisionSupportMismatch(.output)) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsImplementationThatAddsEffectsOrInputMutation() throws {
        let implementation = BlurImplementationFixture.specification(
            effects: OperationEffectContract(
                inputMutation: .permitted,
                effects: [.externalIO]
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.effectContractMismatch) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsLayerKindsOutsideOperationContract() throws {
        let implementation = BlurImplementationFixture.specification(
            layerSupport: .init(inputKinds: [.mask], outputKinds: [.raster])
        )

        #expect(throws: ImplementationSpecificationValidationError.layerSupportMismatch) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsNondeterministicImplementationWhenOperationRequiresDeterminism() throws {
        let operation = OperationSpecification<BlurInput, BlurOutput>(
            identifier: OperationIdentifier(rawValue: "image.deterministic-transform")!,
            semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate,
                determinism: .required
            )
        )
        let implementation = BlurImplementationFixture.specification(
            determinism: .nondeterministic
        )

        #expect(throws: ImplementationSpecificationValidationError.operationIdentityMismatch) {
            try implementation.validate(implements: operation.erased)
        }
    }

    @Test
    func rejectsInvalidResourceAndPerformanceMetadata() throws {
        let invalidResource = BlurImplementationFixture.specification(
            resources: [
                .init(
                    role: .input(0),
                    kind: .buffer,
                    allowedMemoryDomains: [],
                    minimumAlignmentBytes: 3,
                    access: .read
                )
            ]
        )
        #expect(throws: ImplementationSpecificationValidationError.invalidResourceRequirement(.input(0))) {
            try invalidResource.validate(implements: BlurOperation.specification.erased)
        }

        let invalidHints = ImplementationPerformanceHints(operationsPerElement: .nan)
        let invalidHintsImplementation = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "image.blur.bad-hints")!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: BlurOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: BlurInput.typeIdentifier,
            outputType: BlurOutput.typeIdentifier,
            parameterSupport: [
                .init(identifier: BlurFixture.radius, domain: .real(minimum: 0.1, maximum: 5)),
                .init(identifier: BlurFixture.border, domain: .options([BlurFixture.reflect]))
            ],
            precisionSupport: .init(computation: [.float32]),
            determinism: .deterministic,
            layerSupport: .init(inputKinds: [.raster], outputKinds: [.raster]),
            performanceHints: invalidHints
        )
        #expect(throws: ImplementationSpecificationValidationError.invalidPerformanceHints) {
            try invalidHintsImplementation.validate(implements: BlurOperation.specification.erased)
        }
    }
}
