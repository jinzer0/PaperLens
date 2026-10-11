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

## Bounded pending organization activity presentation

Assessment130 inspected exactly Specs1.24/1.25, LibraryBrowserView.swift and existing
LibraryOrganizationTests.swift at source640330d. OrganizationEditor already brackets
save/revalidate awaits with busy and gates interactions, but has no explicit saving
text or accessible pending-work label. Existing criteria require draft/saving/committed/
failed distinction and Korean non-color saving cues. Repair exactly LibraryBrowserView.swift
and existing LibraryOrganizationTests.swift. Reuse busy/failed without adding operation
state, controller, persistence, query or success authority. Production-consumed internal
pure organizationEditorActivityLabel(busy:failed:) returns nil when idle, 저장 중 for
busy/nonfailed saving, 현재 저장값 확인 중 for busy/failed revalidation. Editor consumes
it in a labelled native ProgressView; keep save/revalidate/dismiss/error/CAS unchanged.
Parent branch regressions cover pending save, failed idle, pending current-value check,
and idle after revalidation; revalidation must not claim a save, failure must not claim
success. Run permitted focused/full isolated Product tests, unsigned native compilation,
independent source delta review and local evidence commit. Test strings/state projection
and source mounting do not prove rendered accessibility delivery, native interaction,
contrast/scaling/focus/physical runtime or Story acceptance. No user documents, credentials,
app/helper/SDK/provider/renderer execution, trial renewal, architecture/schema or remote
action. Retain previous receipts and full Epic objective/0-of-26 acceptance boundaries.

### Organization activity local receipt

Preimplementation `76c9fe9ee1f03afc77450d2e3bc903085ae5efd6`; executor131 implemented
the exact one-file helper/native ProgressView binding. Parent's existing paired test
covers all four busy/failed branches and distinct Korean save/revalidation labels.
Actual await contexts and unchanged operation/failure/dismissal/gating inspected by
independent132 SOURCE-ONLY CLEAR / APPROVE. Focused47/zero `artifact://1468`;
isolated Product449/zero `artifact://1470`; fresh unsigned native-bc BUILD SUCCEEDED
`artifact://1471`. Two-source diff SHA256:
`c40d8abb4d62befda0acdbcb972a052a1028173e0be60f8a2d4e82775ec64810`.
Semantic projection and mounted source are not rendered native/VoiceOver delivery,
actual keyboard/focus/contrast/scaling or physical restart/P6 proof. No app/helper binary,
protected SDK/provider/renderer trial or remote action. Story/Epic false,0/26 unchanged.

## Bounded synchronous organization action admission

Assessment137 inspected this Spec, LibraryBrowserView.swift, existing
LibraryOrganizationTests.swift and the established ImportConfirmationView admission
pattern. Actual editor callbacks lack synchronous guards before save/revalidation Tasks
or Cancel dismissal. Declarative disabled-state propagation is not callback admission;
delivered consecutive callbacks must obey the existing Cancel/no-write and in-flight
save/dismissal restriction. This is source ordering evidence, not observed native events.
Exact source scope: LibraryBrowserView.swift and existing LibraryOrganizationTests.swift.
One internal production-used OrganizationEditorInteraction replaces busy/failed state
with phases editing/saving/failed/revalidating/closing. beginSave only editing;
beginRevalidate only failed; beginCancel only editing/failed and terminal closing.
Every button begins with mutating admission before draft capture/Task/dismiss effect.
Saving completion transitions closing before successful dismiss, or failed on failure;
revalidation installs current observed/value/tags before reopening editing, or returns
failed. Completion in other phases denies. Disappearance invalidates to closing.
Derive busy/failed/blocked projections; preserve failure visibility while revalidating.
Only saving/revalidating display existing Korean pending cues; closing never claims a
save. No second failure mirror/controller/durable owner, policy or service/CAS/query
change. These are UI continuation fences, never positive write/database authority.
Parent uses the exact production value plus existing owned GRDB/service fixtures for
Cancel→Save zero commands/unchanged committed values, Save→Cancel/duplicate denial,
failed Save→explicit current-value revalidation→new explicit Save, failed revalidation
and terminal/obsolete-completion denial. No native interleaving/VoiceOver/mouse claims.
Permitted isolated focused/full tests, unsigned compile, independent delta review and
local evidence commit. Retain pending-cue receipt55dd7c7 and resolved CAS/query/Retry.
No protected app/helper/SDK/provider/renderer trial, credentials or remote operation;
full objective/0-of-26 and visible accessibility/physical restart/P6 limits unchanged.

### Organization callback admission local receipt

