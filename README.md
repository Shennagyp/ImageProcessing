# ImageProcessing

A cross-platform image-processing library focused on a stable semantic API over multiple execution technologies and independently supplied operation implementations.

## Project status

The repository contains architecture baseline (0.3), the Phase 0 decision register, the phase-gated implementation plan (0.2), generic execution contracts, and the immutable image/layer/pixel descriptor model, including affine layer-to-canvas registration. The thread-safe Image state owner, typed ImageFunction composition, validated qualification-policy builder, static operation/implementation contracts, operation/provider registries, partial environment discovery, runtime work/resource-access leases, input-bound common qualification, dispatch-boundary output validation, and the first candidate-ranking increment are implemented. Qualification evaluates exact typed inputs, immutable image revisions/layer targets, actual pixel representation/storage precision, generic input resources, operation-derived output/temporary resource plans, and context-supported resource kinds/domains. Qualified candidates retain registration identity, the exact operation/input/context binding, and provider/device observations. Each telemetry metric retains source/quality metadata and is assessed against its own validity interval; stale and unknown observations are not converted into numeric defaults. Replaced registrations fail closed. The new resolve API ranks only qualified candidates using scoped preferences and a deliberately partial, explainable cost model. It compares fresh queue-delay/fixed-overhead evidence for low latency, planned minimum resource-capacity bounds for low memory, and declared determinism; it exposes per-component evidence and feasible memory-domain options without allocating or selecting a domain. Full transfer/conversion/allocation/compute/synchronization/materialization costs, quality weighting/calibration, provider-backed resource acquisition, output binding/publication, pipeline planning, execution coordination, and concrete image operations remain incomplete.

See [Implementation Status](docs/project_management/Implementation-Status.md) for the exact implemented and pending scope. Do not treat a package skeleton or a related type as evidence that a full phase is complete.

## Architecture

- **Image documents and typed layers** are separate from physical pixel storage and execution residency.
- **Operation definitions** are separate from concrete implementation classes. One operation, such as Gaussian blur, can have CPU, CUDA, Metal, OpenCV, or other independent implementations.
- **Operation specifications** describe semantic requirements and permitted behavior. **Implementation specifications** describe tested support subsets for parameters, numerical modes, precision, layer/pixel representations, effects, and generic resource requirements of one implementation.
- **ImageProcessingProtocol** is the primary image-domain contract. **GeneralExecutionProtocol** is the lower-level, image-agnostic execution contract it consumes. **ImageProcessingRuntime** integrates both without moving provider or image semantics into the wrong layer.
- **Execution providers** are distinct from **operation-implementation packages**. The consuming application selects and registers both.
- A **common resolver** evaluates operation semantics, implementation specifications, current environment snapshots, hard pipeline requirements, and prepared-context capabilities through one shared data-driven path. Implementations publish specifications; they do not each implement custom qualification functions. The evaluate API is the eligibility/context-preparation stage; resolve ranks only its qualified candidates. Neither API allocates resources or executes operation work.
- `ImageFunction<Input, Output>` preserves typed sequential composition. Its immutable qualification policy separates hard requirements from optimization preferences and scopes declarations to the full pipeline or an operation occurrence.
- Pipeline qualification is fluent and declarative. Requirements filter candidates; preferences rank only eligible candidates. Conflicting policies are rejected during construction or composition with diagnostics preserving their origins.
- Platform and current hardware state are environmental facts, not hard-coded platform-to-provider preference rules. A low-latency preference may route to CPU when a compatible GPU is busy, but a required provider or precision mode cannot be silently relaxed.
- The public processing model is operation-oriented and compositional. No node editor or visual graph frontend is part of the design.

## Swift package products

The root SwiftPM package currently publishes three modules:

