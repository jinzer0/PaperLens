# Story 1.17 Build Spec — Folder arrangement and duplicate local import

## Native opener-focus source continuation (baseline a22d139)

The existing Workspace toolbar's 폴더 관리 button gains native FocusState. Its
accepted presentation captures a fresh UI receipt and the original Workspace mount,
not current Library selection. Only that receipt's actual folders-sheet onAppear
marks it presented. The existing native sheet onDismiss first invokes unchanged
presentationDidDismiss cleanup, then restores the original toolbar control only
while the same receipt/mount remains, Library is mounted, no Reader/new sheet exists,
and cleanup/preparation/opening fences are clear. Browser-origin folder management
does not synthesize a toolbar opener. Receipt invalidation on unmount/Reader entry
denies late restoration. These values are UI identity only, not resource authority.

Local PDF confirmation focus return remains unimplemented. Existing dismissSheet
launches imports.cancel in an unawaited Task and clears sheetCleanupPending before
that Task returns. Consequently neither binding nil, Cancel acceptance nor the
existing dismissal callback proves completion of existing input cleanup. A future
existing-owner API would need a matching confirmation/presentation identity and an
actual-dismissal plus awaited-cancellation completion receipt before restoring a
captured opener; cancellation completion would still not certify physical closure
or ACK. Parent explicitly declined that API change in this source lane. Existing
ImportConfirmationView, workspace published admission/cleanup guards, Retry,
security scope, lease and schemas remain unchanged. External NSOpenPanel return
and Browser/Reader control restoration are not fabricated or changed.

No tests, test authoring, builds, gates, formatters or runtime actions ran for this
continuation. Parent owns permitted source review/checks. Native keyboard focus,
VoiceOver and sheet scheduling remain unverified; no Story/Epic acceptance claim.

## Current native import presentation continuation (baseline 2c855ee)

Story1.17/Issue19 remains on the Epic integration branch
`issue/epic-1-product-vertical-integration-20261010`; the explicit implementation-first
assignment permits only the two existing Specs and three Library presentation files.
Current ImportConfirmationView displays the selected filename, explicitly unavailable
extracted metadata, actual UUID-backed folders/default, and evaluated SHA match versus
unavailable other duplicate signals. New import warns of independent Paper/PDF copies;
local Retry identifies the existing Paper and does not promise another Paper. Cancel
and Continue still use the existing synchronous action gate and service owner, with
Continue unavailable until destinations load and after intent consumption. Workspace
still uses native PDF selection and prepares without admission, remains Library after
import and retains its existing sheet cleanup/security-scope/publisher fences.

This continuation adds native Escape/Return actions to local confirmation, labelled
destination-load/request progress and icon-plus-text failure states in confirmation and
Workspace. It does not change command admission, cleanup, Retry identity, default
destination, lifecycle, schema or resource ownership. The request progress deliberately
does not claim publication or physical closure. Existing URL controls retain their
independent state gates; no shared concurrency fix is attempted.

Remaining prerequisites: parent source review and permitted compiler checks; actual
native keyboard/VoiceOver role-state reading, local confirmation opener-focus restoration, text
scaling/contrast/resize, Cancel/Continue scheduling and physical duplicate-copy/delete/
restart/publication-failure behavior at the current source revision. This worker runs
no tests, builds, formatters, gates, UI/runtime/network or protected trials and authors
no tests. Historical verification below is not evidence for this continuation.
StoryDone=false, canonical acceptance and Epic acceptance remain unchanged.

## Exact product implementation phase (latest explicit source-order instruction)

This phase supersedes the historical planning-only admission below. Exactly five files:
this Spec; `PaperLensApp/Application/FolderImportService.swift`;
`PaperLensApp/Infrastructure/ProductDatabase+Folders.swift`;
`PaperLensApp/Features/Library/ImportConfirmationView.swift`;
`Tests/Product/FolderImportTests.swift`. Implement durable flat folder create/rename/delete,
ready-Paper placement, bounded security-scoped SHA256 recognition, and native confirmation.
Nil destination explicitly means Unfiled; deleting a folder unfiles its placements without
touching PDF ownership. Metadata not extracted is unavailable; filename is labelled as such.
No bookmark, Paper, Job, stage or retained handle exists before Continue. Intent is single-use.
Continue rehashes before admission; existing importer must compare the copied digest again
before publication and validate/assign destination in its sole publication transaction.
Parent owns that narrow existing-owner change, migration registration and Library wiring.
Register `registerFolderMigrations(in:)` in the existing migrator, never a second startup owner.
Source-only implementation and regression tests are authored; all tests/gates/builds/formatters,
commits/remotes and `.gjc` workflows are skipped by explicit instruction. No runtime PASS claimed.

