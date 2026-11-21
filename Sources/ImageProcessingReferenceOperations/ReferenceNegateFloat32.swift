import Foundation
import GeneralExecutionProtocol
import ImageProcessingProtocol
import ImageProcessingCPUProvider

public enum ReferenceNegateFloat32Error: Error, Equatable, Sendable {
    case missingImageInput
    case unsupportedImageTarget
    case missingLayer(LayerReference)
    case nonRasterLayer(LayerReference)
    case unsupportedPixelRepresentation
    case missingStorageBinding(LayerReference)
    case invalidPlaneBinding
    case inputResourceMissing
    case inputResourceIsNotCPUBuffer
    case outputResourceMissing
    case outputResourceIsNotCPUBuffer
    case pixelOffsetOverflow
    case pixelBufferTooSmall
}

/// Image-bound source details derived from one exact input snapshot.
struct ReferenceNegateFloat32Source {
    let input: ImageOperationInputBinding
    let layer: LayerDescriptor
    let pixels: PixelDataDescriptor
    let plane: PixelPlaneLayout
    let storage: PixelStorageBinding
    let reference: LayerReference
}

/// Reference operation for one interleaved, single-channel scientific Float32
/// raster. It negates each sample and preserves the original pixel layout,
/// including row/slice padding and spatial mapping.
public struct ReferenceNegateFloat32: ImageOperation {
    public typealias Input = ReferenceNegateFloat32Input
    public typealias Output = ReferenceNegateFloat32Output

    public static let pixelDomain = PixelRepresentationDomain(
        layouts: [.interleaved],
        interpretations: [.scientific],
        channelRoles: [.intensity]
    )

    public static let specification = OperationSpecification<Input, Output>(
        identifier: OperationIdentifier(
            rawValue: "image-processing.reference.negate-float32"
        )!,
        semanticVersion: SemanticVersion(major: 1, minor: 0, patch: 0)!,
        layerContract: OperationLayerContract(
            acceptedInputKinds: [.raster],
            producedOutputKinds: [.raster]
        ),
        pixelDataContract: OperationPixelDataContract(
            input: pixelDomain,
            output: pixelDomain
        )
    )

    public init() {}

    public func resourcePlan(
        for input: ReferenceNegateFloat32Input
    ) throws -> OperationResourcePlan {
        let source = try Self.source(for: input)
        let alignment = max(source.plane.requiredAlignmentBytes, 4)
        return try OperationResourcePlan(resources: [
            OperationResourcePlanRequirement(
                role: .output(0),
                minimumCapacityBytes: source.pixels.minimumRequiredStorageBytes,
                minimumAlignmentBytes: alignment
            )
        ])
    }

    public func workload(
        for input: ReferenceNegateFloat32Input
    ) -> OperationWorkload? {
        guard let source = try? Self.source(for: input) else { return nil }
        let extent = source.pixels.extent
        let (xy, overflowXY) = extent.width.multipliedReportingOverflow(by: extent.height)
        let (xyz, overflowXYZ) = xy.multipliedReportingOverflow(by: extent.depth)
        guard !overflowXY, !overflowXYZ else { return nil }
        return OperationWorkload(workItemCount: xyz)
    }

    public func validateOutput(
        _ output: ReferenceNegateFloat32Output,
        for input: ReferenceNegateFloat32Input
    ) throws {
        let source = try Self.source(for: input)
        let expectedRevision = try source.input.imageState.revision.next()
        let outputDescriptor = output.imageOperationOutputDescriptor
        guard outputDescriptor.imageState.identifier == source.input.imageState.identifier,
              outputDescriptor.imageState.revision == expectedRevision,
              outputDescriptor.producedLayers.contains(source.reference) else {
            throw OperationOutputValidationError.operationPostconditionFailed(
                "negated raster output must advance the exact source image revision and replace the selected layer"
            )
        }
        guard let outputLayer = try outputDescriptor.document.layer(for: source.reference),
              case let .raster(outputPixels) = outputLayer.content,
              outputPixels == source.pixels else {
            throw OperationOutputValidationError.operationPostconditionFailed(
                "negated raster output must preserve the source pixel descriptor and layer identity"
            )
        }
    }

