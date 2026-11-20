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

**Status:** Proposed

### Decision

Represent Image as a stable logical document handle with an immutable ImageID and a versioned document state. The public handle should have reference semantics; mutable state should be protected behind an actor or equivalent serialized state owner.

A snapshot contains an immutable image revision and references to retained resources. Image processing runs against a snapshot without holding the document-state lock/actor during compute.

### Replacement semantics

1. Read the current revision and obtain an immutable snapshot.
2. Resolve and execute the operation against that snapshot.
3. Validate output descriptors and postconditions.
4. Commit only if the document still has the revision used for execution.
5. Increment the revision atomically.

If another operation commits first, a stale commit is rejected with a revision-conflict error. The first version does not silently overwrite concurrent work and does not automatically replay arbitrary operations.

applying creates a new logical image identity. apply retains the existing image identity and publishes a new revision. Neither promises physical in-place storage reuse.

### Consequence

The API avoids lost updates, permits concurrent read snapshots, and keeps expensive compute outside the serialized document-state critical section.

### Open validation

Validate whether actor isolation and revision compare-and-swap can be represented cleanly in the desired Swift API without forcing every image read to become an actor hop. Do not freeze method signatures until this is tested.

---

## ADR-009 — Layer identity is scoped to an image

**Status:** Proposed

### Decision

Treat LayerID as unique within one image document, not as a globally meaningful identity. A durable external reference is the pair (ImageID, LayerID) or an equivalent LayerReference.

When deriving a new image, unchanged logical layers may retain their local LayerID values because the new ImageID distinguishes the new document. Newly created layers receive new IDs. Resource identity remains separate and may be shared when safe.

### Consequence

Layer references cannot accidentally resolve against the wrong image. Sharing the same physical resource does not imply that two document layers have the same logical identity.

### Open validation

Confirm that preserving local IDs across derived images matches the intended identity semantics for serialization, annotations, and external references.

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

## Phase 0 completion checklist

- [x] Separate operation, implementation, and provider ownership.
- [x] Define one generic implementation protocol and declarative implementation specification.
- [x] Define one common resolver over specifications, environment snapshot, and policy.
- [x] Separate environment discovery/telemetry from resolver evaluation.
- [x] Define candidate identity as implementation plus execution binding.
- [x] Define hard/soft policy semantics and conflict validation.
- [ ] Validate Image reference/state ownership and concurrent replacement API.
- [ ] Validate layer identity and reference semantics.
- [ ] Validate Swift package targets and the initial OS/architecture/toolchain matrix.
- [ ] Validate the first operation families' color and scientific-data contracts.
- [x] Defer a dynamic plug-in loader until a concrete deployment requirement exists.
- [x] Defer a public C ABI until an actual non-Swift consumer/provider requires it.

The checked items are architecture-level decisions recorded in baseline 0.3. The unchecked items require implementation experiments or explicit product/platform validation before public API freeze.
