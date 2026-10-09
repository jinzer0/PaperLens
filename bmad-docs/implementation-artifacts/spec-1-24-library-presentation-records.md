# Story 1.24 Build Spec — Library presentation and record revisits

## Authority and admission

Issue#26 / `issue/26-story-1-24`; base `f14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8`. PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`; ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Commit own Spec before source; no repeated unchanged-scope SHA approval. No gate certification or credential/live/paid/remote/distribution permission follows.

Architect56 inspected exactly ROOT epics1083–1115,1181–1190 and own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json, PaperLensApp.swift. Root-only source not copied. Planning ONLY, not implementation-ready; product BLOCKED, StoryDone=false. Require actual1.16–17/1.22–23 and real Paper/Reader/persistence/deletion. At planning,1.13 initial20PASS/review48BLOCK/repair49 unaccepted; local14dd7b3/c93e873 are nonproduct. P1/P2/P3/P6 unproved, blankCapture FAIL. Main remains topology UI.

## Projection, sorting and revisit

One Application-owned current Paper/generation projection feeds BOTH card/list and ordering. Show actual title/year/usable grounded summary/Reading Status/Favorite/more-actions; distinguish absent metadata, insufficiency, running/failed Job and deletion failure. Missing optional summary/metadata does not block a readable PDF. Hover/detail actual abstract snippet/topic tags also accessible without hover.

Display stored status/Favorite only; editing/search/filter/tag organization belong1.25. Rendering never generates summary, retains1.23 claim links/insufficiency. No fake completed Brief or future Brief dependency.

Default recently read; provide name/recently added/recently read/publication year sorts. Direction/collation/ties/null placement UNKNOWN until actual query contract, no invented dates/year. Persist card/list selection through sole Application/persistence and restore after restart; failed save truthful. This AC does not silently add sort persistence.

Open only current readable non-deleting Paper after Application admission, restore actual last position and Paper-bound Highlight/Note. Missing/stale locations follow accepted Reader/annotation outcomes; late wrong-Paper callbacks cannot replace context.

## Native delete confirmation and lifecycle

Alert captures target identity/name/actual scope/irreversibility. Cancel changes no Paper/records/Job/saga and returns opener focus. Delete revalidates captured target, never current-selection substitution. Revocation blocks new work/access/writer/publication before effects; drain actual existing producers outside short state arbitration.

Same saga with fresh per-cleanup/removal operation and immutable target. Guard failure synchronously removes owned bytes before permit release; actual Agent purge where applicable, owned absence and durable cascade/contentless tombstone before success. Delete every currently owned Paper datum; reusable Templates survive.

Failure stays non-openable card/row `삭제 미완료`, accessible SAME-saga Retry Deletion, not ordinary Job Retry/new Paper. Late query/detail/Reader/producer/old retry callbacks cannot reopen or resurrect. No false erasure or new accepted-limit disclosure.

## Conditional phase and required proof

### Actual local source phase — 2026-10-09 human source order

This phase supersedes the planning-only source prohibition, not canonical AC, privacy,
physical-proof or Story completion requirements. Exactly five writable files: this Spec;
`PaperLensApp/Application/LibraryOrganizationService.swift`;
`PaperLensApp/Infrastructure/ProductDatabase+Organization.swift`;
`PaperLensApp/Features/Library/LibraryBrowserView.swift`;
`Tests/Product/LibraryOrganizationTests.swift`. Librarycore stays read-only. Infrastructure
uses its sole adapterRead/adapterWrite queue and registers an organization migration for
the parent to install in the existing migrator. No second startup/database/Folder store.

Implement persisted list/grid and sort preferences and current-generation Paper status,
Favorite and explicit user tags (shared 1.25 operations, not 1.25 completion). One durable
query feeds both presentations, search and conjunctive filters; failure/loading/empty/no-match
are distinct. Writes revalidate current generation, ready state, deletionID absence,
canonical owned PDF reference, digest and non-writable regular PDF. Tombstoning removes
organization/tag content transactionally through migration triggers; deleting rows remain
visible but non-editable/non-openable with same-saga retry delegated to lifecycle.

