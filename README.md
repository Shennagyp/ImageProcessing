# ImageProcessing

A cross-platform image-processing library focused on a stable semantic API over multiple execution technologies and independently supplied operation implementations.

## Project status

The repository contains architecture baseline (0.3), the Phase 0 decision register, the phase-gated implementation plan (0.2), the generic execution contracts, and the first immutable image/layer/pixel descriptor model, including explicit affine layer-to-canvas registration. The implementation is in progress; mutable image ownership, execution-resource binding, runtime resolution, and concrete image operations are not yet complete.

See [Implementation Status](docs/project_management/Implementation-Status.md) for the exact implemented and pending scope. Do not treat a package skeleton or a related type as evidence that a full phase is complete.

## Architecture

- **Image documents and typed layers** are separate from physical pixel storage and execution residency.
- **Operation definitions** are separate from concrete implementation classes. One operation, such as Gaussian blur, can have CPU, CUDA, Metal, OpenCV, or other independent implementations.
- **Operation specifications** describe semantic requirements and permitted behavior. **Implementation specifications** describe tested support, precision modes, provider requirements, parameter limits, and resource characteristics of one implementation.
- **ImageProcessingProtocol** is the primary image-domain contract. **GeneralExecutionProtocol** is the lower-level, image-agnostic execution contract it consumes.
- **Execution providers** are distinct from **operation-implementation packages**. The consuming application selects and registers both.
- A **common resolver** will evaluate operation semantics, implementation specifications, current environment observations, and declarative pipeline policy. Implementations publish specifications; they do not each implement custom qualification functions.
- Pipeline qualification is fluent and declarative. Requirements filter candidates; preferences rank only eligible candidates. Conflicting policies are rejected during construction or composition with diagnostics preserving their origins.
- Platform and current hardware state are environmental facts, not hard-coded platform-to-provider preference rules. A low-latency preference may route to CPU when a compatible GPU is busy, but a required provider or precision mode cannot be silently relaxed.
- The public processing model is operation-oriented and compositional. No node editor or visual graph frontend is part of the design.

## Swift package products

The root SwiftPM package currently publishes two modules:

- `GeneralExecutionProtocol` — provider/device identity, generic capability requirements, environment observations, target-scoped resource handles, resource allocation/import contracts, typed work submission/completion, dependencies, cancellation, context-scoped capability reporting, and optional synchronization capabilities.
- `ImageProcessingProtocol` — typed operation/implementation contracts plus image identity, immutable document snapshots, typed layer content, validated pixel-data descriptors, and affine layer-to-canvas mapping.

`ImageProcessingProtocol` depends on `GeneralExecutionProtocol`. The generic execution module has no image-processing dependency. Pixel descriptors describe meaning/layout and validate storage capacity; they do not own or allocate provider resources. `ImageProcessingRuntime` and concrete provider/operation implementation packages have not yet been added.

## Build and test

Requires Swift 6.2.1 or a compatible Swift 6 toolchain. Xcode IDE projects are not required; Swift Package Manager command-line commands are the canonical workflow:

    swift build
    swift test

The GitHub Actions Swift 6.2.1 matrix previously passed on Ubuntu 24.04 and macOS with 22 tests. The expanded 53-test image/spatial/chroma-siting suite is locally green on Linux; its cross-platform CI run is pending. Provider-specific packages will have their own platform and hardware test requirements.

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