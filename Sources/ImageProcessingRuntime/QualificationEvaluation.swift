import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol

public struct QualificationFreshnessPolicy: Hashable, Sendable {
    public let maximumSnapshotAge: TimeInterval
    public let maximumProviderStateAge: TimeInterval
    public let maximumDeviceStateAge: TimeInterval

    public init?(
        maximumSnapshotAge: TimeInterval,
        maximumProviderStateAge: TimeInterval,
        maximumDeviceStateAge: TimeInterval
    ) {
        guard maximumSnapshotAge.isFinite, maximumSnapshotAge >= 0,
              maximumProviderStateAge.isFinite, maximumProviderStateAge >= 0,
              maximumDeviceStateAge.isFinite, maximumDeviceStateAge >= 0 else {
            return nil
        }
        self.maximumSnapshotAge = maximumSnapshotAge
        self.maximumProviderStateAge = maximumProviderStateAge
        self.maximumDeviceStateAge = maximumDeviceStateAge
    }
}

/// Immutable provider/device telemetry captured by the exact environment snapshot
/// used to qualify a candidate. Optional metrics are assessed independently at
/// the resolver's evaluation time; they are evidence for later ranking, not
/// additional hard eligibility requirements.
public struct CandidateEnvironmentObservations: Sendable {
    public let environmentSnapshotIdentifier: RuntimeEnvironmentSnapshotIdentifier
    public let providerState: ExecutionProviderStateSnapshot
    public let deviceState: ExecutionDeviceStateSnapshot?
    public let assessedAt: Date

    public init(
        environmentSnapshotIdentifier: RuntimeEnvironmentSnapshotIdentifier,
        providerState: ExecutionProviderStateSnapshot,
        deviceState: ExecutionDeviceStateSnapshot?,
        assessedAt: Date
    ) {
        self.environmentSnapshotIdentifier = environmentSnapshotIdentifier
        self.providerState = providerState
        self.deviceState = deviceState
        self.assessedAt = assessedAt
    }

    public var providerQueueDepthState: ExecutionObservationState<UInt64> {
        providerState.queueDepth.state(at: assessedAt)
    }

    public var providerQueueDelayState: ExecutionObservationState<UInt64> {
        providerState.estimatedQueueDelayNanoseconds.state(at: assessedAt)
    }

    public var deviceAvailableMemoryState: ExecutionObservationState<UInt64>? {
        deviceState?.availableMemoryBytes.state(at: assessedAt)
    }

    public var deviceQueueDepthState: ExecutionObservationState<UInt64>? {
        deviceState?.queueDepth.state(at: assessedAt)
    }

    public var deviceQueueDelayState: ExecutionObservationState<UInt64>? {
        deviceState?.estimatedQueueDelayNanoseconds.state(at: assessedAt)
    }

    public var deviceUtilizationState: ExecutionObservationState<ExecutionFraction>? {
        deviceState?.utilizationFraction.state(at: assessedAt)
    }
}

public enum CandidateQualificationDisposition: String, Hashable, Sendable {
    case qualified
    case rejected
    case indeterminate
}

public enum CandidateQualificationRejection: Hashable, Sendable {
    case implementationDoesNotSupportOperationStep
    case implementationRegistrationUnavailable
    case implementationRegistrationChanged
    case providerRegistrationChanged(ExecutionProviderID)
    case operationConcreteTypeMismatch
    case inputConcreteTypeMismatch
    case imageInputLayerKindUnsupported(Int, LayerReference, LayerKind)
    case implementationInputLayerKindUnsupported(Int, LayerReference, LayerKind)
    case inputPixelDescriptorMissing(Int, LayerReference)
    case operationInputPixelRepresentationUnsupported(Int, LayerReference)
    case implementationInputPixelRepresentationUnsupported(Int, LayerReference)
    case operationInputStoragePrecisionUnsupported(Int, LayerReference, PixelComponentType)
    case implementationInputStoragePrecisionUnsupported(Int, LayerReference, PixelComponentType)
    case inputBindingMissing(Int)
    case inputResourceBindingMissing(Int, LayerReference)
    case inputResourceContextMissing(Int)
    case inputResourceKindMismatch(Int, ExecutionResourceReference, expected: ExecutionResourceKind, actual: ExecutionResourceKind)
    case inputResourceCapacityInsufficient(Int, ExecutionResourceReference, required: UInt64, actual: UInt64)
    case inputResourceAlignmentInsufficient(Int, ExecutionResourceReference, required: UInt64, actual: UInt64)
    case inputResourceMemoryDomainUnsupported(Int, ExecutionResourceReference, ExecutionMemoryDomain)
    case inputResourceAccessInsufficient(Int, ExecutionResourceReference, actual: ExecutionResourceAccessMode, required: ExecutionResourceAccessMode)
    case inputResourceNotAccessibleFromTarget(Int, ExecutionResourceReference, ExecutionTargetReference)
    case contextCapabilityInvalid(ExecutionCapabilityID)
    case contextResourceKindUnsupported(ImplementationResourceRole, ExecutionResourceKind)
    case contextResourceMemoryDomainsUnsupported(ImplementationResourceRole, Set<ExecutionMemoryDomain>)
    case outputResourcePlanningFailed(String)
    case outputResourceNotDeclaredByImplementation(Int)
    case implementationOutputResourceNotPlanned(Int)
    case requiredProviderNotDiscovered(ExecutionProviderID)
    case noExecutionProviderDiscovered
    case providerNotAllowed(ExecutionProviderID)
    case providerUnavailable(ExecutionProviderID, String)
    case deviceUnavailable(ExecutionTargetReference, String)
    case providerCapabilityMissing(ExecutionCapabilityID)
    case deviceCapabilityMissing(ExecutionCapabilityID)
    case contextCapabilityMissing(ExecutionCapabilityID)
    case contextProtocolMismatch(ExecutionCapabilityID)
    case precisionUnsupported(PrecisionDimension, PrecisionValue)
    case allowedPrecisionUnsupported(PrecisionDimension)
    case deterministicResultsUnsupported
    case contextTargetMismatch
    case contextCreationFailed(String)
    case requiredResourceProtocolUnavailable(ImplementationResourceRole, ExecutionCapabilityID)
}

