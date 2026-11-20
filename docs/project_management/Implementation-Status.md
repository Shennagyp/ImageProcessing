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
- Declarative implementation specifications describe operation/version compatibility, optional provider binding, and scoped generic capability requirements.
- The protocol has no per-implementation qualification hook.

### Tests

The current test suite covers identifiers/capabilities, provider/device/context capability scope, version/operation compatibility, provider snapshot integrity, unavailable/unknown/stale state, resource request validation, import retention, resource identity, work/resource retention through completion and cancellation, dependency ordering, provider context creation, and typed implementation execution.

Local verification performed on Swift 6.2.1, Linux x86_64:

- swift build — passed.
- swift test — passed, 22 tests.

GitHub Actions Swift 6.2.1 matrix passed on ubuntu-24.04 and macos-latest at commit 0895a034b8b75c13336c0a08036c250a61d66cc4. Both jobs completed swift build and swift test successfully. The initial macOS failure exposed Date.now availability (macOS 12+); replacing the defaults with Date() resolved it.

## Not implemented

- Image document, layer, image-specific pixel/data descriptors, and their mapping to generic execution resource handles.
- Concrete provider implementations of resource allocation/import/export, residency transitions, and safe native release.
- Provider conformance tests proving resource retention through asynchronous work, cancellation, device loss, and failure.
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
| 2 — GeneralExecutionProtocol | In progress | Resource and asynchronous lifecycle contracts now exist; no complete provider implementation or provider conformance suite yet. |
| 3 — ImageProcessingProtocol core | In progress | Operation contract exists; image/layer/resource and compositional function model remain. |
| 4–9 | Not started | Depend on the preceding contracts and runtime. |

## Next implementation order

1. Build a reusable test-only provider conformance harness for allocation/import, access retention, dependencies, completion, cancellation, and synchronization.
2. Complete the image/layer semantic descriptors, numerical contracts, and operation-level input/output requirements.
3. Add immutable qualification-policy values and construction/composition conflict validation.
4. Implement the runtime registry and common resolver only after the specification and environment models are sufficient to qualify real candidates.
5. Add a CPU provider and one small operation vertical slice before GPU providers.
