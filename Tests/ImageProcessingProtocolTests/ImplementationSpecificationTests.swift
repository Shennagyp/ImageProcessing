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
    static let srgb = ColorSpaceIdentifier(rawValue: "srgb")!
    static let linearSRGB = ColorSpaceIdentifier(rawValue: "linear-srgb")!

    static let operationPixelDomain = PixelRepresentationDomain(
        layouts: [.interleaved],
        interpretations: [.color],
        colorModels: [.rgb, .gray],
        alphaModes: [.none, .straight, .premultiplied],
        transferFunctions: [.linear, .sRGB],
        colorSpaces: [srgb, linearSRGB],
        channelRoles: [.gray, .red, .green, .blue, .alpha],
        channelOrders: [
            [.red, .green, .blue],
            [.blue, .green, .red]
        ],
        subsamplingFactors: [
            PixelSubsampling()!,
            PixelSubsampling(x: 2, y: 2)!
        ],
        sampleOrigins: [
            .zero,
            PixelGridCoordinate(x: 0.5, y: 0.5)!
        ]
    )

    static let implementationPixelDomain = PixelRepresentationDomain(
        layouts: [.interleaved],
        interpretations: [.color],
        colorModels: [.rgb],
        alphaModes: [.none],
        transferFunctions: [.sRGB],
        colorSpaces: [srgb],
        channelRoles: [.red, .green, .blue],
        channelOrders: [[.red, .green, .blue]],
        subsamplingFactors: [PixelSubsampling()!],
        sampleOrigins: [.zero]
    )
    static let implementationPixelSupport = OperationPixelDataContract(
        input: implementationPixelDomain,
        output: implementationPixelDomain
    )
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
        ),
        pixelDataContract: OperationPixelDataContract(
            input: BlurFixture.operationPixelDomain,
            output: BlurFixture.operationPixelDomain
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
        numericalSupport: ImplementationNumericalSupport? = .init(
            roundingModes: [.nearestEven],
            overflowBehaviors: [.saturate],
            outputRangeBehaviors: [.preserve],
            maximumAbsoluteError: 0.00005
        ),
        effects: OperationEffectContract = .pure,
        layerSupport: ImplementationLayerSupport = .init(
            inputKinds: [.raster],
            outputKinds: [.raster]
        ),
        pixelSupport: OperationPixelDataContract = BlurFixture.implementationPixelSupport,
        capabilities: [ExecutionCapabilityConstraint] = [],
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
            requiredCapabilities: capabilities,
            parameterSupport: parameterSupport,
            precisionSupport: precision,
            determinism: determinism,
            numericalSupport: numericalSupport,
            effectContract: effects,
            layerSupport: layerSupport,
            pixelDataSupport: pixelSupport,
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
            identifier: OperationIdentifier(rawValue: "image.gaussian-blur")!,
            semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate,
                determinism: .required
            )
        )
        let implementation = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "image.gaussian-blur.nondeterministic")!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: operation.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: BlurInput.typeIdentifier,
            outputType: BlurOutput.typeIdentifier,
            determinism: .nondeterministic,
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve]
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.determinismMismatch) {
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
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve],
                maximumAbsoluteError: 0.00005
            ),
            layerSupport: .init(inputKinds: [.raster], outputKinds: [.raster]),
            pixelDataSupport: BlurFixture.implementationPixelSupport,
            performanceHints: invalidHints
        )
        #expect(throws: ImplementationSpecificationValidationError.invalidPerformanceHints) {
            try invalidHintsImplementation.validate(implements: BlurOperation.specification.erased)
        }
    }
}


extension ImplementationSpecificationTests {
    @Test
    func acceptsNarrowerPixelLayoutColorAndChannelSupport() throws {
        let implementation = BlurImplementationFixture.specification()
        try implementation.validate(implements: BlurOperation.specification.erased)
    }

