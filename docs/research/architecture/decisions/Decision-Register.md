# Architecture Decision Register

**Status:** Phase 0 working baseline  
**Architecture:** 0.3  
**Purpose:** Record ownership, invariants, selected defaults, and deliberately deferred decisions before public API implementation.

This register complements [ImageProcessing — Architecture and Semantic Contracts](../ImageProcessing-Architecture.tex). The architecture paper explains the model; this register makes the implementation decisions traceable.

Statuses used here:

- **Baseline** — the current implementation direction. Change requires an explicit architecture revision.
- **Proposed** — a concrete recommendation, but it must be validated before the corresponding public API is frozen.
- **Deferred** — intentionally not decided until a real consumer, platform, or ABI requirement exists.

No status in this register claims that the corresponding code has been implemented.

---

## ADR-001 — Separate operation semantics, operation implementations, and execution providers

**Status:** Baseline

### Decision

Keep three separate identities:

1. **Operation** describes the semantic computation and its parameters.
2. **ImageOperationImplementation** is a concrete algorithm class implementing one operation.
3. **ExecutionProvider** supplies generic execution resources, devices, submission, completion, and synchronization.

One operation may have many implementation classes. One provider may serve many implementation classes. A higher-level algorithm runtime may be an opaque operation implementation without exposing its internal provider.

### Invariants

- Adding an implementation must not require changing the operation type.
- Adding a provider must not imply that it implements any image operation.
- Native provider types must not leak into the image-domain API.
- A backend package must not redefine an operation's meaning.

### Consequence

The runtime resolves operation implementations, not provider names in isolation. An implementation may bind to one provider/device or to a managed runtime.

---

## ADR-002 — One generic, typed operation-implementation contract

**Status:** Baseline

### Decision

Define one generic protocol named ImageOperationImplementation, specialized by an associated operation type. Each implementation publishes an immutable ImplementationSpecification and a typed execution entry point. The runtime may privately type-erase implementations to store heterogeneous operation types in one registry.

### Invariants

- There is no mandatory per-implementation qualify method.
- The associated operation type preserves typed execution at the public boundary.
- Type erasure is an internal registry mechanism, not an application-facing Any API.
- Implementation metadata is declarative and versioned independently from operation semantics.

### Consequence

CPUGaussianBlur, CUDAGaussianBlur, and MetalGaussianBlur can all implement the same GaussianBlur operation.

---

## ADR-003 — Specifications are the qualification inputs

**Status:** Baseline

### Decision

Use two complementary specifications:

- **OperationSpecification** describes required semantics and permitted implementation variation.
- **ImplementationSpecification** describes the static, tested support of one concrete implementation.

Implementation specifications declare operation/version compatibility, supported input/output descriptors, parameter ranges, numerical modes, provider requirements, resource requirements, and optional static cost hints.

Dynamic availability and load do not belong in an implementation specification.

### Invariants

- A specification must not claim that a device is currently idle or available.
- Declared support must be backed by conformance tests.
- Precision is dimensioned: input/storage, computation, accumulation, and output precision are independent.
- A feature name alone is not proof of numerical conformance.

### Consequence

The resolver can compare implementation declarations without embedding backend-specific branches or calling arbitrary qualification code on every implementation class.

---

## ADR-004 — One common resolver evaluates eligibility and ranking

**Status:** Baseline

### Decision

Implement one common, data-driven resolution function in ImageProcessingRuntime. It evaluates:

1. the operation instance and its OperationSpecification;
2. the candidate ImplementationSpecification;
3. the actual execution environment snapshot;
4. the immutable qualification policy attached to the function/pipeline.

The resolver has two internal stages:

- **Eligibility:** reject candidates that fail semantic, precision, provider, resource, or hard policy requirements.
- **Ranking:** order only eligible candidates using preferences and estimated end-to-end cost.

These stages are internal to one common resolver. They are not separate backend hooks and are not a caller-managed selection ceremony.

### Invariants

- A preference score can never make an ineligible candidate eligible.
- No implementation class contains its own independent qualification algorithm.
- Missing provider or device availability is an environmental failure, not a contradictory policy.
- Resolver decisions must include structured reasons and the environment snapshot used.

### Consequence

The ordinary image API can resolve automatically. An advanced inspection API may expose candidate reasons for diagnostics and reproducibility.

---

## ADR-005 — Separate environment discovery from pure resolution

**Status:** Baseline

### Decision

