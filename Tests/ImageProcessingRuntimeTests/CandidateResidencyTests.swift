import Foundation
import GeneralExecutionProtocol
@testable import ImageProcessingRuntime
import Testing

private final class CandidateResidencyTestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

struct CandidateResidencyTests {
    private let registrationIdentifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private func target(
        provider: String,
        device: String
    ) throws -> ExecutionTargetReference {
        ExecutionTargetReference(
            providerID: try #require(ExecutionProviderID(rawValue: provider)),
            deviceID: try #require(ExecutionDeviceID(rawValue: device))
        )
    }

    private func resource(
        id: String,
        target: ExecutionTargetReference,
        capacity: UInt64 = 4_096,
        domain: ExecutionMemoryDomain = .deviceLocal,
        providerRegistrationIdentifier: UUID? = nil
    ) throws -> CandidateResidencyTestResource {
        let descriptor = try ExecutionResourceDescriptor(
            identifier: try #require(ExecutionResourceIdentifier(rawValue: id)),
            target: target,
            kind: .buffer,
            capacityBytes: capacity,
            alignmentBytes: 256,
            memoryDomain: domain,
            providerRegistrationIdentifier: providerRegistrationIdentifier
        )
        return CandidateResidencyTestResource(descriptor: descriptor)
    }

    private func estimate(
        _ resources: [any ExecutionResource],
        on target: ExecutionTargetReference,
        registrationIdentifier: UUID? = nil
    ) -> CandidateInputResidencyEstimate {
        CandidateInputResidencyEstimator.estimate(
            resourceAccesses: resources.map {
                ExecutionResourceAccess(resource: $0, mode: .read)
            },
            on: target,
            providerRegistrationIdentifier: registrationIdentifier ?? self.registrationIdentifier,
            source: "candidate-residency-test"
        )
    }

    @Test
    func resourceReferencesDistinguishProviderRegistrationGenerations() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")
        let firstRegistration = registrationIdentifier
        let secondRegistration = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let first = try resource(
            id: "input.reused-name",
            target: target,
            providerRegistrationIdentifier: firstRegistration
        )
        let second = try resource(
            id: "input.reused-name",
            target: target,
            providerRegistrationIdentifier: secondRegistration
        )

        #expect(first.descriptor.reference != second.descriptor.reference)
    }

    @Test
    func targetLocalDeviceMemoryHasNoBoundInputStagingCost() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")
        let first = try resource(id: "input.first", target: target, capacity: 4_096, providerRegistrationIdentifier: registrationIdentifier)
        let second = try resource(id: "input.second", target: target, capacity: 8_192, providerRegistrationIdentifier: registrationIdentifier)

        let result = estimate([first, second], on: target)

        #expect(result.resources.count == 2)
        #expect(result.resources.allSatisfy {
            $0.disposition == .deviceLocalOnTarget
        })
        #expect({
            guard case let .estimated(value: .integer(bytes), _) = result.deviceLocalCapacityBytes else {
                return false
            }
            return bytes == 12_288
        }())
        #expect({
            guard case let .estimated(value: .integer(nanoseconds), evidence) = result.boundInputTransferTime else {
                return false
            }
            return nanoseconds == 0
                && evidence.first?.kind == .resourceBinding
        }())
    }

    @Test
    func repeatedReferencesAreCountedOnceInResidentCapacity() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")
        let shared = try resource(id: "input.shared", target: target, capacity: 16_384, providerRegistrationIdentifier: registrationIdentifier)

        let result = estimate([shared, shared, shared], on: target)

        #expect(result.resources.count == 1)
        #expect({
            guard case let .estimated(value: .integer(bytes), _) = result.deviceLocalCapacityBytes else {
                return false
            }
            return bytes == 16_384
        }())
        #expect({
            guard case let .estimated(value: .integer(nanoseconds), _) = result.boundInputTransferTime else {
                return false
            }
            return nanoseconds == 0
        }())
    }

    @Test
    func foreignTargetInputRequiresAnUnmodeledImportRoute() throws {
        let candidateTarget = try target(provider: "provider.gpu", device: "device.0")
        let sourceTarget = try target(provider: "provider.other-gpu", device: "device.1")
        let source = try resource(id: "input.foreign", target: sourceTarget)

        let result = estimate([source], on: candidateTarget)

        #expect(result.resources.first?.disposition == .foreignTarget)
        #expect({
            guard case let .estimated(value: .integer(bytes), _) = result.deviceLocalCapacityBytes else {
                return false
            }
            return bytes == 0
        }())
        #expect({
            guard case let .unknown(reason) = result.boundInputTransferTime else {
                return false
            }
            return reason.contains("import")
        }())
    }

    @Test
    func nonDeviceLocalDomainsDoNotProduceAnAssumedZeroTransfer() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")

        for domain in [ExecutionMemoryDomain.host, .shared, .managed, .external] {
            let input = try resource(
                id: "input.\(domain.rawValue)",
                target: target,
                domain: domain
            )
            let result = estimate([input], on: target)

            #expect(result.resources.first?.disposition == .nonDeviceLocalOnTarget)
            #expect({
                if case .unknown = result.boundInputTransferTime { return true }
                return false
            }())
        }
    }

    @Test
    func sameTargetResourceFromAnotherProviderRegistrationIsNotResidentForCandidate() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")
        let previousRegistration = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let input = try resource(
            id: "input.previous-registration",
            target: target,
            providerRegistrationIdentifier: previousRegistration
        )

        let result = estimate([input], on: target)

        #expect(result.resources.first?.disposition == .providerRegistrationMismatch)
        #expect({
            if case .unknown = result.boundInputTransferTime { return true }
            return false
        }())
    }

    @Test
    func deviceLocalResourceWithoutProviderRegistrationRemainsUnknown() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")
        let input = try resource(id: "input.unattributed", target: target)

        let result = estimate([input], on: target)

        #expect(result.resources.first?.disposition == .providerRegistrationUnknown)
        #expect({
            if case .unknown = result.boundInputTransferTime { return true }
            return false
        }())
    }

    @Test
    func absentResourceBindingsRemainUnknown() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")

        let result = estimate([], on: target)

        #expect({
            if case .unknown = result.deviceLocalCapacityBytes { return true }
            return false
        }())
        #expect({
            if case .unknown = result.boundInputTransferTime { return true }
            return false
        }())
    }

    @Test
    func conflictingDescriptorsForOneResourceIdentityRemainUnknown() throws {
        let target = try target(provider: "provider.gpu", device: "device.0")
        let smaller = try resource(
            id: "input.conflict",
            target: target,
            capacity: 4_096,
            providerRegistrationIdentifier: registrationIdentifier
        )
        let larger = try resource(
            id: "input.conflict",
            target: target,
            capacity: 8_192,
            providerRegistrationIdentifier: registrationIdentifier
        )

        let result = estimate([smaller, larger], on: target)

        #expect(result.resources.count == 1)
        #expect(result.resources.first?.disposition == .inconsistentDescriptor)
        #expect({
            if case .unknown = result.deviceLocalCapacityBytes { return true }
            return false
        }())
        #expect({
            if case .unknown = result.boundInputTransferTime { return true }
            return false
        }())
    }
}