- `GeneralExecutionProtocol` — provider/device identity, generic capability requirements, environment observations, target-scoped resource handles, resource allocation/import contracts, typed work submission/completion, dependencies, cancellation, structured provider failure categories/recovery guidance, context-scoped capability reporting, and optional synchronization capabilities.
- `ImageProcessingProtocol` — typed operation/implementation contracts and static compatibility validation, operation parameter/numerical/effect/pixel domains, ImageFunction composition, QualificationPolicy builder, image identity, immutable document snapshots, typed layer content, validated pixel-data descriptors, affine layer-to-canvas mapping, explicit plane-to-resource binding, revision-scoped layer storage binding sets, and a thread-safe Image state owner with revision-checked atomic replacement.
- `ImageProcessingRuntime` — actor-backed operation implementation and provider registries, partial provider/device discovery, structured failures, private checked type-erased dispatch, a runtime work ledger that atomically tracks work leases plus read/write resource-access reservations, hard candidate qualification, and initial preference ranking with per-component cost evidence. Execution and full-path ranking remain incomplete.

`ImageProcessingProtocol` depends on `GeneralExecutionProtocol`; `ImageProcessingRuntime` depends on both. The generic execution module has no image-processing dependency. Pixel descriptors describe meaning/layout and validate storage capacity; they do not own or allocate provider resources. The runtime tracks reserved/submitted work and per-resource access reservations separately from provider telemetry. A resource-bearing lease requires revalidation before submission and retains its generic resource handles through completion. Initial ranking preserves observation provenance and uses fresh comparable queue-delay evidence without an invented source-quality confidence scale; stale/unknown metrics remain explicit. Full source-quality weighting/refresh, complete path-cost evaluation, provider-backed capacity/residency reservation, output-resource binding/publication, and execution coordination remain pending. Output allocation plans combine operation-derived capacity/alignment with implementation kind/domain/access constraints; they do not allocate resources.

## Build and test

Requires Swift 6.2.1 or a compatible Swift 6 toolchain. Xcode IDE projects are not required; Swift Package Manager command-line commands are the canonical workflow:

    swift build
    swift test

The GitHub Actions Swift 6.2.1 matrix previously passed on Ubuntu 24.04 and macOS with 22 tests. A later 53-test image-domain/spatial/chroma-siting suite was verified locally on Linux. The preceding 108-test revision passed on Ubuntu 24.04 in GitHub Actions. The current suite contains 244 test declarations across 20 Swift test files, plus one shared provider-conformance support file. The latest workflow at base commit c931ccd built the package products but failed while compiling test sources due to three fixture issues; the first version-0.1 commit corrected those sources. This branch adds input/resource qualification, stale implementation/provider registration identity, candidate-bound per-observation telemetry, operation resource-plan matching, context resource-kind/memory-domain feasibility, typed output descriptor/postcondition validation, and four initial candidate-ranking tests. No build or test has been run on the current version-0.1 revision, so its verification status is unconfirmed. The earlier 111-test revision passed on Ubuntu 24.04; macOS validation of the current contract additions remains pending. Provider-specific packages will have their own platform and hardware test requirements.

## Architecture decisions

The [Architecture Decision Register](docs/research/architecture/decisions/Decision-Register.md) records the Phase 0 working baseline, proposed public-API decisions, and deliberately deferred questions.

## Design paper

The authoritative design baseline is:

- [ImageProcessing — Architecture and Semantic Contracts](docs/research/architecture/ImageProcessing-Architecture.tex)

## Building the design documents

Build the architecture paper from the repository root:

    latexmk -pdf -interaction=nonstopmode -halt-on-error docs/research/architecture/ImageProcessing-Architecture.tex

Build the implementation plan from its document directory because its section files are included by relative path:

    cd docs/project_management
    latexmk -pdf -interaction=nonstopmode -halt-on-error Implementation-Plan.tex

The generated PDFs are build artifacts; the committed `.tex` entry points and included section sources are canonical.

## Implementation plan

- [Implementation Plan — Phases, Deliverables, and Acceptance Gates](docs/project_management/Implementation-Plan.tex)
- [Implementation Status](docs/project_management/Implementation-Status.md)

The core-library roadmap covers Phase 0 through Phase 9. Concrete execution providers and operation implementations are independent packages/workstreams, not sequential phases of core-library development.