Provider packages expose static device capabilities and supported dynamic observations through GeneralExecutionProtocol. The runtime gathers these observations into a time-bounded ExecutionEnvironmentSnapshot. The common resolver consumes that snapshot as data; it does not poll operating-system APIs or native devices itself.

### Static facts

Examples include provider identity, device architecture, supported formats, compute features, precision modes, allocation limits, resource import/export, and synchronization capabilities.

### Dynamic observations

Examples include device health, availability, available memory, memory pressure, outstanding submissions, queue depth, estimated queue delay, workload/utilization, thermal state, and current resource residency.

### Invariants

- Every dynamic observation carries a timestamp and freshness/quality information.
- Unsupported telemetry is unknown, not zero.
- The runtime may use its own outstanding-work and allocation accounting even when the platform exposes no global GPU utilization metric.
- A busy device can remain eligible; load normally affects ranking, not semantic eligibility.
- State is revalidated when resources are reserved for execution.

### Consequence

The resolver is deterministic for a fixed operation, registry, policy, and environment snapshot. The live environment collector is responsible for platform-specific discovery and telemetry.

---

## ADR-006 — A runtime candidate is an implementation bound to an execution target

**Status:** Baseline

### Decision

A candidate is not merely an implementation class. It is a concrete executable binding:

- implementation class/instance;
- provider or managed-runtime instance;
- device or execution target;
- environment snapshot used for evaluation.

The same implementation class may yield multiple candidates when multiple compatible devices or contexts are available. A managed runtime whose internal device partitioning is opaque may be represented as one candidate.

### Invariants

- Provider/device eligibility is evaluated per binding.
- A generic implementation may be reused across compatible devices.
- A candidate's cost includes the data's current residency and the required output residency.
- The selected binding is revalidated before execution.

### Consequence

The resolver can compare CPU versus GPU, GPU 0 versus GPU 1, or two separate runtime instances without encoding device-specific branches in operation classes.

---

## ADR-007 — Declarative pipeline policy: requirements and preferences

**Status:** Baseline

### Decision

Expose fluent function/pipeline configuration that constructs an immutable QualificationPolicy.

- require(...) adds a hard constraint.
- prefer(...) adds a soft optimization objective.
- Rules may apply to the whole pipeline or to an explicitly scoped operation/step.

### Composition rules

- Hard constraints combine conjunctively.
- Allowed-value constraints combine by intersection when they apply to the same scope and dimension.
- Empty intersections are policy conflicts and must be rejected during policy construction or function composition.
- Different step scopes remain distinct; an operation-local preference must not leak to unrelated steps.
- Preferences combine only through declared objective priorities or weights. They are not intersected as sets.
- Pipeline-wide hard requirements cannot be weakened by a local preference.

### Diagnostics

A conflict must identify the affected dimension, scope, operation/step, and both source declarations.

### Consequence

A pipeline may require FP32 computation and prefer low latency. A compatible CPU implementation may win while the GPU is busy, but an FP16-only implementation can never satisfy a hard FP32 requirement.

---

## ADR-008 — Image identity and concurrent replacement

**Status:** Baseline

### Decision

Represent Image as a stable logical document handle with an immutable ImageIdentifier and a versioned ImageDocumentSnapshot. The public Image handle is a thread-safe reference type. Its mutable state is protected by a short NSLock critical section rather than an actor; immutable snapshot reads remain synchronous and do not require an actor hop.

Image.snapshot() captures one immutable ImageStateSnapshot containing both the document snapshot and the ImageStorageBindingSet for exactly that image identity and revision. The snapshot retains all referenced execution resources independently of later Image replacements.

Image.replace(expectedRevision:canvas:layers:storageBindings:) constructs and validates the candidate document and its matching resource-binding set outside the lock. It then locks, verifies the current revision still equals expectedRevision, and publishes the complete candidate state in one assignment. If another replacement committed first, it throws a revisionConflict. No automatic replay or silent overwrite occurs.

The initial Image initializer may generate an identity or accept an explicit ImageIdentifier. Explicit identity is required when callers construct initial LayerReference-based resource bindings before Image creation.

### Replacement semantics

1. Capture the current immutable ImageStateSnapshot.
2. Resolve and execute processing outside the Image lock.
3. Construct and validate candidate descriptors and resource bindings for the next revision.
4. Commit only if the captured revision remains current.
5. Increment the revision without wrapping and atomically publish document plus resource bindings.

applying creates a new logical Image identity. apply retains the existing Image identity and publishes a new revision. Neither promises physical in-place storage reuse.

### Invariants

