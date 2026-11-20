import Foundation
import GeneralExecutionProtocol

public enum PrecisionDimension: String, Hashable, Sendable {
    case inputStorage
    case computation
    case accumulation
    case output
}

public enum QualificationPolicyScope: Hashable, Sendable {
    case pipeline
    case step(OperationStepIdentifier)
}

public enum QualificationRequirement: Hashable, Sendable {
    case provider(ExecutionProviderID)
    case allowedProviders(Set<ExecutionProviderID>)
    case executionCapability(ExecutionCapabilityConstraint)
    case precision(PrecisionDimension, PixelComponentType)
    case allowedPrecisions(PrecisionDimension, Set<PixelComponentType>)
    case deterministicResults
}

public enum OptimizationObjective: String, Hashable, Sendable {
    case lowLatency
    case lowMemory
    case lowEnergy
    case highThroughput
    case deterministicResults
}

public struct PolicyDeclarationOrigin: Hashable, Sendable {
    public let identifier: UUID
    public let scope: QualificationPolicyScope
    public let source: String?

    public init(
        identifier: UUID = UUID(),
        scope: QualificationPolicyScope,
        source: String? = nil
    ) {
        self.identifier = identifier
        self.scope = scope
        self.source = source
    }

    fileprivate func replacingScope(_ scope: QualificationPolicyScope) -> Self {
        Self(identifier: identifier, scope: scope, source: source)
    }
}

public struct QualificationRequirementDeclaration: Hashable, Sendable {
    public let requirement: QualificationRequirement
    public let origin: PolicyDeclarationOrigin

    public init(requirement: QualificationRequirement, origin: PolicyDeclarationOrigin) {
        self.requirement = requirement
        self.origin = origin
    }
}

public struct OptimizationPreferenceDeclaration: Hashable, Sendable {
    public let objective: OptimizationObjective
    public let priority: Int
    public let weight: Double?
    public let origin: PolicyDeclarationOrigin

    public init(
        objective: OptimizationObjective,
        priority: Int,
        weight: Double?,
        origin: PolicyDeclarationOrigin
    ) {
        self.objective = objective
        self.priority = priority
        self.weight = weight
        self.origin = origin
    }
}

public enum QualificationPolicyConflictDimension: Hashable, Sendable {
    case provider
    case precision(PrecisionDimension)
    case executionCapability(ExecutionCapabilityID, ExecutionCapabilityScope)
    case objective(OptimizationObjective)
}

public struct QualificationPolicyConflict: Error, Hashable, Sendable {
    public let dimension: QualificationPolicyConflictDimension
    /// All declarations contributing to the previously accumulated constraint.
    public let priorDeclarations: [PolicyDeclarationOrigin]
    /// The declaration that made the accumulated intersection impossible.
    public let incomingDeclaration: PolicyDeclarationOrigin
}

public enum QualificationPolicyValidationError: Error, Hashable, Sendable {
    case emptyProviderSet(PolicyDeclarationOrigin)
    case emptyPrecisionSet(PrecisionDimension, PolicyDeclarationOrigin)
    case invalidPreferenceWeight(PolicyDeclarationOrigin)
    case unknownStep(OperationStepIdentifier, PolicyDeclarationOrigin)
    case inapplicableDimension(OperationStepIdentifier, OperationQualificationDimension, PolicyDeclarationOrigin)
    case noApplicableStep(OperationQualificationDimension, PolicyDeclarationOrigin)
}

/// Immutable declarative policy. Requirements filter candidates; preferences
/// rank only the candidates that satisfy every applicable requirement.
public struct QualificationPolicy: Hashable, Sendable {
    public let requirements: [QualificationRequirementDeclaration]
    public let preferences: [OptimizationPreferenceDeclaration]

    public static let unrestricted = Self(requirements: [], preferences: [])

    fileprivate init(
        requirements: [QualificationRequirementDeclaration],
        preferences: [OptimizationPreferenceDeclaration]
    ) {
        self.requirements = requirements
        self.preferences = preferences
    }

