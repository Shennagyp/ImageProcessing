import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

struct OperationContractTests {
    private struct SampleInput: OperationValue {
        static let typeIdentifier = OperationValueIdentifier(rawValue: "sample.integer")!
        let value: Int
    }

    private struct SampleOutput: OperationValue {
        static let typeIdentifier = OperationValueIdentifier(rawValue: "sample.integer")!
        let value: Int
    }

    private struct SampleOperation: ImageOperation {
        typealias Input = SampleInput
        typealias Output = SampleOutput

        static let specification = OperationSpecification<Input, Output>(
            identifier: OperationIdentifier(rawValue: "sample.double")!,
            semanticVersion: SemanticVersion(major: 1, minor: 2, patch: 0)!
        )
    }

    private struct SampleContext: ExecutionContext {
        let target: ExecutionTargetReference
    }

    private struct SampleImplementation: ImageOperationImplementation {
        let specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(rawValue: "sample.double.reference")!,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            operationIdentifier: OperationIdentifier(rawValue: "sample.double")!,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: SemanticVersion(major: 1, minor: 0, patch: 0)!,
                upperBound: SemanticVersion(major: 2, minor: 0, patch: 0)!
            )!,
            inputType: SampleInput.typeIdentifier,
            outputType: SampleOutput.typeIdentifier
        )

        func execute(
            operation: SampleOperation,
            input: SampleInput,
            context: any ExecutionContext
        ) async throws -> SampleOutput {
            SampleOutput(value: input.value * 2)
        }
    }

    @Test
    func implementationMatchesOperationIdentityVersionAndValueTypes() {
        let implementation = SampleImplementation()
        #expect(implementation.implementsDeclaredOperation)

        let incompatible = AnyOperationSpecification(
            identifier: OperationIdentifier(rawValue: "sample.other")!,
            semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            inputType: SampleInput.typeIdentifier,
            outputType: SampleOutput.typeIdentifier
        )
        #expect(!implementation.specification.implements(incompatible))
    }

    @Test
    func implementationProtocolPreservesAssociatedOperationType() async throws {
        let implementation = SampleImplementation()
        let providerID = ExecutionProviderID(rawValue: "provider.test")!
        let deviceID = ExecutionDeviceID(rawValue: "device.test")!
        let context = SampleContext(target: ExecutionTargetReference(providerID: providerID, deviceID: deviceID))
        let output = try await implementation.execute(
            operation: SampleOperation(),
            input: SampleInput(value: 21),
            context: context
        )

        #expect(output.value == 42)
    }
}
