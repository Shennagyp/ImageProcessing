import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

private struct PolicyNumber: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "policy.number")!
}

private struct PolicyText: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "policy.text")!
}

private struct PrecisionAwareOperation: ImageOperation {
    typealias Input = PolicyNumber
    typealias Output = PolicyNumber

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "policy.precision-aware")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        precisionContract: OperationPrecisionContract(
            inputStorage: [.uint8, .uint16, .float16, .float32],
            computation: [.float16, .float32, .float64],
            accumulation: [.float32, .float64],
            outputStorage: [.uint8, .uint16, .float16, .float32]
        ),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate,
            determinism: .implementationSelectable
        )
    )
}

private struct NonNumericOperation: ImageOperation {
    typealias Input = PolicyNumber
    typealias Output = PolicyText

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "policy.non-numeric")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!
    )
}

private struct ComputationOnlyOperation: ImageOperation {
    typealias Input = PolicyNumber
    typealias Output = PolicyNumber

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "policy.computation-only")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        precisionContract: OperationPrecisionContract(
            computation: [.float32]
        ),
        numericalContract: OperationNumericalContract(
            rounding: .nearestEven,
            overflow: .saturate
        )
    )
}

struct QualificationPolicyTests {
    private func provider(_ raw: String) throws -> ExecutionProviderID {
        try #require(ExecutionProviderID(rawValue: raw))
    }

    private func step(_ raw: String) throws -> OperationStepIdentifier {
        try #require(OperationStepIdentifier(rawValue: raw))
    }