    @Test
    func rejectsPixelLayoutOutsideOperationContract() throws {
        let unsupportedLayout = PixelRepresentationDomain(
            layouts: [.planar],
            interpretations: [.color],
            colorModels: [.rgb],
            alphaModes: [.none],
            transferFunctions: [.sRGB],
            colorSpaces: [BlurFixture.srgb],
            channelRoles: [.red, .green, .blue]
        )
        let implementation = BlurImplementationFixture.specification(
            pixelSupport: OperationPixelDataContract(
                input: unsupportedLayout,
                output: BlurFixture.implementationPixelDomain
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.pixelRepresentationMismatch(inputOutput: "input")) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsMissingPixelRepresentationDeclarationForPixelOperation() throws {
        let implementation = BlurImplementationFixture.specification(pixelSupport: .none)
        #expect(throws: ImplementationSpecificationValidationError.pixelRepresentationMismatch(inputOutput: "input")) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsEmptyPixelRepresentationDomainsInOperationContract() throws {
        let invalid = PixelRepresentationDomain(
            layouts: [],
            interpretations: [.scientific]
        )
        let operation = OperationSpecification<BlurInput, BlurOutput>(
            identifier: OperationIdentifier(rawValue: "image.empty-pixel-domain")!,
            semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            pixelDataContract: OperationPixelDataContract(input: invalid)
        )

        #expect(throws: OperationSpecificationValidationError.invalidPixelDataContract) {
            try operation.validateContract()
        }
    }
}


extension ImplementationSpecificationTests {
    @Test
    func rejectsRoundingAndOverflowModesOutsideOperationNumericalContract() throws {
        let wrongRounding = BlurImplementationFixture.specification(
            numericalSupport: .init(
                roundingModes: [.towardZero],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve],
                maximumAbsoluteError: 0.00005
            )
        )
        #expect(throws: ImplementationSpecificationValidationError.numericalSupportMismatch) {
            try wrongRounding.validate(implements: BlurOperation.specification.erased)
        }

        let wrongOverflow = BlurImplementationFixture.specification(
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.wrap],
                outputRangeBehaviors: [.preserve],
                maximumAbsoluteError: 0.00005
            )
        )
        #expect(throws: ImplementationSpecificationValidationError.numericalSupportMismatch) {
            try wrongOverflow.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func implementationErrorBoundMustMeetOperationTolerance() throws {
        let implementation = BlurImplementationFixture.specification(
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve],
                maximumAbsoluteError: 0.001
            )
        )
        #expect(throws: ImplementationSpecificationValidationError.numericalSupportMismatch) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func numericalSupportIsRequiredWhenOperationDeclaresNumericalContract() throws {
        let implementation = BlurImplementationFixture.specification(numericalSupport: nil)
        #expect(throws: ImplementationSpecificationValidationError.missingNumericalSupport) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func operationRequiredEffectsMustBeImplementedButOptionalPermittedEffectsMayBeOmitted() throws {
        let base = BlurOperation.specification
        let operation = OperationSpecification<BlurInput, BlurOutput>(
            identifier: base.identifier,
            semanticVersion: base.semanticVersion,
            parameterSpecifications: base.parameterSpecifications,
            precisionContract: base.precisionContract,
            numericalContract: base.numericalContract,
            effectContract: OperationEffectContract(
                requiredEffects: [.randomness],
                permittedEffects: [.randomness, .deviceState]
            ),
            layerContract: base.layerContract,
            pixelDataContract: base.pixelDataContract
        )
        let valid = BlurImplementationFixture.specification(
            effects: OperationEffectContract(
                requiredEffects: [.randomness],
                permittedEffects: [.randomness]
            )
        )
        try valid.validate(implements: operation.erased)

        let missingRequired = BlurImplementationFixture.specification(
            parameterSupport: [],
            effects: .pure
        )
        #expect(throws: ImplementationSpecificationValidationError.effectContractMismatch) {
            try missingRequired.validate(implements: operation.erased)
        }

        let forbiddenExtraEffect = BlurImplementationFixture.specification(
            parameterSupport: [],
            effects: OperationEffectContract(
                requiredEffects: [.randomness, .externalIO],
                permittedEffects: [.randomness, .externalIO]
            )
        )
        #expect(throws: ImplementationSpecificationValidationError.effectContractMismatch) {
            try forbiddenExtraEffect.validate(implements: operation.erased)
        }
    }

    @Test
    func rejectsPixelRepresentationMismatchOnOutputIndependently() throws {
        let unsupportedOutput = PixelRepresentationDomain(
            layouts: [.planar],
            interpretations: [.color],
            colorModels: [.rgb],
            alphaModes: [.none],
            transferFunctions: [.sRGB],
            colorSpaces: [BlurFixture.srgb],
            channelRoles: [.red, .green, .blue]
        )
        let implementation = BlurImplementationFixture.specification(
            pixelSupport: OperationPixelDataContract(
                input: BlurFixture.implementationPixelDomain,
                output: unsupportedOutput
            )
        )
        #expect(throws: ImplementationSpecificationValidationError.pixelRepresentationMismatch(inputOutput: "output")) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func resourceRequirementsNeedPositiveCapacityAndValidKind() throws {
        let zeroCapacity = BlurImplementationFixture.specification(resources: [
            .init(
                role: .input(0),
                kind: .buffer,
                allowedMemoryDomains: [.host],
                minimumCapacityBytes: 0,
                access: .read
            )
        ])
        #expect(throws: ImplementationSpecificationValidationError.invalidResourceRequirement(.input(0))) {
            try zeroCapacity.validate(implements: BlurOperation.specification.erased)
        }

        let emptyOpaqueKind = BlurImplementationFixture.specification(resources: [
            .init(
                role: .temporary("scratch"),
                kind: .opaque(""),
                allowedMemoryDomains: [.deviceLocal],
                minimumCapacityBytes: 1024,
                access: .readWrite
            )
        ])
        #expect(throws: ImplementationSpecificationValidationError.invalidResourceRequirement(.temporary("scratch"))) {
            try emptyOpaqueKind.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func duplicateResourceRolesAndMalformedCapabilitiesAreRejected() throws {
        let duplicateRole = BlurImplementationFixture.specification(resources: [
            .init(role: .input(0), kind: .buffer, allowedMemoryDomains: [.host], access: .read),
            .init(role: .input(0), kind: .buffer, allowedMemoryDomains: [.shared], access: .read)
        ])
        #expect(throws: ImplementationSpecificationValidationError.duplicateResourceRequirement(.input(0))) {
            try duplicateRole.validate(implements: BlurOperation.specification.erased)
        }

        let capabilityID = ExecutionCapabilityID(rawValue: "execution.maximum-value")!
        let malformedCapability = BlurImplementationFixture.specification(capabilities: [
            .init(
                scope: .device,
                requirement: .decimalAtLeast(capabilityID, .nan)
            )
        ])
        #expect(throws: ImplementationSpecificationValidationError.invalidRequiredCapability) {
            try malformedCapability.validate(implements: BlurOperation.specification.erased)
        }
    }
}


