# ImageProcessing

A cross-platform image-processing library focused on a stable semantic API over multiple execution technologies and independently supplied operation implementations.

## Project status

This repository contains the proposed architecture baseline (0.3) and a phase-gated implementation plan (0.2). These are design documents; they are not evidence that the described protocols, resolver, or runtime have already been implemented.

## Architecture

- **Image documents and typed layers** are separate from physical pixel storage and execution residency.
- **Operation definitions** are separate from concrete implementation classes. One operation, such as Gaussian blur, can have CPU, CUDA, Metal, OpenCV, or other independent implementations.
- **Operation specifications** describe semantic requirements and permitted behavior. **Implementation specifications** describe the tested capabilities, precision modes, provider requirements, parameter limits, and resource characteristics of one implementation.
- **ImageProcessingProtocol** is the primary image-domain contract. **GeneralExecutionProtocol** is the lower-level, image-agnostic execution contract it consumes.
- **Execution providers** (CPU, Metal, CUDA, OpenCL, Direct3D 12, potentially Vulkan) are distinct from **operation-implementation packages** (for example, CPU/GPU Gaussian blur implementations or OpenCV adapters).
- Static implementation support is distinct from the live execution environment: discovered providers/devices, capabilities, availability, memory pressure, queue state, and telemetry freshness.
- A **common resolver** evaluates operation semantics, implementation specifications, current environment observations, and declarative pipeline policy. Implementations publish specifications; they do not each implement custom qualification functions.
- Pipeline qualification is fluent and declarative. Requirements filter candidates; preferences rank only eligible candidates. Contradictory policies are rejected during construction or composition with diagnostics preserving their origins.
- Platform is discovered as an environmental fact; there is no hard-coded platform-to-provider preference table. A low-latency preference may route to CPU when a compatible GPU is busy, but a required provider or precision mode cannot be silently relaxed.
- The core protocols/runtime do not depend on concrete implementation packages. The consuming application selects and registers provider packs and operation-implementation packs.
- The public processing model is operation-oriented and compositional. No node editor or visual graph frontend is part of the design.

## Design paper

The authoritative design baseline is:

- [ImageProcessing — Architecture and Semantic Contracts](docs/research/architecture/ImageProcessing-Architecture.tex)

## Building the paper

Requires a standard LaTeX installation with latexmk, pdflatex, and the packages used by the source (including lmodern, microtype, geometry, amsmath, booktabs, tabularx, enumitem, listings, fancyhdr, hyperref, and cleveref).

Build the architecture paper from the repository root:

    latexmk -pdf -interaction=nonstopmode -halt-on-error docs/research/architecture/ImageProcessing-Architecture.tex

Build the phased implementation plan from its document directory (its section files are included by relative path):

    cd docs/project_management
    latexmk -pdf -interaction=nonstopmode -halt-on-error Implementation-Plan.tex

The generated PDFs are build artifacts; the committed .tex entry points and included section sources are canonical.

## Implementation plan

The phase-gated core-library roadmap is:

- [Implementation Plan — Phases, Deliverables, and Acceptance Gates](docs/project_management/Implementation-Plan.tex)

The roadmap covers Phase 0 (architecture decisions) through Phase 9 (production readiness). Concrete execution providers and operation implementations are independent packages/workstreams, not sequential phases of core-library development. Each core phase defines deliverables, exit criteria, and constraints on what must not be started prematurely.