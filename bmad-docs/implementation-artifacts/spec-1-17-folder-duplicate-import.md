# Story 1.17 Build Spec — Folder arrangement and duplicate local import

## Bounded inner folder-manager outcome and read recovery (baseline 1d194e0)

Architect210 SOURCE_SLICE_READY grounds this continuation in the existing flat-folder
create/rename/delete requirement, truthful persisted state, and Spec1.25 failure/requery/
native Korean state-action accessibility criteria. Exactly this Spec and
PaperLensApp/Features/Library/ImportConfirmationView.swift, only FolderManagementView,
may change. Commit this amendment before implementation. Spec1.25 is unchanged.

Current perform merges mutation and subsequent folders() into one catch: completed
create plus failed read is reported as failed change, retains the create draft, and
offers no read-only recovery. Initial failed read displays an unobserved empty list.
Resolve this real product recovery interaction, not merely a defensive guard.

Use one view-private phase for loading/ready/changing/command failure/list unavailable.
Remember whether an unavailable list follows a successfully returned command; repeated
read retries must preserve that fact. No new controller/query counter/source store,
public API/service/CAS/schema/resource ownership or physical acknowledgment. Existing
folders(), createFolder(name:), renameFolder(id:name:), deleteFolder(id:) stay unchanged.

Unavailable is not observed empty. Show labeled Korean pending/error state and a native
현재 폴더 다시 불러오기 action. Disable edits/mutations during pending work or unavailable
list; leave idle read recovery available. Recovery invokes folders() only, never replays
create/rename/delete. Provide truthful native action/state accessibility semantics.

Capture selected UUID/name synchronously at admitted button command, before delayed Task.
Separate command catch from read catch. Thrown command preserves attempted selection/name
and never claims success. Successful create clears its new-folder draft (no required auto-
selection or dependence on returned creation type); successful delete clears deleted
selection/name. Successful rename/explicit accepted reload installs actual stored name for
surviving selected UUID. Missing explicit selection clears/discloses unavailability, never
silently converts its old draft into a create request. Explain that explicit reload may
replace a failed existing-folder draft with the stored name; preserve failed new-folder
draft where no stored selection exists.

One private read-only loader covers initial load, explicit reload and post-command read.
Successful command plus failed read explicitly says the change completed but current list
is unavailable; retries preserve that completed-change context until accepted read.
Failure of command is not success, and read completion is not a new mutation receipt.
Admitted persistence is not undone/canceled because presentation or read recovery changes.

Do not transplant tag-editor failed-Save revalidation/CAS or native dismissal lifecycle.
No inner Cancel/close callback, autofocus, specific Return shortcut, new folder auto-select
or fourth native slot is established here. Outer folder-toolbar receipt, confirmation
Cancel/Continue, Browser tag/detail/movement/ordinary action and deletion remain unchanged.
Parent owns source syntax/diff, independent review and local commit. Tests/test fixes/type/
build/gates/formatter/native/runtime/keyboard/VoiceOver remain deferred; acceptance0/26.

## Bounded movement native dismissal/current-query return (baseline 57c4199)

Architect203 SOURCE_SLICE_READY identifies the existing opener-focus criterion:
the separate movement item sheet, subtree disappearance and loading=false membership
check cannot establish native dismissal, original root or current enabled opener.
This continuation supersedes only that historical return mechanism, not its durable
placement/CAS evidence. Commit this paired contract before sole Browser source edits.

Add exactly movement to existing LibrarySheetContent/Slot/Presentation/root presenter.
Capture the currently accepted readable Paper/generation, original mount, presentation
identity, filter/revision at guarded admission; clear prior observation before installing
the slot. Remove LibraryMovement/moving/movementFocusToRestore/separate item sheet and
loading-based return, not organization action focus, folder manager or deletion alerts.
No second controller/store/query counter or resource authority.

Slot-captured appearance, close, visibility and actual native receipt retain identity
through closing. Pending native admission blocks replacement Browser work. Invalidation/
unmount revoke payload/load/Save/return eligibility while retaining callback identity;
old-root receipt retires only its matching capture, never queries or affects newer root.
Disappearance cancels local observations only, never proves dismissal or requests focus.