- ImageIdentifier is immutable for the lifetime of an Image instance.
- Snapshot capture is consistent and holds the lock only while acquiring value/reference ownership.
- No processing, provider call, resource allocation, import, or await occurs while the Image lock is held.
- The document and its revision-scoped ImageStorageBindingSet are published atomically.
- A stale replacement cannot overwrite a newer revision.
- Validation failure leaves the published state unchanged.
- Old snapshots retain their resources until those snapshots are released.
- Revision exhaustion is an explicit error; revisions never wrap.

### Consequence

The public object has ordinary reference semantics while processing remains snapshot-based and concurrency-safe. The state lock protects only the short commit boundary; expensive work is independent and concurrent. A revision conflict is explicit and can be handled by the caller/runtime.

### Validation

The Swift implementation and tests cover stable identity, initial revision, synchronous snapshot capture, replacement revision advancement, stale conflict rejection, validation failure atomicity, concurrent same-revision writers (at most one commit succeeds), atomic publication of document plus matching resource set, and resource retention by captured snapshots.


---

## ADR-009 — Layer identity is scoped to an image

**Status:** Baseline

### Decision

Treat LayerID as unique within one image document, not as a globally meaningful identity. A durable external reference is the pair (ImageID, LayerID) or an equivalent LayerReference.

When deriving a new image, unchanged logical layers may retain their local LayerID values because the new ImageID distinguishes the new document. Newly created layers receive new IDs. Resource identity remains separate and may be shared when safe.

### Consequence

Layer references cannot accidentally resolve against the wrong image. Sharing the same physical resource does not imply that two document layers have the same logical identity.

### Validation

The initial Swift model implements the scoped pair as LayerReference and tests that identical local LayerID values in different ImageID scopes are distinct references. Serialization and annotation persistence remain separate future concerns.

---

## ADR-010 — Swift-first API; provider portability is separate

**Status:** Proposed

### Decision

Use Swift Package Manager as the primary build and package model. Keep the semantic core free of Apple-framework imports. Put Metal, Core Image, Accelerate, CUDA, OpenCL, Direct3D 12, and other platform/runtime integrations in separately selectable implementation packages.

Do not require Xcode IDE projects for ordinary builds. Command-line SwiftPM workflows are the canonical developer interface.

### Platform support

Do not claim universal cross-platform support merely because the core compiles on one platform. Publish support only for the Swift toolchain, OS, architecture, provider, and operation/implementation combinations actually built and tested.

### Consequence

The public Swift API can remain stable while providers vary by target. A platform without a particular provider can still use another qualified implementation.

### Open validation

The first supported OS/architecture matrix must be established from actual developer machines and CI agents before provider packages are advertised.

---

## ADR-011 — Async completion is the public materialization boundary

**Status:** Proposed

### Decision

Pipeline construction and composition are declarative and do not execute work. The initial applying and apply APIs are asynchronous. When they return successfully, the promised output must be valid and usable according to the operation's output contract.

The runtime may defer, fuse, or batch internal work while executing a composed function, but it must not return a nominally complete image whose required work or output materialization is still pending.

### Consequence

Callers have a clear completion guarantee. More advanced lazy/deferred public results can be considered later as a separate explicit API, rather than being hidden in ordinary image application.

---

## ADR-012 — Color and scientific data are distinct semantic domains

**Status:** Proposed

### Decision

Image descriptors must distinguish color data from scientific/non-color numerical data.

For color data, operations must declare or receive the working color space, transfer function, and alpha interpretation required for their semantics. Do not apply an undocumented global color conversion.

For scientific/non-color data, preserve numerical values and declared units/ranges. Color transforms must not be applied implicitly.

### Consequence

An operation cannot silently reinterpret a scientific intensity image as display RGB, or silently change color meaning because a provider expects another representation. Any conversion is an explicit, qualified preparation step.

### Open validation

Choose defaults per operation family only after reviewing concrete operations and representative image data. Do not define one global color default for every image type.

---

## ADR-013 — Provider registration is static first; dynamic plug-ins are deferred

**Status:** Proposed

### Decision

The first release uses explicit application registration of provider and operation-implementation packages linked by the consumer's package graph. Provider discovery and runtime availability are dynamic; loading arbitrary binary plug-ins at runtime is not required.

### Consequence

The initial design avoids inventing a dynamic module ABI, sandbox, package trust model, hot reload, and unload lifecycle before they are needed.

### Deferred