## Authority and admission

Issue#19 / issue/19-story-1-17, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source; no repeated unchanged-scope SHA approval, no gate/live/paid/credential/remote/distribution permission inferred.

Architect46 read exactly ROOT epics.md:851–886, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift. Root-only excerpt not copied. Planning ONLY, not implementation-ready. Actual1.14 local Library/import and1.15 Reader absent; product BLOCKED, StoryDone=false. P1/P2/P3/P6 unproved; blankCapture FAIL.1.13 parallel precursor not runtime accepted. Local14dd7b3/c93e873 do not prove SDK/Main/durable physical product. Historical repaired findings not reopened.

## Folder, confirmation and independent ownership

Durable folder creation/move/Paper placement through Application and sole SQLite visibility authority survives re-entry/restart. Logical move does not relocate/replace immutable PDF. Failure preserves prior placement; validate destination/current active Paper, no silent substituted default.

Reuse actual1.14 recognition/input owner. Sheet shows only recognized facts with provenance, actual selected folder/default and possible duplicate status. Filename label is not extracted title; absent/unextracted metadata stays unavailable. Opening/changing/cancelling sheet creates no Paper/Import Job/owned stage, no hidden deferred import/bookmark. Cancel releases temporary input through owner.

Available title/URL/identifier/PDF content hash can signal possible duplicate. Distinguish unevaluated signal from evaluated-no-match, never claim uniqueness from incomplete metadata. Duplicate warning never authorizes overwrite, physical sharing or automatic coalescing.

Explicit Continue revalidates source/destination and consumes confirmation intent once, reserves fresh Paper UUID/generation and Job lineage before mutation. Duplicate delivery of one command adds at most its accepted import; independent confirmations of equal bytes produce separate UUIDs and independently owned immutable physical files, never hardlinks/symlinks/blob-refcount alias. Other Paper unchanged.

After Continue remain Library; ready active Paper offers explicit Open Reader only with actual Reader. No auto navigation or wait for future parsing. URL import/tags/search/filter/folder rename-delete-hierarchy/full schema/future UI/stubs/fallback adapters excluded.

## Recovery and deletion

Reuse1.13 current Job/attempt/fence/correlation/input/Paper/epoch/permit guards and explicit applicable config. Writer permit precedes owned access through close/cleanup; closed validated stage acquires distinct publication permit through rename/guarded commit or synchronous cleanup. State short reservation/decision only, effects/drain/DB/callbacks outside.

Delete revokes new work/permits, drains admitted writers/publishers and removes only targeted UUID/generation namespace/records, never hash-selected scope. Same-content survivor PDF/records remain after restart. Move serializes against current placement/deletion. Unknown closure/cross-store failure retains cleanup debt, not success/absence.

Restart restores committed folders/placements; old running→failed/interrupted, no fence renewal/replay. Unconfirmed sheet never becomes import. Explicit Retry uses fresh lineage/current prerequisites and preserves prior usable results. Late Retry/restart/delete completion cannot publish or change another Paper. No alternate recovery/storage or startup-only failed-guard cleanup.

## UNKNOWNs and conditional ≤5-file phase

Actual folder/default/confirmation APIs, metadata availability/duplicate queries, placement transaction/input versions UNKNOWN. Resolve against accepted1.14/1.15; no invented Inbox/preferences/parallel selector/new folder filesystem namespace/Provider fields/schema/migration registry.

After exact same-Spec amendment name≤3source+2test files: real Library UI; Application confirmation/duplicate/placement commands; sole persistence narrow operations; actual command/transaction tests; real relaunch/physical import-delete tests. Ownership slots not speculative paths or scaffolds. Required wiring fits named bounded phase, otherwise stays blocked.

## Required proof, not executed