Uninterrupted same-mount receipt binds once to the existing exact query Request. Consume
after current acceptance installs folders/tags/facts or matching rejection; newer query/
work/focus permanently denies. Return only to current rendered, enabled, readable,
same-generation movement Button including selected-folder visibility, else existing
search without resetting conditions. Preserve other-kind/different focus, allow only
nil or matching original movement focus, and release record before assignment. Replace
identification-not-tag shorthand with concrete kind checks for all three controls.

Private PaperMovementSheet requires close, reactive Bool and synchronous live eligibility.
Fence payload/destination/error rendering, task/reload/Save admission and delayed Task
entry. Reload checks before placement read, between placement/folders awaits, after
folders and before failure publication; retain actual PaperPlacementLoadState requests,
cancellation and explicit accepted reload after failed Save. Save freezes actual captured
placement/destination and checks eligibility before service admission. Cancel admits no
new write. Already admitted successful move always reaches keyed committed callback,
even after cancellation/invalidation: never undo/replay persistence. Live failure remains
explicit, invalidates observation and requires fresh reload; invalidated UI cannot revive.

Committed callback refreshes current mounted root only and closes only original matching
slot. Preserve only uninterrupted pre-dismissal original movement return, never rearm a
consumed/interrupted one. A narrowly named completed-movement refresh/invalidation mode
revokes newer slot payload/mutation/return eligibility but retains native visibility,
closing state and callback identity. Paired Spec1.25 pins newer-tag mutation admission.
Ordinary invalidation and both own-tag Save outcomes remain unchanged.

No public API/service/DB/schema/placement CAS/PDF/resource changes. Parent owns syntax/
diff checks, independent review and local commit. Tests/test fixes/type/build/gates/
formatter/native/runtime/keyboard/VoiceOver remain deferred; canonical acceptance0/26.

### Authored movement source notes (contract 29ea39d)

LibraryBrowserView.swift now admits movement from the current readable same-generation
projection into its existing immutable LibrarySheetSlot and retained native presenter.
The separate item sheet, LibraryMovement and disappearance/loading focus continuation
are removed. Exact native dismissal binds return to the existing query Request; current
accepted controls select the readable movement Button or existing search, without
resetting conditions or replacing another kind's focus. Old-mount movement receipts
retire only their retained capture. Organization action focus and deletion/folder UI
are unchanged.

PaperMovementSheet uses reactive and live eligibility at rendering, reload, delayed
Task entry, read boundaries and Save admission, retaining placement requests and explicit
reload after failure. Cancel/disappearance invalidate observations, not dismissal proof.
Admitted successful moves still invoke their exact committed callback after cancellation;
it closes only the original slot and refreshes the current mounted root. The narrow
completed-movement mode preserves only uninterrupted original pre-dismissal return and
revokes newer payload/return without dropping native callback identity. These are UI
fences, not persistence, resource or physical-ACK authority.

Parent Browser syntax parsing and git diff --check pass; independent205 SOURCE CLEAR
traces exact receipt/query return, delayed Save/Cancel, old-root retirement and late
movement with newer slots or admitted tag Save. Tests/test fixes/type/build/gates/
formatters/runtime/native/keyboard/VoiceOver remain deferred and were not run.
Historical evidence is unchanged; this is not acceptance promotion (0/26).

## Shared toolbar focus continuation (baseline 0ee17ee)

Spec1.26's Settings opener phase reuses this root's existing folder presentation
receipt as one typed folders/settings toolbar receipt, captured by actual accepted
Buttons and latched by identity into the immutable native slot. Both kinds retain
actual appearance/dismissal, original live mount and clear owner fences; existing
cleanup precedes focus guards and exact matching receipt consumption. Reader entry,
unmount or unrelated presentation denies return. Folder focus still targets its
original surviving Button. Direct PDF Cancel-only event/UUID/task reconciliation
is untouched. Commit this shared contract before the sole Workspace source change;
native/type/runtime/tests remain deferred, no provider/resource/physical ACK or
Story promotion. No new focus controller or parallel presentation owner.

### Shared toolbar source implementation notes (contract 465b289)