Dynamic loading, hot reload, third-party binary compatibility, and failure isolation across dynamically loaded modules require a separate design if an actual deployment requirement emerges.

---

## ADR-014 — Cost ranking begins explainable and measured

**Status:** Baseline

### Decision

Start with a small transparent cost model. Account for queue delay, transfer, conversion, allocation, compute, synchronization, materialization, and current resource pressure. Improve estimates using measured history for an implementation/device/input-size class.

Do not begin with a speculative machine-learning cost predictor.

### Invariants

- Unknown telemetry is never treated as zero cost or zero load.
- Estimated values carry confidence/freshness.
- Kernel duration alone is not an end-to-end cost.
- Cost affects ranking only; it cannot weaken semantic or hard policy requirements.
- A deterministic tie-break is required when candidate estimates are equivalent or unknown.

### Consequence

The resolver can be useful early and improve with workload evidence without making opaque or untestable choices.

---

---

## ADR-015 — Generic resource ownership and asynchronous execution lifecycle

**Status:** Baseline

### Decision

Model generic provider allocations as reference-counted opaque ExecutionResource handles with target-scoped identity. Resource descriptors contain generic kind, capacity, alignment, memory domain, and owning execution target. Image dimensions, pixel formats, color semantics, tensor layouts, and scientific units remain in ImageProcessingProtocol.

Allocation and import are optional context capabilities. An imported handle retains its source handle. Work items declare resource accesses and completion dependencies. A submitting context returns a typed submission handle whose successful completion guarantees that its output is valid.

### Invariants

- Resource identifiers are scoped by the execution target; identity is the target/resource pair.
- A provider validates allocation requests against its returned resource descriptor.
- An imported handle retains the source allocation for the complete import lifetime.
- A provider retains submitted work and all declared resource handles until completion, even if the caller drops its local references.
- Dependencies must complete successfully before dependent work starts.
- Cancellation is best-effort. Requesting cancellation does not permit early resource release.
- Explicit context/resource synchronization is optional; per-submission completion is the preferred narrow boundary.
- Native command buffers, streams, queues, events, and fences remain provider-owned.

### Consequence

The generic execution contract expresses resource and completion semantics without becoming a false common wrapper over native command APIs. Image-specific storage interpretation remains outside this package.

---

## ADR-016 — Context capabilities are evaluated on the prepared execution context

**Status:** Baseline

### Decision

Keep provider, device, and context capabilities distinct. ExecutionContext exposes a context-local ExecutionCapabilities descriptor. Standard generic capability identifiers cover resource allocation/import, work submission/dependencies, and synchronization. Capability requirements may target provider, device, provider-or-device, or context.

The common resolver first checks provider/device facts from the environment snapshot. It then prepares candidate contexts for remaining bindings and checks context-scoped requirements against the actual context descriptor and its optional protocol conformance before submitting operation work.

### Invariants

- A provider/device capability cannot satisfy a context-scoped requirement.
- A context must not advertise a standard capability unless it supports the corresponding optional context protocol.
- Optional protocol conformance is the executable proof; the capability descriptor is the declarative fact used during qualification.
- A context with no capability reporting defaults to an empty descriptor and cannot accidentally satisfy required context capabilities.
- Context preparation or capability mismatch is a structured candidate rejection before operation execution, not a custom per-backend qualification hook.

### Consequence

An implementation can require work submission or resource allocation without assuming every context created by the same provider exposes that capability. Different contexts from one provider/device may advertise different capabilities.

---

## ADR-017 — Typed image semantics and checked pixel storage descriptors

**Status:** Baseline for the initial descriptor model

### Decision

Keep image meaning in ImageProcessingProtocol and generic allocation/lifetime in GeneralExecutionProtocol.

The initial image-domain model includes:

- ImageIdentifier, LayerIdentifier, LayerReference, ImageRevision, ImageExtent, and ImageCanvasDescriptor;
- immutable ImageDocumentSnapshot containing the image identity, revision, canvas, and ordered layer descriptors;
- LayerContentDescriptor variants for raster, mask, label map, and annotation content;
- PixelDataDescriptor containing component type, channel identities/roles, explicit color or scientific interpretation, channel ranges, and storage layout.

Color interpretation explicitly identifies color space, channel model (gray, RGB, YCbCr, or named custom model), transfer function, and alpha mode. Scientific interpretation can identify a measurement unit and does not acquire an implicit color space.

