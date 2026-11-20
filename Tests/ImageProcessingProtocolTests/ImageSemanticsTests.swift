import Testing
import ImageProcessingProtocol

struct ImageIdentityTests {
    @Test
    func layerReferenceIsScopedToImageIdentity() throws {
        let imageA = try #require(ImageIdentifier(rawValue: "image.a"))
        let imageB = try #require(ImageIdentifier(rawValue: "image.b"))
        let layerID = try #require(LayerIdentifier(rawValue: "layer.original"))
        let referenceA = LayerReference(imageID: imageA, layerID: layerID)
        let referenceB = LayerReference(imageID: imageB, layerID: layerID)

        #expect(referenceA != referenceB)
        #expect(referenceA.layerID == referenceB.layerID)
    }

    @Test
    func imageRevisionIsMonotonicAndDetectsExhaustion() throws {
        #expect(try ImageRevision.initial.next() == ImageRevision(rawValue: 1))
        #expect(throws: ImageRevisionError.exhausted) {
            try ImageRevision(rawValue: .max).next()
        }
    }

    @Test
    func imageExtentRejectsEmptyDimensions() {
        #expect(ImageExtent(width: 0, height: 10) == nil)
        #expect(ImageExtent(width: 10, height: 0) == nil)
        #expect(ImageExtent(width: 10, height: 10, depth: 0) == nil)
        #expect(ImageExtent(width: 10, height: 10, depth: 2) != nil)
    }
}

struct PixelDescriptorTests {
    private func colorChannel(
        _ id: String,
        _ role: PixelChannelRole
    ) throws -> PixelChannelDescriptor {
        PixelChannelDescriptor(identifier: try #require(ChannelIdentifier(rawValue: id)), role: role)
    }

    private func rgbDescriptor(
        extent: ImageExtent? = ImageExtent(width: 3, height: 2),
        layout: PixelStorageLayout? = nil,
        alpha: Bool = false
    ) throws -> PixelDataDescriptor {
        var channels = [
            try colorChannel("r", .red),
            try colorChannel("g", .green),
            try colorChannel("b", .blue)
        ]
        if alpha { channels.append(try colorChannel("a", .alpha)) }
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: 16,
            sliceStrideBytes: 32,
            pixelStrideBytes: alpha ? 4 : 3,
            subsampling: try #require(PixelSubsampling()),
            channelIndices: Array(0..<channels.count)
        )
        return try PixelDataDescriptor(
            extent: try #require(extent),
            componentType: .uint8,
            channels: channels,
            interpretation: .color(ColorDataInterpretation(
                colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                channelModel: .rgb,
                transferFunction: .sRGB,
                alphaMode: alpha ? .straight : .none
            )),
            layout: layout ?? .interleaved(plane)
        )
    }

