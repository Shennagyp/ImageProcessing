import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol

public enum CandidateCostEstimateUnit: String, Hashable, Sendable {
    case nanoseconds
    case count
    case bytes
    case fraction
    case bytesPerElement
    case operationsPerElement
    case joules
    case operationsPerSecond
}

public enum CandidateCostEstimateValue: Hashable, Sendable {
    case integer(UInt64)
    case decimal(Double)
}

public enum CandidateCostEstimateEvidenceKind: String, Hashable, Sendable {
    case providerObservation
    case deviceObservation
    case implementationHint
    case resourceRequirement
    case resourceBinding
}

public struct CandidateCostEstimateEvidence: Hashable, Sendable {
    public let kind: CandidateCostEstimateEvidenceKind
    public let source: String?
    public let quality: ObservationQuality?
    public let observedAt: Date?
    public let validUntil: Date?
    public let detail: String?

    public init(
        kind: CandidateCostEstimateEvidenceKind,
        source: String? = nil,
        quality: ObservationQuality? = nil,
        observedAt: Date? = nil,
        validUntil: Date? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.quality = quality
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.detail = detail
    }
}

/// Stale values and unknown values remain explicit. Only .estimated values
/// participate in ranking; evidence provenance is retained without assigning
/// an implicit numeric confidence to reported, estimated, or inferred sources.
public enum CandidateCostEstimateState: Hashable, Sendable {
    case estimated(value: CandidateCostEstimateValue, evidence: [CandidateCostEstimateEvidence])
    case stale(value: CandidateCostEstimateValue, evidence: [CandidateCostEstimateEvidence])
    case unknown(reason: String)
}

public enum CandidateCostComponent: String, Hashable, Sendable, CaseIterable {
    case providerQueueDelay
    case deviceQueueDelay
    case providerQueueDepth
    case deviceQueueDepth
    case availableDeviceMemory
    case deviceUtilization
    case deviceLocalInputCapacityBytes
    case boundInputTransferTime
    case implementationFixedOverhead
    case operationsPerElement
    case temporaryBytesPerElement
    case minimumPlannedOutputCapacityBytes
    case minimumPlannedTemporaryCapacityBytes
    case minimumPlannedResourceCapacityBytes
    case transferTime
    case conversionTime
    case allocationTime
    case computeTime
    case synchronizationTime
    case outputMaterializationTime
    case energy
    case throughput

    public var unit: CandidateCostEstimateUnit {
        switch self {
        case .providerQueueDelay, .deviceQueueDelay, .boundInputTransferTime,
             .implementationFixedOverhead, .transferTime, .conversionTime,
             .allocationTime, .computeTime, .synchronizationTime,
             .outputMaterializationTime:
            .nanoseconds
        case .providerQueueDepth, .deviceQueueDepth:
            .count
        case .availableDeviceMemory, .deviceLocalInputCapacityBytes,
             .minimumPlannedOutputCapacityBytes, .minimumPlannedTemporaryCapacityBytes,
             .minimumPlannedResourceCapacityBytes:
            .bytes
        case .deviceUtilization:
            .fraction
        case .operationsPerElement:
            .operationsPerElement
        case .temporaryBytesPerElement:
            .bytesPerElement
        case .energy:
            .joules
        case .throughput:
            .operationsPerSecond
        }
    }
}

public struct CandidateCostComponentEstimate: Hashable, Sendable {
    public let component: CandidateCostComponent
    public let unit: CandidateCostEstimateUnit
    public let state: CandidateCostEstimateState

    public init(
        component: CandidateCostComponent,
        state: CandidateCostEstimateState
    ) {
        self.component = component
        self.unit = component.unit
        self.state = state
    }
}

public struct CandidateCostEstimate: Hashable, Sendable {
    public let components: [CandidateCostComponentEstimate]

    public func estimate(
        for component: CandidateCostComponent
    ) -> CandidateCostComponentEstimate? {
        components.first { $0.component == component }
    }