Comparators: name ascending POSIX-normalized case/diacritic folding; added/read/year
descending; missing read/year last; all ties use canonical UUID ascending. Default recently
read. Persist sort as an explicit local addition under this human order. Actual Reader and
metadata owners supply generation-bound sort facts to Application; absent facts stay nil,
never invented. No duplicated metadata/read position storage, inferred tags or summaries.
Native view requires explicit Import/Open callbacks and parent-owned sort-fact provider;
open callback remains responsible for read lease and Reader restoration. Delete captures
identity/title, rechecks generation through Application, and uses existing lifecycle.

Parent owns migration registration, composition and Reader/metadata/Folder integration.
All test/build/gate/formatter/commit/remote/UI/document execution is skipped by explicit
instruction. Paired regressions are source evidence only; physical/native proof remains
unverified, product BLOCKED and StoryDone=false.

UNKNOWN actual query/storage/composition/schema/preference APIs and comparator. Before edits, same-Spec amendment names≤5exact source+paired-test files from actual predecessors; only Main composition located. No guessed Library/repository/test scaffold, second cache/visibility/persistence, helper/CI/future-AI stubs.

Both views same identity/order/real missing states/details/grounding; all four admitted comparators including ties/null; card/list actual restart and save failure. Real last-read/Highlight/Note, reject missing/deleting PDF and late context. Alert target/scope/Cancel unchanged; real delete failure/restart/same-saga retry, barriers prove actual drain and synchronous captured-scope cleanup. All currently present Paper data covered, unrelated Paper intact.

Native Canvas semantic styling, Korean state+action and non-color cues; actual-background contrast, native text scaling/window resize. Keyboard/VoiceOver label-role-state, dialog/detail focus return and accessible Retry/Cancel/Delete. No deferred polish.

Architect56 COMMENT/product BLOCK; five-source read-only, no tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done needs actual owners/gates/durable physical/native proof plus parent verification/independent review; planning passes none.

## Persisted abstract/topic identification — bounded actual product source

Canonical Story1.24 (root epics1093–1094) requires actual missing states and abstract/topic
information in hover/detail. Current bdffce6 LibraryBrowserView.paperContent shows title,
year/status/Favorite/user tags but no abstract or source topic presentation. Reader metadata
already has validated, provenance-bearing abstract/topics fields in sole GRDB. This is a
concrete missing mounted product surface, not permission to generate metadata or summary.
The separately investigated URL duplicate warning already matches its committed unknown
predownload contract; it is unchanged. Source296/native-x/source75 remain prior evidence.

Reuse existing OrganizationSortFacts/currentFacts/query fence. Add REQUIRED optional
ReaderMetadataSnapshot metadata to the facts initializer, updating all actual callers;
nil means no published stored metadata observation, not success or an invented empty
result. Parent updates ProductDatabase+LibraryFacts.swift to return the validated snapshot
from its existing one-read-transaction ready/nondeleted/current-generation/SHA/reference/
visible-revision join. No additional database, selector, metadata generation, migration,
poller, query cache or PDF access. Observation is a query-time snapshot, not continuously
current publication/read authority. Keep sorting, organization, read leases and deletion
owners unchanged. Corrupt payload still fails the real query; never quietly return nil.

Both card/list must expose actual abstract/topic fields and a native explicit detail affordance.
Keep source topics distinct from user tags. Unknown stays explicitly unknown; conflicting
candidate texts remain a conflict, never a guessed winner. Detail shows actual source kind/
sourceID for candidates and bounded Unicode-safe excerpts; do not invent confidence, convert
PDF Subject into abstract, infer topic tags from user tags, or display Brief/summary success.
Reusing the existing generation-filtered facts is mandatory. Capture actual selected Paper
identity/data-only facts; invalidate stale detail on query invalidation, work, or disappearance
and return focus to its captured opener. No async callback may reopen stale detail.

