import GeneralExecutionProtocol
import Testing

struct ProviderFailureTests {
    @Test
    func deviceLossFailureCarriesTargetCategoryRecoveryAndNativeCode() throws {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.metal"))
        let device = try #require(ExecutionDeviceID(rawValue: "gpu.0"))
        let target = ExecutionTargetReference(providerID: provider, deviceID: device)

        let failure = try ExecutionProviderFailure(
            providerID: provider,
            target: target,
            kind: .deviceLost,
            recovery: .refreshEnvironment,
            message: "Device was removed during submission.",
            nativeCode: "MTLDeviceRemoved"
        )

        #expect(failure.providerID == provider)
        #expect(failure.target == target)
        #expect(failure.kind == .deviceLost)
        #expect(failure.recovery == .refreshEnvironment)
        #expect(failure.nativeCode == "MTLDeviceRemoved")
    }

    @Test
    func providerWideFailureCanExistWithoutAnExecutionTarget() throws {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.cuda"))
        let failure = try ExecutionProviderFailure(
            providerID: provider,
            kind: .providerUnavailable,
            recovery: .tryAnotherTarget
        )

        #expect(failure.target == nil)
        #expect(failure.kind == .providerUnavailable)
        #expect(failure.recovery == .tryAnotherTarget)
    }

    @Test
    func failureRejectsTargetOwnedByAnotherProvider() throws {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.metal"))
        let otherProvider = try #require(ExecutionProviderID(rawValue: "provider.cuda"))
        let device = try #require(ExecutionDeviceID(rawValue: "gpu.0"))
        let foreignTarget = ExecutionTargetReference(
            providerID: otherProvider,
            deviceID: device
        )

        #expect(throws: ExecutionProviderFailureValidationError.targetProviderMismatch(
            expected: provider,
            actual: otherProvider
        )) {
            try ExecutionProviderFailure(
                providerID: provider,
                target: foreignTarget,
                kind: .deviceLost,
                recovery: .refreshEnvironment
            )
        }
    }

    @Test
    func emptyDiagnosticFieldsAreRejected() throws {
        let provider = try #require(ExecutionProviderID(rawValue: "provider.cpu"))

        #expect(throws: ExecutionProviderFailureValidationError.emptyMessage) {
            try ExecutionProviderFailure(
                providerID: provider,
                kind: .workExecutionFailed,
                recovery: .permanent,
                message: ""
            )
        }

        #expect(throws: ExecutionProviderFailureValidationError.emptyNativeCode) {
            try ExecutionProviderFailure(
                providerID: provider,
                kind: .workExecutionFailed,
                recovery: .permanent,
                nativeCode: ""
            )
        }
    }
}