    init(components: [CandidateCostComponentEstimate]) {
        self.components = components.sorted {
            $0.component.rawValue < $1.component.rawValue
        }
    }
}

public struct CandidateResourceMemoryDomainOptions: Hashable, Sendable {
    public let role: ImplementationResourceRole
    /// Feasible domains for this resource role. Phase 5 exposes alternatives;
    /// it does not allocate or select a domain.
    public let domains: [ExecutionMemoryDomain]

    public init(
        role: ImplementationResourceRole,
        domains: [ExecutionMemoryDomain]
    ) {
        self.role = role
        self.domains = domains
    }
}

public enum CandidateInputResourceResidencyDisposition: String, Hashable, Sendable {
    /// Device-local with a descriptor target equal to the candidate target. This is
    /// not a provider-registration or native-interoperability guarantee.
    case deviceLocalOnTarget
    /// Owned by the candidate target, but not in device-local memory.
    case nonDeviceLocalOnTarget
    /// Owned by another provider or execution target.
    case foreignTarget
    /// The target matches, but the creating provider registration is unknown.
    case providerRegistrationUnknown
    /// The target matches, but another provider registration created the handle.
    case providerRegistrationMismatch
    /// Multiple handles reported different descriptors for one resource identity.
    case inconsistentDescriptor
}

public struct CandidateInputResourceResidency: Hashable, Sendable {
    public let resource: ExecutionResourceReference
    public let memoryDomain: ExecutionMemoryDomain
    public let capacityBytes: UInt64
    public let disposition: CandidateInputResourceResidencyDisposition
}

/// Evidence is limited to distinct handles exposed through this candidate's
/// declared input-resource accesses. It does not assert that every value in the
/// typed operation input is represented by a generic resource binding.
public struct CandidateInputResidencyEstimate: Hashable, Sendable {
    public let resources: [CandidateInputResourceResidency]
    /// Existing target-local device memory, not incremental invocation allocation.
    public let deviceLocalCapacityBytes: CandidateCostEstimateState
    /// Staging/import time for the declared resource handles only.
    public let boundInputTransferTime: CandidateCostEstimateState
}

public struct CandidatePreferenceRankingContribution: Hashable, Sendable {
    public let declaration: OptimizationPreferenceDeclaration
    /// Weighted win rate over candidate pairs for which this preference had
    /// comparable evidence. It is zero when no pair could be compared.
    public let weightedWinRate: Double
    public let comparablePairCount: Int
}

public struct CandidatePreferencePriorityScore: Hashable, Sendable {
    public let priority: Int
    /// Sum of the applicable declarations' weighted win-rate contributions.
    public let weightedScore: Double
}

public struct RankedOperationImplementationCandidate: Sendable {
    /// One-based position in the deterministic preference ordering.
    public let rank: Int
    public let candidate: QualifiedOperationImplementation
    public let costEstimate: CandidateCostEstimate
    public let inputResidency: CandidateInputResidencyEstimate
    public let resourceMemoryDomainOptions: [CandidateResourceMemoryDomainOptions]
    public let preferenceContributions: [CandidatePreferenceRankingContribution]
    public let priorityScores: [CandidatePreferencePriorityScore]
}

/// Ranking is deliberately separate from qualification and execution. This
/// report contains no selected candidate, resource reservation, or allocation.
public struct OperationImplementationResolutionReport: Sendable {
    public let qualification: OperationImplementationQualificationReport
    public let rankedCandidates: [RankedOperationImplementationCandidate]
}

enum OperationImplementationCandidateRanker {
    private enum PairOutcome {
        case left
        case right
        case tie
    }