Create/move/revisit/restart persists; commit failure/invalid destination/move-delete race preserves truthful state. Before Continue/Cancel/restart-open-sheet no Paper/Job/copy. Each available duplicate signal independently tested, unknown facts honest. Concurrent same-content confirmations yield equal bytes but distinct physical identities/UUIDs and zero existing mutation; repeated same intent adds once.

Delete either duplicate while survivor open/importing; survivor PDF/records/placement intact after relaunch. Copy/close/rename/DB failure and crash around accepted intent/publication never false ready. Hold actual writer/publisher barriers with revoke/Retry/restart and late completions: drain before removal, synchronous cleanup before release, no resurrection/cross-Paper deletion. Ready explicit Reader only, pending/failed/deleting cannot open; no automatic navigation/parsing dependency.

Architect46 COMMENT/WATCH, exact five-source read-only proposal; no tests/gates/formatter/build/GUI/SDK/auth/network/credentials/user docs/commits. Done requires real accepted owners/durable physical tests, parent gates and independent review; planning commits certify no product/gate.

## Selected-source read ownership correction

At current verified integration fe7ea93, FolderImportService.hashSelectedSource defers
import resource lease.close and security-scope stop unconditionally. If checked input
FileHandle.close throws producerClosureUnknown, the actual descriptor is not retained
and the importer capacity is released despite unproved physical closure. This is a
concrete still-executable source defect, separate from missing Agent purge/SDK gates.
Also regular/symlink URL attributes checked before Foundation opening do not pin the
opened object's type; replacing it with a FIFO/symlink can precede a blocking/wrong open.

Keep the same actual import pool/budget and temporary read-only recognition semantics.
Use public nonblocking O_RDONLY/O_NOFOLLOW/O_CLOEXEC opening followed by actual fstat
regular-file/type/size and pinned identity checks against observed source facts before
reading. No arbitrary-source fallback, permission repair, new selector or second counter.
Capture real FileHandle/resource lease/security-scope ownership before read effects.
Checked close is attempted once; only known physical close releases its lease/scope.
Unknown close retains actual handle/lease/scope strongly beyond thrown prepare/facade
loss, denies further capacity, returns producerClosureUnknown and creates no confirmation,
Paper/Job/stage. No ARC, FD-number probe, blind retry or error masking is closure evidence.
Normal failure/cancellation with known close releases genuinely and preserves its cause.

Exact worker scope: FolderImportService.swift, existing FolderImportTests.swift and this
Spec. Production close uses actual FileHandle.close; a required internal test injection
may throw while retaining the real descriptor, never default-success. Read-only internal
debt inspection may expose actual retained fixture ownership for explicit test teardown;
manual fixture cleanup/lease release must not change runtime unknown state or claim ACK.
Tests use owned synthetic files/FIFOs/symlinks only, no user document or SDK/runtime trial.
Parent owns focused/union/native verification, independent retention review/evidence/local
commit. Current291 tests1001/native-w1002 remain prior baseline, not correction evidence.
Story/privacy/P1/P2/P3/renderer/trial/remote boundaries remain unchanged and unproved.

Implementation handoff (aa39aab Spec before code): Darwin admission uses lstat of the
selected URL, O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK open, and fstat of the actual
descriptor. Both observations must be regular files with identical device/inode;
actual positive size within pdfBytes is pinned for final read-count comparison.
URL content type remains recognition evidence, never physical admission authority.
A lock-protected static root captures the real handle, actual import lease and original
security-scope flag before fstat/read/close effects. Locks arbitrate ownership only;
no filesystem, scope, budget, read or close effect runs under them. Known checked close
removes the root after lease/scope release; unknown remains retained indefinitely.
Internal required close injection receives the actual FileHandle; optional beforeOpen
hook only permits owned-fixture substitution between observation and real open.
Read-only unknown ownership inspection exposes the actual handle/lease and scope facts
for manual fixture teardown, not runtime repair, retry, closure evidence or ACK.
Tests authored, NOT RUN by the worker: normal hash/release, retained real FD after facade
loss with actual capacity denial/no intent or durable effects, typed signature failure,
size admission, symlink/FIFO/directory and regular-to-FIFO/symlink/regular replacement.
Parent owns all verification/build/review/commit; prior baseline is unchanged evidence.
Parent concurred not to add beforeRead hooks or racing fixture writers just to inject
read/budget errors. Their original catch/preserve-cause path remains source-reviewable;
those runtime failure branches remain explicitly unverified by the authored tests.

