# Implementation Status

**Architecture baseline:** 0.3  
**Implementation plan:** 0.2  
**Current state:** Initial SwiftPM protocol foundation plus image-domain identity and semantic descriptor layer; implementation is in progress.

This file records actual repository state. The architecture and implementation plan remain normative for intended behavior; a listed design or deliverable is not considered complete merely because a related type exists.

## Implemented

### Swift package boundary

- Root SwiftPM package uses Swift language mode 6.
- Separate library products exist for GeneralExecutionProtocol and ImageProcessingProtocol.
- ImageProcessingProtocol depends on GeneralExecutionProtocol; the reverse dependency does not exist.
- Core modules contain no Apple-framework or vendor-specific imports.

### GeneralExecutionProtocol foundation

- Stable provider, device, and capability identifiers.
- Semantic version and half-open version-range types.
- Generic provider/device capability values and declarative capability requirements.
- Capability requirements identify whether a feature must be reported by the provider, device, either, or the created execution context.
- Standard generic capability identifiers cover resource kinds, allocation/import, work submission/dependencies, synchronization, and peer transfer.
- Execution contexts expose context-local capabilities; optional context protocol conformance remains the executable contract.
- Provider and device descriptors.
- Provider-level and device-level availability/load snapshots.
- Dynamic observations explicitly distinguish known, stale, and unknown values. Known observations require a validity interval and source.
- An opaque execution-context contract and provider/device discovery contracts.
- Generic resource identifiers, target-scoped resource references, validated resource descriptors/requests, and allocation/import capability contracts.
- Resource access declarations with reference-counted handle semantics; imported handles retain their source.
- Typed work submission and completion contracts, dependency declarations, cancellation outcomes, and optional synchronization capability.
- Environment snapshots validate provider/device ownership and duplicate identities.
- A provider can represent an opaque managed execution target without exposing a device list.

### ImageProcessingProtocol foundation

- Stable operation and implementation identifiers.
- Typed operation values and associated input/output types.
- Operation specifications derive input/output value identifiers from their associated Swift types.
- One generic ImageOperationImplementation protocol, specialized by its associated operation type.
- Typed ImageFunction<Input,Output> sequential composition, typed identity function, direct operation append, and heterogeneous ordered step storage.
- OperationStepIdentifier identifies each step occurrence; reused right-hand functions are reidentified on composition while source identifiers remain available.
- Declarative implementation specifications describe operation/version compatibility, optional provider binding, and scoped generic capability requirements.
- The protocol has no per-implementation qualification hook.

### ImageProcessingProtocol image semantics

- Image and layer identifiers, with layer identity scoped to an image through LayerReference.
- Monotonic ImageRevision with explicit overflow detection.
- Immutable ImageDocumentSnapshot with canvas extent, ordered typed layers, duplicate-ID validation, foreign-reference rejection, and layer-to-canvas extent validation.
- LayerSpatialMapping with a checked invertible 4x4 affine map from layer sample-centre indices to canvas sample-centre indices. Same-grid layers use identity; different extents require an explicit map.
- Raster, mask, label-map, and annotation content descriptors with distinct semantic validation.
- PixelDataDescriptor with component precision, channel identities/roles, explicit color channel models (gray, RGB, YCbCr, custom), scientific interpretation, alpha mode, and optional channel value ranges.
- PixelStorageBinding assigns every pixel plane exactly once to one or more generic execution resources; it supports one shared allocation or separate per-plane allocations, validates each resource capacity, and retains all handles.
- ImageStorageBindingSet associates plane storage with layer references for one exact ImageIdentifier/ImageRevision, verifies descriptor identity, and reports unbound layers without rejecting non-resident document content.
- Image is a thread-safe reference-type state owner; synchronous snapshots pair immutable document state with its exact binding set.
- Image.replace performs candidate validation outside its short lock and commits document plus binding set atomically with revision compare-and-swap. Stale concurrent replacements fail explicitly.
- Interleaved and planar storage planes with byte offsets, row/pixel/slice strides, subsampling, explicit per-plane sample origin/chroma siting, required power-of-two base/row/slice alignment, plane-to-layer coordinate conversion, channel mappings, checked minimum-capacity computation, and overflow rejection.
- Mask semantics (binary, coverage, probability), integer label identifiers, and explicit annotation coordinate spaces.