    func combined(
        with other: Self,
        for steps: [AnyImageOperationStep]
    ) throws -> Self {
        let policy = Self(
            requirements: requirements + other.requirements,
            preferences: preferences + other.preferences
        )
        try policy.validate(for: steps)
        return policy
    }

    func reidentified(
        stepIdentifiers: [OperationStepIdentifier: OperationStepIdentifier]
    ) throws -> Self {
        func rebase(_ origin: PolicyDeclarationOrigin) throws -> PolicyDeclarationOrigin {
            guard case let .step(identifier) = origin.scope else { return origin }
            guard let replacement = stepIdentifiers[identifier] else {
                throw QualificationPolicyValidationError.unknownStep(identifier, origin)
            }
            return origin.replacingScope(.step(replacement))
        }

        let rebasedRequirements = try requirements.map {
            QualificationRequirementDeclaration(
                requirement: $0.requirement,
                origin: try rebase($0.origin)
            )
        }
        let rebasedPreferences = try preferences.map {
            OptimizationPreferenceDeclaration(
                objective: $0.objective,
                priority: $0.priority,
                weight: $0.weight,
                origin: try rebase($0.origin)
            )
        }
        return Self(requirements: rebasedRequirements, preferences: rebasedPreferences)
    }

    func validate(for steps: [AnyImageOperationStep]) throws {
        let stepsByID = Dictionary(uniqueKeysWithValues: steps.map { ($0.identifier, $0) })

        for declaration in requirements {
            switch declaration.requirement {
            case let .allowedProviders(values) where values.isEmpty:
                throw QualificationPolicyValidationError.emptyProviderSet(declaration.origin)
            case let .allowedPrecisions(dimension, values) where values.isEmpty:
                throw QualificationPolicyValidationError.emptyPrecisionSet(dimension, declaration.origin)
            default:
                break
            }

            switch declaration.origin.scope {
            case .pipeline:
                break
            case let .step(identifier):
                guard stepsByID[identifier] != nil else {
                    throw QualificationPolicyValidationError.unknownStep(identifier, declaration.origin)
                }
            }

            switch declaration.requirement {
            case .precision(_, _), .allowedPrecisions(_, _):
                try validatePrecisionApplicability(
                    declaration.origin,
                    stepsByID: stepsByID,
                    steps: steps
                )
            default:
                break
            }
        }

        for declaration in preferences {
            if let weight = declaration.weight,
               (!weight.isFinite || weight <= 0) {
                throw QualificationPolicyValidationError.invalidPreferenceWeight(declaration.origin)
            }
            if case let .step(identifier) = declaration.origin.scope,
               stepsByID[identifier] == nil {
                throw QualificationPolicyValidationError.unknownStep(identifier, declaration.origin)
            }
        }

        try validateAllowedSetIntersections(for: steps)

        for index in requirements.indices {
            for otherIndex in requirements.indices where otherIndex > index {
                let first = requirements[index]
                let second = requirements[otherIndex]
                guard scopesOverlap(first.origin.scope, second.origin.scope) else { continue }
                if let dimension = conflictDimension(first.requirement, second.requirement) {
                    throw QualificationPolicyConflict(
                        dimension: dimension,
                        priorDeclarations: [first.origin],
                        incomingDeclaration: second.origin
                    )
                }
            }
        }

        for index in preferences.indices {
            for otherIndex in preferences.indices where otherIndex > index {
                let first = preferences[index]
                let second = preferences[otherIndex]
                guard first.origin.scope == second.origin.scope,
                      first.objective == second.objective,
                      first.priority != second.priority || first.weight != second.weight else {
                    continue
                }
                throw QualificationPolicyConflict(
                    dimension: .objective(first.objective),
                    priorDeclarations: [first.origin],
                    incomingDeclaration: second.origin
                )
            }
        }
    }