    static func source(
        for input: ReferenceNegateFloat32Input
    ) throws -> ReferenceNegateFloat32Source {
        let context = input.imageOperationInputContext
        guard context.inputs.count == 1,
              let source = context.input(at: 0),
              source.target.layerReferences.count == 1 else {
            throw ReferenceNegateFloat32Error.missingImageInput
        }
        let reference = source.target.layerReferences[0]
        guard let layer = try source.imageState.document.layer(for: reference) else {
            throw ReferenceNegateFloat32Error.missingLayer(reference)
        }
        guard case let .raster(pixels) = layer.content else {
            throw ReferenceNegateFloat32Error.nonRasterLayer(reference)
        }
        guard pixels.componentType == .float32,
              pixels.channels.count == 1,
              pixels.channels[0].role == .intensity,
              case .scientific = pixels.interpretation,
              case let .interleaved(plane) = pixels.layout,
              plane.channelIndices == [0],
              plane.pixelStrideBytes >= 4 else {
            throw ReferenceNegateFloat32Error.unsupportedPixelRepresentation
        }
        let storage = try source.imageState.storageBindings.binding(for: reference)
        guard let storage else {
            throw ReferenceNegateFloat32Error.missingStorageBinding(reference)
        }
        guard storage.planeBindings.count == 1,
              storage.planeBindings[0].planeIndices == [0] else {
            throw ReferenceNegateFloat32Error.invalidPlaneBinding
        }

        return ReferenceNegateFloat32Source(
            input: source,
            layer: layer,
            pixels: pixels,
            plane: plane,
            storage: storage,
            reference: reference
        )
    }
}

public struct ReferenceNegateFloat32Input: ImageOperationInputValue {
    public static let typeIdentifier = OperationValueIdentifier(
        rawValue: "image-processing.reference.negate-float32.input"
    )!

    public let imageOperationInputContext: ImageOperationInputContext

    public init(imageOperationInputContext: ImageOperationInputContext) {
        self.imageOperationInputContext = imageOperationInputContext
    }
}

public struct ReferenceNegateFloat32Output: ImageOperationOutputValue {
    public static let typeIdentifier = OperationValueIdentifier(
        rawValue: "image-processing.reference.negate-float32.output"
    )!

    public let imageOperationOutputDescriptor: ImageOperationOutputDescriptor

    public init(imageOperationOutputDescriptor: ImageOperationOutputDescriptor) {
        self.imageOperationOutputDescriptor = imageOperationOutputDescriptor
    }
}

/// CPU implementation of the reference negation operation. It uses the
/// provider-owned buffer API and performs a scalar pass; no platform-specific
/// SIMD or threading policy is part of this reference implementation.
public struct CPUReferenceNegateFloat32Implementation: ImageOperationImplementation {
    public typealias Operation = ReferenceNegateFloat32

    public let specification: ImplementationSpecification

    public init() {
        let lower = SemanticVersion(major: 1, minor: 0, patch: 0)!
        let upper = SemanticVersion(major: 2, minor: 0, patch: 0)!
        specification = ImplementationSpecification(
            identifier: OperationImplementationIdentifier(
                rawValue: "image-processing.reference.cpu.negate-float32"
            )!,
            version: lower,
            operationIdentifier: ReferenceNegateFloat32.specification.identifier,
            supportedOperationVersions: SemanticVersionRange(
                lowerBound: lower,
                upperBound: upper
            )!,
            inputType: ReferenceNegateFloat32Input.typeIdentifier,
            outputType: ReferenceNegateFloat32Output.typeIdentifier,
            layerSupport: ImplementationLayerSupport(
                inputKinds: [.raster],
                outputKinds: [.raster]
            ),
            pixelDataSupport: OperationPixelDataContract(
                input: ReferenceNegateFloat32.pixelDomain,
                output: ReferenceNegateFloat32.pixelDomain
            ),
            resourceRequirements: [
                ImplementationResourceRequirement(
                    role: .input(0),
                    kind: .buffer,
                    allowedMemoryDomains: [.host],
                    minimumCapacityBytes: 1,
                    access: .read
                ),
                ImplementationResourceRequirement(
                    role: .output(0),
                    kind: .buffer,
                    allowedMemoryDomains: [.host],
                    minimumCapacityBytes: 1,
                    minimumAlignmentBytes: 4,
                    access: .write
                )
            ]
        )
    }

    public func execute(
        operation: ReferenceNegateFloat32,
        input: ReferenceNegateFloat32Input,
        context: any ExecutionContext
    ) async throws -> ReferenceNegateFloat32Output {
        throw ImageOperationExecutionError.implementationDoesNotConsumeAllocatedResources
    }

