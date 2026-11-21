import GeneralExecutionProtocol
import ImageProcessingProtocol
@testable import ImageProcessingRuntime
import Testing

private struct SequenceInput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "function-execution.input")!
    let value: Int
}

private struct SequenceMiddle: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "function-execution.middle")!
    let value: Int
}

private struct SequenceOutput: OperationValue {
    static let typeIdentifier = OperationValueIdentifier(rawValue: "function-execution.output")!
    let value: Int
}

private struct SequenceAddOperation: ImageOperation {
    typealias Input = SequenceInput
    typealias Output = SequenceMiddle

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "function-execution.add")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!
    )
}

private struct SequenceMultiplyOperation: ImageOperation {
    typealias Input = SequenceMiddle
    typealias Output = SequenceOutput

    static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(rawValue: "function-execution.multiply")!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!
    )
}

private struct SequenceAddImplementation: ImageOperationImplementation {
    typealias Operation = SequenceAddOperation

    let specification: ImplementationSpecification

    init() {
        specification = makeSequenceImplementationSpecification(
            identifier: "function-execution.add.cpu",
            operation: SequenceAddOperation.specification.erased
        )
    }

    func execute(
        operation: SequenceAddOperation,
        input: SequenceInput,
        context: any ExecutionContext
    ) async throws -> SequenceMiddle {
        SequenceMiddle(value: input.value + 3)
    }
}

private struct SequenceMultiplyImplementation: ImageOperationImplementation {
    typealias Operation = SequenceMultiplyOperation

    let specification: ImplementationSpecification

    init() {
        specification = makeSequenceImplementationSpecification(
            identifier: "function-execution.multiply.cpu",
            operation: SequenceMultiplyOperation.specification.erased
        )
    }

    func execute(
        operation: SequenceMultiplyOperation,
        input: SequenceMiddle,
        context: any ExecutionContext
    ) async throws -> SequenceOutput {
        SequenceOutput(value: input.value * 4)
    }
}

private func makeSequenceImplementationSpecification(
    identifier: String,
    operation: AnyOperationSpecification
) -> ImplementationSpecification {
    let lower = SemanticVersion(major: 1, minor: 0, patch: 0)!
    let upper = SemanticVersion(major: 2, minor: 0, patch: 0)!
    return ImplementationSpecification(
        identifier: OperationImplementationIdentifier(rawValue: identifier)!,
        version: lower,
        operationIdentifier: operation.identifier,
        supportedOperationVersions: SemanticVersionRange(
            lowerBound: lower,
            upperBound: upper
        )!,
        inputType: operation.inputType,
        outputType: operation.outputType
    )
}

private struct SequenceProviderContext: ExecutionProviderRegistrationBoundContext {
    let target: ExecutionTargetReference
    let providerRegistrationIdentifier: UUID
}

private struct SequenceProvider: ExecutionProvider {
    let descriptor: ExecutionProviderDescriptor

    init(identifier: ExecutionProviderID) {
        descriptor = ExecutionProviderDescriptor(
            identifier: identifier,
            version: SemanticVersion(major: 1, minor: 0, patch: 0)!,
            displayName: identifier.rawValue
        )
    }

    func observeState() async throws -> ExecutionProviderStateSnapshot {
        ExecutionProviderStateSnapshot(availability: .available)
    }

    func discoverDevices() async throws -> [any ExecutionDevice] {
        []
    }

    func makeContext(for target: ExecutionTargetReference) async throws -> any ExecutionContext {
        SequenceProviderContext(
            target: target,
            providerRegistrationIdentifier: UUID()
        )
    }

    func makeContext(
        for target: ExecutionTargetReference,
        registrationIdentifier: UUID
    ) async throws -> any ExecutionContext {
        SequenceProviderContext(
            target: target,
            providerRegistrationIdentifier: registrationIdentifier
        )
    }
}

struct ImageFunctionExecutionCoordinatorTests {
    @Test
    func executesComposedStepsSequentiallyAgainstFreshEnvironmentSnapshots() async throws {
        let providerID = ExecutionProviderID(rawValue: "provider.function-execution")!
        let providers = ExecutionProviderRegistry()
        try await providers.register(SequenceProvider(identifier: providerID))

        let implementations = OperationImplementationRegistry()
        try await implementations.register(SequenceAddImplementation())
        try await implementations.register(SequenceMultiplyImplementation())

        let workLedger = RuntimeWorkLedger()
        let environments = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: workLedger
        )
        let resolver = CommonQualificationResolver(
            implementations: implementations,
            providers: providers
        )
        let operationCoordinator = OperationExecutionCoordinator(
            implementations: implementations,
            providers: providers,
            workLedger: workLedger
        )
        let functionCoordinator = ImageFunctionExecutionCoordinator(
            resolver: resolver,
            environments: environments,
            operations: operationCoordinator
        )

