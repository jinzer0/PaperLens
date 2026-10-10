# Story 1.24 Build Spec — Library presentation and record revisits

## Stored title and year candidate identification

Baseline1408cd4f85d0fbced4688121e150838494ce1403 Library rows/cards/detail
show the durable imported Paper name, numeric accepted year, abstract and topics,
but omit validated stored metadata title candidates and omit year candidates/conflict
from detail. Numeric nil displays year absence even when conflicting or nonnumeric
actual source candidates exist. Exact source scope: LibraryBrowserView.swift only.
Keep durable Paper name and name-sort/alert/action identity unchanged; separately show
stored source-title preview through existing grapheme-safe/no-conflict-precedence
LibraryMetadataPresentation.preview. Same card/list and captured detail reuse existing
generation-filtered facts and stored metadata snapshot. Detail shows title/year through
its existing bounded labelled candidate/provenance renderer. Conflicting years must
remain explicit; known nonnumeric candidates are unconfirmed, not invented numeric
years or absent source. Rename the existing detail action to include general Paper
information without a second detail/focus owner. No rename/persistence/schema/SQL/
query/sort/summary/provider/read-authority changes, guessed precedence, topics-as-tags
or PDF attribute access. Parent minimum existing metadata excerpt/conflict and actual
current-revision year facts scenarios/source compilation only; new native UI tests/
review/full/native/rendered/accessibility gates remain deferred; acceptance stays false.

## Compact saved Summary preview versus complete detail

Baseline e50a60f2f2d015a0e0365e6d3a175d44330b96fe renders full saved Summary text
in both rows/cards, contrary to canonical one-line preview. Change only
LibraryBrowserView.swift/LibraryStoredSummary: showEvidence false renders one native
line with trailing truncation and Korean preview label; detail keeps full selectable
original text and every full ordered quote/page. Do not truncate persisted/result
bytes, construct a replacement Summary, change observations/identity/availability,
hide actual recent-attempt or insufficiency/failure states, or modify navigation,
organization/focus/actions/queries/SQL. Same validated record feeds both surfaces.
Parent minimum existing stored-summary case/source compilation only; new UI tests,
independent review/full/native/accessibility gates remain deferred; Story/Epic false.

### Compact preview delivery receipt

Worker147/agent://147-CompactSummaryPreview read applicable integration Spec9639602
then edited only LibraryStoredSummary. Preview title explicitly labels one-line native
Text with trailing truncation; detail keeps complete original selectable text and
every ordered full quote/one-based page. No substring/replacement model/storage,
identity/availability/attempt/insufficiency or sidebar/action/focus/query change.
Source diff SHA256 against96396028cc32cb2b8a1f278ef9b0a9f7ce5e31c4:
`bd680187b03aabe22345cc7ebdc00d924066681d3bbea7021f6eb7cab6967b28`.
Parent existing canonical saved Summary retained-revision reopen and actual Reader
search cases both pass exit0 with changed source compilation5.46 seconds. Reopen
fixture injects independent geometry; it is not geometry-free archive restart or
compact/full-detail rendered behavior/accessibility proof. No new tests/review/full/
native/formatter/protected trial; Story/Epic acceptance remains false.

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

## Native Folder-save progress cue

Root canonical epics1181–1189 applies Korean non-color progress cues to the1.24 Library UI.
PaperMovementSheet already tracks actual pending saving but only disables destinations/
Save; no labelled pending cue is rendered. Add one native ProgressView("폴더 배치 저장 중")
with matching accessibilityLabel while saving. Exact source: LibraryBrowserView.swift
only; no helper/state/controller/authority/service/Cancel/commit/load logic change.
Existing captured movement admission/CAS/recovery proofs retained. Parent permitted
owned Folder/Library tests and unsigned compile; static source cue is not observed
rendered progress/VoiceOver/focus or actual Cancel/Save interleaving. No actual app/helper/
SDK/provider/renderer trial or remote operation; Story/Epic0-of-26 unchanged.

Parent direct one-line LOW-risk source correction; no new tests for a literal native
label (no fabricated rendering/VoiceOver assertion). Current isolated Product455/zero
`artifact://1507`; fresh unsigned native-bf BUILD SUCCEEDED `artifact://1508`.
One-source diff SHA256 `3afc8f395198673ad8a043e0b7d4f8221863a88a0d728049ff134e247242e76f`.
Parent inspected the actual saving predicate and sole added ProgressView; prior80
captured movement authority/CAS remains unchanged. No fresh independent review claimed
for this single literal cue; prior139 concerns separate editor interaction, not this cue.
Root epics is root-only, absent from the integration worktree; its common criteria were
read directly, not inferred from planner136's unverified canonical-file map.
All physical/native/accessibility/Story limits remain false; no gate promotion.

## Stored grounded Summary projection

