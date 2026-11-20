import Foundation

public struct ImageIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public static func generate() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }

    public var description: String { rawValue }
}

/// Layer identifiers are unique within an image document, not globally.
public struct LayerIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public static func generate() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }

    public var description: String { rawValue }
}

public struct LayerReference: Hashable, Sendable {
    public let imageID: ImageIdentifier
    public let layerID: LayerIdentifier

    public init(imageID: ImageIdentifier, layerID: LayerIdentifier) {
        self.imageID = imageID
        self.layerID = layerID
    }
}

public struct ImageRevision: RawRepresentable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let initial = Self(rawValue: 0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func next() throws -> Self {
        let (nextValue, overflow) = rawValue.addingReportingOverflow(1)
        guard !overflow else { throw ImageRevisionError.exhausted }
        return Self(rawValue: nextValue)
    }

    public var description: String { String(rawValue) }
}

public enum ImageRevisionError: Error, Equatable, Sendable {
    case exhausted
}

public struct ImageExtent: Hashable, Sendable {
    public let width: UInt64
    public let height: UInt64
    public let depth: UInt64

    public init?(width: UInt64, height: UInt64, depth: UInt64 = 1) {
        guard width > 0, height > 0, depth > 0 else { return nil }
        self.width = width
        self.height = height
        self.depth = depth
    }
}

public struct ImageCanvasDescriptor: Hashable, Sendable {
    public let extent: ImageExtent

    public init(extent: ImageExtent) {
        self.extent = extent
    }
}

public enum LayerKind: String, Hashable, Sendable {
    case raster
    case mask
    case labelMap
    case annotation
}
