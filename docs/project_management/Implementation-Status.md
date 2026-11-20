# Implementation Status

**Architecture baseline:** 0.3  
**Implementation plan:** 0.2  
**Current state:** SwiftPM protocol boundaries, image-domain state/storage model, typed function composition, policy validation, declarative operation/implementation contracts, both runtime registries with per-registration identities, partial environment discovery, work/resource-access lease accounting, and the first input-bound common qualification pass are implemented. Qualification now checks exact image revisions/layer targets, concrete typed inputs, actual pixel representation/storage precision, and generic input-resource requirements before context acceptance. Preference ranking, complete cost evaluation, planning, and execution remain incomplete.

This file records actual repository state. The architecture and implementation plan remain normative for intended behavior; a listed design or deliverable is not considered complete merely because a related type exists.

## Implemented

### Swift package boundary

- Root SwiftPM package uses Swift language mode 6.
- Separate library products exist for GeneralExecutionProtocol, ImageProcessingProtocol, and ImageProcessingRuntime.
- ImageProcessingProtocol depends on GeneralExecutionProtocol; ImageProcessingRuntime depends on both; neither lower-level protocol depends on ImageProcessingRuntime.
- Core modules contain no Apple-framework or vendor-specific imports.

### ImageProcessingRuntime foundation

- A separate ImageProcessingRuntime SwiftPM product depends on GeneralExecutionProtocol and ImageProcessingProtocol.
- Actor-backed OperationImplementationRegistry stores implementations by implementation identifier plus implementation version; exact duplicate registrations are rejected and distinct versions may coexist.
- Registration validates the implementation specification against its associated operation's static specification before storing it.
- Private type-erased entries preserve the associated implementation type in a checked async dispatch closure; operation and input values are downcast at the boundary, and output type identity is checked.
- Registered metadata and statically compatible candidates can be enumerated in deterministic order by operation specification or concrete operation step; this does not rank candidates or inspect the provider environment.
- Each implementation and provider registration receives a unique registration identifier in addition to its stable identity. Environment snapshots carry provider registration identities. Qualified candidates carry the exact operation step, typed input, implementation and provider registration identities, execution target, and prepared context. Runtime dispatch consumes the candidate as a unit and rejects removed/replaced registrations rather than silently dispatching a new implementation/provider under the same key.
- Actor-backed ExecutionProviderRegistry independently stores selected provider packages by provider identifier and rejects duplicate registrations.
- Provider discovery assembles an ExecutionEnvironmentSnapshot from provider/device descriptors and state observations. Partial failures are retained alongside the snapshot; failed observations are represented as unknown rather than available or zero load.
- Provider/device ownership violations and duplicate device identifiers are reported as structured provider contract failures; a provider with no discovered devices remains valid for opaque managed execution.
- RuntimeWorkLedger atomically tracks per-target reserved/submitted work and exact generic resource-access reservations. Read-only reservations may coexist; any write/read-write access is exclusive. Multi-resource acquisition is all-or-nothing, current bindings must be revalidated before a resource-bearing lease can be submitted, and retained handles are released only on pre-submit cancellation or observed completion.
- RuntimeEnvironmentSnapshotCoordinator composes provider discovery with runtime-owned workload state into uniquely identified snapshots with monotonically increasing generations.
- Provider-reported queue/load observations remain separate from runtime-owned reserved/submitted counts.
- CommonQualificationResolver accepts the actual typed OperationValue. It verifies the operation's concrete Swift input and operation types against the registered implementation, not only their stable type identifiers.
- ImageOperationInputValue supplies an explicit mapping from logical input indices to exact ImageStateSnapshot revisions and explicit layer/composite targets. It never infers a layer from visibility, order, or first-match rules. Generic non-image values can instead conform to OperationResourceInputValue and describe their own generic ExecutionResource bindings.
- Input qualification checks accepted operation/implementation layer kinds, actual pixel layout/interpretation/channel order/subsampling/sample origin/color/scientific metadata, input storage component precision, and each required bound resource's kind/capacity/alignment/memory domain/access mode/target compatibility.
- Candidate dispatch consumes the operation step, input value, registered implementation descriptor, target, and context captured by qualification. A registration removed or replaced after qualification produces a structured stale-registration failure; it cannot silently substitute an implementation with the same key.
- Qualified candidates retain the exact environment snapshot identifier plus the provider/device state snapshots used during evaluation. Each telemetry metric exposes a known/stale/unknown assessment at the resolver's evaluation time using its own observedAt/validUntil interval; source and quality metadata remain available unchanged. Unknown or stale optional telemetry does not invalidate an otherwise eligible candidate, and a reported zero remains a known zero.
- ImageOperation may derive a typed, invocation-specific output-resource plan from its exact input and immutable parameters. The resolver matches each planned output slot to the implementation's static output resource requirement and combines data-derived capacity/alignment with implementation kind, allowed domains, and access mode. After context preparation, each output/temporary resource kind must be advertised by the context, and the candidate's allocatable domains are the intersection of the implementation's allowed domains and the context's advertised memory domains. These capabilities describe support, not free capacity or a reservation; no resource is allocated at qualification time.
- Resource-access reservations are runtime-owned and generic. They do not allocate resources, reserve provider memory capacity, establish residency, or prove that a provider can still execute after device loss.
- The resolver still does not rank candidates or estimate whole-path cost. A candidate is invalidated if its implementation registration is removed/replaced before dispatch; the registry does not yet retain unregistered plugin code until every outstanding candidate is released.

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
- Structured ExecutionProviderFailure values carry provider/target identity, machine-readable failure kind, advisory recovery guidance, and optional native code/message diagnostics.
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