Worker EXACT five files: Application/LibraryOrganizationService.swift,
Features/Library/LibraryBrowserView.swift, Tests/Product/LibraryOrganizationTests.swift,
Tests/Product/ProductWorkspaceTests.swift and this Spec. Parent alone changes
Infrastructure/ProductDatabase+LibraryFacts.swift for the same-transaction fact extraction.
Worker skips all tests/builds/lint/format/gates/commits/remotes/workflows/delegation/runtime.
Parent verifies real owned GRDB storage/reopen/current-revision/generation/no-payload/conflict/
corrupt-data behavior, unchanged user-tag filters and focused/union/native compilation;
then concrete metadata/query-lifetime review, exact evidence/local commit. Existing protection,
calibration/provider/SDK/P1/P2/P3/UI/trial/remote/Story boundaries remain unchanged and unproved.

### Authored identification surface and paired regressions (not executed)

`OrganizationSortFacts.metadata` is a required optional constructor argument carrying only
the stored query-time `ReaderMetadataSnapshot`; all worker-owned constructor calls explicitly
pass nil. Both mounted presentations use the existing `paperContent` and generation-filtered
`currentFacts` for abstract/source-topic previews, explicit unknown/conflict and a native detail
button. Source topics remain separate from user tags and existing title/user-tag search.
`LibraryIdentification` captures the exact OrganizedPaper and data-only snapshot; detail lists
all actual candidate texts/source kinds/source IDs with character-safe 1,200/256-character
excerpts. Previews are bounded to 220/120 characters; conflict never selects the first candidate.
The detail expressly describes a stored observation, not current publication or access authority.

`invalidateObservation` synchronously clears the captured detail and currentFacts alongside
the existing query invalidation on refresh/filter, mutation/preferences/editor work, import
intent and disappearance. Only accepted query completions install generation-matching facts;
no asynchronous completion opens detail. Dismissal targets the captured detail button's
dedicated native focus binding, not the existing more-actions opener.

Authored tests: `testMetadataExcerptsPreserveGraphemesAndPreviewNeverChoosesConflictingCandidate`;
extended `testYearFactsOnlyUseCurrentRevisionWithNoConflictPrecedence` using the existing owned
canonical extraction publication fixture for persisted abstracts/topics/provenance/conflicts,
reopen, no payload, publication replacement, pointer removal, generation replacement and
unchanged topic-versus-user-tag/search behavior; and
`testLibraryMetadataQueryRejectsCorruptPayloadAndFencesMismatchedRevisionIdentity` for retained
payload with mismatched revision/generation/SHA/reference and malformed/invalid metadata.
`testLateLibraryQueryCannotAdmitOldMetadataFactsAfterInvalidation` pairs actual stored facts
and service projections with the existing request-revision acceptance and Paper-generation
fences; it does not claim to mount or exercise the native sheet.
These are authored source, not execution evidence or native accessibility acceptance.
Parent owns DB fact extraction, focused/union/native verification, query-lifetime/detail/focus
review, durable evidence and commit. No worker tests/builds/gates/lint/formatters/runtime or
commits were run; canonical 0/26, Epicfalse, product BLOCKED and StoryDone=false are unchanged.

### Parent verified actual persisted identification binding

Parent updated only ProductDatabase+LibraryFacts alongside the worker-owned five paths:
unchanged one-read-transaction identity joins now return the validated metadata snapshot;
corrupt data still throws. Focused LibraryOrganization/ProductWorkspace40 tests passed,
zero failures (artifact1022), including3 new cases and the expanded year/published fixture.
Full Product299 passed, zero failures (artifact1026). Fresh unsigned native-y Release
arm64/macOS15 compilation succeeded (artifact1027). Independent source review78 returned
SOURCE-ONLY CLEAR/APPROVE, no concrete metadata/provenance/query/detail delta finding.
Five-source binary delta against preimplementationaa1b787:
8fefb89e817ff05cff9d0ddfc0f3d6e49908e8d463f0de6cc3726745fe6c69ed.
No new migration/database/selector/poll/lease or actual document/provider/helper operation.
The mounted source now renders stored abstract/topic observations and true missing/conflict
states, not generated summaries or synthetic successful metadata. Physical card/list/detail,
native opener-focus return, accessibility/contrast/resize remain unverified; compilation,
windowless owned-fixture tests and source review are not those proofs. Canonical0/26,
Epicfalse and StoryDone=false remain unchanged; no protected trial or remote action ran.
