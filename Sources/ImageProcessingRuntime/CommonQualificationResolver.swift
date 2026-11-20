import GeneralExecutionProtocol
import ImageProcessingProtocol

/// One shared evaluator for implementation specifications, execution state,
/// and hard pipeline requirements. This stage establishes eligibility only;
/// objective ranking and cost optimization remain separate.
public actor CommonQualificationResolver {
    private let implementations: OperationImplementationRegistry
    private let providers: ExecutionProviderRegistry

    public init(
        implementations: OperationImplementationRegistry,
        providers: ExecutionProviderRegistry
    ) {
        self.implementations = implementations
        self.providers = providers
    }

    public func evaluate(
        step: AnyImageOperationStep,
        policy: QualificationPolicy,
        environment: RuntimeEnvironmentSnapshot,
        freshness: QualificationFreshnessPolicy,
        now: Date = Date()
    ) async throws -> OperationImplementationQualificationReport {
        do {
            try step.specification.validateContract()
        } catch let error as OperationSpecificationValidationError {
            throw OperationImplementationQualificationError.invalidOperationSpecification(error)
        }

        do {
            try step.validateParameters()
        } catch let error as OperationParameterValidationError {
            throw OperationImplementationQualificationError.invalidOperationParameters(error)
        }

        let implementationCandidates = await implementations.implementations(
            for: step.specification
        )
        let applicableRequirements = policy.requirements.filter { declaration in
            switch declaration.origin.scope {
            case .pipeline:
                return true
            case let .step(identifier):
                return identifier == step.identifier
            }
        }

        var evaluations: [OperationImplementationCandidateEvaluation] = []

        for implementation in implementationCandidates {
            guard implementation.specification.supports(step) else {
                evaluations.append(
                    evaluation(
                        implementation,
                        target: nil,
                        rejections: [.implementationDoesNotSupportOperationStep],
                        uncertainties: []
                    )
                )
                continue
            }

            let providerSnapshots = matchingProviders(
                for: implementation.specification,
                requirements: applicableRequirements,
                in: environment
            )

            if providerSnapshots.isEmpty {
                let requiredProvider = implementation.specification.requiredProviderID
                    ?? requiredProvider(from: applicableRequirements)
                if let requiredProvider {
                    evaluations.append(
                        evaluation(
                            implementation,
                            target: nil,
                            rejections: [.requiredProviderNotDiscovered(requiredProvider)],
                            uncertainties: []
                        )
                    )
                } else {
                    evaluations.append(
                        evaluation(
                            implementation,
                            target: nil,
                            rejections: [.noExecutionProviderDiscovered],
                            uncertainties: []
                        )
                    )
                }
                continue
            }

            for provider in providerSnapshots {
                let targets = executionTargets(
                    for: provider,
                    failures: environment.failures
                )

                if targets.isEmpty {
                    evaluations.append(
                        evaluation(
                            implementation,
                            target: nil,
                            rejections: [],
                            uncertainties: [.providerDiscoveryIncomplete(provider.descriptor.identifier)]
                        )
                    )
                    continue
                }

                for target in targets {
                    var rejections: [CandidateQualificationRejection] = []
                    var uncertainties: [CandidateQualificationUncertainty] = []

                    evaluateProviderPolicy(
                        provider: provider,
                        requirements: applicableRequirements,
                        rejections: &rejections
                    )
                    evaluatePrecisionAndDeterminismPolicy(
                        implementation: implementation.specification,
                        requirements: applicableRequirements,
                        rejections: &rejections
                    )

                    evaluateSnapshotFreshness(
                        environment: environment,
                        provider: provider,
                        target: target,
                        freshness: freshness,
                        now: now,
                        uncertainties: &uncertainties
                    )

                    evaluateAvailability(
                        provider: provider,
                        target: target,
                        freshnessUncertain: !uncertainties.isEmpty,
                        rejections: &rejections,
                        uncertainties: &uncertainties
                    )

                    evaluateStaticCapabilities(
                        implementation: implementation.specification,
                        provider: provider,
                        target: target,
                        requirements: applicableRequirements,
                        rejections: &rejections
                    )

                    guard rejections.isEmpty, uncertainties.isEmpty else {
                        evaluations.append(
                            evaluation(
                                implementation,
                                target: target,
                                rejections: rejections,
                                uncertainties: uncertainties
                            )
                        )
                        continue
                    }

                    let context: any ExecutionContext
                    do {
                        context = try await providers.makeContext(
                            for: target,
                            expecting: provider.descriptor
                        )
                    } catch {
                        evaluations.append(
                            evaluation(
                                implementation,
                                target: target,
                                rejections: [.contextCreationFailed(String(describing: error))],
                                uncertainties: []
                            )
                        )
                        continue
                    }

                    guard context.target == target else {
                        evaluations.append(
                            evaluation(
                                implementation,
                                target: target,
                                rejections: [.contextTargetMismatch],
                                uncertainties: []
                            )
                        )
                        continue
                    }

                    evaluateContextClaims(
                        context,
                        rejections: &rejections
                    )
                    evaluateContextCapabilities(
                        implementation: implementation.specification,
                        context: context,
                        requirements: applicableRequirements,
                        rejections: &rejections
                    )

                    if rejections.isEmpty {
                        let qualified = QualifiedOperationImplementation(
                            implementation: implementation,
                            target: target,
                            context: context
                        )
                        evaluations.append(
                            OperationImplementationCandidateEvaluation(
                                implementation: implementation,
                                target: target,
                                disposition: .qualified,
                                rejections: [],
                                uncertainties: [],
                                qualifiedCandidate: qualified
                            )
                        )
                    } else {
                        evaluations.append(
                            evaluation(
                                implementation,
                                target: target,
                                rejections: rejections,
                                uncertainties: []
                            )
                        )
                    }
                }
            }
        }

        return OperationImplementationQualificationReport(
            operationStep: step.identifier,
            environmentSnapshot: environment.identifier,
            evaluations: evaluations
        )
    }

    private func matchingProviders(
        for specification: ImplementationSpecification,
        requirements: [QualificationRequirementDeclaration],
        in environment: RuntimeEnvironmentSnapshot
    ) -> [ExecutionProviderSnapshot] {
        environment.environment.providers.filter { provider in
            if let requiredProvider = specification.requiredProviderID,
               provider.descriptor.identifier != requiredProvider {
                return false
            }
            return providerAllowed(
                provider.descriptor.identifier,
                by: requirements
            )
        }
    }

    private func providerAllowed(
        _ providerID: ExecutionProviderID,
        by requirements: [QualificationRequirementDeclaration]
    ) -> Bool {
        for declaration in requirements {
            switch declaration.requirement {
            case let .provider(required):
                if providerID != required { return false }
            case let .allowedProviders(allowed):
                if !allowed.contains(providerID) { return false }
            default:
                break
            }
        }
        return true
    }

    private func requiredProvider(
        from requirements: [QualificationRequirementDeclaration]
    ) -> ExecutionProviderID? {
        for declaration in requirements {
            switch declaration.requirement {
            case let .provider(provider):
                return provider
            case let .allowedProviders(providers) where providers.count == 1:
                return providers.first
            default:
                continue
            }
        }
        return nil
    }

    private func executionTargets(
        for provider: ExecutionProviderSnapshot,
        failures: [ExecutionProviderFailure]
    ) -> [ExecutionTargetReference] {
        if !provider.devices.isEmpty {
            return provider.devices.map(\.target)
        }

        let discoveryFailed = failures.contains {
            $0.providerID == provider.descriptor.identifier
                && $0.target == nil
                && $0.kind == .deviceDiscoveryFailed
        }
        guard !discoveryFailed else { return [] }

        // A successfully discovered empty device list represents one opaque
        // provider-managed execution target, not a missing provider.
        return [ExecutionTargetReference(providerID: provider.descriptor.identifier)]
    }

    private func evaluateProviderPolicy(
        provider: ExecutionProviderSnapshot,
        requirements: [QualificationRequirementDeclaration],
        rejections: inout [CandidateQualificationRejection]
    ) {
        for declaration in requirements {
            switch declaration.requirement {
            case let .provider(required) where provider.descriptor.identifier != required:
                rejections.append(.providerNotAllowed(provider.descriptor.identifier))
            case let .allowedProviders(allowed) where !allowed.contains(provider.descriptor.identifier):
                rejections.append(.providerNotAllowed(provider.descriptor.identifier))
            default:
                break
            }
        }
    }

    private func evaluatePrecisionAndDeterminismPolicy(
        implementation: ImplementationSpecification,
        requirements: [QualificationRequirementDeclaration],
        rejections: inout [CandidateQualificationRejection]
    ) {
        for declaration in requirements {
            switch declaration.requirement {
            case let .precision(dimension, value):
                if !implementation.precisionSupport.values(for: dimension).contains(value) {
                    rejections.append(.precisionUnsupported(dimension, value))
                }
            case let .allowedPrecisions(dimension, allowed):
                if implementation.precisionSupport.values(for: dimension).isDisjoint(with: allowed) {
                    rejections.append(.allowedPrecisionUnsupported(dimension))
                }
            case .deterministicResults:
                if implementation.determinism != .deterministic {
                    rejections.append(.deterministicResultsUnsupported)
                }
            default:
                break
            }
        }
    }

    private func evaluateSnapshotFreshness(
        environment: RuntimeEnvironmentSnapshot,
        provider: ExecutionProviderSnapshot,
        target: ExecutionTargetReference,
        freshness: QualificationFreshnessPolicy,
        now: Date,
        uncertainties: inout [CandidateQualificationUncertainty]
    ) {
        if isStale(
            observedAt: environment.capturedAt,
            now: now,
            maximumAge: freshness.maximumSnapshotAge
        ) {
            uncertainties.append(.environmentSnapshotStale)
        }
        if isStale(
            observedAt: provider.state.capturedAt,
            now: now,
            maximumAge: freshness.maximumProviderStateAge
        ) {
            uncertainties.append(.providerStateStale(provider.descriptor.identifier))
        }
        if let deviceID = target.deviceID,
           let device = provider.devices.first(where: { $0.descriptor.identifier == deviceID }),
           isStale(
                observedAt: device.state.capturedAt,
                now: now,
                maximumAge: freshness.maximumDeviceStateAge
           ) {
            uncertainties.append(.deviceStateStale(target))
        }
    }

    private func isStale(
        observedAt: Date,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age < 0 || age > maximumAge
    }

    private func evaluateAvailability(
        provider: ExecutionProviderSnapshot,
        target: ExecutionTargetReference,
        freshnessUncertain: Bool,
        rejections: inout [CandidateQualificationRejection],
        uncertainties: inout [CandidateQualificationUncertainty]
    ) {
        guard !freshnessUncertain else { return }

        switch provider.state.availability {
        case .available:
            break
        case let .unavailable(reason):
            rejections.append(.providerUnavailable(provider.descriptor.identifier, reason))
        case let .unknown(reason):
            uncertainties.append(.providerStateUnknown(provider.descriptor.identifier, reason))
        }

        if let deviceID = target.deviceID,
           let device = provider.devices.first(where: { $0.descriptor.identifier == deviceID }) {
            switch device.state.availability {
            case .available:
                break
            case let .unavailable(reason):
                rejections.append(.deviceUnavailable(target, reason))
            case let .unknown(reason):
                uncertainties.append(.deviceStateUnknown(target, reason))
            }
        }
    }

    private func evaluateStaticCapabilities(
        implementation: ImplementationSpecification,
        provider: ExecutionProviderSnapshot,
        target: ExecutionTargetReference,
        requirements: [QualificationRequirementDeclaration],
        rejections: inout [CandidateQualificationRejection]
    ) {
        let deviceCapabilities = target.deviceID.flatMap { identifier in
            provider.devices.first { $0.descriptor.identifier == identifier }?.descriptor.capabilities
        }

        for constraint in implementation.requiredCapabilities {
            evaluateCapability(
                constraint,
                providerCapabilities: provider.descriptor.capabilities,
                deviceCapabilities: deviceCapabilities,
                context: nil,
                rejections: &rejections
            )
        }

        for declaration in requirements {
            guard case let .executionCapability(constraint) = declaration.requirement,
                  constraint.scope != .context else {
                continue
            }
            evaluateCapability(
                constraint,
                providerCapabilities: provider.descriptor.capabilities,
                deviceCapabilities: deviceCapabilities,
                context: nil,
                rejections: &rejections
            )
        }
    }

    private func evaluateCapability(
        _ constraint: ExecutionCapabilityConstraint,
        providerCapabilities: ExecutionCapabilities,
        deviceCapabilities: ExecutionCapabilities?,
        context: ExecutionCapabilities?,
        rejections: inout [CandidateQualificationRejection]
    ) {
        if constraint.isSatisfied(
            providerCapabilities: providerCapabilities,
            deviceCapabilities: deviceCapabilities,
            contextCapabilities: context
        ) {
            return
        }

        let identifier = capabilityIdentifier(constraint.requirement)
        switch constraint.scope {
        case .provider:
            rejections.append(.providerCapabilityMissing(identifier))
        case .device:
            rejections.append(.deviceCapabilityMissing(identifier))
        case .providerOrDevice:
            rejections.append(.providerCapabilityMissing(identifier))
        case .context:
            rejections.append(.contextCapabilityMissing(identifier))
        }
    }

    private func evaluateContextClaims(
        _ context: any ExecutionContext,
        rejections: inout [CandidateQualificationRejection]
    ) {
        let capabilities = context.capabilities
        validateCapabilityClaim(
            .resourceAllocation,
            protocolAvailable: context is any ExecutionResourceAllocatingContext,
            capabilities: capabilities,
            rejections: &rejections
        )
        validateCapabilityClaim(
            .resourceImport,
            protocolAvailable: context is any ExecutionResourceAllocatingContext,
            capabilities: capabilities,
            rejections: &rejections
        )
        validateCapabilityClaim(
            .workSubmission,
            protocolAvailable: context is any ExecutionWorkSubmittingContext,
            capabilities: capabilities,
            rejections: &rejections
        )
        validateCapabilityClaim(
            .workDependencies,
            protocolAvailable: context is any ExecutionWorkSubmittingContext,
            capabilities: capabilities,
            rejections: &rejections
        )
        validateCapabilityClaim(
            .contextSynchronization,
            protocolAvailable: context is any ExecutionSynchronizingContext,
            capabilities: capabilities,
            rejections: &rejections
        )
        validateCapabilityClaim(
            .resourceSynchronization,
            protocolAvailable: context is any ExecutionSynchronizingContext,
            capabilities: capabilities,
            rejections: &rejections
        )
    }

    private func validateCapabilityClaim(
        _ identifier: ExecutionCapabilityID,
        protocolAvailable: Bool,
        capabilities: ExecutionCapabilities,
        rejections: inout [CandidateQualificationRejection]
    ) {
        guard case .boolean(true)? = capabilities[identifier],
              !protocolAvailable else {
            return
        }
        rejections.append(.contextProtocolMismatch(identifier))
    }

    private func evaluateContextCapabilities(
        implementation: ImplementationSpecification,
        context: any ExecutionContext,
        requirements: [QualificationRequirementDeclaration],
        rejections: inout [CandidateQualificationRejection]
    ) {
        for constraint in implementation.requiredCapabilities where constraint.scope == .context {
            evaluateCapability(
                constraint,
                providerCapabilities: .init(),
                deviceCapabilities: nil,
                context: context.capabilities,
                rejections: &rejections
            )
        }

        for declaration in requirements {
            guard case let .executionCapability(constraint) = declaration.requirement,
                  constraint.scope == .context else {
                continue
            }
            evaluateCapability(
                constraint,
                providerCapabilities: .init(),
                deviceCapabilities: nil,
                context: context.capabilities,
                rejections: &rejections
            )
        }

        for resource in implementation.resourceRequirements {
            if case .temporary = resource.role {
                requireContextProtocol(
                    context,
                    role: resource.role,
                    capability: .resourceAllocation,
                    rejections: &rejections
                )
            }
            if resource.requiresImport {
                requireContextProtocol(
                    context,
                    role: resource.role,
                    capability: .resourceImport,
                    rejections: &rejections
                )
            }
        }
    }

    private func requireContextProtocol(
        _ context: any ExecutionContext,
        role: ImplementationResourceRole,
        capability: ExecutionCapabilityID,
        rejections: inout [CandidateQualificationRejection]
    ) {
        guard context is any ExecutionResourceAllocatingContext,
              case .boolean(true)? = context.capabilities[capability] else {
            rejections.append(.requiredResourceProtocolUnavailable(role, capability))
            return
        }
    }

    private func capabilityIdentifier(
        _ requirement: ExecutionCapabilityRequirement
    ) -> ExecutionCapabilityID {
        switch requirement {
        case let .exact(identifier, _),
             let .integerAtLeast(identifier, _),
             let .decimalAtLeast(identifier, _),
             let .stringSetContains(identifier, _):
            return identifier
        }
    }

    private func evaluation(
        _ implementation: RegisteredOperationImplementation,
        target: ExecutionTargetReference?,
        rejections: [CandidateQualificationRejection],
        uncertainties: [CandidateQualificationUncertainty]
    ) -> OperationImplementationCandidateEvaluation {
        let disposition: CandidateQualificationDisposition
        if !rejections.isEmpty {
            disposition = .rejected
        } else if !uncertainties.isEmpty {
            disposition = .indeterminate
        } else {
            disposition = .qualified
        }
        return OperationImplementationCandidateEvaluation(
            implementation: implementation,
            target: target,
            disposition: disposition,
            rejections: rejections,
            uncertainties: uncertainties
        )
    }
}
