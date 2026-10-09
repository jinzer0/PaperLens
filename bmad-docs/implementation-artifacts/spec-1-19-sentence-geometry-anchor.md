# Story 1.19 Build Spec — Shared sentence, geometry and Anchor contract

## Authority and admission

Issue#21 / issue/21-story-1-19, basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source; no repeated unchanged-scope SHA approval, no actual gate/live/paid/credential/remote/distribution permission.

Historical Architect51 inspected exactly ROOTepics921–951, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift; root-only source not copied. That planning phase was not implementation-ready. Initial1.13 pure20PASS was independently BLOCKED48, repair not accepted at planning. Local14dd7b3/c93e873 nonproduct only. StoryDone=false, blankCapture FAIL/noP6. Main topology not Reader. The exact local phase below supersedes the historical source prohibition; actual prerequisite proofs remain required for acceptance.

## Exact local implementation phase — explicit 2026-10-09 source order

The current human assignment authorizes implementation in exactly this Spec,
`PaperLensApp/Domain/PDFGeometry.swift`,
`PaperLensApp/Adapters/PDFKitGeometryAdapter.swift`, and
`Tests/Product/PDFGeometryTests.swift`. This replaces the planning-only source
prohibition for this phase, not canonical acceptance criteria. No tests, builds,
formatters, gates, commits, runtime/document trials, actual files or remotes run.
Domain owns immutable tuple validation, full-quote/multiquad anchors, CropBox
containment, PDFium-style crop-local top-left conversion, clockwise quarter-turn
mapping and invertible affine algebra. Adapter owns PDFKit display conversion via
public PDFView.convert(_:from:)/convert(_:to:), sampled page-space affine mapping,
page-object membership and roundtrip validation. Tests own independent expected
landmarks and rejection cases; parent owns target integration and profile binding.

Canonical points retain absolute unrotated PDF page coordinates: CropBox minimum
is the canonical lower-left; crop-local input adds that actual minimum. Rotation
is separate clockwise metadata and is never baked into stored quads. Top-left
rotated display formulas for crop-local (x,y) are (x,h-y), (y,x), (w-x,y),
(h-y,w-x) at 0/90/180/270 respectively. Quads preserve TL/TR/BR/BL source order;
nonfinite, degenerate, non-convex or outside-CropBox geometry fails.

`PDFGeometryPrecision` requires an explicit finite nonnegative maximum absolute
error in PDF points, inclusive per-axis; there is no default or guessed tolerance.
Adapter roundtrips each input/landmark through public PDFKit conversion in PDF
points. Mapping is captured only for one immediate main-actor call, never retained
across zoom/page changes. Missing page, identity/revision mismatch, malformed and
outside-page errors are distinct; same SHA in another Paper never matches.
Encoding accepts page 0...1999 and sentence 0...199999, but resolution additionally
requires exact membership from an owning revision, not encoding validity alone.
SHA uses the existing lowercase 64-hex encoding and extraction revision uses the
existing ProviderRequest lowercase v4 UUID encoding, without normalization.
Exported APIs are `PDFPageGeometry`, `PDFPoint`, `PDFQuad`, `PDFGeometryAffine`,
`PDFGeometryPrecision`, `PDFSentenceIdentity`, `PDFSentenceAnchor` and main-actor
`PDFKitGeometryAdapter.pageGeometry/displayPoint/canonicalPoint/displayQuads`.
`PDFGeometryError` enumerates malformedGeometry, outsidePage, unsupportedRotation,
invalidPrecision, invalidIdentity, identityMismatch, staleRevision,
unknownSentence, missingGeometry, missingPage, differentPage and roundtripExceeded.

AD-8's exact clause “round-trip tolerance를 PDF component Build Spec 전에 pin한다”
and Story 1.19's actual pre-split correspondence proof remain unsatisfied. Minimal
order-only amendment permits independent stateless implementation now; owning
profile selection/calibration and actual PDFium/PDFKit landmarks remain required
before parent binds dependents or claims StoryDone. Configured precision is an
input contract, not a calibrated product profile. Unknown geometry remains failure.

## Immutable identity and geometry

### Application codec phase — explicit 2026-10-10 source order

This independent phase owns only `PaperLensApp/Application/CanonicalExtractionGeometry.swift`,
`Tests/Product/CanonicalExtractionGeometryTests.swift`, and this Spec. It connects
the existing `ExtractionGeometryValidating` protocol without changing Domain,
publication, database, recovery, producer, or numeric policy. Parent alone commits
the amended Spec and integrated evidence and runs gates/formatters; this session
runs none, as explicitly instructed.

