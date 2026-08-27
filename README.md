# PaperLens

PaperLens is a planned macOS open-source AI paper workspace for reading papers, checking claims against source evidence, organizing research notes, and returning to a personal paper library.

## Current Status

This repository is currently in the planning stage. There is no runnable application, build, installation flow, release artifact, screenshot set, or contribution process in this repository yet.

## Product Vision

PaperLens connects a fast AI Reader with a compounding AI Library. The intended product loop is:

`read -> evidence -> organize -> revisit -> compound`

The product is not intended to claim perfect AI accuracy, a privacy-first/local-first architecture, or a broad all-purpose research copilot. Its v1 focus is a usable end-to-end workflow for one paper at a time.

## Planned v1 Scope

The final PRD defines planned v1 as a macOS desktop application where a user can:

- Configure a supported AI provider before entering the full app.
- Import papers from arXiv URLs, PDF URLs, or local PDF files.
- Read the original PDF in a Reader with navigation, zoom, search, and text selection.
- Compare sentence-aligned translations with the source text.
- Ask Paper Chat questions answered from whole-paper evidence.
- Generate and revisit Markdown Briefs, highlights, notes, reading status, favorites, and last-read position in a local Library.
- See job progress, errors, retry actions, and recovery state for import, parsing, translation, chat preparation, and brief generation.

Non-goals for v1 include recommendations, personal knowledge graphs, local model support, cloud sync, mobile apps, collaboration, Zotero sync, OCR, and complete table/figure/formula analysis.

## Planning Artifacts

- [Final PRD](bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/prd.md)
- [Final PRD Addendum](bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/addendum.md)

## License

This repository adopts `AGPL-3.0-only` as the PaperLens open-source license.
