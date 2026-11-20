import GeneralExecutionProtocol
import ImageProcessingProtocol
import Testing

private final class BindingTestResource: ExecutionResource, @unchecked Sendable {
    let descriptor: ExecutionResourceDescriptor

    init(_ descriptor: ExecutionResourceDescriptor) {
        self.descriptor = descriptor
    }
}

struct PixelStorageBindingTests {
    private func resource(
        id: String,
        capacity: UInt64,
        target: ExecutionTargetReference? = nil
    ) throws -> BindingTestResource {
        let providerID = try #require(ExecutionProviderID(rawValue: "provider.pixel-storage"))
        let deviceID = try #require(ExecutionDeviceID(rawValue: "device.pixel-storage"))
        let resolvedTarget = target ?? ExecutionTargetReference(
            providerID: providerID,
            deviceID: deviceID
        )
        let descriptor = try ExecutionResourceDescriptor(
            identifier: try #require(ExecutionResourceIdentifier(rawValue: id)),
            target: resolvedTarget,
            kind: .buffer,
            capacityBytes: capacity,
            alignmentBytes: 1,
            memoryDomain: .host
        )
        return BindingTestResource(descriptor)
    }

    private func planarRGBDescriptor(offsets: [UInt64]) throws -> PixelDataDescriptor {
        guard offsets.count == 3 else { throw TestError.invalidFixture }
        let roles: [PixelChannelRole] = [.red, .green, .blue]
        let channels = try roles.enumerated().map { index, role in
            PixelChannelDescriptor(
                identifier: try #require(ChannelIdentifier(rawValue: "channel.\(index)")),
                role: role
            )
        }
        let planes = offsets.enumerated().map { index, offset in
            PixelPlaneLayout(
                byteOffset: offset,
                rowStrideBytes: 4,
                sliceStrideBytes: 8,
                pixelStrideBytes: 1,
                subsampling: PixelSubsampling()!,
                channelIndices: [index]
            )
        }
        return try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 4, height: 2)),
            componentType: .uint8,
            channels: channels,
            interpretation: .color(ColorDataInterpretation(
                colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                channelModel: .rgb,
                transferFunction: .sRGB,
                alphaMode: .none
            )),
            layout: .planar(planes)
        )
    }

    private enum TestError: Error {
        case invalidFixture
    }

    @Test
    func oneResourceCanOwnEveryPlaneInOneContiguousAllocation() throws {
        let descriptor = try planarRGBDescriptor(offsets: [0, 8, 16])
        let storage = try resource(id: "rgb.contiguous", capacity: 24)
        let binding = try PixelStorageBinding(
            descriptor: descriptor,
            planeBindings: [
                PixelPlaneResourceBinding(
                    resource: storage,
                    planeIndices: [0, 1, 2],
                    access: .read
                )
            ]
        )

        #expect(descriptor.minimumRequiredStorageBytesByPlane == [8, 16, 24])
        #expect(descriptor.minimumRequiredStorageBytes == 24)
        #expect(binding.resource(forPlaneAt: 0) === storage)
        #expect(binding.resource(forPlaneAt: 1) === storage)
        #expect(binding.resource(forPlaneAt: 2) === storage)
        #expect(binding.executionResourceAccesses.count == 1)
        #expect(binding.executionResourceAccesses[0].mode == .read)
    }

    @Test
    func eachPlanarPlaneCanUseItsOwnResource() throws {
        let descriptor = try planarRGBDescriptor(offsets: [0, 0, 0])
        let red = try resource(id: "rgb.red", capacity: 8)
        let green = try resource(id: "rgb.green", capacity: 8)
        let blue = try resource(id: "rgb.blue", capacity: 8)
        let binding = try PixelStorageBinding(
            descriptor: descriptor,
            planeBindings: [
                PixelPlaneResourceBinding(resource: red, planeIndices: [0]),
                PixelPlaneResourceBinding(resource: green, planeIndices: [1]),
                PixelPlaneResourceBinding(resource: blue, planeIndices: [2])
            ]
        )

        #expect(binding.resource(forPlaneAt: 0) === red)
        #expect(binding.resource(forPlaneAt: 1) === green)
        #expect(binding.resource(forPlaneAt: 2) === blue)
        #expect(binding.executionResourceAccesses.count == 3)
    }

    @Test
    func bindingRejectsInsufficientResourceCapacity() throws {
        let descriptor = try planarRGBDescriptor(offsets: [0, 0, 0])
        let shortResource = try resource(id: "rgb.short", capacity: 7)

        #expect(throws: PixelStorageBindingError.resourceCapacityTooSmall(
            resource: shortResource.descriptor.reference,
            required: 8,
            actual: 7
        )) {
            try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(resource: shortResource, planeIndices: [0, 1, 2])
                ]
            )
        }
    }

    @Test
    func bindingRejectsMissingDuplicateAndOutOfRangePlaneAssignments() throws {
        let descriptor = try planarRGBDescriptor(offsets: [0, 0, 0])
        let resource = try resource(id: "rgb.mapping", capacity: 8)

        #expect(throws: PixelStorageBindingError.missingPlaneAssignment(2)) {
            try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(resource: resource, planeIndices: [0, 1])
                ]
            )
        }

        #expect(throws: PixelStorageBindingError.duplicatePlaneAssignment(1)) {
            try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(resource: resource, planeIndices: [0, 1]),
                    PixelPlaneResourceBinding(
                        resource: try self.resource(id: "rgb.other", capacity: 8),
                        planeIndices: [1, 2]
                    )
                ]
            )
        }

        #expect(throws: PixelStorageBindingError.invalidPlaneIndex(3)) {
            try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(resource: resource, planeIndices: [0, 1, 3])
                ]
            )
        }
    }

    @Test
    func bindingRejectsEmptyGroupsAndRepeatedResourceGroups() throws {
        let descriptor = try planarRGBDescriptor(offsets: [0, 0, 0])
        let storage = try resource(id: "rgb.single", capacity: 8)

        #expect(throws: PixelStorageBindingError.emptyPlaneGroup) {
            try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(resource: storage, planeIndices: [])
                ]
            )
        }

        #expect(throws: PixelStorageBindingError.resourceRepeatedAcrossGroups(storage.descriptor.reference)) {
            try PixelStorageBinding(
                descriptor: descriptor,
                planeBindings: [
                    PixelPlaneResourceBinding(resource: storage, planeIndices: [0]),
                    PixelPlaneResourceBinding(resource: storage, planeIndices: [1, 2])
                ]
            )
        }
    }

    @Test
    func bindingRetainsResourceHandlesAndExposesDeclaredAccesses() throws {
        let descriptor = try planarRGBDescriptor(offsets: [0, 0, 0])
        var resource: BindingTestResource? = try self.resource(id: "rgb.retained", capacity: 8)
        weak var weakResource = resource
        let binding = try PixelStorageBinding(
            descriptor: descriptor,
            planeBindings: [
                PixelPlaneResourceBinding(
                    resource: try #require(resource),
                    planeIndices: [0, 1, 2],
                    access: .readWrite
                )
            ]
        )
        resource = nil

        #expect(weakResource != nil)
        #expect(binding.executionResourceAccesses.first?.mode == .readWrite)
    }
}
