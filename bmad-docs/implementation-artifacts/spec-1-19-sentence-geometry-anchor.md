# Story 1.19 Build Spec — Shared sentence, geometry and Anchor contract

## Authority and admission

Issue#21 / issue/21-story-1-19, basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source; no repeated unchanged-scope SHA approval, no actual gate/live/paid/credential/remote/distribution permission.

Architect51 inspected exactly ROOTepics921–951, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift; root-only source not copied. Planning ONLY, not implementation-ready; product BLOCKED until actual1.15/1.13 and applicableP1/P2/P3. Initial1.13 pure20PASS was independently BLOCKED48, repair not accepted at planning. Local14dd7b3/c93e873 nonproduct only. StoryDone=false, blankCapture FAIL/noP6. Main topology not Reader.

## Immutable identity and geometry

Identity tuple PaperUUID/PDFSHA256/extractionRevision/zero-basedPage/sentenceID immutable; local page/sentence pair or same PDF hash in another Paper insufficient. Preserve FULL original sentence/semantic extent including multiline/multiquad; display truncation never narrows identity/quote/citation, expansion same sentence.

Canonical unrotated CropBox/PDF points/lower-left origin/+x right,+y up; quad TL/TR/BR/BL order, rotation separate metadata. Preserve actual CropBox offsets, no MediaBox substitution/zero-offset assumption/baked rotation/screen pixels. Application validates identity/revision; PDFium typed canonical batch, PDFKit display transform only. No adapter-owned publication/revision.

Missing/empty geometry/revision mismatch/unknown page-sentence typed failure, no nearest substitute/rebinding/successful empty navigation. Exact error API UNKNOWN. ProviderRequest existing contextual identity/bounds/errors not geometry tolerance; no payload rewrite. Reuse1.13 lineage/permits/op-scoped synchronous cleanup, no FS/waits under state.

## Calibration and conditional phases

UNKNOWN: actual conversion owners/public APIs/CropBox conventions/document-page-handle lifetime/fixture witnesses/full geometry encoding/sentence allocation/zoom domain/metric precision and tolerance. No guessed number or local inverse-only proof. Before PDF component split, an admitted unsplit actual PDFium→canonical→PDFKit slice calibrates independent PDF-space landmarks; finalize shared numeric tolerance with metric/PDF-point units/precision/inclusive boundary/error justification, then prove actual correspondence and roundtrip.

Every conditional source+pairedtest phase≤5exact named paths after same-Spec ownership/API amendment. Application/PDFium/PDFKit/test responsibility slots UNKNOWN, not scaffolded Contracts/EvidenceAnchor/helper/schema/CI/ReaderUI. No actual implementation before prerequisites. No Chat/Brief Anchor UI/Translation/futureAI requirement; geometry proof independent of them.

## Required proof, not run

Exact tuple resolves first/last actual page; independently change every identity component/otherPaper-samehash rejects. Shared encoding limits1999page/199999sentence admit encoding only, actual membership still required; one-over/negative invalid. Multiline fullsentence/multiquad preserved, truncated/drop-continuation cannot satisfy anchored semantic range.

Actual CropBox offsets/MediaBox difference/rotation0/90/180/270 fixtures assert units/axes/quad order; mirrored axis/wrong origin/reorderedvertices/double rotation fails independent landmarks even if inverse math self-consistent. PDFKit admitted zoom boundaries/interior/navigation-away-back/stale transforms/otherrevision preserve exact identity and location.

Final metric errors0/exactτ pass, smallest representable>τ/nonfinite/unsupported inputs reject; NOτ decided here. Typed missing/revision failures distinct. Raw geometry/measured values stay RAM; durable evidence only approved bounded safe outcome projection/approved fixture-code/source identity, not arbitrary raw records/paths/content hashes. No pixel-only/render success proof.

Applicable UI includes Native Canvas semantics/Korean state+action/non-color cues/actual contrast/text scaling/resize/keyboardVoiceOver label-role-state/focus return/accessible RetryCancelDelete and currentPaper failure-restart-delete races, not deferred polish. Do not create UI to claim these conditions in pure contract work.

Architect51 COMMENT/planning product BLOCK; five-source read-only, no writes/tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done requires actual calibrated public/lifetime/shared tolerance and physical transform evidence, parent gates/independent review. Planning certifies none.
