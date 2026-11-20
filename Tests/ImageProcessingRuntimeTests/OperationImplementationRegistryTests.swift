import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol
@testable import ImageProcessingRuntime
import Testing

private struct RegistryInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "registry.integer")!
    let value: Int
}

private struct RegistryOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "registry.integer")!
    let value: Int
}

private struct ForeignRegistryInput: OperationValue {
    // Deliberately reuses the stable identifier with a different Swift type.
    static let typeIdentifier = RegistryInput.typeIdentifier
    let value: Int
}

private struct RegistryOperation: ImageOperation {
    typealias Input = RegistryInput
    typealias Output = RegistryOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "registry.multiply")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!
    )
}

private struct AlternativeRegistryOperation: ImageOperation {
    typealias Input = RegistryInput
    typealias Output = RegistryOutput

    // Same public semantic contract but a different Swift operation type.
    static let specification = RegistryOperation.specification
}

private struct RegistryContext: ExecutionContext {
    let target: ExecutionTargetReference
}

private struct MultiplyImplementation: ImageOperationImplementation {
    typealias Operation = RegistryOperation

    let specification: ImplementationSpecification
    let factor: Int

    init(identifier: String, factor: Int, implementationVersion: SemanticVersion? = nil) {
        let lower = SemanticVersion(major: 1, minor: 0, patch: 0)!
        let upper = SemanticVersion(major: 2, minor: 0, patch: 0)!
        self.specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: identifier)!,
            version: implementationVersion ?? lower,
            operationIdentifier: RegistryOperation.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: lower,
                upperBound: upper
            )!,
            inputType: RegistryInput.typeIdentifier,
            outputType: RegistryOutput.typeIdentifier
        )
        self.factor = factor
    }

    func execute(
        operation: RegistryOperation,
        input: RegistryInput,
        context: any ExecutionContext
    ) async throws -> RegistryOutput {
        RegistryOutput(value: input.value * factor)
    }
}

struct OperationImplementationRegistryTests {
    private func providerID() -> ExecutionProviderID {
        ExecutionProviderID(rawValue: "provider.runtime-test")!
    }

    private func context() -> RegistryContext {
        RegistryContext(target: ExecutionTargetReference(providerID: providerID()))
    }

    private func step() -> AnyImageOperationStep {
        AnyImageOperationStep(operation: RegistryOperation())
    }

    private func key(_ identifier: String, version: SemanticVersion? = nil) -> OperationImplementationKey {
        OperationImplementationKey(
            identifier: OperationImplementationIdentifier(rawValue: identifier)!,
            version: version ?? SemanticVersion(major: 1, minor: 0, patch: 0)!
        )
    }

    private func qualifiedCandidate(
        _ implementation: RegisteredOperationImplementation,
        operationStep: AnyImageOperationStep? = nil,
        input: any OperationValue,
        context: RegistryContext? = nil
    ) -> QualifiedOperationImplementation {
        let selectedContext = context ?? self.context()
        return QualifiedOperationImplementation(
            implementation: implementation,
            providerRegistrationIdentifier: UUID(),
            operationStep: operationStep ?? step(),
            input: input,
            target: selectedContext.target,
            context: selectedContext,
            imageInputContext: nil,
            inputResourceAccesses: []
        )
    }