extension ImplementationSpecificationTests {
    @Test
    func acceptsNarrowerChannelOrderSubsamplingAndSampleOriginSupport() throws {
        let implementation = BlurImplementationFixture.specification()
        try implementation.validate(implements: BlurOperation.specification.erased)
    }

    @Test
    func rejectsUnsupportedChannelSequence() throws {
        let unsupported = PixelRepresentationDomain(
            layouts: [.interleaved],
            interpretations: [.color],
            colorModels: [.rgb],
            alphaModes: [.none],
            transferFunctions: [.sRGB],
            colorSpaces: [BlurFixture.srgb],
            channelRoles: [.red, .green, .blue, .alpha],
            channelOrders: [[.alpha, .red, .green, .blue]],
            subsamplingFactors: [PixelSubsampling()!],
            sampleOrigins: [.zero]
        )
        let implementation = BlurImplementationFixture.specification(
            pixelSupport: OperationPixelDataContract(
                input: unsupported,
                output: BlurFixture.implementationPixelDomain
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.pixelRepresentationMismatch(inputOutput: "input")) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsUnsupportedSubsamplingFactors() throws {
        let unsupported = PixelRepresentationDomain(
            layouts: [.interleaved],
            interpretations: [.color],
            colorModels: [.rgb],
            alphaModes: [.none],
            transferFunctions: [.sRGB],
            colorSpaces: [BlurFixture.srgb],
            channelRoles: [.red, .green, .blue],
            channelOrders: [[.red, .green, .blue]],
            subsamplingFactors: [PixelSubsampling(x: 4, y: 4)!],
            sampleOrigins: [.zero]
        )
        let implementation = BlurImplementationFixture.specification(
            pixelSupport: OperationPixelDataContract(
                input: unsupported,
                output: BlurFixture.implementationPixelDomain
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.pixelRepresentationMismatch(inputOutput: "input")) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }

    @Test
    func rejectsUnsupportedSampleOrigins() throws {
        let unsupported = PixelRepresentationDomain(
            layouts: [.interleaved],
            interpretations: [.color],
            colorModels: [.rgb],
            alphaModes: [.none],
            transferFunctions: [.sRGB],
            colorSpaces: [BlurFixture.srgb],
            channelRoles: [.red, .green, .blue],
            channelOrders: [[.red, .green, .blue]],
            subsamplingFactors: [PixelSubsampling()!],
            sampleOrigins: [PixelGridCoordinate(x: 0.25, y: 0.25)!]
        )
        let implementation = BlurImplementationFixture.specification(
            pixelSupport: OperationPixelDataContract(
                input: unsupported,
                output: BlurFixture.implementationPixelDomain
            )
        )

        #expect(throws: ImplementationSpecificationValidationError.pixelRepresentationMismatch(inputOutput: "input")) {
            try implementation.validate(implements: BlurOperation.specification.erased)
        }
    }
}


extension ImplementationSpecificationTests {
    @Test
    func scientificOnlyImplementationCanNarrowMixedColorAndScientificOperationDomain() throws {
        let operationDomain = PixelRepresentationDomain(
            layouts: [.interleaved, .planar],
            interpretations: [.color, .scientific],
            colorModels: [.rgb],
            alphaModes: [.none, .straight],
            transferFunctions: [.linear, .sRGB],
            colorSpaces: [BlurFixture.srgb, BlurFixture.linearSRGB],
            channelRoles: [.red, .green, .blue, .intensity],
            measurementUnits: [MeasurementUnitIdentifier(rawValue: "um")!,
                               MeasurementUnitIdentifier(rawValue: "mm")!]
        )
        let scientificImplementationDomain = PixelRepresentationDomain(
            layouts: [.planar],
            interpretations: [.scientific],
            channelRoles: [.intensity],
            measurementUnits: [MeasurementUnitIdentifier(rawValue: "um")!]
        )
        let operation = OperationSpecification<BlurInput, BlurOutput>(
            identifier: OperationIdentifier(rawValue: "image.scientific-domain-op")!,
            semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            pixelDataContract: OperationPixelDataContract(input: operationDomain)
        )
        let implementation = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "image.scientific-domain-impl")!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: operation.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: BlurInput.typeIdentifier,
            outputType: BlurOutput.typeIdentifier,
            pixelDataSupport: OperationPixelDataContract(input: scientificImplementationDomain)
        )

        try implementation.validate(implements: operation.erased)
    }
}