public enum CandidateQualificationUncertainty: Hashable, Sendable {
    case environmentSnapshotStale
    case providerStateUnknown(ExecutionProviderID, String)
    case providerStateStale(ExecutionProviderID)
    case providerDiscoveryIncomplete(ExecutionProviderID)
    case deviceStateUnknown(ExecutionTargetReference, String)
    case deviceStateStale(ExecutionTargetReference)
    case providerRegistrationIdentityMissing(ExecutionProviderID)
}

/// Effective output allocation requirement after combining operation-derived
/// size/alignment with the selected implementation's static constraints.
public struct QualifiedOutputResourceAllocation: Hashable, Sendable {
    public let outputIndex: Int
    public let kind: ExecutionResourceKind
    public let allowedMemoryDomains: Set<ExecutionMemoryDomain>
    public let minimumCapacityBytes: UInt64
    public let minimumAlignmentBytes: UInt64
    public let access: ExecutionResourceAccessMode
    /// Domains supported by this prepared context and permitted by the implementation.
    /// This is not a reservation or a statement about currently free bytes.
    public let allocatableMemoryDomains: Set<ExecutionMemoryDomain>
}

public struct QualifiedOperationImplementation: Sendable {
    public let implementation: RegisteredOperationImplementation
    /// Exact provider package registration used to create the execution context.
    public let providerRegistrationIdentifier: UUID
    /// Exact operation occurrence qualified by the resolver.
    public let operationStep: AnyImageOperationStep
    /// Exact typed value whose descriptors and resources were qualified.
    public let input: any OperationValue
    public let target: ExecutionTargetReference
    public let context: any ExecutionContext
    /// Exact immutable image revisions and targets used during qualification.
    public let imageInputContext: ImageOperationInputContext?
    /// Provider/device telemetry from the same environment snapshot as qualification.
    public let environmentObservations: CandidateEnvironmentObservations
    /// Candidate-bound output allocation requirements; these are not reservations.
    public let outputResourceAllocations: [QualifiedOutputResourceAllocation]
    /// Source-resource accesses implied by the implementation's input roles.
    public let inputResourceAccesses: [ExecutionResourceAccess]
}

public struct OperationImplementationCandidateEvaluation: Sendable {
    public let implementation: RegisteredOperationImplementation
    public let target: ExecutionTargetReference?
    public let disposition: CandidateQualificationDisposition
    public let rejections: [CandidateQualificationRejection]
    public let uncertainties: [CandidateQualificationUncertainty]
    public let qualifiedCandidate: QualifiedOperationImplementation?

    public init(
        implementation: RegisteredOperationImplementation,
        target: ExecutionTargetReference?,
        disposition: CandidateQualificationDisposition,
        rejections: [CandidateQualificationRejection],
        uncertainties: [CandidateQualificationUncertainty],
        qualifiedCandidate: QualifiedOperationImplementation? = nil
    ) {
        self.implementation = implementation
        self.target = target
        self.disposition = disposition
        self.rejections = rejections
        self.uncertainties = uncertainties
        self.qualifiedCandidate = qualifiedCandidate
    }
}

public struct OperationImplementationQualificationReport: Sendable {
    public let operationStep: OperationStepIdentifier
    public let environmentSnapshot: RuntimeEnvironmentSnapshotIdentifier
    public let evaluations: [OperationImplementationCandidateEvaluation]

    public var qualifiedCandidates: [QualifiedOperationImplementation] {
        evaluations.compactMap(\.qualifiedCandidate)
    }

    public var rejectedCandidates: [OperationImplementationCandidateEvaluation] {
        evaluations.filter { $0.disposition == .rejected }
    }

    public var indeterminateCandidates: [OperationImplementationCandidateEvaluation] {
        evaluations.filter { $0.disposition == .indeterminate }
    }
}

public enum OperationImplementationQualificationError: Error, Equatable, Sendable {
    case invalidOperationSpecification(OperationSpecificationValidationError)
    case invalidOperationParameters(OperationParameterValidationError)
    case inputValueTypeMismatch(expected: OperationValueIdentifier, actual: OperationValueIdentifier)
    case imageInputContextRequired
}
