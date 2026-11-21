import Foundation

public enum ImageStateSnapshotError: Error, Equatable, Sendable {
    case storageBindingSetMismatch
}

/// Immutable capture of a document revision and the storage resources associated
/// with that exact revision. Holding this value retains its resource bindings
/// independently of later Image replacements.
public struct ImageStateSnapshot: Sendable {
    public let document: ImageDocumentSnapshot
    public let storageBindings: ImageStorageBindingSet

    public var identifier: ImageIdentifier { document.identifier }
    public var revision: ImageRevision { document.revision }

    public init(
        document: ImageDocumentSnapshot,
        storageBindings: ImageStorageBindingSet
    ) throws {
        guard storageBindings.imageID == document.identifier,
              storageBindings.revision == document.revision else {
            throw ImageStateSnapshotError.storageBindingSetMismatch
        }
        self.document = document
        self.storageBindings = storageBindings
    }
}

public enum ImageError: Error, Equatable, Sendable {
    case revisionConflict(expected: ImageRevision, actual: ImageRevision)
    case replacementImageIdentifierMismatch(expected: ImageIdentifier, actual: ImageIdentifier)
    case replacementRevisionMismatch(expected: ImageRevision, actual: ImageRevision)
}

/// Thread-safe mutable owner of one logical image document.
///
/// Reads capture an immutable ImageStateSnapshot under a short lock. Processing
/// must happen after that read returns, never while this lock is held. A
/// replacement builds and validates its candidate state outside the lock, then
/// publishes document plus resource bindings atomically using revision compare-and-swap.
/// Old snapshots keep their resources alive until their own lifetimes end.
public final class Image: @unchecked Sendable {
    public let identifier: ImageIdentifier

    private let stateLock = NSLock()
    private var currentState: ImageStateSnapshot

    public init(
        identifier: ImageIdentifier = .generate(),
        canvas: ImageCanvasDescriptor,
        layers: [LayerDescriptor],
        storageBindings: [LayerPixelStorageBinding] = []
    ) throws {
        let document = try ImageDocumentSnapshot(
            identifier: identifier,
            revision: .initial,
            canvas: canvas,
            layers: layers
        )
        let bindingSet = try ImageStorageBindingSet(
            snapshot: document,
            bindings: storageBindings
        )
        let state = try ImageStateSnapshot(
            document: document,
            storageBindings: bindingSet
        )

        self.identifier = identifier
        self.currentState = state
    }

    public init(
        snapshot: ImageDocumentSnapshot,
        storageBindings: [LayerPixelStorageBinding] = []
    ) throws {
        let bindingSet = try ImageStorageBindingSet(
            snapshot: snapshot,
            bindings: storageBindings
        )
        let state = try ImageStateSnapshot(
            document: snapshot,
            storageBindings: bindingSet
        )

        self.identifier = snapshot.identifier
        self.currentState = state
    }

    /// Adopts an already-validated image state without rebuilding or detaching
    /// its revision-matched storage bindings. This is the ownership path for
    /// operation results that create a new logical Image.
    public init(snapshot: ImageStateSnapshot) {
        self.identifier = snapshot.identifier
        self.currentState = snapshot
    }

    /// Captures a consistent immutable document/resource snapshot.
    /// The lock is held only while copying value/reference ownership.
    public func snapshot() -> ImageStateSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    /// Replaces the logical document content while preserving Image identity.
    ///
    /// The expected revision must match both before candidate construction and
    /// at commit time. A concurrent replacement wins at most once; stale work
    /// receives a revisionConflict and is never silently replayed or overwritten.
    ///
    /// Candidate validation occurs outside the state lock. The only locked
    /// mutation is the final atomic publication of document plus bindings.
    @discardableResult
    public func replace(
        expectedRevision: ImageRevision,
        canvas: ImageCanvasDescriptor,
        layers: [LayerDescriptor],
        storageBindings: [LayerPixelStorageBinding] = []
    ) throws -> ImageStateSnapshot {
        let observed = snapshot()
        guard observed.revision == expectedRevision else {
            throw ImageError.revisionConflict(
                expected: expectedRevision,
                actual: observed.revision
            )
        }

        let nextRevision = try expectedRevision.next()
        let document = try ImageDocumentSnapshot(
            identifier: identifier,
            revision: nextRevision,
            canvas: canvas,
            layers: layers
        )
        let bindingSet = try ImageStorageBindingSet(
            snapshot: document,
            bindings: storageBindings
        )
        let candidate = try ImageStateSnapshot(
            document: document,
            storageBindings: bindingSet
        )

        stateLock.lock()
        defer { stateLock.unlock() }

        guard currentState.revision == expectedRevision else {
            throw ImageError.revisionConflict(
                expected: expectedRevision,
                actual: currentState.revision
            )
        }

        currentState = candidate
        return candidate
    }

    /// Publishes a fully prepared immutable image revision without unpacking or
    /// rebuilding its storage bindings. The candidate must belong to this Image
    /// and be exactly the next revision after expectedRevision.
    ///
    /// Candidate construction and resource ownership remain outside the lock;
    /// only the final revision check and state swap occur inside it.
    @discardableResult
    public func replace(
        expectedRevision: ImageRevision,
        with candidate: ImageStateSnapshot
    ) throws -> ImageStateSnapshot {
        guard candidate.identifier == identifier else {
            throw ImageError.replacementImageIdentifierMismatch(
                expected: identifier,
                actual: candidate.identifier
            )
        }

        let requiredRevision = try expectedRevision.next()
        guard candidate.revision == requiredRevision else {
            throw ImageError.replacementRevisionMismatch(
                expected: requiredRevision,
                actual: candidate.revision
            )
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        guard currentState.revision == expectedRevision else {
            throw ImageError.revisionConflict(
                expected: expectedRevision,
                actual: currentState.revision
            )
        }

        currentState = candidate
        return candidate
    }
}