    private func numericFunction(
        stepIdentifier: OperationStepIdentifier? = nil
    ) -> ImageFunction<PolicyNumber, PolicyNumber> {
        ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: stepIdentifier ?? .generate()
        )
    }

    @Test
    func pipelineRequirementsAndPreferencesAreStoredSeparately() throws {
        let source = try numericFunction().qualifying { policy in
            policy.require(.precision(.computation, .float32), source: "scientific workflow")
            policy.prefer(.lowLatency, priority: 10, source: "interactive response")
        }

        #expect(source.qualificationPolicy.requirements.count == 1)
        #expect(source.qualificationPolicy.preferences.count == 1)
        #expect(source.qualificationPolicy.requirements[0].origin.scope == .pipeline)
        #expect(source.qualificationPolicy.preferences[0].priority == 10)
        #expect(source.qualificationPolicy.requirements[0].origin.source == "scientific workflow")
    }

    @Test
    func precisionAllowedSetsAreConjoinedAndNonEmptyIntersectionsAreAccepted() throws {
        let first = try numericFunction().qualifying {
            $0.require(.allowedPrecisions(.computation, [.float16, .float32, .float64]))
        }
        let combined = try first.qualifying {
            $0.require(.allowedPrecisions(.computation, [.float32, .float64]))
        }

        #expect(combined.qualificationPolicy.requirements.count == 2)
    }

    @Test
    func emptyPrecisionIntersectionIsRejectedWithBothOrigins() throws {
        let first = try numericFunction().qualifying {
            $0.require(.allowedPrecisions(.computation, [.float16]), source: "first declaration")
        }

        #expect(throws: QualificationPolicyConflict.self) {
            try first.qualifying {
                $0.require(.precision(.computation, .float32), source: "second declaration")
            }
        }
    }

    @Test
    func providerRequirementsAndAllowedSetsAreIntersected() throws {
        let cpu = try provider("provider.cpu")
        let cuda = try provider("provider.cuda")
        let metal = try provider("provider.metal")

        let allowed = try numericFunction().qualifying {
            $0.require(.allowedProviders([cpu, cuda]))
        }
        let narrowed = try allowed.qualifying {
            $0.require(.provider(cuda))
        }
        #expect(narrowed.qualificationPolicy.requirements.count == 2)

        #expect(throws: QualificationPolicyConflict.self) {
            try allowed.qualifying {
                $0.require(.provider(metal))
            }
        }
    }

    @Test
    func scopedProviderConflictDoesNotLeakAcrossDifferentSteps() throws {
        let cpu = try provider("provider.cpu")
        let cuda = try provider("provider.cuda")
        let firstID = try step("step.cpu")
        let secondID = try step("step.cuda")
        let first = ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: firstID
        )
        let second = ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: secondID
        )
        let left = try first.qualifying {
            $0.forStep(firstID) { $0.require(.provider(cpu)) }
        }
        let right = try second.qualifying {
            $0.forStep(secondID) { $0.require(.provider(cuda)) }
        }
        let composed = try left.followed(by: right)

        #expect(composed.qualificationPolicy.requirements.count == 2)
        #expect(composed.qualificationPolicy.requirements.allSatisfy {
            if case .step = $0.origin.scope { return true }
            return false
        })
    }

    @Test
    func pipelineProviderAndStepProviderContradictionIsRejectedAtComposition() throws {
        let cpu = try provider("provider.cpu")
        let cuda = try provider("provider.cuda")
        let left = try numericFunction().qualifying {
            $0.require(.provider(cpu), source: "pipeline deployment rule")
        }
        let stepID = try step("step.cuda-only")
        let rightBase = ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: stepID
        )
        let right = try rightBase.qualifying {
            $0.forStep(stepID) { $0.require(.provider(cuda), source: "step deployment rule") }
        }

        #expect(throws: QualificationPolicyConflict.self) {
            try left.followed(by: right)
        }
    }

    @Test
    func precisionRequirementMustApplyToTheTargetStep() throws {
        let stepID = try step("step.text-only")
        let function = ImageFunction(
            operation: NonNumericOperation(),
            stepIdentifier: stepID
        )

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.forStep(stepID) {
                    $0.require(.precision(.computation, .float32))
                }
            }
        }
    }

    @Test
    func pipelinePrecisionRequirementNeedsAtLeastOneApplicableStep() throws {
        let function = ImageFunction(operation: NonNumericOperation())

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.require(.precision(.computation, .float32))
            }
        }
    }

    @Test
    func unknownStepScopeIsRejected() throws {
        let function = numericFunction()
        let unknown = try step("step.unknown")

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.forStep(unknown) {
                    $0.prefer(.lowLatency)
                }
            }
        }
    }

    @Test
    func preferencesAtTheSameScopeCannotContradictTheirPriorityOrWeight() throws {
        let function = numericFunction()

        #expect(throws: QualificationPolicyConflict.self) {
            try function.qualifying {
                $0.prefer(.lowLatency, priority: 1, source: "first")
                $0.prefer(.lowLatency, priority: 2, source: "second")
            }
        }
    }

    @Test
    func pipelineAndStepPreferencesMayExpressDifferentPriorities() throws {
        let stepID = try step("step.emphasized")
        let function = ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: stepID
        )
        let qualified = try function.qualifying {
            $0.prefer(.lowLatency, priority: 1)
            $0.forStep(stepID) {
                $0.prefer(.lowLatency, priority: 5)
            }
        }

        #expect(qualified.qualificationPolicy.preferences.count == 2)
        #expect(qualified.qualificationPolicy.preferences[0].origin.scope == .pipeline)
        #expect(qualified.qualificationPolicy.preferences[1].origin.scope == .step(stepID))
    }

    @Test
    func nonFiniteAndNonPositivePreferenceWeightsAreRejected() throws {
        let function = numericFunction()

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.prefer(.lowLatency, weight: .infinity)
            }
        }
        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.prefer(.lowLatency, weight: 0)
            }
        }
    }

    @Test
    func stepScopedPolicyIsRebasedWhenItsFunctionIsComposedOnTheRight() throws {
        let left = numericFunction()
        let originalRightID = try step("step.original-right")
        let right = ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: originalRightID
        )
        let qualifiedRight = try right.qualifying {
            $0.forStep(originalRightID) {
                $0.require(.precision(.computation, .float32))
            }
        }
        let composed = try left.followed(by: qualifiedRight)
        let rebasedRightID = composed.steps[1].identifier
        let declaration = try #require(composed.qualificationPolicy.requirements.first)

        #expect(rebasedRightID != originalRightID)
        #expect(declaration.origin.scope == .step(rebasedRightID))
        #expect(declaration.origin.source == nil)
        #expect(composed.steps[1].sourceIdentifier == originalRightID)
    }

    @Test
    func exactExecutionCapabilityContradictionsAreRejected() throws {
        let capability = try #require(ExecutionCapabilityID(rawValue: "execution.test.feature"))
        let function = numericFunction()

        #expect(throws: QualificationPolicyConflict.self) {
            try function.qualifying {
                $0.require(.executionCapability(.init(
                    scope: .provider,
                    requirement: .exact(capability, .boolean(true))
                )))
                $0.require(.executionCapability(.init(
                    scope: .provider,
                    requirement: .exact(capability, .boolean(false))
                )))
            }
        }
    }
}