The suite contains 235 test declarations across 19 Swift test files, plus the shared provider-conformance harness. New qualification contracts cover exact image-input snapshots and explicit layer targets, sparse logical input indices, operation/implementation pixel and storage-precision checks, generic non-image resource inputs, actual resource capacity/target/access compatibility, concrete Swift input-type identity, stale implementation/provider registration rejection, resource-access/mutation consistency, future-dated observation handling, candidate-bound per-metric telemetry assessment, operation-derived output-resource plan matching, output slot ordering, output-plan validation, context resource-kind support, memory-domain intersection, and temporary-resource fail-closed handling.

Historical verification: an earlier descriptor milestone passed Swift 6.2.1 build and test on Linux x86_64; earlier CI milestones also passed on Ubuntu and macOS. These results do not validate the current branch.

The latest workflow for base commit `c931ccd493ca65594cc11e516f3e7f45369c2ee4` built all three package products on Ubuntu and macOS, then failed while compiling test targets. The first `version-0.1` commit contains source corrections for those three test-fixture issues. This follow-up adds the input-qualification and candidate-dispatch tests described above. No build or test has been run on this branch, so its compile/test status remains unverified.
## Not implemented

- Non-affine spatial deformation fields and calibrated world-coordinate transform model.
- Concrete provider implementations of resource allocation/import/export, residency transitions, and safe native release.
- Provider conformance tests proving resource retention through asynchronous work, cancellation, device loss, and failure.
- Provider-backed memory-capacity reservation, resource allocation/reuse, and complete residency/import feasibility. RuntimeWorkLedger currently coordinates access to already-bound generic resource handles; it does not reserve physical memory or verify every provider-specific interop path.
- Source-quality-aware ranking and refresh policy for available-memory/queue/load telemetry. Per-observation validity is now assessed and preserved on qualified candidates, but quality weighting and use in cost ranking are not implemented.
- Actual output value/descriptor and postcondition validation. Operation-derived output resource capacity/alignment plans are combined with implementation kind/domain/access requirements, but no output resource is allocated and no returned value is yet checked against its expected descriptor.
- Provider-backed output allocation, physical capacity reservation/reuse, residency transitions, imported input remapping, and allocation-failure recovery. Candidate plans and context kind/domain capabilities are requirements/support facts, not reservations or available-byte guarantees.
- Data-derived temporary-resource planning. Implementations declaring temporary allocations are currently rejected until the operation plan can describe their sizes and alignment.
- Reference-counted retention of an unregistered implementation package until all outstanding candidates are released. Candidates fail closed when their registration is removed/replaced.
- Preference ranking and end-to-end cost estimation using queue delay, transfer/conversion, allocation, context, compute, synchronization, and materialization observations.
- Whole-pipeline planning and the execution coordinator, including reservation refresh, provider submission, completion/cancellation, output validation, and transactional Image publication.
- CPU provider and numerical reference image operations.
- Metal, CUDA, OpenCL, Direct3D 12, Vulkan, OpenCV, Core Image, Accelerate, or model-runtime implementation packs.

