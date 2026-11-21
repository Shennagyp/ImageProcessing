import GeneralExecutionProtocol

/// One generic execution resource supplied by a typed operation input.
/// Multiple bindings may share an input index (for example, a planar image).
public struct OperationInputResourceBinding: Sendable {
    public let inputIndex: Int
    public let resource: any ExecutionResource
    /// Access available through this input value's ownership/binding contract.
    public let access: ExecutionResourceAccessMode

    public init?(
        inputIndex: Int,
        resource: any ExecutionResource,
        access: ExecutionResourceAccessMode
    ) {
        guard inputIndex >= 0 else { return nil }
        self.inputIndex = inputIndex
        self.resource = resource
        self.access = access
    }
}

/// Optional resource description for non-image OperationValue types. The
/// resource index corresponds to ImplementationResourceRole.input(index).
///
/// The binding list is part of the input value's invocation contract: it must
/// remain stable for the lifetime of that value and must not change between
/// qualification and execution. The runtime rechecks the exact resource objects
/// and descriptors before dispatch; implementations must use the imported
/// execution-resource mapping when one is supplied for an input index.
public protocol OperationResourceInputValue: OperationValue {
    var operationInputResourceBindings: [OperationInputResourceBinding] { get }
}
