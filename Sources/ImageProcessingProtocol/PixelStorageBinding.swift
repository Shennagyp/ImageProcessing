import GeneralExecutionProtocol

/// Assigns one or more pixel planes to a generic execution resource.
/// Multiple planes may share one resource (one contiguous allocation), or
/// each plane may use a separate allocation. Plane byte offsets are relative
/// to the resource assigned to that plane.
public struct PixelPlaneResourceBinding: Sendable {
    public let resource: any ExecutionResource
    public let planeIndices: [Int]
    public let access: ExecutionResourceAccessMode

    public init(
        resource: any ExecutionResource,
        planeIndices: [Int],
        access: ExecutionResourceAccessMode = .read
    ) {
        self.resource = resource
        self.planeIndices = planeIndices
        self.access = access
    }
}

public enum PixelStorageBindingError: Error, Equatable, Sendable {
    case emptyPlaneGroup
    case invalidPlaneIndex(Int)
    case duplicatePlaneAssignment(Int)
    case missingPlaneAssignment(Int)
    case resourceRepeatedAcrossGroups(ExecutionResourceReference)
    case resourceCapacityTooSmall(
        resource: ExecutionResourceReference,
        required: UInt64,
        actual: UInt64
    )
    case resourceAlignmentTooSmall(
        resource: ExecutionResourceReference,
        required: UInt64,
        actual: UInt64
    )
}

/// Immutable binding from semantic pixel-plane descriptors to generic,
/// provider-owned resources. It retains each concrete resource handle for the
/// image revision's lifetime. If a resource depends on provider/package code
/// for native destruction, that resource must itself retain an
/// ExecutionResourceOwnerLifetime token.
///
/// It does not allocate, import, copy, synchronize, or infer provider choice.
/// The runtime and provider packages own those operations.
public struct PixelStorageBinding: Sendable {
    public let descriptor: PixelDataDescriptor
    public let planeBindings: [PixelPlaneResourceBinding]

    public init(
        descriptor: PixelDataDescriptor,
        planeBindings: [PixelPlaneResourceBinding]
    ) throws {
        var assignedPlanes = Set<Int>()
        var assignedResources = Set<ExecutionResourceReference>()

        for binding in planeBindings {
            guard !binding.planeIndices.isEmpty else {
                throw PixelStorageBindingError.emptyPlaneGroup
            }

            let resourceReference = binding.resource.descriptor.reference
            guard assignedResources.insert(resourceReference).inserted else {
                throw PixelStorageBindingError.resourceRepeatedAcrossGroups(resourceReference)
            }

            var groupRequiredCapacity: UInt64 = 0
            var groupRequiredAlignment: UInt64 = 1
            for planeIndex in binding.planeIndices {
                guard descriptor.minimumRequiredStorageBytesByPlane.indices.contains(planeIndex) else {
                    throw PixelStorageBindingError.invalidPlaneIndex(planeIndex)
                }
                guard assignedPlanes.insert(planeIndex).inserted else {
                    throw PixelStorageBindingError.duplicatePlaneAssignment(planeIndex)
                }
                groupRequiredCapacity = max(
                    groupRequiredCapacity,
                    descriptor.minimumRequiredStorageBytesByPlane[planeIndex]
                )
                let planeLayout = descriptor.layout.planes[planeIndex]
                groupRequiredAlignment = max(
                    groupRequiredAlignment,
                    planeLayout.requiredAlignmentBytes
                )
            }

            let resourceDescriptor = binding.resource.descriptor
            guard resourceDescriptor.alignmentBytes >= groupRequiredAlignment,
                  resourceDescriptor.alignmentBytes.isMultiple(of: groupRequiredAlignment) else {
                throw PixelStorageBindingError.resourceAlignmentTooSmall(
                    resource: resourceReference,
                    required: groupRequiredAlignment,
                    actual: resourceDescriptor.alignmentBytes
                )
            }
            guard resourceDescriptor.capacityBytes >= groupRequiredCapacity else {
                throw PixelStorageBindingError.resourceCapacityTooSmall(
                    resource: resourceReference,
                    required: groupRequiredCapacity,
                    actual: resourceDescriptor.capacityBytes
                )
            }
        }

        for planeIndex in descriptor.minimumRequiredStorageBytesByPlane.indices {
            guard assignedPlanes.contains(planeIndex) else {
                throw PixelStorageBindingError.missingPlaneAssignment(planeIndex)
            }
        }

        self.descriptor = descriptor
        self.planeBindings = planeBindings
    }

    /// Generic work access declarations derived from the binding.
    /// Work items can include these accesses in their ExecutionWork declaration.
    public var executionResourceAccesses: [ExecutionResourceAccess] {
        planeBindings.map {
            ExecutionResourceAccess(resource: $0.resource, mode: $0.access)
        }
    }

    public func resource(forPlaneAt index: Int) -> (any ExecutionResource)? {
        planeBindings.first(where: { $0.planeIndices.contains(index) })?.resource
    }
}