    static func rank(
        _ candidates: [QualifiedOperationImplementation],
        stepIdentifier: OperationStepIdentifier,
        preferences: [OptimizationPreferenceDeclaration]
    ) -> [RankedOperationImplementationCandidate] {
        guard !candidates.isEmpty else { return [] }

        let applicablePreferences = preferences.filter { declaration in
            switch declaration.origin.scope {
            case .pipeline:
                true
            case let .step(identifier):
                identifier == stepIdentifier
            }
        }

        let inputResidencies = candidates.map { candidate in
            CandidateInputResidencyEstimator.estimate(
                resourceAccesses: candidate.inputResourceAccesses,
                on: candidate.target,
                providerRegistrationIdentifier: candidate.providerRegistrationIdentifier,
                source: candidate.implementation.specification.identifier.rawValue
            )
        }
        let estimates = candidates.indices.map { index in
            CandidateCostEstimator.estimate(
                candidates[index],
                inputResidency: inputResidencies[index]
            )
        }
        let domainOptions = candidates.map { memoryDomainOptions(for: $0) }
        var contributions = Array(
            repeating: [CandidatePreferenceRankingContribution](),
            count: candidates.count
        )
        var scores = Array(repeating: [Int: Double](), count: candidates.count)

        for declaration in applicablePreferences {
            var wins = Array(repeating: 0, count: candidates.count)
            var comparisons = Array(repeating: 0, count: candidates.count)

            for left in candidates.indices {
                for right in candidates.indices where right > left {
                    guard let outcome = compare(
                        candidates[left],
                        estimates[left],
                        candidates[right],
                        estimates[right],
                        objective: declaration.objective
                    ) else {
                        continue
                    }

                    comparisons[left] += 1
                    comparisons[right] += 1
                    switch outcome {
                    case .left:
                        wins[left] += 1
                    case .right:
                        wins[right] += 1
                    case .tie:
                        break
                    }
                }
            }

            let weight = declaration.weight ?? 1
            for index in candidates.indices {
                let contribution = comparisons[index] == 0
                    ? 0
                    : weight * Double(wins[index]) / Double(comparisons[index])
                let current = scores[index][declaration.priority] ?? 0
                let combined = current + contribution
                scores[index][declaration.priority] = combined.isFinite
                    ? combined
                    : Double.greatestFiniteMagnitude
                contributions[index].append(
                    CandidatePreferenceRankingContribution(
                        declaration: declaration,
                        weightedWinRate: contribution,
                        comparablePairCount: comparisons[index]
                    )
                )
            }
        }

        let priorities = Set(applicablePreferences.map(\.priority)).sorted(by: >)
        let orderedIndices = candidates.indices.sorted { left, right in
            for priority in priorities {
                let leftScore = scores[left][priority] ?? 0
                let rightScore = scores[right][priority] ?? 0
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
            }
            return stablePrecedes(candidates[left], candidates[right])
        }

        return orderedIndices.enumerated().map { offset, index in
            let priorityScores = priorities.map {
                CandidatePreferencePriorityScore(
                    priority: $0,
                    weightedScore: scores[index][$0] ?? 0
                )
            }
            return RankedOperationImplementationCandidate(
                rank: offset + 1,
                candidate: candidates[index],
                costEstimate: estimates[index],
                inputResidency: inputResidencies[index],
                resourceMemoryDomainOptions: domainOptions[index],
                preferenceContributions: contributions[index],
                priorityScores: priorityScores
            )
        }
    }

    private static func compare(
        _ left: QualifiedOperationImplementation,
        _ leftEstimate: CandidateCostEstimate,
        _ right: QualifiedOperationImplementation,
        _ rightEstimate: CandidateCostEstimate,
        objective: OptimizationObjective
    ) -> PairOutcome? {
        switch objective {
        case .lowLatency:
            return compareLatency(leftEstimate, rightEstimate)
        case .lowMemory:
            return comparePlannedResourceCapacity(leftEstimate, rightEstimate)
        case .deterministicResults:
            let leftIsDeterministic =
                left.implementation.specification.determinism == .deterministic
            let rightIsDeterministic =
                right.implementation.specification.determinism == .deterministic
            guard leftIsDeterministic != rightIsDeterministic else { return .tie }
            return leftIsDeterministic ? .left : .right
        case .lowEnergy, .highThroughput:
            // No calibrated energy or throughput model exists yet.
            return nil
        }
    }

