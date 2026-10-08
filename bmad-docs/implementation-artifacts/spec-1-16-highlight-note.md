# Story 1.16 Build Spec — Native Highlight and personal Note

## Authority and admission

Issue#18 / issue/18-story-1-16, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec commit precedes source; no repeated unchanged-scope SHA approval. No gate, credential/live/paid/remote/distribution permissions inferred.

Architect45 inspected exactly canonical ROOT epics.md:815–850, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift. Root-only excerpt not copied. Planning ONLY, not implementation-ready; actual1.14 durable Paper/deletion and1.15 native Reader owners absent. Product BLOCKED, StoryDone=false; P1/P2/P3/P6 unproved, blankCapture remains FAIL. Parallel1.13 policy is not accepted product proof; local purge14dd7b3/GRDBc93e873 not Main/SDK/physical persistence.

## Acceptance and ownership

Valid native text selection offers Highlight/Add Note/Copy, never selection→Paper Chat or automatic/manual Note injection. Copy only original selected text, no annotation save or Provider dispatch. Highlight captures originating Paper/location. Add Note opens NotesDrawer preserving original text/Reader context; later selection changes cannot retarget draft. Close returns same Reader position/context.

Application/persistence authoritatively saves both Paper-bound record kinds, not transient overlays/direct PDFKit writes. Only confirmed guarded commit may show saved. Failure/cancel/close without commit never fabricates record or removes existing committed records. Re-entry and actual restart reload records and linked native PDF locations from durable authority, not memory/cache reconstruction.

Reader owns ephemeral viewport/page/zoom/selection/presentation; never modifies immutable imported PDF. Capture originating Paper/generation/input/location and Drawer intent. Late UI result cannot navigate/mark another Paper saved. Keyboard/VoiceOver invoke selection actions and Save/Close with truthful feedback/focus return.

Personal Note/native location is NOT canonical AI Anchor. No fabricated sentenceID/extraction revision/EvidenceBundle, no Provider payload changes. Complete local annotations without future parsing/Translation/Chat/Brief, no new taxonomy/search.

## Save/delete arbitration

Deletion revokes annotation save admission. Queued draft/repeated Save/old completion cannot reactivate Paper. For DB-only save, guarded commit and cascade serialize: either save precedes and is deleted, or save rejects. UI callback is not publication authority. Completed deletion removes both kinds; restart/late-save cannot restore. Reimported identical bytes are different Paper.

Only if actual storage requires owned FS: writer permit before access through close/cleanup; publication permit through rename/guarded commit or synchronous failed-guard cleanup. Delete drains admitted writers/publishers before removal/absence; uncertainty/cleanup failure retains obligation. No FS/DB/blocking submit/drain under short state arbitration. No startup scavenging/error suppression/synthetic ACK instead of guarded save/delete.

## UNKNOWNs and conditional ≤5 owners

Exact geometry/location/input-version, annotation identity/idempotency, transaction selector/public/storage APIs, owning files/test harness UNKNOWN until accepted Reader/storage. Do not pre-generate schema/migrations/adapters/fallback store; reuse sole persistence/migration authority and applicable1.13 rules, not invent Provider Job for local save.

Bind exact existing paths in amended phase before source: (1) Reader selection/NotesDrawer; (2) Application annotation save/read; (3) persistence/Paper deletion; (4) actual Application/persistence tests; (5) real Reader/accessibility tests. Responsibility slots are not existing implementations or admitted scaffold. Required wiring must fit named phase, no helper/CI/AI dependency expansion.

## Required observable proof

Single/multiline/supported multipage/rotated/scaled selections preserve text/native location; empty/invalid saves nothing. Copy correct and zero Provider dispatch. Open/edit selection/save/close via keyboard/mouse; captured draft remains original and same context returns. Late completion after Paper switch does not affect new Paper.

Both record kinds actual commit/readback, validation/storage failures, repeated/out-of-order result and real fresh store/app restart. Barrier save admission/commit/UI completion against deletion in both orders; no restored records, unrelated Paper intact. Conditional physical write/close/rename/commit races, held publisher and cleanup failure prove synchronous cleanup/drain, not mocked policy-only assertions. Actual keyboard/VoiceOver in actual Reader, no mocked-control acceptance.

Architect45 COMMENT/WATCH, five-source read-only only; no writes/tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done needs accepted prerequisites, exact APIs and real durable restart/delete/native accessibility evidence plus parent verification/independent review. Planning commit passes none.