    private func validateAllowedSetIntersections(
        for steps: [AnyImageOperationStep]
    ) throws {
        // A pipeline declaration applies to the complete function. Step
        // declarations refine that pipeline constraint only for their target
        // occurrence. Evaluate each effective scope so three-way empty
        // intersections are detected, not just pairwise contradictions.
        let effectiveScopes: [QualificationPolicyScope] =
            [.pipeline] + steps.map { .step($0.identifier) }

        for effectiveScope in effectiveScopes {
            let applicable = requirements.filter { declaration in
                declaration.origin.scope == .pipeline
                    || declaration.origin.scope == effectiveScope
            }

            try validateIntersection(
                applicable,
                dimension: .provider,
                values: { allowedProviders($0) }
            )

            let precisionDimensions = Set(applicable.compactMap { declaration -> PrecisionDimension? in
                switch declaration.requirement {
                case let .precision(dimension, _),
                     let .allowedPrecisions(dimension, _):
                    dimension
                default:
                    nil
                }
            })
            for dimension in precisionDimensions {
                try validateIntersection(
                    applicable,
                    dimension: .precision(dimension),
                    values: { requirement in
                        guard let allowed = allowedPrecision(requirement),
                              allowed.dimension == dimension else {
                            return nil
                        }
                        return allowed.values
                    }
                )
            }
        }
    }

    private func validateIntersection<Value: Hashable>(
        _ declarations: [QualificationRequirementDeclaration],
        dimension: QualificationPolicyConflictDimension,
        values: (QualificationRequirement) -> Set<Value>?
    ) throws {
        var intersection: Set<Value>?
        var contributors: [PolicyDeclarationOrigin] = []

        for declaration in declarations {
            guard let nextValues = values(declaration.requirement) else { continue }
            guard let current = intersection else {
                intersection = nextValues
                contributors = [declaration.origin]
                continue
            }

            let narrowed = current.intersection(nextValues)
            guard !narrowed.isEmpty else {
                throw QualificationPolicyConflict(
                    dimension: dimension,
                    priorDeclarations: contributors,
                    incomingDeclaration: declaration.origin
                )
            }
            intersection = narrowed
            contributors.append(declaration.origin)
        }
    }

    private func validatePrecisionApplicability(
        _ origin: PolicyDeclarationOrigin,
        stepsByID: [OperationStepIdentifier: AnyImageOperationStep],
        steps: [AnyImageOperationStep]
    ) throws {
        switch origin.scope {
        case .pipeline:
            guard steps.contains(where: {
                $0.specification.qualificationDimensions.contains(.precision)
            }) else {
                throw QualificationPolicyValidationError.noApplicableStep(.precision, origin)
            }
        case let .step(identifier):
            guard let step = stepsByID[identifier] else {
                throw QualificationPolicyValidationError.unknownStep(identifier, origin)
            }
            guard step.specification.qualificationDimensions.contains(.precision) else {
                throw QualificationPolicyValidationError.inapplicableDimension(
                    identifier,
                    .precision,
                    origin
                )
            }
        }
    }

    private func scopesOverlap(
        _ lhs: QualificationPolicyScope,
        _ rhs: QualificationPolicyScope
    ) -> Bool {
        switch (lhs, rhs) {
        case (.pipeline, _), (_, .pipeline):
            true
        case let (.step(a), .step(b)):
            a == b
        }
    }

    private func conflictDimension(
        _ lhs: QualificationRequirement,
        _ rhs: QualificationRequirement
    ) -> QualificationPolicyConflictDimension? {
        if case let .executionCapability(a) = lhs,
           case let .executionCapability(b) = rhs,
           a.scope == b.scope,
           capabilityIdentifier(a.requirement) == capabilityIdentifier(b.requirement),
           capabilityRequirementsConflict(a.requirement, b.requirement),
           let identifier = capabilityIdentifier(a.requirement) {
            return .executionCapability(identifier, a.scope)
        }

        return nil
    }

    private func allowedProviders(_ requirement: QualificationRequirement) -> Set<ExecutionProviderID>? {
        switch requirement {
        case let .provider(provider): return [provider]
        case let .allowedProviders(values): return values
        default: return nil
        }
    }