    /// Latency is a multi-component comparison. A candidate wins only when it
    /// is no worse on every fresh shared component and better on at least one.
    /// Conflicting or unavailable components do not create a synthetic total.
    private static func compareLatency(
        _ left: CandidateCostEstimate,
        _ right: CandidateCostEstimate
    ) -> PairOutcome? {
        let components: [CandidateCostComponent] = [
            .providerQueueDelay,
            .deviceQueueDelay,
            .boundInputTransferTime,
            .implementationFixedOverhead
        ]
        var leftIsBetter = false
        var rightIsBetter = false
        var didCompareSharedEvidence = false

        for component in components {
            guard let leftValue = estimatedNumericValue(left, component),
                  let rightValue = estimatedNumericValue(right, component) else {
                continue
            }
            guard let ordering = compare(leftValue, rightValue) else {
                continue
            }
            didCompareSharedEvidence = true
            switch ordering {
            case .less:
                leftIsBetter = true
            case .greater:
                rightIsBetter = true
            case .equal:
                break
            }
        }

        if leftIsBetter && !rightIsBetter { return .left }
        if rightIsBetter && !leftIsBetter { return .right }
        if leftIsBetter && rightIsBetter { return nil }
        return didCompareSharedEvidence ? .tie : nil
    }

    private enum NumericOrdering {
        case less
        case equal
        case greater
    }

    private static func estimatedNumericValue(
        _ estimate: CandidateCostEstimate,
        _ component: CandidateCostComponent
    ) -> CandidateCostEstimateValue? {
        guard let componentEstimate = estimate.estimate(for: component),
              case let .estimated(value, _) = componentEstimate.state else {
            return nil
        }
        if case let .decimal(value) = value, !value.isFinite {
            return nil
        }
        return value
    }

    /// Comparisons preserve UInt64 precision. Different numeric representations
    /// are intentionally incomparable rather than coercing large byte/time
    /// counts through a lossy Double conversion.
    private static func compare(
        _ left: CandidateCostEstimateValue,
        _ right: CandidateCostEstimateValue
    ) -> NumericOrdering? {
        switch (left, right) {
        case let (.integer(lhs), .integer(rhs)):
            if lhs < rhs { return .less }
            if lhs > rhs { return .greater }
            return .equal
        case let (.decimal(lhs), .decimal(rhs)):
            guard lhs.isFinite, rhs.isFinite else { return nil }
            if lhs < rhs { return .less }
            if lhs > rhs { return .greater }
            return .equal
        default:
            return nil
        }
    }

    private static func comparePlannedResourceCapacity(
        _ left: CandidateCostEstimate,
        _ right: CandidateCostEstimate
    ) -> PairOutcome? {
        guard let leftValue = estimatedIntegerValue(
            left,
            .minimumPlannedResourceCapacityBytes
        ),
        let rightValue = estimatedIntegerValue(
            right,
            .minimumPlannedResourceCapacityBytes
        ) else {
            return nil
        }
        guard leftValue != rightValue else {
            return .tie
        }
        return leftValue < rightValue ? .left : .right
    }

    private static func estimatedIntegerValue(
        _ estimate: CandidateCostEstimate,
        _ component: CandidateCostComponent
    ) -> UInt64? {
        guard let componentEstimate = estimate.estimate(for: component),
              case let .estimated(value, _) = componentEstimate.state,
              case let .integer(integer) = value else {
            return nil
        }
        return integer
    }

    private static func memoryDomainOptions(
        for candidate: QualifiedOperationImplementation
    ) -> [CandidateResourceMemoryDomainOptions] {
        candidate.resourceAllocations
            .map { allocation in
                CandidateResourceMemoryDomainOptions(
                    role: allocation.role,
                    domains: allocation.allocatableMemoryDomains.sorted {
                        $0.rawValue < $1.rawValue
                    }
                )
            }
            .sorted {
                rolePrecedes($0.role, $1.role)
            }
    }