Workspace's existing FolderPresentation is replaced by one typed folders/settings
ToolbarPresentation, not a second owner. Both actual toolbar Buttons capture fresh
receipts under the same explicit admission guards; each has its own native focus
binding. The immutable native slot retains the exact kind/mount-matched receipt ID,
and common native appearance marks only that receipt. Unrelated sheets consume
eligibility; Reader entry/unmount invalidate it. Actual dismissal still calls owner
cleanup before focus guards, consumes only its matching receipt, and returns to
the original surviving Button after appearance and clear live-owner fences.
The folder-only sheet appearance path is removed; Browser-origin folders gain no
toolbar receipt. Direct-PDF Cancel/event/task reconciliation and model cleanup
are unchanged. These are UI identities, not resource or physical-ACK authority.

Tests/test fixes, gates, formatters, type/build/runtime and native keyboard/VoiceOver
proof remain deferred and were not executed. Parent Workspace syntax parsing and
git diff --check pass; independent196 is SOURCE CLEAR for this three-file delta.
This shared source continuation is not Story/Epic acceptance.

## Direct PDF-button Cancel focus integration (baseline b8b3bd3)

Review190 resolves the next source input: URLImportView's existing PDF 선택 Button
survives over Library. The earlier five-file missing-opener finding was scoped and
does not describe this actual child control. Commit this contract before the shared
UI/model change. Exact sources: ProductWorkspaceView.swift, URLImportView.swift and
ImportConfirmationView.swift; paired Spec1.18 records the child wiring. No new files,
controller, database, resource owner or generic focus framework.

Revise existing discardable prepareImport(source:) to return the real prepared and
installed confirmation UUID, and pickPDF() to return the selected preparation
Task<UUID?, Never>? (nil on rejected/cancelled picker or failed preparation). Preserve
all original hash/scope/preparation/installation/error guards. No fixture veto hook
is production authority. Browser/drop ignored-return callers remain source-valid;
explicitly discard results in value-inferred Void closures where needed.

presentationDidDismiss(confirmationID: UUID? = nil) must key confirmation cleanup
against its actual pending UUID or retained cancellation tuple before mutation.
Mismatches do nothing; matching duplicates join existing b8b3bd3 completion. Nil
supports only nonconfirmation cleanup, not an identity-less confirmation fallback.
Existing dismissal/preparation/installation fences and dismissSheet remain intact.

The existing root view owns native FocusState for only the direct PDF button and a
UI intent with unique UUID, original mount and monotonic invalidation. Supply required
native focus and keyed invalidation bindings plus chooseLocalPDF(UUID) to the one
production URLImportView constructor. Every accepted child interruption/unmount
reports its own retained intent UUID before advancing the drag fence; equality may
invalidate only that intent, never a newer one. Extend existing drag state, not an
independent owner. LibraryBrowser/Retry/drop do not acquire a direct-button intent.

Retain one UI-only native presentation slot in the existing root presenter. Its
immutable slot UUID/mount/owner Sheet payload/confirmation UUID closes over the
native visibility setter and onDismiss. Keep payload/presenter until actual native
dismissal; do not remove/rekey on binding nil or overwrite an undismissed slot.
Latch owner sheet independently of picker-result timing. Matching onAppear proves
appearance. Token-checked visibility changes cannot clear another owner sheet. The
slot is presentation scheduling/projection only, never admission or physical ACK.

ImportConfirmationView requires slot-keyed cancelled/continued UUID bindings. Write
only after its existing successful synchronous action guard, before suspension.
Continue permanently disqualifies Cancel focus, even if it later fails. Disappearance
alone is not Cancel. Direct-origin interactive cancellation is eligible only after
appearance, before Continue and while not working; other origins retain current
disabled interactive dismissal. Keep all existing service/actions/imported callbacks.

Actual native onDismiss invokes keyed Workspace cleanup before all focus guards,
captures that returned task once, and records the matching event. Await that exact
task, never invoke cleanup again after suspension. Buffer native appearance/dismissal,
Cancel/Continue and cancellation UUID independently of picker preparation UUID: fast
native events may precede pickerTask.value. Both completions attempt the same one-shot
reconciliation. Require every identity to match, actual appearance AND dismissal,
Cancel but never Continue, matching cancellation completion, original live root mount
and child control, uninvalidated intent, no Reader/slot/new sheet and clear preparation/
opening/cleanup fences. Consume only that intent. Cancelled waiters do not restore or
cancel owner cleanup. Lost tasks/callbacks are not completion. Existing folder/URL
focus and cleanup-first behavior remain unchanged.