extension QualificationPolicyTests {
    @Test
    func threeWayProviderIntersectionIsValidatedAsAWhole() throws {
        let cpu = try provider("provider.cpu")
        let cuda = try provider("provider.cuda")
        let metal = try provider("provider.metal")
        let function = numericFunction()

        do {
            _ = try function.qualifying {
                $0.require(.allowedProviders([cpu, cuda]), source: "set A")
                $0.require(.allowedProviders([cuda, metal]), source: "set B")
                $0.require(.allowedProviders([cpu, metal]), source: "set C")
            }
            Issue.record("Expected three-way provider intersection conflict")
        } catch let conflict as QualificationPolicyConflict {
            #expect(conflict.dimension == .provider)
            #expect(conflict.priorDeclarations.count == 2)
            #expect(conflict.priorDeclarations.map(\.source).contains("set A"))
            #expect(conflict.priorDeclarations.map(\.source).contains("set B"))
            #expect(conflict.incomingDeclaration.source == "set C")
        }
    }

    @Test
    func threeWayPrecisionIntersectionIsValidatedAsAWhole() throws {
        let function = numericFunction()

        #expect(throws: QualificationPolicyConflict.self) {
            try function.qualifying {
                $0.require(.allowedPrecisions(.computation, [.float16, .float32]))
                $0.require(.allowedPrecisions(.computation, [.float32, .float64]))
                $0.require(.allowedPrecisions(.computation, [.float16, .float64]))
            }
        }
    }

    @Test
    func capabilityRequirementsWithDifferentValueKindsConflict() throws {
        let feature = try #require(ExecutionCapabilityID(rawValue: "execution.policy.mode"))
        let function = numericFunction()

        #expect(throws: QualificationPolicyConflict.self) {
            try function.qualifying {
                $0.require(.executionCapability(.init(
                    scope: .provider,
                    requirement: .exact(feature, .boolean(true))
                )))
                $0.require(.executionCapability(.init(
                    scope: .provider,
                    requirement: .stringSetContains(feature, "fast")
                )))
            }
        }
    }
}


extension QualificationPolicyTests {
    @Test
    func emptyProviderAllowedSetIsRejected() throws {
        let function = numericFunction()
        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.require(.allowedProviders([]))
            }
        }
    }

    @Test
    func emptyPrecisionAllowedSetIsRejected() throws {
        let function = numericFunction()
        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.require(.allowedPrecisions(.computation, []))
            }
        }
    }
}


