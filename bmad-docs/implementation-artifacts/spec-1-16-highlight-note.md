# Story 1.16 Build Spec — Native Highlight and personal Note

## Actual admitted Reader binding — parent verified

The existing annotation migration and CRUD remain owned by the sole ProductDatabase. The next source phase binds `NativeReaderView.swift`, `AnnotationInspector.swift`, `ProductWorkspaceView.swift`, `ProductDatabase+Annotations.swift`, and `ReaderAnnotationBindingTests.swift`. Workspace supplies the guarded current Paper/generation/SHA identity and its real AnnotationService. ReaderPresentation privately owns the PDFView/document; ReaderAnnotationContext holds only weak PDF references and pins every capture/reveal/copy/CRUD operation through the actual ReaderSession. It verifies session, document and durable identity before and after each operation. No original PDF modification, Provider dispatch, AI context or calibrated canonical geometry is added.

Reader discard synchronously invalidates context and clears data-only drafts/results before detaching the document and releasing its actual lifecycle lease. Retained old contexts cannot revive; closing the inspector preserves Reader position. The native Highlight/Note inspector is mounted only after document admission. Parent executed the 129-test ProductTests union (including 12 real owned-file/GRDB/windowless-PDFKit binding regressions), with zero failures, and unsigned arm64 native full-scheme compilation succeeded in `.build/product-native-compile-20261010-d`. Evidence: `evidence/epic-1-product-vertical/local-verification.json`.

This supersedes historical owner-absence/source-only wiring status below, not the acceptance criteria or protected boundaries. Visible mouse/keyboard/VoiceOver/focus behavior, successful clipboard interaction, live authentication, physical renderer/profile gates and Story completion remain unproved. StoryDone=false.

## Actual implementation phase — explicit source-order instruction

This phase supersedes the earlier planning-only absence of owners; it does not claim runtime acceptance. Exact five mutable owners are this Spec, `PaperLensApp/Application/AnnotationService.swift` (immutable selection snapshot and CRUD use case), `PaperLensApp/Infrastructure/ProductDatabase+Annotations.swift` (sole-queue guarded SQL and migration registration), `PaperLensApp/Features/Reader/AnnotationInspector.swift` (native editable drawer and selection actions), and `Tests/Product/AnnotationServiceTests.swift` (real GRDB persistence regressions). No tests/builds/gates/formatters/commits/remotes run in this phase.

Public service takes an admitted Paper UUID/generation/SHA snapshot and never opens or rewrites PDF bytes. Snapshot capture accepts the actual Reader PDFView and admitted PDFDocument and requires object identity and currentSelection membership. Ordered page/line rectangles are PDFKit page-native coordinates (unrotated page space, PDFKit origin and units), with media/crop boxes and page rotation retained. These are not canonical geometry/AI Anchors; parent mapping must explicitly convert them. No guessed tolerance or geometry-worker dependency. The Reader lease/revocation owner admits document access and parent binds this inspector to that lease; stale DB generation/status/reference/deletion guard remains authoritative at every read/write.

Notes are limited to 16,384 UTF-8 bytes; selected original text to 65,536 bytes and 4,096 nonempty rectangles. Draft capture remains frozen while later selection changes. Revision compare-and-swap rejects repeated/stale edits rather than overwriting newer text. SQL migration installs foreign-key cascade plus tombstone/generation-change deletion triggers because Library retains tombstones. Parent registers `ProductDatabase.registerAnnotationMigrations(in:)` in the existing migration owner; no feature queue/startup/fallback schema. Actual restart/delete/CAS tests are supplied but intentionally unexecuted; GUI/accessibility and physical integration remain parent verification, not FakePASS.

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

## Bounded complete native reveal correction

Current ReaderAnnotationContext.reveal silently skips a saved rectangle when PDFKit
cannot reconstruct its selection, then installs a partial overlay and navigates as if
the saved native location were completely revealed. Reject that missing fragment with
AnnotationError.invalidSelection before installing any overlay or navigating. Keep
existing membership, page geometry, session and durable identity checks. This is not
canonical AI geometry validation, PDF text recalibration or a new publication owner.
Exact source scope: existing AnnotationInspector.swift and ReaderAnnotationBindingTests.swift.
Owned windowless PDFKit fixtures may use its public PDFDocumentDelegate page-class hook
to deterministically deny one later page selection after a genuine captured multi-page
annotation; assert no partial overlay/navigation, no saved-record loss and no PDF rewrite.
Also cover complete reveal and session revocation during reconstruction. Parent owns
focused/full isolated tests, fresh unsigned build, independent review and local evidence.
No visible renderer/accessibility/clipboard trial, live request, remote operation or
Story acceptance is admitted or inferred; existing protected gates remain unfinished.

### Complete-reveal local receipt

After preimplementation Spec `b4a209d5b280029a37ee5d1b42d980c517453926`, missing
PDFKit rectangle selection throws before overlay installation/navigation. Owned real
multi-page capture verifies complete reveal, later-fragment refusal preserving prior
overlay/page/records/imported bytes, and a later successful complete reveal. Actual
session close during reconstruction denies presentation and retains the saved record.
Focused17/zero `artifact://1440`; isolated full Product443/zero `artifact://1445`;
fresh unsigned native-az `artifact://1446` BUILD SUCCEEDED. Independent126 SOURCE-ONLY
CLEAR / APPROVE, no actionable delta findings. Two-source binary diff SHA256:
`8c3a76173418e9d9fc473d1dd15092f3439dbc0f97903adfa5030e4936fe437d`.
Windowless tests and source review do not establish visible native interaction,
VoiceOver/focus, clipboard success, application restart or calibrated AI geometry.
No protected execution/remote action; Story/Epic false, canonical completion0/26.

## Direct admitted selection controls — implementation-first delivery

At22bb9df, Highlight/Add Note/Copy were available only inside an already-open inspector.
Canonical1.16 selection actions and Add Note drawer entry require direct Reader controls.
Routine scoped implementation used existing NativeReaderView.swift and AnnotationInspector.swift;
no acceptance/architecture/privacy/authority change or separate approval was inferred.
Worker145 authored direct accessible controls while admitted, with genuine bounded native
capture on action (no selection Boolean/observer used as authority). Private lazy context
uses actual ReaderSession pins/PDF/document/identity. Add Note freezes original selection
and opens/focuses the existing editor; pending drafts/edits are retained, not retargeted.
Copy uses actual existing guarded original-text clipboard method; a temporary weak-PDF
context is invalidated afterward without opening the drawer or writing annotations.
Highlight and Note Save require actual guarded commit and durable readback before saved
feedback. Shared editor helpers retain pre/post identity checks across publication;
context/presentation interruption fences prevent closed contexts from remounting. Focus
return to the originating annotation control is authored without moving the PDF. Existing
search/restoration/metadata/reveal, original PDF bytes, Provider and sole database unchanged.
Two-source scope delivered with independent URLImportView correction under Spec1.18.
Combined three-source diff versus22bb9df401203678d4cd39529c612c460d41febc SHA256:
`925183e894530dce1c5067d1cc618eb09d8680106d916bb3054b865e175a0e1d`.
Minimum existing Reader nominal search/no-results/latest-request and URL pre-Continue
cancel/no-grant cases both pass artifact1535; changed UI/source compiled in5.30 seconds.
These cases do NOT verify the new direct controls, pending draft/readback/reentrancy,
focus/accessibility or successful clipboard. User implementation-first defers new/correction
tests, broad/native gates, formatter and independent review in all lanes. Actual UI, restart,
physical profile and canonical Story proof stay false; no protected trial or remote action.