No actor cancellation, task UUID or picker result certifies consumed Continue abort,
FD/scope/lease/writer/publication/purge/physical closure. No lifecycle/schema/profile/
selector/permission/trial change. External panel controls, Retry and drop focus are
excluded, not replaced by another control. Test authoring/fixes/execution and native
trials stay deferred; constructor callers must be updated without no-op defaults.
Parent source checks/independent review precede delivery. Both event/task orders,
interruption/replacement/unmount, Continue-error-Cancel, native scheduling, keyboard
and VoiceOver remain verification obligations; no Story/Epic promotion.

### Source implementation notes (contract d211384)

The three scoped Swift files now implement the direct-button phase. Workspace
returns the installed UUID from discardable prepareImport and the selected
Task<UUID?, Never>? from pickPDF; presentationDidDismiss accepts the actual UUID,
joins only its retained cancellation, and rejects nil confirmation cleanup.
The root retains one NativeSlot payload until token-matched native onDismiss;
owner-sheet observation latches it independently of the preparation observer.
Cancel/Continue bindings buffer IDs synchronously. Native dismissal captures
keyed cleanup once before focus eligibility, then awaits exactly that task.
Preparation-first and native-events-first orders meet in one reconcile function.
Continue, interruption, replacement and unmount deny restoration; cancellation
waiter cancellation never cancels owner cleanup. Slot scheduling remains UI-only.

Tests/Product/ProductWorkspaceTests.swift still contains identity-less
confirmation dismissal callers and synchronous cleanup expectations. Parent must
adapt those callers to captured actual IDs and await the returned cancellation
task; nil remains valid only for nonconfirmation cases. No test files, tests,
builds, formatters, gates or native trials were changed/run in this source phase.
Parent syntax parsing of the three changed Swift files and git diff --check pass.
Independent192 is SOURCE CLEAR for the five-file direct-button integration only;
no typechecked build, behavioral tests or native focus proof is established.
Keyboard/VoiceOver, native scheduling, external-panel/Browser/Retry/drop focus,
and physical cleanup certification remain outside this delivered source slice.
Historical source-stage limitations below describe their named earlier baselines,
not a new verification or completion claim for this phase.

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
or ACK. That API change was excluded from the earlier focus-only lane. Existing
ImportConfirmationView, workspace published admission/cleanup guards, Retry,
security scope, lease and schemas remain unchanged. External NSOpenPanel return
and Browser/Reader control restoration are not fabricated or changed.

No tests, test authoring, builds, gates, formatters or runtime actions ran for this
continuation. Parent owns permitted source review/checks. Native keyboard focus,
VoiceOver and sheet scheduling remain unverified; no Story/Epic acceptance claim.

### Existing Workspace confirmation-cancellation completion

Review187 identifies that current cleanup admission reopens before the matching
actor cancellation returns. FolderImportService.cancel only removes its matching
ephemeral pending intent; Continue consumes that intent before asynchronous work,
so cancelling an absent intent is not producer cancellation or physical cleanup.
Implement the completion boundary in ProductWorkspaceView.swift only, after this
contract is committed. FolderImportService and ImportConfirmationView stay unchanged.

Revise existing dismissSheet and presentationDidDismiss to return an optional
retained Task<UUID, Never>, marked discardable. It yields the exact captured
confirmation UUID after awaiting the same imports.cancel and Workspace finalization.
No new receipt schema, operation UUID, await API, queue or resource owner. Duplicate
observations may join this one task, not start another cleanup. Retain the completed
handle until the next accepted presentation/input operation, invalidating it before
replacement; stale callbacks during installation/preparation remain inert.

Keep the synchronous cleanup front half and the current original security-scope
stop position unchanged. Assert cleaningSheet before published mutations; invalidate
preparation, clear the captured confirmation, increment revision once. With a captured
confirmation, keep cleaningSheet and sheetCleanupPending asserted across cancellation
await, and let only that retained operation finish them. No new input, sheet, Reader
opening or task replacement during this interval. No-confirmation cleanup finishes
synchronously, retaining current folder/settings and preparation-interruption behavior.
Always invoke Workspace cleanup before existing focus guards. Cancelling a UI waiter
must not abort retained owner cleanup. Lost Task/callback/process is not completion.