extension QualificationPolicyTests {
    @Test
    func deterministicRequirementAndPreferenceNeedAnApplicableOperation() throws {
        let function = ImageFunction(operation: NonNumericOperation())

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.require(.deterministicResults)
            }
        }
        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.prefer(.deterministicResults)
            }
        }
    }

    @Test
    func deterministicRequirementAndPreferenceAttachToAnApplicableOperation() throws {
        let qualified = try numericFunction().qualifying {
            $0.require(.deterministicResults)
            $0.prefer(.deterministicResults, priority: 2)
        }

        #expect(qualified.qualificationPolicy.requirements.count == 1)
        #expect(qualified.qualificationPolicy.preferences.count == 1)
    }
}


extension QualificationPolicyTests {
    @Test
    func storagePrecisionUsesPixelComponentRepresentation() throws {
        let function = numericFunction()
        let qualified = try function.qualifying {
            $0.require(.precision(.inputStorage, .uint8))
            $0.require(.precision(.output, .storageFloat32))
        }

        #expect(qualified.qualificationPolicy.requirements.count == 2)
    }

    @Test
    func arithmeticPrecisionCannotUsePixelStoragePrecisionValue() throws {
        let function = numericFunction()
        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.require(.precision(.computation, .uint8))
            }
        }
    }
}


extension QualificationPolicyTests {
    @Test
    func precisionRequirementMustMatchTheExactOperationPrecisionDimension() throws {
        let stepID = try step("step.computation-only")
        let function = ImageFunction(
            operation: ComputationOnlyOperation(),
            stepIdentifier: stepID
        )

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.forStep(stepID) {
                    $0.require(.precision(.inputStorage, .uint8))
                }
            }
        }

        let computationRequirement = try function.qualifying {
            $0.forStep(stepID) {
                $0.require(.precision(.computation, .float32))
            }
        }
        #expect(computationRequirement.qualificationPolicy.requirements.count == 1)
    }
}


extension QualificationPolicyTests {
    @Test
    func precisionPreferenceMustUseTheValueKindForItsDimension() throws {
        #expect(throws: QualificationPolicyValidationError.self) {
            try numericFunction().qualifying {
                $0.prefer(.precision(.computation, .uint8))
            }
        }

        let qualified = try numericFunction().qualifying {
            $0.prefer(.precision(.computation, .float32), priority: 4)
        }
        #expect(qualified.qualificationPolicy.preferences.count == 1)
    }

    @Test
    func precisionPreferenceMustApplyToTheExactOperationDimension() throws {
        let stepID = try step("step.computation-preference-only")
        let function = ImageFunction(
            operation: ComputationOnlyOperation(),
            stepIdentifier: stepID
        )

        #expect(throws: QualificationPolicyValidationError.self) {
            try function.qualifying {
                $0.forStep(stepID) {
                    $0.prefer(.precision(.inputStorage, .uint8))
                }
            }
        }

        let valid = try function.qualifying {
            $0.forStep(stepID) {
                $0.prefer(.precision(.computation, .float32))
            }
        }
        #expect(valid.qualificationPolicy.preferences.count == 1)
    }

    @Test
    func precisionPreferencesForOneDimensionCannotConflictAtTheSameScope() throws {
        #expect(throws: QualificationPolicyConflict.self) {
            try numericFunction().qualifying {
                $0.prefer(.precision(.computation, .float32), priority: 3)
                $0.prefer(.precision(.computation, .float64), priority: 3)
            }
        }
    }

    @Test
    func pipelineAndStepPrecisionPreferencesRemainScoped() throws {
        let stepID = try step("step.precision-preference")
        let function = ImageFunction(
            operation: PrecisionAwareOperation(),
            stepIdentifier: stepID
        )
        let qualified = try function.qualifying {
            $0.prefer(.precision(.computation, .float32), priority: 1)
            $0.forStep(stepID) {
                $0.prefer(.precision(.computation, .float64), priority: 5)
            }
        }

        #expect(qualified.qualificationPolicy.preferences.count == 2)
        #expect(qualified.qualificationPolicy.preferences[0].origin.scope == .pipeline)
        #expect(qualified.qualificationPolicy.preferences[1].origin.scope == .step(stepID))
    }
}
