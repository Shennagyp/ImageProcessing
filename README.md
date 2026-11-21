# ImageProcessing

A cross-platform image-processing library focused on a stable semantic API over multiple execution technologies and independently supplied operation implementations.

## Project status

The `version-0.1` branch contains the architecture baseline (0.3), phased plan (0.2), three protocol/runtime products, immutable image and pixel descriptors, typed function composition, validated qualification policy, implementation/provider registries, partial environment discovery, input-bound qualification, candidate telemetry provenance, initial scoped candidate ranking, and a single-operation execution coordinator. The coordinator allocates qualified output/temporary roles, passes them to the exact implementation, reserves and revalidates declared accesses, validates output plane bindings, and can publish an image revision through compare-and-swap.

Phase 5 ranking now includes exact precision preferences over implementation-declared supported modes, in addition to its initial latency, memory, and determinism objectives. The cost model remains intentionally partial: cross-target/cross-registration transfer, conversion, allocation latency, compute, synchronization, output materialization, source-quality calibration, and full-pipeline transition costs are not yet modeled. A precision preference ranks candidates whose declared support includes the requested value; it does not turn that preference into a hard eligibility rule. The effective precision mode is not yet passed into multi-mode implementations, so declared support is not proof of the mode actually used.

The suite contains 273 test declarations across 22 Swift test files, plus shared provider-conformance support. No build or test has been run on the current branch head, so its verification status is unconfirmed.

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
- Platform and current hardware state are environmental facts, not hard-coded platform-to-provider preference rules. A low-latency preference may route to CPU when a compatible GPU is busy, but a required provider or precision mode cannot be silently relaxed. Explicitly binding a precision mode into a multi-mode implementation's execution is still pending.
- The public processing model is operation-oriented and compositional. No node editor or visual graph frontend is part of the design.

## Swift package products

The root SwiftPM package currently publishes three modules:

- `GeneralExecutionProtocol` — provider/device identity, generic capability requirements, environment observations, target-scoped resource handles, resource allocation/import contracts, typed work submission/completion, dependencies, cancellation, structured provider failure categories/recovery guidance, context-scoped capability reporting, and optional synchronization capabilities.
- `ImageProcessingProtocol` — typed operation/implementation contracts and static compatibility validation, operation parameter/numerical/effect/pixel domains, ImageFunction composition, QualificationPolicy builder, image identity, immutable document snapshots, typed layer content, validated pixel-data descriptors, affine layer-to-canvas mapping, explicit plane-to-resource binding, revision-scoped layer storage binding sets, and a thread-safe Image state owner with revision-checked atomic replacement.
- `ImageProcessingRuntime` — actor-backed operation implementation and provider registries, partial provider/device discovery, structured failures, private checked type-erased dispatch, a runtime work ledger that atomically tracks work leases plus read/write resource-access reservations, hard candidate qualification, and scoped ranking for latency, memory, determinism, and exact precision-support preferences. Single-operation execution is partially implemented; full-path ranking and whole-pipeline execution remain incomplete.

`ImageProcessingProtocol` depends on `GeneralExecutionProtocol`; `ImageProcessingRuntime` depends on both. The generic execution module has no image-processing dependency. Pixel descriptors describe meaning/layout and validate storage capacity; they do not own or allocate provider resources. The runtime tracks reserved/submitted work and per-resource access reservations separately from provider telemetry. A resource-bearing lease requires revalidation before submission and retains its generic resource handles through completion. The initial ranker supports scoped latency, memory, determinism, and exact precision-support preferences without changing hard eligibility. Full source-quality weighting/refresh, complete path-cost evaluation, physical capacity/residency policy, cross-target input import/remapping, whole-pipeline planning, and complete cancellation/device-loss recovery remain pending. Output allocation plans combine operation-derived capacity/alignment with implementation kind/domain/access constraints; the single-operation coordinator acquires and validates the selected candidate's output/temporary resources.

## Build and test

Requires Swift 6.2.1 or a compatible Swift 6 toolchain. Xcode IDE projects are not required; Swift Package Manager command-line commands are the canonical workflow:

    swift build
    swift test

The GitHub Actions Swift 6.2.1 matrix previously passed on Ubuntu 24.04 and macOS with 22 tests. A later 53-test image-domain/spatial/chroma-siting suite was verified locally on Linux. The preceding 108-test revision passed on Ubuntu 24.04 in GitHub Actions. The current suite contains 273 test declarations across 22 Swift test files, plus shared provider-conformance support. Historical build/test passes apply only to earlier commits and do not validate the current branch head. No build or test has been run on the current `version-0.1` HEAD, so its compile/test status remains unverified. Provider-specific packages will have their own platform and hardware test requirements.

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