Preimplementation `80290b2e6e034743fa9225ea29f4e8288757a410`; executor138 implemented
the exact production interaction value and all three guarded button/continuation paths.
Parent four tests use this actual value with owned GRDB/LibraryOrganizationService:
Cancel→Save zero commands/one simulated dismiss/unchanged reopen; saving denies delivered
Cancel/duplicate/revalidation before one actual commit; owned SQL failure preserves old
record, explicit revalidation observes another editor's newer committed fields before
another explicit Save; actual generation replacement denies revalidation and terminal
disappearance denies obsolete completion. No actual overlapping native callbacks delivered.
Focused51/zero `artifact://1499`; isolated Product455/zero `artifact://1504`;
fresh unsigned native-be BUILD SUCCEEDED `artifact://1505`; independent139 SOURCE-ONLY
CLEAR / APPROVE explicitly resolves historical137 MEDIUM/P2 finding with no new finding.
Two-source diff SHA256:
`fb2c1458370c3f1ed86263bc529c913441e810cc5b78240360defed930077b63`.
Existing pending-label receipt retained; busy/failed now derived from one phase rather
than duplicate State. Tests do not mount OrganizationEditor or prove native event/VoiceOver/
focus, physical restart/P6. Service/CAS remains write authority; no actual app/helper/
SDK/provider/renderer trial or remote action. Full objective/0-of-26/Story/Epic false.

## Native sidebar and direct organization controls

Baseline3c4bcda04c0ea0e30f5db9bd47b1dcb40f460bec keeps filters in a horizontal
header and organization actions behind the editor. Implement the canonical sidebar
filters and directly accessible Favorite/Reading Status controls in existing
LibraryBrowserView.swift only. Native HSplitView separates labeled status/Favorite/
exact user-tag filters from toolbar title/tag search and the shared list/card result.
Keep the same bound OrganizationFilter/query/preferences; reset is explicit and
presentation changes retain conditions. This is an existing acceptance implementation,
not a new product/architecture/numeric-policy contract or permission change.
Direct actions copy the observed whole PaperOrganization, change only the selected
field, and call existing service.save with exact observed Paper/generation/organization.
Synchronous busy/loading/failure/readability checks precede existing perform/Task;
no optimistic row mutation, stale rebase, automatic retry, SQL/schema/new owner.
Existing failure/requery path displays committed values. Tag editor, move/deletion,
stored Summary and current query fences remain unchanged. Parent runs only minimum
existing guarded save/restart and combined-filter scenarios under implementation-first;
new UI/branch tests, broad/native gates, formatter and independent review stay deferred.
Actual sidebar resize/keyboard/VoiceOver, direct native actions/focus and real app restart
remain unproved; this source phase cannot establish Story/Epic acceptance or renew trials.

### Sidebar/direct controls local delivery

Preimplementation Spec87f4f4757b117fa0f32caa0e8599ba0ad03e039f committed before
single LibraryBrowserView source change. HSplitView mounts native labeled sidebar
filters with shared toolbar search and list/card projection; explicit reset clears
combined conditions, not saved presentation/sort. Native Favorite Toggle and Reading
Status menu display current committed values and issue existing whole-record guarded
save with observed Paper/generation/organization. Tags/other fields retained; same-value,
busy/loading/failed/nonreadable actions deny synchronously. No optimistic mutation or
automatic retry/rebase. After actual requery, authored keyboard focus returns to the
same exact Paper-generation control, or search if removed by filters/unavailable; an
already-focused different tracked control is not overwritten. Existing tag editor,
folder movement/deletion, Summary, persistence and query arbitration unchanged.
One-source binary diff against Spec87f4f47 SHA256:
`ce35f875c7fa4f87e504fa0b5ae971dcc7bb8171b4c1fe16ced23f449e282f28`.
Parent minimum existing owned GRDB restart/combined-filter/independent-identity case
and actual service stale-editor/duplicate/reopened CAS case both pass artifact1537;
changed source/UI compiled in6.62 seconds. These are storage/service checks, not
native Toggle/Menu/sidebar interaction, focus/resize/VoiceOver or app restart proof.
Implementation-first keeps new/regression tests, broad/native gate, formatter and
independent review deferred. No protected execution/remote operation; Story/Epic false.

### Persisted folder query regression

Three new LibraryOrganizationTests exercise actual sole-GRDB service projections:
all/unfiled/two UUID folders through durable moves and reopen, whole-Library count
and independent Paper-generation/PDF references, combined title-or-tag search AND
exact tag/status/favorite with decoys, list/grid equality, missing/deleted selected
folder returning none instead of all, tombstone exclusion and obsolete query fence.
Six focused folder/startup cases passed; current full isolated Product475 passed
artifact1668. Database reopen is not native app restart or visible focus/VoiceOver;
no Summary/provider/Agent/purge/renderer authority is inferred. Story/Epic gates stay
unaccepted and no trials or remote actions were renewed.

### Review172 required presentation cleanup admission fence

SOURCE BLOCK/P2: sheet binding becomes nil before its identity-free onDismiss
clears preparation/confirmation/source scope; a newly admitted input can be cancelled
or lose its scope by that old callback. Serialize cleanup rather than introducing
overlapping resource owners. Retain pending-cleanup state from admitted presentation
until its actual dismissal cleanup finishes; nil binding alone must not permit new
picker/drop/Retry/Reader admission or replacement folders/settings/confirmation.
Keep existing per-confirmation imports.cancel and matching scope stop. Native
dismissal callbacks with no pending nil presentation must not invalidate a new
preparation; explicit owned-fixture preparation interruption remains supported.
Use existing workspace state only, no schema/store/namespace/generation/physical
authority or permission change. Source scope ProductWorkspaceView.swift plus direct
Workspace regression tests; this amendment precedes the bounded source correction.