Storage layout is interleaved or planar. Every plane describes byte offset, row/pixel/slice strides, channel mapping, spatial subsampling, and an explicit sample origin whenever it is subsampled. The sample origin distinguishes centered from co-sited chroma; plane sample indices convert to layer-grid coordinates before layer-to-canvas mapping. The descriptor validates channel mapping, sample origin, stride sufficiency, and arithmetic overflow, then calculates minimum required storage capacity. Binding that descriptor to one or more generic ExecutionResource handles is a separate responsibility.

### Invariants

- LayerIdentifier is unique within one ImageIdentifier; a LayerReference contains both identities.
- ImageRevision never wraps; overflow is an explicit error.
- ImageDocumentSnapshot is immutable and rejects duplicate layer IDs and foreign layer references.
- Pixel/channel/color/scientific semantics never enter GeneralExecutionProtocol.
- Raster, mask, label-map, and annotation semantics remain distinct.
- Label maps require one integer label-identifier channel.
- A mask is a single scientific channel with explicit binary/coverage/probability semantics.
- A pixel descriptor does not own or allocate memory. Its minimum storage requirement is checked against the actual resource binding.
- Unknown channel ranges remain unknown; a descriptor does not infer numerical values from the component type.

### Consequence

Image-domain meaning is validated before runtime qualification, while execution resources remain provider-neutral. The current immutable snapshot is a value descriptor, not yet the mutable Image handle or its concurrency/commit implementation.

### Deferred

- Mapping a logical multi-plane descriptor to one resource or a set of independently allocated plane resources.
- Non-affine spatial deformation fields and calibrated world-coordinate transforms.
- Mutable Image actor/state-owner API and revision-checked commit mechanics.
- Per-operation default color spaces, resampling defaults, and scientific-unit conversion policies.

---

## ADR-018 — Pixel layers require explicit registration to the image canvas

**Status:** Baseline for the initial spatial model

### Decision

A raster, mask, or label-map layer has its own pixel sample grid. ImageDocumentSnapshot validates its relationship to the document canvas:

- If the layer pixel extent equals the canvas extent and no mapping is supplied, the effective mapping is identity.
- If the extents differ, LayerSpatialMapping is mandatory.
- A mapping may also be supplied for equal extents when the layer is shifted, rotated, scaled, sheared, or otherwise registered differently.

The initial LayerSpatialMapping is an invertible 4-by-4 affine transformation from layer sample-centre index coordinates to image-canvas sample-centre index coordinates. Integer coordinate positions denote sample centres. A 2D plane uses z = 0. The mapping is geometric metadata only; it does not resample pixels.

### Invariants

- A snapshot cannot contain a pixel layer with a different extent and no explicit mapping.
- Mapping matrices must contain 16 finite values, have an affine final row, and have a nonsingular linear component.
- A renderer or operation must use the declared mapping; equal dimensions alone are not proof of spatial alignment.
- Resampling is an explicit operation with its own interpolation, border, and output-grid semantics.
- Annotation descriptors retain their own coordinate-space declaration.
- The generic execution protocol remains unaware of layer mapping and canvas semantics.

### Consequence

Multi-resolution layers, crops, and affine-registered layers can coexist in one document without silent alignment assumptions. The initial model has a clear boundary for later non-affine registration and world-coordinate calibration.

### Deferred

- Non-affine deformation fields and local registration maps.
- Physical/world coordinate calibration, including units, origin, orientation, and transforms between named coordinate systems.
- Resampling and rendering policies that consume the mapping; they belong to explicit operation contracts, not the descriptor itself.

---

## ADR-019 — Subsampled planes declare sample-origin/chroma-siting semantics

**Status:** Baseline for the initial pixel descriptor

### Decision

A subsampling ratio does not fully define the sample grid of a plane. Each subsampled PixelPlaneLayout must declare the layer-grid coordinate of its plane sample at index (0,0,0). Non-subsampled planes may omit the origin and use zero.

For plane index (i,j,k), the layer-grid coordinate is:

    sampleOrigin + (i * subsampling.x, j * subsampling.y, k * subsampling.z)

The origin must be finite and lie within the corresponding subsampling cell. This makes centered and co-sited chroma distinct and explicit.

### Invariants

- Any plane with a subsampling factor greater than one requires an explicit sample origin.
- Missing or out-of-cell origins are rejected when constructing PixelDataDescriptor.
- Plane sample coordinates are in the layer's base sample grid; LayerSpatialMapping then maps them to the image canvas.
- Sample siting is metadata. It does not perform interpolation or resampling.

### Consequence