This task/UUID proves only matching UI-intent cancellation completion, never FD,
security-scope, lease, writer, publication, purge or physical ACK. No local opener is
captured in the current five-file boundary: picker controls have closed, drop has no
opener, and child control callbacks carry no surviving control receipt. Therefore
local confirmation focus stays unfinished, not redirected to the folder toolbar or
fabricated from Paper/generation IDs. A separately bounded child-control integration
would have to supply the real surviving opener and native dismissal receipt.

Existing Workspace tests that reenter after confirmation dismissal must await its
returned task; settings/folders and uninstalled preparation interruption remain
synchronous. Old failure/history/no-replay and stale-callback assertions must not be
weakened. Test edits/execution remain deferred by the implementation-first instruction;
their old synchronous timing is not current verification. Parent source checks and
independent review precede source delivery, without native/physical/Story promotion.

### Source implementation receipt (contract ef105354d68a116057d6ac3eadec0ecbd76d29d2)

Implemented the existing-owner completion boundary in ProductWorkspaceView.swift.
The earlier focus-only section above records its historical baseline, not the
current cancellation timing. Both existing methods are now `@discardableResult`
and return `Task<UUID, Never>?`; ignored-return statement callers remain unchanged.
No compatibility alias, additional API, operation UUID or receipt schema was added.

Workspace retains one tuple of captured confirmation UUID and cancellation task.
`dismissSheet` asserts cleaning before published mutations, sets pending, clears
the active sheet, invalidates preparation/preparing, captures and clears the
confirmation, stops the original security scope at its unchanged position, then
increments revision once. With a captured confirmation it creates and retains
exactly one task, returning that handle. The task awaits the same actor's
`imports.cancel(capturedUUID)`; only a matching retained UUID can finalize cleanup.
Cleaning and pending remain asserted across that await. Finalization clears
cleaning, then publishes pending=false as its last mutation, so synchronous
subscriber reentry cannot be followed by old-task mutation of a newer operation.
The task yields the exact captured UUID after cancellation and owner finalization.

Duplicate method observations return the retained handle without another cancel,
revision increment or cleanup. Installation, preparation and current-presentation
guards gate observations; native callbacks during those states remain inert.
Explicit dismissal of an uninstalled preparation still invalidates it synchronously.
No-confirmation dismissal, including settings/folders, also remains synchronous
and returns nil. A retained completed handle is not automatically discarded:
the next accepted sheet presentation, local preparation/Retry, picker operation
or Reader open invalidates it before replacement or published admission. Rejected
admission does not invalidate it. Existing pending guards block new sheet/input/open
admission during cancellation. Matching finalization never clears a newer operation.

The retained task is unstructured owner cleanup, not a child of an observing waiter.
Cancelling a waiter or the returned task does not skip actor cancellation or
finalization: there is no cancellation check or throwing cancellation boundary in
this path, and the existing synchronous actor cancel is not cancellation-aware.
Lost task/callback/process is not completion evidence. UUID equality names only the
one-shot ephemeral confirmation intent; Continue may already have consumed it.
This does not cancel that producer or certify FD/scope/lease/writer/publication,
purge or physical ACK. Security-scope stop remains the original synchronous action,
not newly certified physical closure.

The native onDismiss still invokes Workspace cleanup before all existing folder
focus guards. The 42c8 folder-toolbar focus behavior is unchanged. There is no
surviving local opener in this boundary, so local confirmation focus remains
unfinished; neither toolbar focus nor NSOpenPanel reopening is fabricated.
FolderImportService, ImportConfirmationView, URLImportView and tests are unchanged.

The worker performed only source inspection and diff review. All tests, new tests,
test fixes, gates, formatters, compiler/build/runtime/PDF/SDK/helper/provider,
signing, network/credentials, staging and commits were skipped as instructed.
Existing confirmation-dismissal tests that immediately reenter must eventually
await the returned task before asserting reopened admission; their old synchronous
timing is intentionally deferred, not passing evidence. Preserve existing failure,
history/no-replay and stale-callback assertions. Settings/folders and explicit
preparation-interruption timing remain synchronous. Parent Swift syntax parsing
and git diff --check pass; independent189 is SOURCE CLEAR. Behavioral/type/native
verification remains deferred; no current test-count, native focus, physical
cleanup, Story or Epic acceptance is claimed.

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
