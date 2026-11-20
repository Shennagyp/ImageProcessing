# Implementation Status

**Architecture baseline:** 0.3  
**Implementation plan:** 0.2  
**Current state:** Initial SwiftPM protocol foundation; implementation is in progress.

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
- Capability requirements identify whether a feature must be reported by the provider, device, or either.
- Provider and device descriptors.
- Provider-level and device-level availability/load snapshots.
- Dynamic observations explicitly distinguish known, stale, and unknown values. Known observations require a validity interval and source.
- An opaque execution-context contract and provider/device discovery contracts.
- Environment snapshots validate provider/device ownership and duplicate identities.
- A provider can represent an opaque managed execution target without exposing a device list.

### ImageProcessingProtocol foundation

- Stable operation and implementation identifiers.
- Typed operation values and associated input/output types.
- Operation specifications derive input/output value identifiers from their associated Swift types.
- One generic ImageOperationImplementation protocol, specialized by its associated operation type.
- Declarative implementation specifications describe operation/version compatibility, optional provider binding, and scoped generic capability requirements.
- The protocol has no per-implementation qualification hook.

### Tests

The current test suite covers identifiers/capabilities, capability scope, version/operation compatibility, provider snapshot integrity, unavailable/unknown/stale state, and typed implementation execution.

Local verification performed on Swift 6.2.1, Linux x86_64:

- swift build — passed.
- swift test — passed, 10 tests.

The GitHub Actions Linux/macOS matrix is configured separately; its result must be checked before claiming CI coverage.

## Not implemented

- Image document, layer, pixel/data descriptors, and resource ownership.
- Generic resource allocation, import/export, retention, release, and residency transitions.
- Generic submission, completion, synchronization, cancellation, and failure lifecycle.
- Provider discovery aggregation and runtime registry.
- Operation implementation registry and safe type-erased execution dispatch.
- QualificationPolicy, fluent policy builder, scope composition, and conflict diagnostics.
- Common environment-aware resolver and end-to-end cost ranking.
- Execution planner, resource reservation/revalidation, and execution coordinator.
- Transactional image result publication and replacement.
- CPU provider and numerical reference image operations.
- Metal, CUDA, OpenCL, Direct3D 12, Vulkan, OpenCV, Core Image, Accelerate, or model-runtime implementation packs.

## Phase state

| Phase | State | Reason |
|---|---|---|
| 0 — Architecture decisions | In progress | Decision register exists; image concurrency, layer identity, target platform matrix, and per-operation color policy remain proposed/open. |
| 1 — Operation/implementation contracts | In progress | Typed contract skeleton exists; semantic descriptors, numerical contracts, and complete implementation-support schema remain. |
| 2 — GeneralExecutionProtocol | In progress | Discovery, capability and state foundations exist; resource and asynchronous work lifecycle remain. |
| 3 — ImageProcessingProtocol core | In progress | Operation contract exists; image/layer/resource and compositional function model remain. |
| 4–9 | Not started | Depend on the preceding contracts and runtime. |

## Next implementation order

1. Complete generic resource descriptors and lifecycle without introducing image concepts into GeneralExecutionProtocol.
2. Complete the generic asynchronous submission/completion/synchronization model while preserving provider-native mechanisms behind optional/provider-specific capabilities.
3. Add image and layer semantic descriptors, numerical contracts, and operation-level input/output requirements.
4. Add immutable qualification-policy values and construction/composition conflict validation.
5. Implement the runtime registry and common resolver only after the specification and environment models are sufficient to qualify real candidates.
6. Add a CPU reference provider and one small operation vertical slice before GPU providers.