A YCbCr descriptor cannot silently treat all 4:2:0 or 4:2:2 layouts as having the same chroma-centre convention. Conversion and resampling operations receive enough information to implement the declared sampling geometry.

---
---

## ADR-020 — Pixel plane storage is bound explicitly to generic execution resources

**Status:** Baseline for the initial storage-binding model

### Decision

Keep PixelDataDescriptor as the semantic/layout description and PixelStorageBinding as the association to existing generic execution allocations.

PixelStorageBinding maps each descriptor plane exactly once to a generic ExecutionResource. A binding record may assign several planes to one shared allocation, or a plane may have its own independent resource. Plane byte offsets are relative to the resource assigned to that plane. Per-plane required byte capacities are computed independently; a shared resource must satisfy the maximum required end offset among its assigned planes.

The binding retains every resource handle for its lifetime and exposes ExecutionResourceAccess declarations for downstream work submissions. It does not allocate/import resources, perform transfers, synchronize, or select an execution provider.

### Invariants

- Every plane has exactly one resource assignment.
- Every resource assignment must meet the byte capacity required by all planes assigned to it.
- A repeated logical resource handle is represented by one binding group, not split across groups.
- One resource may contain multiple planes at descriptor-relative byte offsets; separate resources may each begin their plane at byte offset zero.
- Resource lifetime is retained by the binding and later by each submitted work item that accesses it.
- Pixel descriptor semantics remain in ImageProcessingProtocol; allocation ownership and execution remain in GeneralExecutionProtocol.

### Consequence

Logical pixel layout can be independent of its physical storage topology. Providers can expose one contiguous allocation, separate plane allocations, or imported resources without changing color/channel semantics.

### Deferred

- Resource replacement, copy-on-write, and lifetime across derived/replaced image revisions.
- Resource replacement, copy-on-write, and lifetime across derived/replaced image revisions.
- Transfer/import orchestration when a selected implementation requires another resource domain or execution target.

---

## ADR-021 — Layer storage bindings are scoped to an exact image revision

**Status:** Baseline for the initial binding model

### Decision

Use ImageStorageBindingSet to associate PixelStorageBinding values with LayerReference values for one exact ImageIdentifier and ImageRevision. The constructor validates that every reference belongs to the supplied snapshot, resolves to an existing pixel-backed layer, and uses a PixelDataDescriptor exactly equal to that layer's semantic descriptor.

The set may be partial. Non-resident or externally backed logical layers may exist without an execution-resource binding. The set reports those layers through unboundPixelLayers; runtime qualification must reject or prepare/import a resource as required by the selected implementation rather than interpreting absence as an empty image.

### Invariants

- The binding set's image identity and revision are immutable.
- A binding from another image or an unknown layer is rejected.
- Annotation layers cannot receive pixel storage.
- Bound pixel descriptors must match the layer's descriptor exactly.
- A binding set from a stale revision cannot be queried against a newer snapshot.
- Resource handles remain retained by the storage binding set for its lifetime.

### Consequence

Image metadata can exist independently of current resource residency, while runtime execution receives explicit, revision-correct resource associations. Image state and storage residency can be updated atomically later by the Image state owner.

### Deferred

- Resource sharing/copy-on-write rules across derived images and revisions.

---

## ADR-022 — Typed sequential function composition and operation-step occurrence identity

**Status:** Baseline for the initial composition API

### Decision

Represent a processing sequence as ImageFunction<Input,Output>. Its generic parameters preserve the input/output value-type chain. A function is created from a typed ImageOperation, and followed(by:) composes two functions only when the previous output type equals the next input type. A second overload appends one compatible operation. The identity function is an empty sequence for matching input/output types.

The function stores an ordered immutable sequence of AnyImageOperationStep values. Each step retains its immutable operation instance and erased OperationSpecification. Every occurrence has an OperationStepIdentifier; a right-hand function's step occurrences are reidentified when composed, while sourceIdentifier preserves the original step identity.

Composition is declarative and does not execute operations or select implementations. The runtime will later qualify and dispatch each ordered operation step. The initial public model is linear and sequential; it does not add a visual graph, branching graph, implicit fan-out, or arbitrary closure execution model.

### Invariants

- Input/output compatibility is enforced by Swift generic constraints at composition time.
- Step order is preserved exactly.
- Every occurrence in a composed function has a unique OperationStepIdentifier.
- Reusing the same function creates new occurrence IDs for the copied right-hand steps.
- Source identifiers remain available for diagnostics and traceability.
- Composition and identity construction have no execution side effects.