    private func allowedPrecision(
        _ requirement: QualificationRequirement
    ) -> (dimension: PrecisionDimension, values: Set<PixelComponentType>)? {
        switch requirement {
        case let .precision(dimension, value): return (dimension, [value])
        case let .allowedPrecisions(dimension, values): return (dimension, values)
        default: return nil
        }
    }

    private func capabilityIdentifier(
        _ requirement: ExecutionCapabilityRequirement
    ) -> ExecutionCapabilityID {
        switch requirement {
        case let .exact(id, _),
             let .integerAtLeast(id, _),
             let .decimalAtLeast(id, _),
             let .stringSetContains(id, _):
            return id
        }
    }

    private enum CapabilityValueKind: Equatable {
        case boolean
        case integer
        case decimal
        case string
        case stringSet
    }

    private func capabilityValueKind(
        _ requirement: ExecutionCapabilityRequirement
    ) -> CapabilityValueKind {
        switch requirement {
        case let .exact(_, value):
            switch value {
            case .boolean: return .boolean
            case .integer: return .integer
            case .decimal: return .decimal
            case .string: return .string
            case .stringSet: return .stringSet
            }
        case .integerAtLeast: return .integer
        case .decimalAtLeast: return .decimal
        case .stringSetContains: return .stringSet
        }
    }

    private func capabilityRequirementsConflict(
        _ lhs: ExecutionCapabilityRequirement,
        _ rhs: ExecutionCapabilityRequirement
    ) -> Bool {
        guard capabilityValueKind(lhs) == capabilityValueKind(rhs) else {
            return true
        }

        switch (lhs, rhs) {
        case let (.exact(_, left), .exact(_, right)):
            return left != right
        case let (.exact(_, .integer(value)), .integerAtLeast(_, minimum)),
             let (.integerAtLeast(_, minimum), .exact(_, .integer(value))):
            return value < minimum
        case let (.exact(_, .decimal(value)), .decimalAtLeast(_, minimum)),
             let (.decimalAtLeast(_, minimum), .exact(_, .decimal(value))):
            return !value.isFinite || value < minimum
        case let (.exact(_, .stringSet(values)), .stringSetContains(_, expected)),
             let (.stringSetContains(_, expected), .exact(_, .stringSet(values))):
            return !values.contains(expected)
        default:
            return false
        }
    }
}

/// Mutable construction helper. Build validates scopes, precision applicability,
/// empty intersections, and contradictory declarations before attachment.
public struct QualificationPolicyBuilder {
    private let defaultScope: QualificationPolicyScope
    private var requirements: [QualificationRequirementDeclaration] = []
    private var preferences: [OptimizationPreferenceDeclaration] = []

    public init() {
        self.defaultScope = .pipeline
    }

    private init(defaultScope: QualificationPolicyScope) {
        self.defaultScope = defaultScope
    }

    public mutating func require(
        _ requirement: QualificationRequirement,
        source: String? = nil
    ) {
        let origin = PolicyDeclarationOrigin(scope: defaultScope, source: source)
        requirements.append(.init(requirement: requirement, origin: origin))
    }

    public mutating func prefer(
        _ objective: OptimizationObjective,
        priority: Int = 0,
        weight: Double? = nil,
        source: String? = nil
    ) {
        let origin = PolicyDeclarationOrigin(scope: defaultScope, source: source)
        preferences.append(.init(
            objective: objective,
            priority: priority,
            weight: weight,
            origin: origin
        ))
    }

    public mutating func forStep(
        _ identifier: OperationStepIdentifier,
        _ configure: (inout QualificationPolicyBuilder) -> Void
    ) {
        var nested = QualificationPolicyBuilder(defaultScope: .step(identifier))
        configure(&nested)
        requirements.append(contentsOf: nested.requirements)
        preferences.append(contentsOf: nested.preferences)
    }

    func build(for steps: [AnyImageOperationStep]) throws -> QualificationPolicy {
        let policy = QualificationPolicy(requirements: requirements, preferences: preferences)
        try policy.validate(for: steps)
        return policy
    }
}