After original-owner archive17c1d03, implement actual stored result display in the existing
Library projection, not a generation placeholder. Exact source: LibraryOrganizationService.swift,
ProductDatabase+LibraryFacts.swift and LibraryBrowserView.swift. Parent supplies existing
internal restoreLibrarySummary(paperID:geometry:in:) so facts/metadata/Summary are validated
inside ONE existing adapterRead snapshot. No nested database/cache, polling, Provider send,
parse, invented owner or preview from unchecked result JSON.
Add optional accepted Summary observation to OrganizationSortFacts: nil means no delivered
Summary fact, an explicit unavailable state distinguishes missing independent ownership,
and restored carries actual LibrarySummaryRecord. Only catch geometryUnavailable as that
safe unavailable state; corrupt/stale/invalid data continue throwing, not fake absence.
Bind restored identity Paper UUID/generation to the current fact and existing actual owned
PDF/revision checks. Both grid/list show actual validated saved text where available;
existing identification detail shows full saved text and its actual claimAnchors' full
source quotes/PDF page numbers. No reranking, quote truncation disguised as complete
evidence, manufactured navigation or new generation. Do not call the result whole-Paper
summary for unknown/fragment kind. Native Korean semantic labels and explicit unavailable
state; no fake sample/disabled-success feature.
Preserve existing refresh/filter/detail lifetime fences and Caller validation; these
passive facts grant no PDF read/publication/write authority. User implementation-first
applies to this lane too: no tests, correction fixtures, full/native gates or fresh review.
Parent minimum confirmation only; production creator/calibration/profile, actual rendered
interaction/accessibility/physical restart and Story/Epic0-of-26 remain unproved.

### Implemented saved Summary projection

Worker143 changed only the three specified source files. Parent connected the existing
Summary read helper without a nested queue. Actual validated record, exact Paper/generation,
explicit unavailable ownership, full saved text and stored-order untruncated source quotes
with one-based PDF pages now feed existing list/grid/detail. Neutral Korean labels do not
claim fragment results summarize the whole Paper; no generation/navigation stub was added.
SwiftPM minimum existing canonical Summary and atomic Library facts cases exited0; product
source compiled, but neither scenario exercises new visible Summary UI or geometry-free
archive reconstruction. Six-source digest and deferred proof are in Spec1.23/shared evidence.
No new/correction tests, broad/full native build or independent review; rendered interaction,
accessibility, missing/corrupt archive, physical restart, genuine creator/profile and Story
acceptance remain unverified. Historical455/native-bf receipts belong to03ee2f5 only.

## Independent Summary availability and retained reading

Baseline64d0ea7 source restores saved Summary inside the existing Library facts read.
Canonical Story1.23 requires actual preparation/unavailable/failure/evidence states and
Summary failures must not prevent PDF reading. A semantic saved-Summary validation error
currently escapes into the whole Library query; correct that concrete integration gap
in LibraryOrganizationService.swift, ProductDatabase+LibraryFacts.swift and LibraryBrowserView.swift.
Replace the mutually exclusive observation with one immutable passive snapshot containing
optional fully validated prior record, actual recent attempt activity and explicit validation
availability/failure. Preserve usable saved results while a later real attempt runs/fails.
Read latest inserted Summary Job on the same SQLite snapshot, scoped by actual Paper UUID,
generation and immutable PDF SHA. Its rowid insertion ordering is a display observation,
not claim/retry/publication/fresh-action authority. Decode existing typed identity; malformed
or foreign facts become explicit Summary verification failure, never current-job success.
Only validated saved record proves a usable summary. Missing owner remains unavailable;
semantic codec/Domain/result/identity errors remain throws at restore service boundary but
are exposed as safe Summary verification-failure state in this feature projection. SQL
DatabaseError/schema/storage failures still propagate; do not silently treat them as absence.
Do not alter immutable storage, original owner/precision, Provider/policy, Reader admission,
filter/editor/refresh fences or actual retained metadata. Projection error isolation may not
invent records, raw diagnostics, fallback quotes, current Input/Provider availability or Retry
authority. Display preparing/failed from actual Job facts, and missing/unverified from actual
observation; full original saved text/evidence remain when valid. Explicitly label insufficient
claim evidence (including zero saved claimAnchors), not a false complete-paper/evidence success.
No fake Retry button: genuine dispatch/closure/Input/profile prerequisites remain absent.
User implementation-first: no new/correction tests, broad/native gate or independent review;
parent minimum existing confirmation only. Real new branch/rendering/Provider/profile/Story
proof remains deferred; canonical completion0/26 unchanged.

### Availability implementation receipt

Worker144 replaced the observation enum with independent immutable record/recent-attempt/
availability facts in the three scoped files. Same-snapshot actual Job state and complete
typed identity/lineage/PDF binding are observed without new authority. Valid prior text and
ordered full quotes remain independently renderable during later running/failed attempts.
Semantic restore/identity/state failures become explicit Summary verification-failure;
DatabaseError/RowDecodingError still propagate. Empty saved claim anchors explicitly show
insufficient evidence. Parent moved unknown semantic Job state inside that failure isolation.
Binary source diff against7264014 SHA256:
`f85ffda7469318e85877faef1e29aff4cac128377c5353e42bd82f5f4336298d`.
Minimum existing atomic year/metadata fact case passed (artifact1525 and final source
rerun exit0; changed source/UI compiled). This case has no Summary Job and does NOT prove
new failed/running/corrupt/prior-result or UI branches. No new/correction tests, broad/native
gate, formatter or independent review. Worker reported reading the root Spec without the
new section; explicit assignment contained the full contract, and parent uses this committed
integration Spec. Actual rendering, semantic-error reading continuity, insufficient-evidence
delivery and genuine Provider/owner/profile activation remain unverified; 0/26 unchanged.