        let function = try ImageFunction(operation: SequenceAddOperation())
            .followed(by: SequenceMultiplyOperation())
        let platform = ExecutionPlatformDescriptor(
            operatingSystem: "testOS",
            architecture: "testArchitecture"
        )
        let freshness = try #require(QualificationFreshnessPolicy(
            maximumSnapshotAge: 60,
            maximumProviderStateAge: 60,
            maximumDeviceStateAge: 60
        ))

        let result = try await functionCoordinator.executeWithReport(
            function,
            input: SequenceInput(value: 2),
            platform: platform,
            freshness: freshness
        )

        #expect(result.output.value == 20)
        #expect(result.steps.count == 2)
        #expect(result.steps.map(\.stepIdentifier) == function.stepIdentifiers)
        #expect(result.steps.map(\.rank) == [1, 1])
        #expect(result.steps[0].implementation.identifier.rawValue == "function-execution.add.cpu")
        #expect(result.steps[1].implementation.identifier.rawValue == "function-execution.multiply.cpu")
        #expect(
            result.steps[0].environmentSnapshotIdentifier
                != result.steps[1].environmentSnapshotIdentifier
        )
        #expect(await workLedger.activeLeaseCount == 0)
    }

    @Test
    func laterStepFailureReportsEarlierCompletedStepsAndDoesNotFallback() async throws {
        let providerID = ExecutionProviderID(rawValue: "provider.function-execution.partial")!
        let providers = ExecutionProviderRegistry()
        try await providers.register(SequenceProvider(identifier: providerID))

        let implementations = OperationImplementationRegistry()
        try await implementations.register(SequenceAddImplementation())

        let workLedger = RuntimeWorkLedger()
        let environments = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: workLedger
        )
        let resolver = CommonQualificationResolver(
            implementations: implementations,
            providers: providers
        )
        let operationCoordinator = OperationExecutionCoordinator(
            implementations: implementations,
            providers: providers,
            workLedger: workLedger
        )
        let functionCoordinator = ImageFunctionExecutionCoordinator(
            resolver: resolver,
            environments: environments,
            operations: operationCoordinator
        )
        let function = try ImageFunction(operation: SequenceAddOperation())
            .followed(by: SequenceMultiplyOperation())
        let freshness = try #require(QualificationFreshnessPolicy(
            maximumSnapshotAge: 60,
            maximumProviderStateAge: 60,
            maximumDeviceStateAge: 60
        ))

        do {
            _ = try await functionCoordinator.executeWithReport(
                function,
                input: SequenceInput(value: 2),
                platform: ExecutionPlatformDescriptor(
                    operatingSystem: "testOS",
                    architecture: "testArchitecture"
                ),
                freshness: freshness
            )
            Issue.record("Expected the second step to fail qualification.")
        } catch let failure as ImageFunctionStepExecutionFailure {
            #expect(failure.failedStepIdentifier == function.stepIdentifiers[1])
            #expect(failure.completedSteps.map(\.stepIdentifier) == [function.stepIdentifiers[0]])
            if let underlying = failure.underlying as? ImageFunctionExecutionCoordinatorError,
               case let .noQualifiedCandidate(stepIdentifier, _) = underlying {
                #expect(stepIdentifier == function.stepIdentifiers[1])
            } else {
                Issue.record("Expected a no-qualified-candidate failure for the second step.")
            }
        }
        #expect(await workLedger.activeLeaseCount == 0)
    }

    @Test
    func identityFunctionReturnsItsInputWithoutResolvingOrExecutingSteps() async throws {
        let providers = ExecutionProviderRegistry()
        let implementations = OperationImplementationRegistry()
        let workLedger = RuntimeWorkLedger()
        let environments = RuntimeEnvironmentSnapshotCoordinator(
            providers: providers,
            workLedger: workLedger
        )
        let resolver = CommonQualificationResolver(
            implementations: implementations,
            providers: providers
        )
        let operations = OperationExecutionCoordinator(
            implementations: implementations,
            providers: providers,
            workLedger: workLedger
        )
        let coordinator = ImageFunctionExecutionCoordinator(
            resolver: resolver,
            environments: environments,
            operations: operations
        )
        let function = ImageFunction<SequenceInput, SequenceInput>.identity()
        let freshness = try #require(QualificationFreshnessPolicy(
            maximumSnapshotAge: 60,
            maximumProviderStateAge: 60,
            maximumDeviceStateAge: 60
        ))
        let output = try await coordinator.execute(
            function,
            input: SequenceInput(value: 17),
            platform: ExecutionPlatformDescriptor(
                operatingSystem: "testOS",
                architecture: "testArchitecture"
            ),
            freshness: freshness
        )

        #expect(output.value == 17)
    }
}