Parent verification:13 focused tests passed (artifact1005), including5 new actual owned
source/FD/retention cases. Full Product union296 passed, zero failures (artifact1007).
Fresh unsigned native Release arm64/macOS15 compiled in native-x (artifact1010).
Independent review75 SOURCE-ONLY CLEAR / APPROVE. Two-source binary delta vsaa39aab:
c45ea42346e98a3e5b37595b2d6f02992a5d38da4938f83cbdfce27344ce3052.
Preserve1003 inaccessible private error initializer and1004 incorrect cap-one test
assumption. Public error fields and actual contract-derived capacity saturation repaired
the tests; shared pool caps/nonblocking admission remain unchanged. Unknown debt consumes
its actual slot, not a guessed blanket prohibition of all remaining contract capacity.
Manual owned-fixture physical cleanup precedes lease/scope teardown but does not alter
runtime unknown state or fabricate ACK. Granted user security scope and deterministic
read/body-budget error branches remain runtime-unverified. No actual user PDFs, helper/
SDK/app/renderer/paid/remote/trial renewal ran; Story/P1/P2/P3/hard bounds remain unproved.

## Mounted captured Paper movement — actual product continuation

Canonical1.17 root epics858–862/876 requires Library Paper movement with persisted placement.
At verified2260e36 the actual folder manager creates/renames/deletes folders and import can
choose a destination, but LibraryBrowserView has no move-existing-Paper action. The unused
assignPaper(UUID,to:) service/DB path also lacks a captured generation/current-placement
fence. Implement the existing criterion, not another folder store or metadata inference.

Use a data-only captured placement from sole GRDB: actual Paper UUID/generation/immutable
SHA/reference plus actual current folder UUID/name (or actual Unfiled). Capture read checks
ready/nondeleted/current requested generation; invalid stored identity fails, not success.
Replace public UUID-only assignPaper with captured-placement movement (remove obsolete
entry points and update callers/tests, no alias). In one existing adapterWrite transaction,
revalidate captured Paper generation/immutable facts/current ready/nondeleted status and
expected placement before applying existing folder membership. Validate actual destination
exists; stale/deleted/rebound targets and changed placement reject without effect. No new
Job/PDF/copy/selector/migration/counter/lease. Imported-publication assignImportedPaper stays
the existing internal ready-publication operation; its current authority is unchanged.
Value comparison is optimistic observed-state fencing, NOT global ABA or read authority.

Both card/list expose native move action for a captured current readable Paper. The sheet
loads actual folders/current placement using shared FolderImportService, uses UUIDs not
labels as destinations, explicit Unfiled, Cancel with zero effects and explicit Save.
Fences/cancellation prevent old loads repopulating a replaced/dismissed sheet; Save captures
the actual observed placement/destination before suspension, and cannot silently move a
new current selection or replay failed Save. Failure stays explicit with current-state
reload before a fresh Save. Committed movement may win late UI dismissal; do not undo it.
Success refreshes the actual Library and closes; preserve opener focus. Required service
injection uses workspace.imports, not a new instance/store. Existing detail/query fences
must stay intact when entering movement. Physical UI/focus remains unproved by compilation.

Worker EXACT5 files: FolderImportService.swift, ProductDatabase+Folders.swift,
LibraryBrowserView.swift, FolderImportTests.swift and this Spec. Parent alone updates actual
ProductWorkspaceView initializer and Korean folder-manager controls in ImportConfirmationView
(labels only, no extra behavior). Worker skips every gate/build/test/lint/formatter/commit/
remote/workflow/delegation/runtime. Parent verifies actual owned-file/GRDB move/Unfiled/reopen,
stale Paper/generation/hash/reference/current placement/destination/delete rejection with
no extra Paper/Job/copies, cancellation/late-load fixtures as feasible, full Product/native;
independent changed-source review and exact local evidence commit. Protected/runtime/remote/
calibration/auth/Story boundaries are unchanged; previous299/native-y are prior evidence.

### Captured movement source handoff (baseline Spec edf2751)