    @Test
    func packedRGBDescriptorCalculatesMinimumStorage() throws {
        let descriptor = try rgbDescriptor()
        #expect(descriptor.channels.count == 3)
        #expect(descriptor.minimumRequiredStorageBytes == 25)
        try descriptor.validateStorageCapacity(25)
        #expect(throws: PixelDataDescriptorError.storageCapacityTooSmall(required: 25, actual: 24)) {
            try descriptor.validateStorageCapacity(24)
        }
    }

    @Test
    func colorAlphaModeMustMatchChannelPresence() throws {
        let channels = [
            try colorChannel("r", .red),
            try colorChannel("g", .green),
            try colorChannel("b", .blue)
        ]
        let plane = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 12, sliceStrideBytes: 12,
            pixelStrideBytes: 3, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0, 1, 2]
        )

        #expect(throws: PixelDataDescriptorError.alphaModeMismatch) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 4, height: 1)),
                componentType: .uint8,
                channels: channels,
                interpretation: .color(ColorDataInterpretation(
                    colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                    channelModel: .rgb,
                    transferFunction: .sRGB,
                    alphaMode: .premultiplied
                )),
                layout: .interleaved(plane)
            )
        }
    }

    @Test
    func colorInterpretationRejectsIncompleteRGBModel() throws {
        let channels = [
            try colorChannel("r", .red),
            try colorChannel("g", .green)
        ]
        let plane = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 8, sliceStrideBytes: 8,
            pixelStrideBytes: 2, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0, 1]
        )

        #expect(throws: PixelDataDescriptorError.invalidColorChannelRoles) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 4, height: 1)),
                componentType: .uint8,
                channels: channels,
                interpretation: .color(ColorDataInterpretation(
                    colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                    channelModel: .rgb,
                    transferFunction: .sRGB,
                    alphaMode: .none
                )),
                layout: .interleaved(plane)
            )
        }
    }

    @Test
    func planarSubsampledYUVLayoutComputesStorageAcrossPlanes() throws {
        let channels = [
            try colorChannel("y", .luma),
            try colorChannel("u", .chromaBlue),
            try colorChannel("v", .chromaRed)
        ]
        let yPlane = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 5, sliceStrideBytes: 15,
            pixelStrideBytes: 1, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        let uPlane = PixelPlaneLayout(
            byteOffset: 15, rowStrideBytes: 3, sliceStrideBytes: 6,
            pixelStrideBytes: 1, subsampling: try #require(PixelSubsampling(x: 2, y: 2)),
            channelIndices: [1]
        )
        let vPlane = PixelPlaneLayout(
            byteOffset: 21, rowStrideBytes: 3, sliceStrideBytes: 6,
            pixelStrideBytes: 1, subsampling: try #require(PixelSubsampling(x: 2, y: 2)),
            channelIndices: [2]
        )
        let descriptor = try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 5, height: 3)),
            componentType: .uint8,
            channels: channels,
            interpretation: .color(ColorDataInterpretation(
                colorSpace: try #require(ColorSpaceIdentifier(rawValue: "bt709")),
                channelModel: .yCbCr,
                transferFunction: .rec709,
                alphaMode: .none
            )),
            layout: .planar([yPlane, uPlane, vPlane])
        )

        #expect(descriptor.minimumRequiredStorageBytes == 27)
        try descriptor.validateStorageCapacity(27)
    }

    @Test
    func interleavedChannelOrderCanDifferFromSemanticChannelOrder() throws {
        let channels = [
            try colorChannel("red", .red),
            try colorChannel("green", .green),
            try colorChannel("blue", .blue)
        ]
        let bgr = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 12, sliceStrideBytes: 12,
            pixelStrideBytes: 3, subsampling: try #require(PixelSubsampling()),
            channelIndices: [2, 1, 0]
        )
        let descriptor = try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 4, height: 1)),
            componentType: .uint8,
            channels: channels,
            interpretation: .color(ColorDataInterpretation(
                colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                channelModel: .rgb,
                transferFunction: .sRGB,
                alphaMode: .none
            )),
            layout: .interleaved(bgr)
        )
        #expect(descriptor.minimumRequiredStorageBytes == 12)
    }

    @Test
    func customColorModelCanDescribeNonRGBColorEncodings() throws {
        let channels = [
            try colorChannel("c", .custom("cyan")),
            try colorChannel("m", .custom("magenta")),
            try colorChannel("y", .custom("yellow")),
            try colorChannel("k", .custom("black"))
        ]
        let plane = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 16, sliceStrideBytes: 16,
            pixelStrideBytes: 4, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0, 1, 2, 3]
        )
        let descriptor = try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 4, height: 1)),
            componentType: .uint8,
            channels: channels,
            interpretation: .color(ColorDataInterpretation(
                colorSpace: try #require(ColorSpaceIdentifier(rawValue: "device-cmyk")),
                channelModel: .custom("cmyk"),
                transferFunction: .linear,
                alphaMode: .none
            )),
            layout: .interleaved(plane)
        )
        #expect(descriptor.channels.count == 4)
    }

    @Test
    func planeMappingsMustCoverEveryChannelExactlyOnce() throws {
        let channels = [
            try colorChannel("r", .red),
            try colorChannel("g", .green),
            try colorChannel("b", .blue)
        ]
        let duplicate = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 9, sliceStrideBytes: 9,
            pixelStrideBytes: 3, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0, 1, 1]
        )
        #expect(throws: PixelDataDescriptorError.duplicateChannelMapping(1)) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 3, height: 1)),
                componentType: .uint8,
                channels: channels,
                interpretation: .color(ColorDataInterpretation(
                    colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                    channelModel: .rgb,
                    transferFunction: .sRGB,
                    alphaMode: .none
                )),
                layout: .planar([duplicate])
            )
        }

        let missing = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 6, sliceStrideBytes: 6,
            pixelStrideBytes: 2, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0, 1]
        )
        #expect(throws: PixelDataDescriptorError.missingChannelMapping(2)) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 3, height: 1)),
                componentType: .uint8,
                channels: channels,
                interpretation: .color(ColorDataInterpretation(
                    colorSpace: try #require(ColorSpaceIdentifier(rawValue: "srgb")),
                    channelModel: .rgb,
                    transferFunction: .sRGB,
                    alphaMode: .none
                )),
                layout: .planar([missing])
            )
        }
    }

    @Test
    func rowAndSliceStridesMustContainTheirPlanes() throws {
        let channels = [try colorChannel("i", .intensity)]
        let shortRow = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 2, sliceStrideBytes: 4,
            pixelStrideBytes: 1, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        let interpretation = PixelDataInterpretation.scientific(ScientificDataInterpretation())
        #expect(throws: PixelDataDescriptorError.rowStrideTooSmall(plane: 0, minimum: 3)) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 3, height: 2)),
                componentType: .uint8, channels: channels,
                interpretation: interpretation, layout: .interleaved(shortRow)
            )
        }

        let shortSlice = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 3, sliceStrideBytes: 5,
            pixelStrideBytes: 1, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        #expect(throws: PixelDataDescriptorError.sliceStrideTooSmall(plane: 0, minimum: 6)) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 3, height: 2, depth: 2)),
                componentType: .uint8, channels: channels,
                interpretation: interpretation, layout: .interleaved(shortSlice)
            )
        }
    }

    @Test
    func volumePlaneCalculatesSliceStorage() throws {
        let channel = try colorChannel("intensity", .intensity)
        let plane = PixelPlaneLayout(
            byteOffset: 8, rowStrideBytes: 16, sliceStrideBytes: 48,
            pixelStrideBytes: 4, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        let descriptor = try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 3, height: 2, depth: 2)),
            componentType: .float32,
            channels: [channel],
            interpretation: .scientific(ScientificDataInterpretation()),
            layout: .interleaved(plane)
        )
        #expect(descriptor.minimumRequiredStorageBytes == 84)
    }

    @Test
    func duplicateChannelIdentifiersAreRejected() throws {
        let id = try #require(ChannelIdentifier(rawValue: "duplicate"))
        let channels = [
            PixelChannelDescriptor(identifier: id, role: .intensity),
            PixelChannelDescriptor(identifier: id, role: .custom("second"))
        ]
        let plane = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 2, sliceStrideBytes: 2,
            pixelStrideBytes: 2, subsampling: try #require(PixelSubsampling()),
            channelIndices: [0, 1]
        )
        #expect(throws: PixelDataDescriptorError.duplicateChannelIdentifier(id)) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: 1, height: 1)),
                componentType: .uint8, channels: channels,
                interpretation: .scientific(ScientificDataInterpretation()),
                layout: .interleaved(plane)
            )
        }
    }

    @Test
    func storageSizeArithmeticRejectsOverflow() throws {
        let channel = PixelChannelDescriptor(
            identifier: try #require(ChannelIdentifier(rawValue: "large")),
            role: .intensity
        )
        let plane = PixelPlaneLayout(
            byteOffset: 0,
            rowStrideBytes: .max,
            sliceStrideBytes: .max,
            pixelStrideBytes: 8,
            subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        #expect(throws: PixelDataDescriptorError.arithmeticOverflow) {
            try PixelDataDescriptor(
                extent: try #require(ImageExtent(width: .max, height: 1)),
                componentType: .float64,
                channels: [channel],
                interpretation: .scientific(ScientificDataInterpretation()),
                layout: .interleaved(plane)
            )
        }
    }

    @Test
    func numericRangeRejectsNonFiniteOrReversedBounds() {
        #expect(NumericValueRange(minimum: .nan, maximum: 1) == nil)
        #expect(NumericValueRange(minimum: 0, maximum: .infinity) == nil)
        #expect(NumericValueRange(minimum: 2, maximum: 1) == nil)
    }
}