    private static func rolePrecedes(
        _ left: ImplementationResourceRole,
        _ right: ImplementationResourceRole
    ) -> Bool {
        switch (left, right) {
        case let (.input(leftIndex), .input(rightIndex)):
            return leftIndex < rightIndex
        case (.input(_), _):
            return true
        case (_, .input(_)):
            return false
        case let (.output(leftIndex), .output(rightIndex)):
            return leftIndex < rightIndex
        case (.output(_), .temporary(_)):
            return true
        case (.temporary(_), .output(_)):
            return false
        case let (.temporary(leftIdentifier), .temporary(rightIdentifier)):
            return leftIdentifier < rightIdentifier
        }
    }

    private static func stablePrecedes(
        _ left: QualifiedOperationImplementation,
        _ right: QualifiedOperationImplementation
    ) -> Bool {
        let leftSpecification = left.implementation.specification
        let rightSpecification = right.implementation.specification

        if leftSpecification.identifier.rawValue != rightSpecification.identifier.rawValue {
            return leftSpecification.identifier.rawValue < rightSpecification.identifier.rawValue
        }
        if leftSpecification.version != rightSpecification.version {
            return leftSpecification.version < rightSpecification.version
        }
        if left.target.providerID.rawValue != right.target.providerID.rawValue {
            return left.target.providerID.rawValue < right.target.providerID.rawValue
        }

        let leftDevice = left.target.deviceID?.rawValue
        let rightDevice = right.target.deviceID?.rawValue
        if leftDevice != rightDevice {
            switch (leftDevice, rightDevice) {
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case let (.some(leftValue), .some(rightValue)):
                return leftValue < rightValue
            case (nil, nil):
                break
            }
        }

        return left.implementation.registrationIdentifier.uuidString
            < right.implementation.registrationIdentifier.uuidString
    }
}