Authored exactly the five worker-owned files above. Public DB and async service APIs are
`capturePaperPlacement(paperID: UUID, generation: UUID) -> CapturedPaperPlacement` and
`movePaper(_ captured: CapturedPaperPlacement, to folderID: UUID?)`. The data-only value
holds paperID/generation/SHA/reference and optional actual LibraryFolder UUID/name. Capture
requires the requested current ready/nondeleted generation and valid stored UUID/digest/
canonical reference. Movement compares all observed facts in adapterWrite, including the
prior folder name; a concurrent rename also requires explicit fresh observation. Destination
validation and membership mutation reuse the unchanged internal assignImportedPaper body.
Removed both UUID-only public assignment entry points; updated all four known test calls.
No migration, lifecycle, import publication, resource owner or physical PDF operation changed.

LibraryBrowserView requires `folderService: FolderImportService` after `service:`; parent
injects the existing `workspace.imports`. Both presentations share the native Korean move
button and sheet. UUID-tagged destinations include explicit 미분류. Each presentation has a
fresh sheet identity; a late committed Save refreshes Library but cannot dismiss a reopened
sheet. Save freezes placement/destination before suspension. Failure discards the observation
and requires explicit reload before another Save. Cancellation invalidates quiescent load
requests and cancels tasks without DB undo. Dismissal refreshes the existing Library query
to avoid permanent Loading; opener UUID/generation is retained for native focus restoration
after load only when that same Paper is still in the current Library result.
Entering movement clears prior metadata/query observations without altering their fences.

Six new test methods authored: actual owned import move/Unfiled/reopen with unchanged full
Paper/Job rows, PDF bytes/inode and namespace entries; stale generation/SHA/reference,
deletion/status/missing Paper rejection without writes; changed placement/name/current
folder and missing destination rejection followed only by explicit fresh capture; required
generation/invalid stored identity; and two tests of the actual production shared pure load
state covering dismissal/replacement/late failure/wrong target/wrong generation/missing
folder. Existing 13 tests retain import/source-ownership semantics. Pure-state fixtures prove
only observation fencing, not SwiftUI task scheduling, keyboard focus, sheet presentation,
Cancel/Save interactions or physical UI acceptance. Value CAS is not ABA protection or PDF
read authority. All worker tests/builds/gates/formatters/commits/runtime explicitly skipped;
source-only handoff is not PASS. Parent owns focused/full/native checks and independent
review. StoryDone/Epic/protected acceptance and historical verification evidence unchanged.

### Parent verified durable captured movement

Parent supplied workspace.imports to the required Browser argument and Korean folder-manager
labels only; no extra behavior, owner or migration. Focused19 passed, zero failures1044,
including6 new movement/actual-load-state methods. Full Product305 passed, zero failures1045.
Fresh unsigned native-z Release arm64/macOS15 compilation succeeded1047. Independent80
SOURCE-ONLY CLEAR / APPROVE; final fixture was reread. Six-source binary delta vsedf2751:
82218ac38a35d38daf825b6141216499c75a56e68da7c0c6ca4fd576a0507922.
Preserve1036 focused19/one: missing-Paper fault hit genuine importJob FK before command
rejection. Owned fixture removes that Paper's referencing importJob then Paper in one
fault transaction; foreign keys remain enforced, production/schema/guards unchanged.
Successful move proves reopened membership with unchanged complete Paper/Job rows, PDF
bytes/inode/namespace; rejected observations preserve the post-fault placement/rows/bytes.
Physical sheet scheduling/Cancel/Save/focus/accessibility are NOT those fixture proofs.
No user PDF, provider/SDK/app/helper/renderer execution, paid/trial renewal or remote action;
observed-value CAS is not ABA/read authority. Canonical0/26/Epicfalse/StoryDone=false unchanged.

### Parent Korean import-confirmation presentation correction

After2014434, the existing ImportConfirmationView ordinary/Retry sheet text is
aligned with its surrounding Korean native controls. Preserve selected filename
versus unextracted metadata, evaluated content-hash/no-match versus unavailable
duplicate signals, explicit independent-copy versus same-Job Retry disclosure,
fresh PDF reselection on failure and chosen folder/미분류. Labels only; the reviewed
synchronous Cancel/Continue and post-await Workspace fences are unchanged.
Focused25 isolated Folder/Workspace/confirmation cases pass1412; fresh unsigned
native-aw compiles1413. Prior433/full1409 belongs to2014434 and was not rerun for
these strings. No visible UI/VoiceOver/focus/layout/runtime or Story acceptance
is inferred; no application/helper/protected trial or remote operation occurred.