### Consequence

Callers can build typed operation pipelines without manually routing provider or implementation names. The runtime can inspect an ordered heterogeneous step sequence while callers retain a compile-time input/output contract.

### Deferred

- Runtime execution and heterogeneous implementation dispatch for ImageFunction steps.
- Immutable QualificationPolicy attachment, step-scoped policy rebasing, and conflict provenance.
- Composition optimizations such as fusion, batching, and resource-residency planning.

---

## ADR-023 — Qualification policy is immutable, scoped, and source-preserving

**Status:** Baseline for the initial policy builder

### Decision

Attach QualificationPolicy directly to ImageFunction. It contains hard requirement declarations and soft optimization preference declarations as separate collections. It preserves each declaration's source identity, optional source label, and scope so diagnostics can explain how an effective policy was formed.

Policy scope is either the complete pipeline or one OperationStepIdentifier occurrence. Pipeline declarations apply to every step where their dimension is applicable. Step declarations affect only that operation occurrence. When a function is reused on the right-hand side of composition, the copied step occurrences receive new identifiers and their step-scoped declarations are rebased to those identifiers. Pipeline declarations remain pipeline-scoped.

The first requirement vocabulary contains exact/allowed provider identities, generic ExecutionCapabilityConstraint values, dimensioned precision constraints (input/storage, computation, accumulation, output), and deterministic-result requirements. PrecisionValue distinguishes storage representation from arithmetic precision: inputStorage/output accept PixelComponentType; computation/accumulation accept ArithmeticPrecision. An inputStorage/output requirement with an arithmetic value, or a computation/accumulation requirement with a storage value, is invalid. The first optimization objectives are low latency, low memory, low energy, high throughput, and deterministic results, with optional explicit priority and positive finite weight.

OperationSpecification declares the policy dimensions that an operation exposes. Input-storage, computation, accumulation, and output precision applicability are independent dimensions, as is deterministic-result applicability. A precision or deterministic-result requirement/preference scoped to one step is rejected unless that operation declares the corresponding dimension. A pipeline declaration for either dimension is rejected if no step exposes it; operations that do not expose it do not acquire invented numerical or determinism semantics.

Policy construction and function composition are validation boundaries. The builder checks step references, precision applicability, nonempty provider/precision allowed sets, effective provider/precision intersections, execution capability value-type compatibility, preference weights, and contradictory preference declarations at the same objective/scope. Pipeline restrictions are intersected with each target step's restrictions. This validates aggregate intersections across all declarations, not merely pairwise intersections. Conflicts retain every prior declaration that contributed to the empty intersection and the incoming declaration.

### Invariants

- Requirements and preferences are stored separately; preferences never relax or override requirements.
- Hard requirements combine conjunctively. Provider and precision allowed sets have intersection semantics at each effective scope.
- Pipeline requirements are inherited; step-scoped declarations do not leak to other steps.
- Different step scopes do not conflict merely because they constrain the same dimension.
- Preferences for the same objective at the same scope cannot disagree on priority or weight. A pipeline and a step may use different priorities for the same objective.
- Precision and deterministic-result requirements are operation-dimensioned and require OperationSpecification-declared applicability.
- Generic execution capability requirements retain provider/device/context scope from GeneralExecutionProtocol.
- Invalid or unknown step references, empty intersections, mismatched capability value types, and invalid weights are rejected before function execution.
- Composition does not execute work or resolve implementations; it only validates and preserves the policy.

### Consequence

Policy is declarative and travels with the typed function value. Runtime resolution can evaluate the same immutable requirement declarations against operation/implementation specifications and the current execution environment, while retaining enough provenance to explain candidate rejection and preference ranking.

### Deferred

- Candidate eligibility and end-to-end ranking against real ImplementationSpecification precision/support matrices.
- Additional operation-specific policy dimensions such as border modes and color/alpha behavior after their semantic contracts are modeled.
- Runtime policy serialization/versioning and compatibility across persisted policy versions.
- Cost estimate confidence, objective trade-offs, and measured ranking calibration.

---

## ADR-024 — Operation semantics and implementation support are complementary validated contracts

**Status:** Implemented static contract baseline; resolver integration pending

### Decision

OperationSpecification defines the semantic domain of one operation version. It owns named parameter domains, typed input/output identity, independent precision domains (input storage, computation, accumulation, output storage), numerical behavior, required/permitted effects, mutation/aliasing rules, layer kinds, and applicable pixel-representation domains.

