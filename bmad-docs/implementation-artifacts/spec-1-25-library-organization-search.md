# Story 1.25 Build Spec — Library organization, search and filters

## Authority and admission

Issue#27 / `issue/27-story-1-25`; base `f14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8`. PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`; ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source, no repeated unchanged-scope SHA approval; no gate/live/paid/credential/remote/distribution permission. Parent reconciled proposal's per-SHA wording; absent predecessor is an admission fact, not a new source defect.

Architect57 inspected exactly ROOT epics1116–1147,1181–1190 plus own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json, PaperLensApp.swift. Root-only not copied. Planning ONLY, not implementation-ready; actual1.24 missing, product BLOCKED/StoryDone=false. At planning1.13 initial20PASS/review48BLOCK/repair49 unaccepted; local14dd7b3/c93e873 nonproduct. P1/P2/P3/P6 unproved, blankCapture FAIL, Main topology not Library.

## Durable organization and one query projection

Application saves tag add/edit/delete, Reading Status and Favorite; truthful labels/current committed values survive re-entry/restart. Distinguish draft/saving/committed/failed; uncertain or failed persistence never success, preserve prior values and explicit revalidated Retry. No direct UI DB or separate failure mirror.

Toolbar title/tag search combines sidebar status/Favorite against ACTUAL stored data. ONE current projection feeds card/list with identical results and1.24 ordering; presentation switch retains conditions. Search is not summary recommendation/synthetic data.

Distinct cold-loading/populated/genuinely empty Library/no-match. Empty offers real Import; no-match means conditions found none, not absent storage. Load/query failure distinct safe error/action, never empty/no-match or stale-result completion.

Application serializes saves, checks current Paper/generation/expected values; prevent stale whole-record overwrite/lost edits. Committed organization/folder change invalidates/requeries; superseded reverse query completions cannot replace current state. Delete revokes and excludes from search/recent/folders; late save/query/restart never reconstructs identity.

Short state arbitration only, no FS/DB/waits; reuse accepted1.13 lineage/operation-scoped cleanup/synchronous failure cleanup, not second policy. UNKNOWN exact case/Unicode/token/substring/AND-OR semantics, tag identity/rename scope/validation, status set, null/tie sorts, query-restart policy, persistence APIs/schema; pin before edits, no invented FTS/index/numeric scheme.

## Conditional phase and required proof

After actual1.24, same-Spec amendment names≤5exact source+paired-test paths: existing Application commands/projection, sole persistence, Library UI and actual behavior/native tests. UNKNOWN owners aren't scaffold permission. Required composition/migrations/tests fit named bounded phases, no hidden sixth file/fallback/helperCI/schema split/new taxonomy/knowledge graph/recommendation/future AI.

Actual tag CRUD/status/Favorite save/read/restart, failure before commit/uncertain ACK/duplicate request/stale editor/Cancel race preserve committed truth. Each field/combinations/clearing/explicit empty-whitespace-Unicode semantics, card/list same result/conditions, no-match vs empty vs failure. Barrier reverse queries/concurrent edits/folder move/delete both orders; no stale/deleted return. Real restart does not persist uncommitted draft, no resurrected search/recent/folder Paper.

Native Canvas semantics/Korean state+action/non-color saving/error/delete cues, actual-background contrast/native text scaling/resize. Keyboard/VoiceOver label-role-state, accessible Retry/Cancel/Delete. Tag dialog/drawer returns opener or valid Library focus if deleted; every currently owned datum failure/restart/delete races here, no deferred polish.

Architect57 COMMENT/product BLOCK/read-only five files, no tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done needs real accepted1.24/interfaces/durable query and native race proof, parent verification/independent review. Planning certifies none.
