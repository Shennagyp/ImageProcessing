# ImageProcessing

A cross-platform image-processing library focused on a stable semantic API over multiple execution technologies and algorithm implementations.

## Project status

This repository is being established from an empty baseline. The current committed artifact is the internal architecture paper; it is a design specification, not evidence that the described API or runtime has already been implemented.

## Architecture

The current design separates:

- **Image documents and layers** from physical pixel storage.
- **Immutable operation objects and their semantics** from operation-specific implementations.
- **General compute providers** (CPU, Metal, CUDA, OpenCL, Direct3D 12, and potentially Vulkan) from algorithm-library adapters (for example OpenCV, Core Image, or inference runtimes).
- **Qualification** (whether an implementation can correctly satisfy a contract) from **selection** (which qualified implementation should execute).
- **Logical image replacement** from physical in-place memory reuse.

The public processing model is operation-oriented and compositional. No node editor or visual graph frontend is part of the current design.

## Design paper

The authoritative design baseline is:

- [ImageProcessing — Architecture and Semantic Contracts](docs/research/architecture/ImageProcessing-Architecture.tex)

The paper is an internal engineering record, not a publication. It distinguishes accepted architectural decisions from unresolved API and implementation questions.

## Building the paper

Requires a standard LaTeX installation with `latexmk`, `pdflatex`, and the packages used by the source (including `lmodern`, `microtype`, `geometry`, `amsmath`, `booktabs`, `tabularx`, `enumitem`, `listings`, `fancyhdr`, `hyperref`, and `cleveref`).

From the repository root, run:

    latexmk -pdf -interaction=nonstopmode -halt-on-error docs/research/architecture/ImageProcessing-Architecture.tex

The generated PDF is a build artifact; the committed `.tex` source is canonical.