`CanonicalExtractionGeometryInput(anchor:)` accepts only already-canonical typed
`PDFSentenceAnchor`, never raw backend coordinates. The stateless
`CanonicalExtractionGeometryValidator(owningAnchors:precision:)` requires actual
caller-owned revision anchors and explicit `PDFGeometryPrecision`; there is no
default, selected product profile, guessed membership, or geometry conversion.
Domain validates the exact Paper/hash/revision/page/sentence tuple and membership.
Validation additionally requires exact page metadata, full source quote and quad
count, and compares each ordered vertex against the owning full semantic extent
using the supplied inclusive per-axis PDF-point precision. Duplicate ownership,
unknown input, missing membership, truncated text/quads and altered page fail.
Versioned sorted-key JSON stores the complete canonical anchor with exact doubles,
CropBox origin and separate rotation. Decode reconstructs through Domain
initializers and revalidates against the same owning revision; serialized bytes
are never their own membership authority.

Parent must add both files to explicit package/native target lists, bind actual
PDFium canonical output only after the backend coordinate contract is finalized,
provide independently owned full-extent anchors/membership and the admitted
precision profile, and require `ExtractionSentenceInput.text` to equal the typed
anchor's `fullSourceQuote` before publication (the existing validator signature
does not receive text). No service/producer outside this file list is edited.
Synthetic codec/validator tests are authored, not run; actual calibrated
PDFium/PDFKit correspondence, AD-8 and Story acceptance remain unclaimed.

Identity tuple PaperUUID/PDFSHA256/extractionRevision/zero-basedPage/sentenceID immutable; local page/sentence pair or same PDF hash in another Paper insufficient. Preserve FULL original sentence/semantic extent including multiline/multiquad; display truncation never narrows identity/quote/citation, expansion same sentence.

Canonical unrotated CropBox/PDF points/lower-left origin/+x right,+y up; quad TL/TR/BR/BL order, rotation separate metadata. Preserve actual CropBox offsets, no MediaBox substitution/zero-offset assumption/baked rotation/screen pixels. Application validates identity/revision; PDFium typed canonical batch, PDFKit display transform only. No adapter-owned publication/revision.

Missing/empty geometry/revision mismatch/unknown page-sentence typed failure, no nearest substitute/rebinding/successful empty navigation. Exact local error API is enumerated above. ProviderRequest existing contextual identity/bounds/errors not geometry tolerance; no payload rewrite. Reuse1.13 lineage/permits/op-scoped synchronous cleanup, no FS/waits under state.

## Calibration and conditional phases

Local conversion ownership/public APIs/CropBox convention and immediate main-actor lifetime are pinned above. UNKNOWN: actual PDFium input convention/fixture witnesses/sentence allocation/admitted zoom domain/owning metric precision and tolerance. No guessed number or local inverse-only proof. Before acceptance, an admitted unsplit actual PDFium→canonical→PDFKit slice calibrates independent PDF-space landmarks; finalize shared numeric tolerance with metric/PDF-point units/precision/inclusive boundary/error justification, then prove actual correspondence and roundtrip.

Every conditional source+pairedtest phase≤5exact named paths after same-Spec ownership/API amendment. The four-file phase above supplies Domain/adapter/test ownership, not Contracts/EvidenceAnchor/helper/schema/CI/ReaderUI scaffolds. Parent binds Application/PDFium after these APIs finish; no evolving consumer contract. No Chat/Brief Anchor UI/Translation/futureAI requirement; geometry proof independent of them.

## Required proof, not run

Exact tuple resolves first/last actual page; independently change every identity component/otherPaper-samehash rejects. Shared encoding limits1999page/199999sentence admit encoding only, actual membership still required; one-over/negative invalid. Multiline fullsentence/multiquad preserved, truncated/drop-continuation cannot satisfy anchored semantic range.

Actual CropBox offsets/MediaBox difference/rotation0/90/180/270 fixtures assert units/axes/quad order; mirrored axis/wrong origin/reorderedvertices/double rotation fails independent landmarks even if inverse math self-consistent. PDFKit admitted zoom boundaries/interior/navigation-away-back/stale transforms/otherrevision preserve exact identity and location.

Final metric errors0/exactτ pass, smallest representable>τ/nonfinite/unsupported inputs reject; NOτ decided here. Typed missing/revision failures distinct. Raw geometry/measured values stay RAM; durable evidence only approved bounded safe outcome projection/approved fixture-code/source identity, not arbitrary raw records/paths/content hashes. No pixel-only/render success proof.

Applicable UI includes Native Canvas semantics/Korean state+action/non-color cues/actual contrast/text scaling/resize/keyboardVoiceOver label-role-state/focus return/accessible RetryCancelDelete and currentPaper failure-restart-delete races, not deferred polish. Do not create UI to claim these conditions in pure contract work.

Historical Architect51 COMMENT/planning certified no product proof. Local implementation and authored synthetic tests are not executed proof. No tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits run in this phase. Done requires actual calibrated public/lifetime/shared tolerance and physical transform evidence, parent gates/independent review. This phase claims none.
