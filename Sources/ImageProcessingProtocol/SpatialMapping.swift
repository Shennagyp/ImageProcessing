/// A point expressed in the image document's canvas index coordinate system.
/// Integer coordinates refer to sample centres, not pixel-cell corners.
public struct CanvasIndexCoordinate: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init?(x: Double, y: Double, z: Double = 0) {
        guard x.isFinite, y.isFinite, z.isFinite else { return nil }
        self.x = x
        self.y = y
        self.z = z
    }
}

public enum LayerSpatialMappingError: Error, Equatable, Sendable {
    case invalidElementCount(expected: Int, actual: Int)
    case nonFiniteElement(index: Int)
    case invalidAffineLastRow
    case singularLinearTransform
    case nonFiniteMappedCoordinate
}

/// Maps layer sample-centre index coordinates into image-canvas sample-centre
/// index coordinates. The matrix is a row-major 4x4 affine transform using
/// column-vector multiplication. It is geometric metadata only: it does not
/// resample pixel data or change the operation's interpolation semantics.
public struct LayerSpatialMapping: Hashable, Sendable {
    public let rowMajorValues: [Double]

    public init(rowMajorValues: [Double]) throws {
        guard rowMajorValues.count == 16 else {
            throw LayerSpatialMappingError.invalidElementCount(
                expected: 16,
                actual: rowMajorValues.count
            )
        }
        for (index, value) in rowMajorValues.enumerated() where !value.isFinite {
            throw LayerSpatialMappingError.nonFiniteElement(index: index)
        }
        guard rowMajorValues[12] == 0,
              rowMajorValues[13] == 0,
              rowMajorValues[14] == 0,
              rowMajorValues[15] == 1 else {
            throw LayerSpatialMappingError.invalidAffineLastRow
        }

        let a = rowMajorValues[0], b = rowMajorValues[1], c = rowMajorValues[2]
        let d = rowMajorValues[4], e = rowMajorValues[5], f = rowMajorValues[6]
        let g = rowMajorValues[8], h = rowMajorValues[9], i = rowMajorValues[10]
        let scale = [abs(a), abs(b), abs(c), abs(d), abs(e), abs(f), abs(g), abs(h), abs(i)].max() ?? 0
        guard scale > 0 else { throw LayerSpatialMappingError.singularLinearTransform }

        // Normalize before evaluating the determinant. This avoids overflow for
        // large finite transforms and keeps the singularity threshold relative
        // to the linear part's own scale (so small valid voxel scales survive).
        let na = a / scale, nb = b / scale, nc = c / scale
        let nd = d / scale, ne = e / scale, nf = f / scale
        let ng = g / scale, nh = h / scale, ni = i / scale
        let determinant = na * (ne * ni - nf * nh)
            - nb * (nd * ni - nf * ng)
            + nc * (nd * nh - ne * ng)
        guard determinant.isFinite, abs(determinant) > 1e-12 else {
            throw LayerSpatialMappingError.singularLinearTransform
        }

        self.rowMajorValues = rowMajorValues
    }

    public static let identity = try! LayerSpatialMapping(rowMajorValues: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ])

    public func mapToCanvas(_ coordinate: CanvasIndexCoordinate) throws -> CanvasIndexCoordinate {
        let m = rowMajorValues
        let x = m[0] * coordinate.x + m[1] * coordinate.y + m[2] * coordinate.z + m[3]
        let y = m[4] * coordinate.x + m[5] * coordinate.y + m[6] * coordinate.z + m[7]
        let z = m[8] * coordinate.x + m[9] * coordinate.y + m[10] * coordinate.z + m[11]
        guard let mapped = CanvasIndexCoordinate(x: x, y: y, z: z) else {
            throw LayerSpatialMappingError.nonFiniteMappedCoordinate
        }
        return mapped
    }
}