extension ImplementationSpecificationTests {
    @Test
    func concreteNumericalModesSatisfyImplementationDefinedOperationModes() throws {
        let base = BlurOperation.specification
        let operation = OperationSpecification<BlurInput, BlurOutput>(
            identifier: base.identifier,
            semanticVersion: base.semanticVersion,
            parameterSpecifications: base.parameterSpecifications,
            precisionContract: base.precisionContract,
            numericalContract: OperationNumericalContract(
                rounding: .implementationDefined,
                overflow: .implementationDefined,
                outputRange: .preserve,
                determinism: .implementationSelectable
            ),
            layerContract: base.layerContract,
            pixelDataContract: base.pixelDataContract
        )
        let implementation = BlurImplementationFixture.specification(
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve],
                maximumAbsoluteError: 0.00005
            )
        )

        try implementation.validate(implements: operation.erased)
    }

    @Test
    func operationToleranceMayLeaveImplementationErrorUnreported() throws {
        let base = BlurOperation.specification
        let operation = OperationSpecification<BlurInput, BlurOutput>(
            identifier: base.identifier,
            semanticVersion: base.semanticVersion,
            parameterSpecifications: base.parameterSpecifications,
            precisionContract: base.precisionContract,
            numericalContract: OperationNumericalContract(
                rounding: .nearestEven,
                overflow: .saturate,
                absoluteErrorTolerance: nil,
                relativeErrorTolerance: nil,
                determinism: .implementationSelectable
            ),
            layerContract: base.layerContract,
            pixelDataContract: base.pixelDataContract
        )
        let implementation = BlurImplementationFixture.specification(
            numericalSupport: .init(
                roundingModes: [.nearestEven],
                overflowBehaviors: [.saturate],
                outputRangeBehaviors: [.preserve]
            )
        )

        try implementation.validate(implements: operation.erased)
    }
}
