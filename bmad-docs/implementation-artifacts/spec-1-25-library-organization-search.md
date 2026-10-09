# Story 1.25 Build Spec — Library organization, search and filters

## Authority and admission

Issue#27 / `issue/27-story-1-25`; base `f14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8`. PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`; ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source, no repeated unchanged-scope SHA approval; no gate/live/paid/credential/remote/distribution permission. Parent reconciled proposal's per-SHA wording; absent predecessor is an admission fact, not a new source defect.

Historical planning assessment: Architect57 inspected exactly ROOT epics1116–1147,1181–1190 plus own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json, PaperLensApp.swift. Root-only not copied. At that phase actual1.24 was missing, planning was not implementation-ready and product was BLOCKED/StoryDone=false. At planning1.13 initial20PASS/review48BLOCK/repair49 unaccepted; local14dd7b3/c93e873 nonproduct. P1/P2/P3/P6 unproved, blankCapture FAIL, Main topology not Library. The bounded source phase below supersedes the missing-source admission, not the unproven completion gates.

## Durable organization and one query projection

Application saves tag add/edit/delete, Reading Status and Favorite; truthful labels/current committed values survive re-entry/restart. Distinguish draft/saving/committed/failed; uncertain or failed persistence never success, preserve prior values and explicit revalidated Retry. No direct UI DB or separate failure mirror.

Toolbar title/tag search combines sidebar status/Favorite against ACTUAL stored data. ONE current projection feeds card/list with identical results and1.24 ordering; presentation switch retains conditions. Search is not summary recommendation/synthetic data.

Distinct cold-loading/populated/genuinely empty Library/no-match. Empty offers real Import; no-match means conditions found none, not absent storage. Load/query failure distinct safe error/action, never empty/no-match or stale-result completion.

Application serializes saves, checks current Paper/generation/expected values; prevent stale whole-record overwrite/lost edits. Committed organization/folder change invalidates/requeries; superseded reverse query completions cannot replace current state. Delete revokes and excludes from search/recent/folders; late save/query/restart never reconstructs identity.

Short state arbitration only, no FS/DB/waits; reuse accepted1.13 lineage/operation-scoped cleanup/synchronous failure cleanup, not second policy. The source-phase inspection below pins the existing semantics; no invented FTS/index/numeric scheme.

## Conditional phase and required proof

After actual1.24, same-Spec amendment names≤5exact source+paired-test paths: existing Application commands/projection, sole persistence, Library UI and actual behavior/native tests. UNKNOWN owners aren't scaffold permission. Required composition/migrations/tests fit named bounded phases, no hidden sixth file/fallback/helperCI/schema split/new taxonomy/knowledge graph/recommendation/future AI.

Actual tag CRUD/status/Favorite save/read/restart, failure before commit/uncertain ACK/duplicate request/stale editor/Cancel race preserve committed truth. Each field/combinations/clearing/explicit empty-whitespace-Unicode semantics, card/list same result/conditions, no-match vs empty vs failure. Barrier reverse queries/concurrent edits/folder move/delete both orders; no stale/deleted return. Real restart does not persist uncommitted draft, no resurrected search/recent/folder Paper.

Native Canvas semantics/Korean state+action/non-color saving/error/delete cues, actual-background contrast/native text scaling/resize. Keyboard/VoiceOver label-role-state, accessible Retry/Cancel/Delete. Tag dialog/drawer returns opener or valid Library focus if deleted; every currently owned datum failure/restart/delete races here, no deferred polish.

Historical planning disposition: Architect57 COMMENT/product BLOCK/read-only five files, no tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done needs real accepted1.24/interfaces/durable query and native race proof, parent verification/independent review. Planning certifies none.

## Bounded product source phase (base 45acff8, Issue #27)

