# Implementation Status

**Architecture baseline:** 0.3  
**Implementation plan:** 0.2  
**Current state:** SwiftPM protocol foundation, image-domain state/storage model, typed function composition, policy validation, and declarative operation/implementation compatibility contracts are implemented; heterogeneous runtime registration and execution are not.

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
- Test-only ExecutionProviderConformanceHarness validates provider/device ownership and duplicate IDs, visible and opaque targets, context-target identity, truthful optional capability claims, allocation/import descriptors, typed submission, and synchronization.

### ImageProcessingProtocol foundation

- Stable operation, implementation, parameter, option, and typed value identifiers.
- Typed operation values and associated input/output types; typed and erased operation specifications preserve the same semantic data.
- Named immutable operation parameter schemas and instance values, with required/optional entries, typed domains, duplicate/unknown/missing-value checks, and finite numeric bounds.
- Operation specifications declare independent input-storage, computation, accumulation, and output-storage precision domains. Storage component types and arithmetic precision are distinct types.
- Numerical contracts declare rounding, overflow, output-range behavior, determinism, and optional absolute/relative error tolerances.
- Effect contracts separate required operation effects from effects permitted to implementations, and separately state input-mutation and output-aliasing semantics.
- Layer contracts declare accepted and produced layer kinds. Pixel-backed raster/mask/label-map operations must declare input/output pixel representation domains; annotation-only operations do not invent pixel-storage constraints.
- Pixel representation domains describe layout, color/scientific interpretation, color model, alpha, transfer function, color-space identity, channel roles/order, subsampling, sample origins, and measurement units.
- One generic ImageOperationImplementation protocol, specialized by its associated operation type; the protocol has no per-implementation qualification hook.
- ImplementationSpecification statically validates operation identity/version/value types, parameter support subsets, precision support subsets, numerical guarantees, determinism, effects/mutation/aliasing, layer/pixel representation subsets, resource requirements, capability declarations, and optional cost hints.
- Implementation resource requirements declare input/output/temporary roles, generic resource kind, allowed memory domains, minimum capacity/alignment, access mode, and import requirements. Performance hints remain static estimates, not live load.
- Operation-instance preflight validates whether parameter values are legal for the operation. A value outside one implementation's narrower support rejects that candidate without invalidating the operation instance.
- Typed ImageFunction<Input,Output> sequential composition, typed identity function, direct operation append, and heterogeneous ordered step storage.
- OperationStepIdentifier identifies each step occurrence; reused right-hand functions are reidentified on composition while source identifiers remain available.
- Immutable QualificationPolicy keeps hard requirements separate from soft optimization objectives and scopes declarations to the pipeline or a concrete step occurrence.
- Policy validation checks provider/precision set intersections over effective scopes, execution-capability type contradictions, same-scope preference conflicts, invalid weights, step identity, and precision applicability.
- Step-scoped policy declarations are rebased when a right-hand function is composed and its step occurrences receive new identifiers.

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

The current test suite covers generic provider/device/context capabilities, provider/environment snapshots, generic resource allocation/import contracts, typed asynchronous work/dependencies/cancellation/synchronization, typed operation implementation execution, typed ImageFunction composition and step rebasing, operation parameter schemas and values, precision-domain typing and applicability, numerical/effect/layer/pixel operation contracts, implementation support subset validation, parameter/precision/format/numerical/effect/resource/capability mismatch diagnostics, qualification-policy scope/conflicts/provenance, image/layer identity and snapshots, pixel channel/color/scientific descriptors, planar/volumetric storage calculations, centered/co-sited chroma origins, plane-to-layer coordinate conversion, pixel-resource topology/capacity/alignment binding, revision-scoped image/layer storage bindings, retained resource handles, label/mask/annotation semantics, layer spatial registration, affine transform validation, image replacement atomicity, stale revision rejection, concurrent writer conflict, and overflow.

Local verification performed on Swift 6.2.1, Linux x86_64:

- The last independently verified descriptor milestone passed swift build and swift test with 53 tests in 9 suites on Linux x86_64. Later binding-set and Image-state tests have not yet completed a green CI run.

GitHub Actions Swift 6.2.1 matrix previously passed on ubuntu-24.04 and macos-latest at commit 9b1f27318439199c5ee97b12d72838601e477688 with 22 tests in 4 suites. A later 53-test image-domain/spatial/chroma-siting suite was locally verified on Linux. The current suite contains 167 tests across 12 Swift test files, plus one shared provider-conformance support file. Coverage includes generic resource lifecycle and provider conformance, typed function composition, operation/implementation support compatibility, numerical/effect/pixel contracts, qualification-policy validation, revision-scoped layer bindings, and mutable Image concurrency. GitHub Actions passed swift build and all 108 tests across 15 suites on ubuntu-24.04 at source commit f036e11bc6253708d9c12d5d74e60760a94f1649. The corresponding macOS job had not completed at that source revision. The current 161-test suite adds parameter-domain, operation semantic-contract, implementation support, numerical conformance, pixel-representation, and resource/capability validation tests. The 153-test predecessor compiled but exposed three test-fixture mismatches; those fixtures and subsequent edge cases have been corrected. The current 167-test revision, including the provider conformance harness, is awaiting CI. The initial macOS failure exposed Date.now availability (macOS 12+); replacing the defaults with Date() resolved it.

## Not implemented

- Non-affine spatial deformation fields and calibrated world-coordinate transform model.
- Concrete provider implementations of resource allocation/import/export, residency transitions, and safe native release.
- Provider conformance tests proving resource retention through asynchronous work, cancellation, device loss, and failure.
- Provider discovery aggregation and runtime registry.
- Operation implementation registry and safe type-erased execution dispatch.
- Common environment-aware resolver and end-to-end cost ranking.
- Execution planner, resource reservation/revalidation, and execution coordinator.
- CPU provider and numerical reference image operations.
- Metal, CUDA, OpenCL, Direct3D 12, Vulkan, OpenCV, Core Image, Accelerate, or model-runtime implementation packs.

## Phase state

| Phase | State | Reason |
|---|---|---|
| 0 — Architecture decisions | In progress | Decision register exists; image concurrency, layer identity, target platform matrix, and per-operation color policy remain proposed/open. |
| 1 — Operation/implementation contracts | In progress | Typed operation schemas, parameter validation, precision/numerical/effect/layer/pixel semantics, implementation support subsets, static resource requirements, and compatibility validation are implemented. Qualification result vocabulary and representative multi-implementation operation examples remain. |
| 2 — GeneralExecutionProtocol | In progress | Generic resource/work lifecycle contracts and a reusable test-only conformance harness are implemented and exercised against an in-memory provider; standardized provider/device failure semantics and a production provider remain. |
| 3 — ImageProcessingProtocol core | In progress | Image/document/resource descriptors, atomic Image state, typed ImageFunction composition, validated QualificationPolicy, and static operation/implementation conformance contracts are implemented; heterogeneous type-erased registration and function execution remain. |
| 4–9 | Not started | Depend on the preceding contracts and runtime. |

## Next implementation order

1. Define structured provider/device failure categories, including device loss, allocation/import, submission, synchronization, and recoverability; preserve native details without exposing native types in the common API.
2. Implement the private type-erased operation-implementation registry while preserving associated-type dispatch at the typed boundary; prove that independent CPU/Metal classes can register for one operation without modifying the core.
3. Complete provider registry/discovery and environment snapshot aggregation from provider/device observations plus runtime-owned outstanding-work accounting.
4. Implement the common resolver: static specification eligibility first, context preparation/validation second, then ranking of eligible candidates using fresh state and whole-path cost.
5. Implement the execution planner and coordinator, including resource request construction, reservation/revalidation, synchronization, cancellation, and structured failure recovery.
6. Add a CPU provider and a small numerical reference operation as the first end-to-end vertical slice; only then add GPU and managed-runtime adapters.
