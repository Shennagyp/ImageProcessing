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

public enum CandidateQualificationDisposition: String, Hashable, Sendable {
    case qualified
    case rejected
    case indeterminate
}

public enum CandidateQualificationRejection: Hashable, Sendable {
    case implementationDoesNotSupportOperationStep
    case requiredProviderNotDiscovered(ExecutionProviderID)
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
}

public struct QualifiedOperationImplementation: Sendable {
    public let implementation: RegisteredOperationImplementation
    public let target: ExecutionTargetReference
    public let context: any ExecutionContext
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
}
