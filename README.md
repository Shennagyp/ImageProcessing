# ImageProcessing

A cross-platform image-processing library focused on a stable semantic API over multiple execution technologies and algorithm implementations.

## Project status

This repository is being established from an empty baseline. The current committed artifact is the internal architecture paper; it is a design specification, not evidence that the described API or runtime has already been implemented.

## Architecture

The current design separates:

- **Image documents and layers** from physical pixel storage.
- **Immutable operation objects and their semantics** from operation-specific implementations.
- **`ImageProcessingProtocol`**, the primary image-domain contract library, from **`GeneralExecutionProtocol`**, the lower-level, image-agnostic execution contract it consumes.
- Concrete compute providers (CPU, Metal, CUDA, OpenCL, Direct3D 12, and potentially Vulkan) from image-processing operation adapters.
- **Qualification** (whether an implementation can correctly satisfy an operation contract) from **selection** (which qualified implementation should execute).
- **Logical image replacement** from physical in-place memory reuse.

Dependency direction is one-way: `ImageProcessingProtocol` may depend on `GeneralExecutionProtocol`, but `GeneralExecutionProtocol` must never depend on image-processing concepts. The former defines images, layers, operation contracts, and the image-specific qualifying function. The latter defines generic devices, resources, work submission, completion, and synchronization. Concrete provider packages implement the general protocol; operation adapters implement the image-processing contracts.

The public processing model is operation-oriented and compositional. No node editor or visual graph frontend is part of the current design.

## Design paper

The authoritative design baseline is:

- [ImageProcessing — Architecture and Semantic Contracts](docs/research/architecture/ImageProcessing-Architecture.tex)

The paper is an internal engineering record, not a publication. It distinguishes accepted architectural decisions from unresolved API and implementation questions.

## Building the paper

Requires a standard LaTeX installation with `latexmk`, `pdflatex`, and the packages used by the source (including `lmodern`, `microtype`, `geometry`, `amsmath`, `booktabs`, `tabularx`, `enumitem`, `listings`, `fancyhdr`, `hyperref`, and `cleveref`).

Build the architecture paper from the repository root:

    latexmk -pdf -interaction=nonstopmode -halt-on-error docs/research/architecture/ImageProcessing-Architecture.tex

Build the phased implementation plan from its document directory (its section files are included by relative path):

    cd docs/project_management
    latexmk -pdf -interaction=nonstopmode -halt-on-error Implementation-Plan.tex

The generated PDFs are build artifacts; the committed `.tex` entry points and included section sources are canonical.

## Implementation plan

The phase-gated implementation roadmap is:

- [Implementation Plan — Phases, Deliverables, and Acceptance Gates](docs/project_management/Implementation-Plan.tex)

The plan covers Phase 0 (architecture decisions) through Phase 12 (planner optimization and production hardening). Each phase defines deliverables, exit criteria, and constraints on what must not be started prematurely.

Build the PDF locally with:

    latexmk -pdf -interaction=nonstopmode -halt-on-error docs/project_management/Implementation-Plan.tex