## Phase state

| Phase | State | Reason |
|---|---|---|
| 0 — Architecture decisions | In progress | Image concurrency and document-scoped layer identity are implemented; target platform/toolchain matrix and first operation-family color/scientific contracts remain open. |
| 1 — Operation/implementation contracts | In progress | Typed operation schemas, parameter validation, precision/numerical/effect/layer/pixel semantics, implementation support subsets, static resource requirements, and compatibility validation are implemented. Qualification result vocabulary and representative multi-implementation operation examples remain. |
| 2 — GeneralExecutionProtocol | In progress | Generic resource/work lifecycle contracts, structured provider failure categories/recovery guidance, and a reusable test-only conformance harness are implemented and exercised against an in-memory provider; a production provider and hardware conformance remain. |
| 3 — ImageProcessingProtocol core | In progress | Image/document/resource descriptors, atomic Image state, typed ImageFunction composition, validated QualificationPolicy, and static operation/implementation conformance contracts are implemented; end-to-end image function execution remains. |
| 4 — Environment discovery and registries | In progress | Registries, partial provider/device discovery, structured discovery failures, work accounting, resource-access reservations/revalidation, and identity-bearing snapshots are implemented. Registration identity is preserved through candidate dispatch, with stale registrations rejected. Physical memory/residency reservation, unregister lifetime retention, and provider timeout/refresh policy remain. |
| 5 — Common qualification/resolution | In progress | Static operation/parameter/implementation checks, provider/device capabilities, snapshot-age checks, context preparation, context protocol validation, concrete input-type checks, exact image revision/layer qualification, actual pixel representation/storage precision checks, generic input-resource validation, candidate-bound per-observation validity assessment, and operation-derived output-resource plan matching are implemented. Actual output descriptor validation, source-quality-aware preferences, ranking, and complete cost evaluation remain. |
| 6 — Execution coordination and planning | Not started | No complete resource acquisition/submission coordinator, whole-pipeline planner, completion/recovery lifecycle, or transactional result publication. |
| 7 — Independent packs and reference application | Not started | No production provider package, reference algorithm pack, or consuming sample application. |
| 8 — Measured optimization | Not started | No end-to-end cost calibration, residency-aware optimization, or performance benchmark baseline. |
| 9 — Production readiness | Not started | Platform support matrix, packaging, diagnostics, compatibility, and release evidence remain. |

## Next implementation order

1. Finish provider-backed output feasibility: select a memory domain from each candidate's context-supported/implementation-allowed intersection, allocate and validate concrete ExecutionResource handles against qualified candidate output plans; verify target, kind, capacity, alignment, and the required residency/import/synchronization path. Add actual output value/descriptor validation and imported-input remapping before ranking. Then use the preserved per-observation validity, source, and quality evidence in ranking without treating unknown as zero. Keep removed provider/implementation registrations alive only as long as explicitly pinned contexts/dispatches require them, or invalidate them with structured lifecycle results.
2. Complete Phase 5 ranking over fully eligible candidates only. Apply immutable preferences as soft objectives and estimate complete path cost, including queueing, transfers, conversions, allocation, context setup, compute, synchronization, and materialization.
3. Implement the Phase 6 planner/coordinator with reservation revalidation, opaque managed-runtime handling, completion/cancellation/device-loss cleanup, output validation, and atomic Image publication.
4. Add a CPU provider and a small numerical reference operation as the first end-to-end vertical slice after the runtime lifecycle is correct; then add GPU and managed-runtime adapters independently.