Operation parameter values are immutable named records attached to an operation instance. Preflight validation rejects missing required values, duplicate/unknown names, type mismatches, non-finite real values, and values outside the operation's domain. An operation value may be valid for the operation while unsupported by a particular implementation; this is a candidate-support failure, not an invalid operation.

ImplementationSpecification defines the tested static subset one implementation can execute. It must match operation identity, a supported semantic version, and input/output value types. Its parameter domains, precision modes, layer kinds, and pixel representation declarations must be subsets of the operation's permitted domains. It must preserve operation numerical guarantees, determinism, required effects, permitted effects, input mutation, and output aliasing. It also declares provider/capability dependencies, input/output/temporary resource roles, resource kind, allowed memory domains, minimum capacity/alignment, access, import needs, and optional static performance hints.

Storage precision and arithmetic precision are distinct types. Input/output storage dimensions accept PixelComponentType; computation/accumulation accept ArithmeticPrecision. A storage format such as FP32 does not establish the arithmetic or accumulation precision used by an implementation.

OperationNumericalContract states rounding, overflow, output-range behavior, determinism, and optional absolute/relative error tolerances. When rounding or overflow is implementation-defined, an implementation may declare a concrete supported mode. Otherwise it must declare the exact required mode. A declared implementation error bound must meet any operation tolerance; an operation with no tolerance leaves error-bound choice unconstrained.

OperationEffectContract separates effects required by the operation from the superset of effects permitted to implementations. An implementation must include all required effects, and its permitted effect set must be contained in the operation's permitted set. Input mutation and output aliasing remain separate dimensions. The default pure contract forbids extra effects and input mutation and requires outputs distinct from inputs.

Raster, mask, and label-map layer contracts require matching input/output pixel representation domains. Annotation-only operations do not acquire pixel-storage requirements. Pixel domains can constrain interleaved/planar layout, color/scientific interpretation, color models, alpha, transfer function, color-space identity, channel roles/order, subsampling, sample origins, and measurement units.

### Invariants

- Operation semantics are owned by the operation contract, not backend code.
- An implementation's declared static support is a subset of the operation's permitted domain.
- An operation-invalid parameter value fails preflight; an operation-valid value outside one implementation's support rejects only that implementation.
- Precision dimensions are independent; storage precision never implies computation or accumulation precision.
- Numerical precision compatibility does not imply rounding, overflow, determinism, error-bound, or effect compatibility.
- Static resource minima and cost hints are not dynamic availability, live memory capacity, queue depth, or measured performance.
- No per-implementation qualify hook is required; static compatibility is validated by shared code.
- Environment-aware eligibility, context checks, reservation, ranking, and execution remain runtime responsibilities.

### Consequence

The registry and resolver can inspect complete, typed semantic/support metadata without calling backend-specific code. Candidate rejection can identify the exact unsupported parameter, precision mode, numerical guarantee, representation, effect, capability, or resource requirement before execution.

### Deferred

- Context preparation and live validation of required resource requests against actual descriptor capacity/alignment and provider capabilities.
- Validation of implementation declarations against numerical conformance suites and reference outputs, beyond structural metadata checks.
- Runtime candidate outcome vocabulary and complete diagnostics/provenance.
- Cost-model calibration from measured end-to-end execution and transfer data.
- Representative Gaussian blur, resize, and blend operation families and their CPU/accelerator implementations.

## Phase 0 completion checklist

- [x] Separate operation, implementation, and provider ownership.
- [x] Define one generic implementation protocol and declarative implementation specification.
- [x] Define one common resolver over specifications, environment snapshot, and policy.
- [x] Separate environment discovery/telemetry from resolver evaluation.
- [x] Define candidate identity as implementation plus execution binding.
- [x] Define hard/soft policy semantics and conflict validation.
- [x] Validate mutable Image reference/state ownership and concurrent replacement API; Image uses a thread-safe state owner with immutable snapshots, revision-checked atomic replacement, resource-set consistency, and concurrency tests.
- [x] Establish document-scoped layer identity and test that references include ImageIdentifier.
- [ ] Validate Swift package targets and the initial OS/architecture/toolchain matrix.
- [ ] Validate the first operation families' color and scientific-data contracts.
- [x] Defer a dynamic plug-in loader until a concrete deployment requirement exists.
- [x] Defer a public C ABI until an actual non-Swift consumer/provider requires it.

The checked items are architecture-level decisions recorded in baseline 0.3. The unchecked items require implementation experiments or explicit product/platform validation before public API freeze.