enum CandidateInputResidencyEstimator {
    static func estimate(
        resourceAccesses: [ExecutionResourceAccess],
        on candidateTarget: ExecutionTargetReference,
        providerRegistrationIdentifier: UUID,
        source: String
    ) -> CandidateInputResidencyEstimate {
        var descriptors: [ExecutionResourceReference: ExecutionResourceDescriptor] = [:]
        var inconsistentReferences = Set<ExecutionResourceReference>()

        for access in resourceAccesses {
            let descriptor = access.resource.descriptor
            let reference = descriptor.reference
            if let existing = descriptors[reference] {
                if existing != descriptor {
                    inconsistentReferences.insert(reference)
                }
            } else {
                descriptors[reference] = descriptor
            }
        }

        let resources = descriptors.keys.sorted(by: referencePrecedes).compactMap { reference in
            guard let descriptor = descriptors[reference] else { return nil }
            let disposition: CandidateInputResourceResidencyDisposition
            if inconsistentReferences.contains(reference) {
                disposition = .inconsistentDescriptor
            } else if descriptor.target != candidateTarget {
                disposition = .foreignTarget
            } else if descriptor.memoryDomain == .deviceLocal {
                guard let resourceRegistration = descriptor.providerRegistrationIdentifier else {
                    disposition = .providerRegistrationUnknown
                    return CandidateInputResourceResidency(
                        resource: reference,
                        memoryDomain: descriptor.memoryDomain,
                        capacityBytes: descriptor.capacityBytes,
                        disposition: disposition
                    )
                }
                disposition = resourceRegistration == providerRegistrationIdentifier
                    ? .deviceLocalOnTarget
                    : .providerRegistrationMismatch
            } else {
                disposition = .nonDeviceLocalOnTarget
            }
            return CandidateInputResourceResidency(
                resource: reference,
                memoryDomain: descriptor.memoryDomain,
                capacityBytes: descriptor.capacityBytes,
                disposition: disposition
            )
        }

        let capacityEvidence = CandidateCostEstimateEvidence(
            kind: .resourceBinding,
            source: source,
            detail: "Capacity of distinct declared input resource bindings attributed to this provider registration. This is already allocated storage, not an incremental allocation request or a physical-capacity reservation."
        )

        let deviceLocalCapacity: CandidateCostEstimateState
        if resources.isEmpty {
            deviceLocalCapacity = .unknown(
                reason: "No declared input-resource access bindings are available; current residency cannot be inferred."
            )
        } else if !inconsistentReferences.isEmpty {
            deviceLocalCapacity = .unknown(
                reason: "Conflicting descriptors exist for an input resource identity; resident capacity cannot be aggregated."
            )
        } else if resources.contains(where: { $0.disposition == .providerRegistrationUnknown }) {
            deviceLocalCapacity = .unknown(
                reason: "At least one device-local input resource has no provider registration provenance; its residency for this candidate cannot be established."
            )
        } else {
            var total: UInt64 = 0
            var overflowed = false
            for resource in resources where resource.disposition == .deviceLocalOnTarget {
                let (next, overflow) = total.addingReportingOverflow(resource.capacityBytes)
                if overflow {
                    overflowed = true
                    break
                }
                total = next
            }
            deviceLocalCapacity = overflowed
                ? .unknown(reason: "Summing device-local input resource capacities overflowed UInt64.")
                : .estimated(value: .integer(total), evidence: [capacityEvidence])
        }

        let boundInputTransferTime: CandidateCostEstimateState
        if resources.isEmpty {
            boundInputTransferTime = .unknown(
                reason: "No declared input-resource access bindings are available; absence of bindings is not evidence of zero transfer."
            )
        } else if resources.allSatisfy({ $0.disposition == .deviceLocalOnTarget }) {
            boundInputTransferTime = .estimated(
                value: .integer(0),
                evidence: [
                    CandidateCostEstimateEvidence(
                        kind: .resourceBinding,
                        source: source,
                        detail: "Every distinct declared input resource handle reports deviceLocal memory, the exact candidate target, and the same provider registration identifier as the candidate. This provenance fact excludes unrepresented inputs and does not validate device-loss validity, external eviction, synchronization, or total execution latency."
                    )
                ]
            )
        } else if resources.contains(where: { $0.disposition == .inconsistentDescriptor }) {
            boundInputTransferTime = .unknown(
                reason: "Conflicting descriptors exist for an input resource identity; zero transfer cannot be established."
            )
        } else if resources.contains(where: { $0.disposition == .foreignTarget }) {
            boundInputTransferTime = .unknown(
                reason: "At least one input resource belongs to another execution target; import, remapping, and transfer cost are not modeled."
            )
        } else if resources.contains(where: { $0.disposition == .providerRegistrationMismatch }) {
            boundInputTransferTime = .unknown(
                reason: "At least one device-local input resource was created by another provider registration that reused the same target identity; import/remapping is not modeled."
            )
        } else if resources.contains(where: { $0.disposition == .providerRegistrationUnknown }) {
            boundInputTransferTime = .unknown(
                reason: "At least one device-local input resource has no provider registration provenance; target equality alone cannot establish residency in this provider instance."
            )
        } else {
            boundInputTransferTime = .unknown(
                reason: "At least one input resource is not device-local; host/shared/managed/external staging or migration cost is not modeled."
            )
        }

        return CandidateInputResidencyEstimate(
            resources: resources,
            deviceLocalCapacityBytes: deviceLocalCapacity,
            boundInputTransferTime: boundInputTransferTime
        )
    }

    private static func referencePrecedes(
        _ left: ExecutionResourceReference,
        _ right: ExecutionResourceReference
    ) -> Bool {
        if left.target.providerID.rawValue != right.target.providerID.rawValue {
            return left.target.providerID.rawValue < right.target.providerID.rawValue
        }
        let leftDevice = left.target.deviceID?.rawValue ?? ""
        let rightDevice = right.target.deviceID?.rawValue ?? ""
        if leftDevice != rightDevice { return leftDevice < rightDevice }
        if left.identifier.rawValue != right.identifier.rawValue {
            return left.identifier.rawValue < right.identifier.rawValue
        }
        let leftRegistration = left.providerRegistrationIdentifier?.uuidString ?? ""
        let rightRegistration = right.providerRegistrationIdentifier?.uuidString ?? ""
        return leftRegistration < rightRegistration
    }
}