The dedicated `issue/27-story-1-25-product-query` worktree contains actual Workspace/Reader/notes/URL/folders owners. This phase changes exactly `PaperLensApp/Application/LibraryOrganizationService.swift`, `PaperLensApp/Infrastructure/ProductDatabase+Organization.swift`, `PaperLensApp/Features/Library/LibraryBrowserView.swift`, `Tests/Product/LibraryOrganizationTests.swift`, and this Spec. Parent owns integration, verification and commits. No tests, gates, builds, formatters, helper/renderer/live/network/credential execution in this lane. This amendment is within the existing Whole-Story acceptance, not a new architecture or StoryDone claim.

Concrete defect: `updatePaperOrganization` checks UUID/generation and owned immutable PDF but blindly replaces the whole organization. Same-generation editors, duplicate saves and another service/reopened database can overwrite later Favorite/status/tags. Require the editor's exact observed committed `PaperOrganization` (including stored tag order/labels) and compare within the sole GRDB write transaction before any mutation; reject with typed `staleOrganization`. No schema/version/migration/fallback. A failed save preserves the committed record. Retry first reloads the exact current generation and validates the owned PDF, presents that committed value (discarding the failed draft), and requires an explicit subsequent save. Cancel invokes no write; an in-flight save disables Cancel/dismissal.

Existing query semantics are retained: `en_US_POSIX` case- and diacritic-insensitive Foundation folding; search trims surrounding whitespace/newlines, then matches the entire folded substring in title OR any one user tag (not tokenized, no FTS). Tag filter folds but does not trim and requires a whole-tag match. Search, tag, status and Favorite conditions combine with AND. Empty/whitespace search imposes no condition. Tags trim surrounding whitespace, reject empty/control characters, >80 Swift Characters, >100 tags, and folded duplicate labels; labels remain Unicode, stored in normalized-key/label order. Status is unread/reading/read. Empty tags clear the stored set. Name sorts folded ascending; added/read/year descending; missing read/year last; ties use UUID string ascending. Sort facts require exact generation; duplicate IDs/invalid facts fail. One actual projection and preferences feed both list/grid, preserving filters on presentation changes.

Query-state revision acceptance is synchronous at scheduling/invalidation, not deferred until an asynchronous task begins. Both success and failure must match revision AND captured current filters. Mutation invalidates pending query results before awaiting, hides old rows during work, and refreshes on both outcomes; successful editor saves refresh immediately. Workspace owns ephemeral libraryFilter and passes a required Binding plus refreshRevision to Browser; task(id: refreshRevision) refreshes without forced view identity that resets conditions. Reader unmount/return and import/folder refresh retain the session conditions without another durable store. This does not create cross-process observation: any unrelated adapter mutation must trigger the existing owner refresh to invalidate an already delivered projection. Deletion guards remain UUID/generation/reference/hash/deletion bound; failed deletion stays visibly unreadable, tombstones are excluded.

Authored regressions use actual GRDB databases and app-owned immutable synthetic PDF files: same-generation stale/duplicate commits across services/reopen, concurrent writers, independent fields and combinations, clearing/Unicode/substring/AND/tag validation, restart/unsubmitted drafts/transaction rollback/query failure, sort/presentation preservation, reverse query success and superseded failure rejection, and query invalidation plus save-vs-delete orders. These are authored, not executed proof; the unsubmitted-draft test is not native Cancel evidence. Parent must run focused product checks and native composition. Visible UI, actual Cancel no-write and Retry composition, real VoiceOver/keyboard opener focus, contrast/text scaling/resize, screen-reader Retry/Cancel/Delete states and folder/import refresh composition remain unproven; StoryDone=false.

Parent aggregation from isolated source commit3e37b20 adapted the required filter Binding/
refreshRevision callsite and added an owned-file/GRDB workspace regression that opens and
returns from the actual Reader session, imports another Paper, and queries the retained
combined Favorite/status/tag conditions against committed records. The resulting union
passed137 ProductTests/zero failures (artifact://788); unsigned native Release arm64/macOS15
scheme build succeeded in .build/product-native-compile-20261010-e (artifacts792/793).
This supersedes the unexecuted-test statement for that integrated source only, not the
visible UI/Cancel/Retry/accessibility/runtime/Story acceptance limitations above.