    public func execute(
        operation: ReferenceNegateFloat32,
        input: ReferenceNegateFloat32Input,
        context: any ExecutionContext,
        resources: OperationExecutionResources
    ) async throws -> ReferenceNegateFloat32Output {
        let source = try ReferenceNegateFloat32.source(for: input)
        let originalResource = source.storage.planeBindings[0].resource
        let importedBindings = resources.importedInputResources(for: 0)
        let inputResource: CPUBufferResource
        if importedBindings.isEmpty {
            guard let cpuResource = originalResource as? CPUBufferResource else {
                throw ReferenceNegateFloat32Error.inputResourceIsNotCPUBuffer
            }
            inputResource = cpuResource
        } else {
            guard importedBindings.count == 1,
                  let cpuResource = importedBindings.first?.resource as? CPUBufferResource else {
                throw ReferenceNegateFloat32Error.inputResourceIsNotCPUBuffer
            }
            inputResource = cpuResource
        }
        guard let outputResource = resources.resource(for: .output(0)) as? CPUBufferResource else {
            throw ReferenceNegateFloat32Error.outputResourceIsNotCPUBuffer
        }

        let inputBytes = inputResource.copyBytes()
        guard let outputByteCount = Int(exactly: source.pixels.minimumRequiredStorageBytes),
              outputByteCount > 0,
              inputBytes.count >= outputByteCount,
              outputResource.descriptor.capacityBytes >= source.pixels.minimumRequiredStorageBytes else {
            throw ReferenceNegateFloat32Error.pixelBufferTooSmall
        }
        var outputBytes = Array(inputBytes.prefix(outputByteCount))
        try Self.negateSamples(
            in: &outputBytes,
            extent: source.pixels.extent,
            plane: source.plane
        )
        try outputResource.writeBytes(outputBytes)

        let outputPixels = source.pixels
        let outputLayer = LayerDescriptor(
            identifier: source.layer.identifier,
            properties: source.layer.properties,
            content: .raster(outputPixels),
            spatialMapping: source.layer.spatialMapping
        )
        let outputLayers = source.input.imageState.document.layers.map { layer in
            layer.identifier == source.layer.identifier ? outputLayer : layer
        }
        let nextRevision = try source.input.imageState.revision.next()
        let outputDocument = try ImageDocumentSnapshot(
            identifier: source.input.imageState.identifier,
            revision: nextRevision,
            canvas: source.input.imageState.document.canvas,
            layers: outputLayers
        )

        let preservedBindings = source.input.imageState.storageBindings.layerBindings.filter {
            $0.reference != source.reference
        }
        let outputStorage = try PixelStorageBinding(
            descriptor: outputPixels,
            planeBindings: [
                PixelPlaneResourceBinding(
                    resource: outputResource,
                    planeIndices: [0],
                    access: .read
                )
            ]
        )
        let outputBindings = try ImageStorageBindingSet(
            snapshot: outputDocument,
            bindings: preservedBindings + [
                LayerPixelStorageBinding(
                    reference: source.reference,
                    storage: outputStorage
                )
            ]
        )
        let outputState = try ImageStateSnapshot(
            document: outputDocument,
            storageBindings: outputBindings
        )
        let outputDescriptor = try ImageOperationOutputDescriptor(
            imageState: outputState,
            producedLayers: [source.reference]
        )
        return ReferenceNegateFloat32Output(
            imageOperationOutputDescriptor: outputDescriptor
        )
    }

    private static func negateSamples(
        in bytes: inout [UInt8],
        extent: ImageExtent,
        plane: PixelPlaneLayout
    ) throws {
        for z in 0..<extent.depth {
            for y in 0..<extent.height {
                for x in 0..<extent.width {
                    let (zOffset, overflowZ) = z.multipliedReportingOverflow(
                        by: plane.sliceStrideBytes
                    )
                    let (yOffset, overflowY) = y.multipliedReportingOverflow(
                        by: plane.rowStrideBytes
                    )
                    let (xOffset, overflowX) = x.multipliedReportingOverflow(
                        by: plane.pixelStrideBytes
                    )
                    guard !overflowZ, !overflowY, !overflowX else {
                        throw ReferenceNegateFloat32Error.pixelOffsetOverflow
                    }
                    let (rowOffset, overflowRow) = plane.byteOffset.addingReportingOverflow(zOffset)
                    let (sliceOffset, overflowSlice) = rowOffset.addingReportingOverflow(yOffset)
                    let (offset, overflowOffset) = sliceOffset.addingReportingOverflow(xOffset)
                    let (end, overflowEnd) = offset.addingReportingOverflow(4)
                    guard !overflowRow, !overflowSlice, !overflowOffset, !overflowEnd,
                          let byteIndex = Int(exactly: offset),
                          let endIndex = Int(exactly: end),
                          endIndex <= bytes.count else {
                        throw ReferenceNegateFloat32Error.pixelOffsetOverflow
                    }

                    var bits: UInt32 = 0
                    withUnsafeMutableBytes(of: &bits) { destination in
                        for byte in 0..<4 {
                            destination[byte] = bytes[byteIndex + byte]
                        }
                    }
                    var negatedBits = (-Float(bitPattern: bits)).bitPattern
                    withUnsafeBytes(of: &negatedBits) { source in
                        for byte in 0..<4 {
                            bytes[byteIndex + byte] = source[byte]
                        }
                    }
                }
            }
        }
    }
}