enum CandidateCostEstimator {
    static func estimate(
        _ candidate: QualifiedOperationImplementation,
        inputResidency: CandidateInputResidencyEstimate
    ) -> CandidateCostEstimate {
        let observation = candidate.environmentObservations
        let implementation = candidate.implementation.specification
        let hint = implementation.performanceHints
        let hintSource = implementation.identifier.rawValue

        var components: [CandidateCostComponentEstimate] = [
            .init(
                component: .providerQueueDelay,
                state: observationEstimate(
                    observation.providerState.estimatedQueueDelayNanoseconds,
                    assessedAt: observation.assessedAt,
                    kind: .providerObservation,
                    map: { .integer($0) }
                )
            ),
            .init(
                component: .providerQueueDepth,
                state: observationEstimate(
                    observation.providerState.queueDepth,
                    assessedAt: observation.assessedAt,
                    kind: .providerObservation,
                    map: { .integer($0) }
                )
            ),
            .init(
                component: .deviceLocalInputCapacityBytes,
                state: inputResidency.deviceLocalCapacityBytes
            ),
            .init(
                component: .boundInputTransferTime,
                state: inputResidency.boundInputTransferTime
            ),
            .init(
                component: .implementationFixedOverhead,
                state: hintEstimate(
                    hint?.fixedOverheadNanoseconds,
                    name: "fixed submission/setup overhead",
                    source: hintSource
                )
            ),
            .init(
                component: .operationsPerElement,
                state: hintEstimate(
                    hint?.operationsPerElement,
                    name: "operations per processed element",
                    source: hintSource
                )
            ),
            .init(
                component: .temporaryBytesPerElement,
                state: hintEstimate(
                    hint?.temporaryBytesPerElement,
                    name: "temporary bytes per processed element",
                    source: hintSource
                )
            ),
            .init(
                component: .minimumPlannedOutputCapacityBytes,
                state: minimumPlannedResourceCapacityEstimate(
                    candidate,
                    matching: { role in
                        if case .output(_) = role { return true }
                        return false
                    },
                    description: "output"
                )
            ),
            .init(
                component: .minimumPlannedTemporaryCapacityBytes,
                state: minimumPlannedResourceCapacityEstimate(
                    candidate,
                    matching: { role in
                        if case .temporary(_) = role { return true }
                        return false
                    },
                    description: "temporary"
                )
            ),
            .init(
                component: .minimumPlannedResourceCapacityBytes,
                state: minimumPlannedResourceCapacityEstimate(
                    candidate,
                    matching: { _ in true },
                    description: "output and temporary"
                )
            )
        ]

        if let deviceState = observation.deviceState {
            components.append(contentsOf: [
                .init(
                    component: .deviceQueueDelay,
                    state: observationEstimate(
                        deviceState.estimatedQueueDelayNanoseconds,
                        assessedAt: observation.assessedAt,
                        kind: .deviceObservation,
                        map: { .integer($0) }
                    )
                ),
                .init(
                    component: .deviceQueueDepth,
                    state: observationEstimate(
                        deviceState.queueDepth,
                        assessedAt: observation.assessedAt,
                        kind: .deviceObservation,
                        map: { .integer($0) }
                    )
                ),
                .init(
                    component: .availableDeviceMemory,
                    state: observationEstimate(
                        deviceState.availableMemoryBytes,
                        assessedAt: observation.assessedAt,
                        kind: .deviceObservation,
                        map: { .integer($0) }
                    )
                ),
                .init(
                    component: .deviceUtilization,
                    state: observationEstimate(
                        deviceState.utilizationFraction,
                        assessedAt: observation.assessedAt,
                        kind: .deviceObservation,
                        map: { .decimal($0.value) }
                    )
                )
            ])
        } else {
            components.append(contentsOf: [
                .init(component: .deviceQueueDelay, state: .unknown(reason: "No device-scoped observation exists for this provider-managed target.")),
                .init(component: .deviceQueueDepth, state: .unknown(reason: "No device-scoped observation exists for this provider-managed target.")),
                .init(component: .availableDeviceMemory, state: .unknown(reason: "No device-scoped observation exists for this provider-managed target.")),
                .init(component: .deviceUtilization, state: .unknown(reason: "No device-scoped observation exists for this provider-managed target."))
            ])
        }

        let unmodeledComponents: [(CandidateCostComponent, String)] = [
            (.transferTime, "No calibrated transfer route/bandwidth estimate is available."),
            (.conversionTime, "No declared or measured conversion-cost model is available."),
            (.allocationTime, "Resource allocation latency is not observed or calibrated."),
            (.computeTime, "No comparable device throughput model is available for this operation workload."),
            (.synchronizationTime, "Synchronization cost is not exposed by the current context contract."),
            (.outputMaterializationTime, "Output materialization cost is not exposed by the current result contract."),
            (.energy, "No calibrated energy model is available."),
            (.throughput, "No calibrated throughput model is available.")
        ]
        components.append(contentsOf: unmodeledComponents.map {
            CandidateCostComponentEstimate(
                component: $0.0,
                state: .unknown(reason: $0.1)
            )
        })

        return CandidateCostEstimate(components: components)
    }