struct LayerDescriptorTests {
    private func singleChannelPixels(
        component: PixelComponentType = .float32,
        role: PixelChannelRole = .intensity,
        range: NumericValueRange? = nil
    ) throws -> PixelDataDescriptor {
        let channel = PixelChannelDescriptor(
            identifier: try #require(ChannelIdentifier(rawValue: "channel.0")),
            role: role,
            valueRange: range
        )
        let plane = PixelPlaneLayout(
            byteOffset: 0, rowStrideBytes: 8, sliceStrideBytes: 16,
            pixelStrideBytes: component.bytesPerComponent,
            subsampling: try #require(PixelSubsampling()),
            channelIndices: [0]
        )
        return try PixelDataDescriptor(
            extent: try #require(ImageExtent(width: 2, height: 2)),
            componentType: component,
            channels: [channel],
            interpretation: .scientific(ScientificDataInterpretation()),
            layout: .interleaved(plane)
        )
    }

    @Test
    func masksRequireSingleScientificChannel() throws {
        let pixels = try singleChannelPixels(range: NumericValueRange(minimum: 0, maximum: 1))
        let mask = try MaskDataDescriptor(pixels: pixels, semantics: .probability)
        #expect(mask.semantics == .probability)

        let invalidRangePixels = try singleChannelPixels(range: NumericValueRange(minimum: -1, maximum: 2))
        #expect(throws: LayerContentDescriptorError.maskRangeMustBeUnitInterval) {
            try MaskDataDescriptor(pixels: invalidRangePixels, semantics: .coverage)
        }
    }

    @Test
    func labelMapsRequireSingleIntegerChannel() throws {
        let labelSet = try #require(LabelSetIdentifier(rawValue: "cell-classes.v1"))
        let integerPixels = try singleChannelPixels(component: .uint16, role: .labelIdentifier)
        let descriptor = try LabelMapDataDescriptor(pixels: integerPixels, labelSet: labelSet)
        #expect(descriptor.labelSet == labelSet)

        let floatPixels = try singleChannelPixels(component: .float32, role: .labelIdentifier)
        #expect(throws: LayerContentDescriptorError.labelMapRequiresOneIntegerChannel) {
            try LabelMapDataDescriptor(pixels: floatPixels, labelSet: labelSet)
        }
    }

    @Test
    func annotationDescriptorCarriesExplicitCoordinateSpace() throws {
        let schema = try #require(AnnotationSchemaIdentifier(rawValue: "microscopy.contour.v1"))
        let world = try #require(CoordinateSystemIdentifier(rawValue: "stage-microns"))
        let descriptor = AnnotationDataDescriptor(schema: schema, coordinateSpace: .world(world))
        let layer = LayerDescriptor(
            identifier: try #require(LayerIdentifier(rawValue: "contours")),
            content: .annotation(descriptor)
        )
        #expect(layer.kind == .annotation)
    }

    @Test
    func imageDocumentRejectsDuplicateLayerIdentifiers() throws {
        let imageID = try #require(ImageIdentifier(rawValue: "document.1"))
        let layerID = try #require(LayerIdentifier(rawValue: "layer.same"))
        let pixels = try singleChannelPixels()
        let layerA = LayerDescriptor(identifier: layerID, content: .raster(pixels))
        let layerB = LayerDescriptor(identifier: layerID, content: .mask(
            try MaskDataDescriptor(pixels: pixels, semantics: .binary)
        ))
        let canvas = ImageCanvasDescriptor(extent: try #require(ImageExtent(width: 2, height: 2)))

        #expect(throws: ImageDocumentSnapshotError.duplicateLayerIdentifier(layerID)) {
            try ImageDocumentSnapshot(identifier: imageID, canvas: canvas, layers: [layerA, layerB])
        }
    }

    @Test
    func imageDocumentResolvesOnlyReferencesFromItsOwnIdentity() throws {
        let imageID = try #require(ImageIdentifier(rawValue: "document.1"))
        let layerID = try #require(LayerIdentifier(rawValue: "raster.main"))
        let pixels = try singleChannelPixels()
        let layer = LayerDescriptor(identifier: layerID, content: .raster(pixels))
        let canvas = ImageCanvasDescriptor(extent: try #require(ImageExtent(width: 2, height: 2)))
        let snapshot = try ImageDocumentSnapshot(identifier: imageID, canvas: canvas, layers: [layer])

        #expect(try snapshot.layer(for: layer.reference(in: imageID)) == layer)
        let foreignID = try #require(ImageIdentifier(rawValue: "document.other"))
        let foreignReference = LayerReference(imageID: foreignID, layerID: layerID)
        #expect(throws: ImageDocumentSnapshotError.foreignLayerReference(
            expectedImage: imageID,
            actualImage: foreignID
        )) {
            try snapshot.layer(for: foreignReference)
        }
        #expect(try snapshot.layer(for: LayerReference(imageID: imageID, layerID: try #require(LayerIdentifier(rawValue: "missing")))) == nil)
    }

    @Test
    func layerOpacityMustBeFiniteAndWithinUnitInterval() {
        #expect(LayerProperties(opacity: .nan) == nil)
        #expect(LayerProperties(opacity: -0.1) == nil)
        #expect(LayerProperties(opacity: 1.1) == nil)
        #expect(LayerProperties(opacity: 0) != nil)
        #expect(LayerProperties(opacity: 1) != nil)
    }
}