### Tests

The current test suite covers identifiers/capabilities, provider/device/context capability scope, version/operation compatibility, provider snapshot integrity, unavailable/unknown/stale state, resource request validation, import retention, resource identity, work/resource retention through completion and cancellation, dependency ordering, provider context creation, typed implementation execution, image/layer identity and snapshots, pixel channel/color/scientific descriptors, planar/volumetric storage calculations, explicit centered/co-sited chroma origins, plane-to-layer coordinate conversion, pixel-resource topology/capacity/alignment binding, resource-handle retention, revision-scoped image/layer binding sets, partial-binding diagnostics, stable Image identity, atomic revision replacement, validation failure atomicity, concurrent writer conflict, captured-snapshot resource retention, label/mask/annotation semantics, layer spatial registration, affine transform validation, capacity validation, and overflow.

Local verification performed on Swift 6.2.1, Linux x86_64:

- The last independently verified descriptor milestone passed swift build and swift test with 53 tests in 9 suites on Linux x86_64. Later binding-set and Image-state tests have not yet completed a green CI run.

GitHub Actions Swift 6.2.1 matrix previously passed on ubuntu-24.04 and macos-latest at commit 9b1f27318439199c5ee97b12d72838601e477688 with 22 tests in 4 suites. A later 53-test image-domain/spatial/chroma-siting suite was locally verified on Linux. The current suite contains 86 tests across 13 suites, including pixel resource binding/alignment, revision-scoped layer bindings, and mutable Image concurrency tests; cross-platform CI is pending. An intervening CI test build caught a missing try in a test helper, which has been corrected. The initial macOS failure exposed Date.now availability (macOS 12+); replacing the defaults with Date() resolved it.

## Not implemented

- Non-affine spatial deformation fields and calibrated world-coordinate transform model.
- Concrete provider implementations of resource allocation/import/export, residency transitions, and safe native release.
- Provider conformance tests proving resource retention through asynchronous work, cancellation, device loss, and failure.
- Provider discovery aggregation and runtime registry.
- Operation implementation registry and safe type-erased execution dispatch.
- QualificationPolicy, fluent policy builder, scope composition, and conflict diagnostics.
- Common environment-aware resolver and end-to-end cost ranking.
- Execution planner, resource reservation/revalidation, and execution coordinator.
- CPU provider and numerical reference image operations.
- Metal, CUDA, OpenCL, Direct3D 12, Vulkan, OpenCV, Core Image, Accelerate, or model-runtime implementation packs.

## Phase state

| Phase | State | Reason |
|---|---|---|
| 0 — Architecture decisions | In progress | Decision register exists; image concurrency, layer identity, target platform matrix, and per-operation color policy remain proposed/open. |
| 1 — Operation/implementation contracts | In progress | Typed contract skeleton exists; semantic descriptors, numerical contracts, and complete implementation-support schema remain. |
| 2 — GeneralExecutionProtocol | In progress | Resource and asynchronous lifecycle contracts now exist; no complete provider implementation or provider conformance suite yet. |
| 3 — ImageProcessingProtocol core | In progress | Identity, immutable snapshot, layer-content, pixel semantic descriptors, affine layer-to-canvas registration, and pixel-plane resource binding are implemented; Image identity, immutable snapshots, and atomic revision/resource-set replacement are implemented; policy builder and runtime type-erased implementation registry remain. |
| 4–9 | Not started | Depend on the preceding contracts and runtime. |

## Next implementation order

1. Build a reusable test-only provider conformance harness for allocation/import, access retention, dependencies, completion, cancellation, and synchronization.
2. Bind PixelDataDescriptor/LayerDescriptor values to generic execution resources with explicit plane ownership and lifetime.
3. Complete typed function composition.
4. Add immutable qualification-policy values and construction/composition conflict validation.
5. Implement the runtime registry and common resolver only after the specification and environment models are sufficient to qualify real candidates.
6. Add a CPU provider and one small operation vertical slice before GPU providers.