    private static func observationEstimate<Value: Sendable>(
        _ observation: ExecutionObservation<Value>,
        assessedAt: Date,
        kind: CandidateCostEstimateEvidenceKind,
        map: (Value) -> CandidateCostEstimateValue
    ) -> CandidateCostEstimateState {
        let evidence = CandidateCostEstimateEvidence(
            kind: kind,
            source: observation.source,
            quality: observation.quality,
            observedAt: observation.observedAt,
            validUntil: observation.validUntil
        )
        switch observation.state(at: assessedAt) {
        case let .known(value):
            return .estimated(value: map(value), evidence: [evidence])
        case let .stale(value):
            return .stale(value: map(value), evidence: [evidence])
        case let .unknown(reason):
            return .unknown(reason: reason)
        }
    }

    private static func hintEstimate(
        _ value: Double?,
        name: String,
        source: String
    ) -> CandidateCostEstimateState {
        guard let value else {
            return .unknown(reason: "No \(name) hint is declared.")
        }
        return .estimated(
            value: .decimal(value),
            evidence: [
                CandidateCostEstimateEvidence(
                    kind: .implementationHint,
                    source: source,
                    detail: name
                )
            ]
        )
    }

    private static func minimumPlannedResourceCapacityEstimate(
        _ candidate: QualifiedOperationImplementation,
        matching predicate: (ImplementationResourceRole) -> Bool,
        description: String
    ) -> CandidateCostEstimateState {
        guard !candidate.resourceAllocations.isEmpty else {
            return .unknown(reason: "The invocation has no declared output/temporary allocation slots.")
        }

        var total: UInt64 = 0
        for allocation in candidate.resourceAllocations where predicate(allocation.role) {
            let (next, overflow) = total.addingReportingOverflow(allocation.minimumCapacityBytes)
            guard !overflow else {
                return .unknown(reason: "Summing the minimum planned \(description) resource capacities overflowed UInt64.")
            }
            total = next
        }

        return .estimated(
            value: .integer(total),
            evidence: [
                CandidateCostEstimateEvidence(
                    kind: .resourceRequirement,
                    source: candidate.implementation.specification.identifier.rawValue,
                    detail: "Sum of declared per-invocation minimum \(description) resource capacities. This is a planned-capacity lower bound, not physical allocation size or measured peak memory."
                )
            ]
        )
    }
}