    @Test
    func registersHeterogeneousImplementationsForOneOperation() async throws {
        let registry = OperationImplementationRegistry()
        let cpu = MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        let metal = MultiplyImplementation(identifier: "registry.multiply.metal", factor: 3)

        try await registry.register(cpu)
        try await registry.register(metal)

        let count = await registry.count
        #expect(count == 2)

        let registered = await registry.registeredImplementations()
        #expect(registered.count == 2)
        #expect(registered.allSatisfy {
            $0.specification.operationIdentifier == RegistryOperation.specification.identifier
        })
    }

    @Test
    func candidateEnumerationSeparatesOperationCompatibilityFromStepSupport() async throws {
        let registry = OperationImplementationRegistry()
        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        )
        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.metal", factor: 3)
        )

        let byOperation = await registry.implementations(
            for: RegistryOperation.specification.erased
        )
        let byStep = await registry.implementations(supporting: step())

        #expect(byOperation.count == 2)
        #expect(byStep.count == 2)
    }

    @Test
    func explicitExecutionDispatchesToTheRequestedTypedImplementation() async throws {
        let registry = OperationImplementationRegistry()
        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        )
        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.metal", factor: 3)
        )

        let registrations = await registry.registeredImplementations()
        let cpu = try #require(registrations.first { $0.key == key("registry.multiply.cpu") })
        let metal = try #require(registrations.first { $0.key == key("registry.multiply.metal") })
        let cpuOutput = try await registry.execute(
            using: qualifiedCandidate(cpu, input: RegistryInput(value: 7))
        ) as? RegistryOutput
        let metalOutput = try await registry.execute(
            using: qualifiedCandidate(metal, input: RegistryInput(value: 7))
        ) as? RegistryOutput

        #expect(cpuOutput?.value == 14)
        #expect(metalOutput?.value == 21)
    }

    @Test
    func missingRegistrationIsReportedWithoutSelectingAnotherImplementation() async throws {
        let registry = OperationImplementationRegistry()
        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        )
        let missingKey = key("registry.multiply.cuda")
        let registered = try #require((await registry.registeredImplementations()).first)
        let missing = RegisteredOperationImplementation(
            key: missingKey,
            registrationIdentifier: UUID(),
            specification: registered.specification
        )

        await #expect(throws: OperationImplementationRegistryError.registrationNotFound(missingKey)) {
            try await registry.execute(
                using: qualifiedCandidate(
                    missing,
                    input: RegistryInput(value: 4)
                )
            )
        }
    }

    @Test
    func duplicateImplementationIdentityAndVersionAreRejected() async throws {
        let registry = OperationImplementationRegistry()
        let implementation = MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        try await registry.register(implementation)

        await #expect(throws: OperationImplementationRegistryError.duplicateRegistration(
            key("registry.multiply.cpu")
        )) {
            try await registry.register(implementation)
        }

        // A different version of the same implementation identity is a distinct registration.
        let secondVersion = MultiplyImplementation(
            identifier: "registry.multiply.cpu",
            factor: 4,
            implementationVersion: SemanticVersion(major: 1, minor: 1, patch: 0)!
        )
        try await registry.register(secondVersion)
        let count = await registry.count
        #expect(count == 2)
    }

    @Test
    func sameValueIdentifierDoesNotBypassRuntimeSwiftTypeCheck() async throws {
        let registry = OperationImplementationRegistry()
        let implementation = MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        try await registry.register(implementation)

        let registered = try #require((await registry.registeredImplementations()).first)
        await #expect(throws: OperationImplementationRegistryError.typedDispatchMismatch(
            key("registry.multiply.cpu")
        )) {
            try await registry.execute(
                using: qualifiedCandidate(
                    registered,
                    input: ForeignRegistryInput(value: 7)
                )
            )
        }
    }

    @Test
    func sameOperationSpecificationDoesNotBypassOperationTypeCheck() async throws {
        let registry = OperationImplementationRegistry()
        let implementation = MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        try await registry.register(implementation)
        let alternativeStep = AnyImageOperationStep(operation: AlternativeRegistryOperation())

        let registered = try #require((await registry.registeredImplementations()).first)
        await #expect(throws: OperationImplementationRegistryError.typedDispatchMismatch(
            key("registry.multiply.cpu")
        )) {
            try await registry.execute(
                using: qualifiedCandidate(
                    registered,
                    operationStep: alternativeStep,
                    input: RegistryInput(value: 7)
                )
            )
        }
    }

    @Test
    func staleCandidateCannotDispatchAfterSameKeyIsReregistered() async throws {
        let registry = OperationImplementationRegistry()
        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        )
        let original = try #require((await registry.registeredImplementations()).first)
        #expect(await registry.unregister(original.key))

        try await registry.register(
            MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 3)
        )

        await #expect(throws: OperationImplementationRegistryError.registrationChanged(original.key)) {
            try await registry.execute(
                using: qualifiedCandidate(original, input: RegistryInput(value: 7))
            )
        }
    }

    @Test
    func unregisterRemovesOnlyTheExactImplementationVersion() async throws {
        let registry = OperationImplementationRegistry()
        let v1 = MultiplyImplementation(identifier: "registry.multiply.cpu", factor: 2)
        let v11 = MultiplyImplementation(
            identifier: "registry.multiply.cpu",
            factor: 4,
            implementationVersion: SemanticVersion(major: 1, minor: 1, patch: 0)!
        )
        try await registry.register(v1)
        try await registry.register(v11)

        #expect(await registry.unregister(key("registry.multiply.cpu")))
        let remaining = await registry.registeredImplementations()
        #expect(remaining.count == 1)
        #expect(remaining[0].key.version == SemanticVersion(major: 1, minor: 1, patch: 0)!)
        #expect(!(await registry.unregister(key("registry.multiply.cpu"))))
    }
}
