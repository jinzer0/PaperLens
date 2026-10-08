# Story 1.14 Build Spec — Actual Library, local PDF import and deletion

## Authority and admission

Issue#16 / `issue/16-story-1-14`, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Commit own Spec before source; unchanged-scope local work requires no repeated SHA approval. Material scope changes still require governance. Authority does not pass gates or permit credentials/paid/live/remote/distribution.

Architect43 read exactly ROOT epics.md:750–782, own SOLUTION-DESIGN, Story1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift; root-only canonical source not copied. Parent reconciled proposal's per-SHA approval wording with Whole-Epic authority. Trace AD-1/5/6/7/10/11, FR-001–003/005/007/030–034, UX-DR1/4–8/26/35.

Planning ONLY, not implementation-ready. Product BLOCKED pending actual P1/P2/P3, real1.10–12 connections and applied/accepted1.13 policy. StoryDone=false. P6 unproved/blankCapture FAIL. Local purge14dd7b3/GRDBc93e873 are not SDK/Main/product persistence. Current Main is topology UI, not onboarding/Library.

UNKNOWN: actual connection/selector/slot APIs; durable Paper/Job/saga/epoch transaction boundaries; security-scope/input API; owned storage/stage layout; physical permits/cleanup/Agent verification; actual Library composition. Bind these in same Spec before product source. Reader geometry/timing belongs to1.15/P6; no full schema/helper/CI split now.

## Required end-to-end behavior

1. Fresh full-window onboarding offers native API-key and official Codex browser/device paths equally. Real authenticated current typed connectionTest plus selector promotion is prerequisite. Explicit Continue enters actual empty Library, never automatically. Failed/stale/synthetic/model/identity/import-only results cannot enable entry; no UI-selected second authority.
2. Selecting/cancelling a local input creates no Paper/Job. Explicit confirmation allocates fresh Paper UUID/generation and minimal Import Job; obtain writer permit BEFORE first access within valid security scope. Copy bounded source to attempt-owned stage; validate declared PDF type/magic, close handles and return typed outcome. Independent immutable Paper-owned physical copy, no source alias/link/bookmark/shared blob. SHA is content identity, not lifecycle identity.
3. Apply1.13 immutable input and fresh attempt/fence/correlation/epoch reservation before mutation. Closed validated stage alone acquires distinct publication permit; hold through rename/guarded durable PDF-reference+Job-success+usable-pointer commit or synchronous failed-guard removal. Guards include current running attempt/fence/input/Paper/epoch/permit and applicable config, never wildcard. Local import dispatches no AI request.
4. Writer spans access through close/cancellation cleanup. Revoked writer removes bytes before release. Close source handles/release scope on all paths, no retained bookmark; restart Retry may require source reselection. Library renders actual durable progress/success/failure, not optimistic filesystem presence.
5. Delete durably revokes Paper/current generation and new dispatch/writer/publication before cancellation effects. Pending/running fail paperDeleting, no ordinary Import Retry. Drain admitted writers/publishers; actual Agent-owned purge/closure/absence and owned stage/final/cache removal plus durable cascade/contentless tombstone BEFORE success. Main never scans Agent zone; terminal/cancel is not drain.
6. Any drain/purge/removal/absence/finalization failure remains unopenable `삭제 미완료`; only same idempotent saga `Retry Deletion`. Never reactivate tombstone, reconstruct from files/startup/late callbacks or share cleanup across Papers. A later import uses new UUID/copy.
7. Restart running→failed/interrupted without renewing fence/replaying ambiguous dispatch; preserve historical outcomes/usable result/cleanup debt. Restore truthful actions, missing referenced PDF becomes failure, orphan stage never becomes Paper. Deletion restores same saga, no Open/Import Retry.

Short state arbitration only reservation/decision/accounting. No FS/DB/transport/blocking callbacks/drain under state; execute effects outside and revalidate lineage. No raw keys/paths/documents/bodies in diagnostics or false erasure claims. No Open Reader until actual Reader exists. URL/folder/duplicate/Reader/parsing/Translation/Chat/Brief/summary are excluded, no stubs.

## Conditional ≤5-file phase

After prerequisites/exact amendment: inspected PaperLensApp/App/PaperLensApp.swift composition; proposed PaperLensApp/Application/LocalLibraryLifecycle.swift; proposed PaperLensApp/Adapters/LocalPDFImportAdapter.swift; sole persistence/publication owner path UNKNOWN; paired actual lifecycle/integration test path UNKNOWN (proposal Tests/LocalLibraryLifecycleTests.swift not existing wiring). These are ownership slots, not permission to scaffold. Fit actual source/tests/callsites in bounded same-Spec phase before edits; no second DB/migration/visibility owner or hidden sixth file.

## Required proof, not observed here

Both genuine onboarding paths and explicit Continue; failed/stale probe and CAS races stay outside Library. Confirmation Cancel zero Paper/Job/files; source change/removal proves copy independence; type/magic/resource exact and one-over cases. Real scope/read/write/close/rename/DB failure cleans/releases in correct order, failure retains debt.

Deterministic barriers at permit/copy/close/rename/commit versus deletion in both orders: held producers block removal; state remains available during outside-lock waits. Actual Agent failure/unknown closure cannot yield success. Crash before/after acceptance, staging, rename, DB success, deletion revoke/purge/tombstone restores correct actions, not old lineage. Duplicate/late results/restart/Retry never resurrect; referenced-missing and unreferenced-present artifacts are not usable Papers.

Architect43 COMMENT/WATCH, read-only five-source proposal, no tests/build/formatter/GUI/SDK/auth/network/commits. Planning checks are not product evidence; Done needs actual dependencies/physical durable UI lifecycle, scoped parent gates and independent review.
