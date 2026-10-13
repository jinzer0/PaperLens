# Story 1.22 Build Spec — Metadata and Reader Contents

## Preserve confirmed current section across metadata refresh

Source scope: this Spec and Application/ReaderMetadataBinding.swift only. Metadata-only
refresh must not erase an already-observed and saved current position solely because
metadata/Contents were reloaded. Carry only this binding's published observedLocation,
revalidate it against the same admitted document and recalculate its section using the
fresh actual outline. Restoration candidates do not establish observation; invalid or
unmapped positions remain unselected. Capture/recheck existing context and observation
around potentially reentrant PDF reads and before guarded installation: newer observation,
failed-observation clearing or terminal invalidation supersedes the prepared refresh.
Preserve Reader read access, identity/document/Paper/generation/SHA/reference/revision
pins, publication guards, original errors, immutable snapshots and existing context/CAS.
Refresh must not navigate, restore, save position, acquire a lease or introduce an owner.
Leave UI and ReaderMetadataService unchanged. No schema/extraction/OCR/AI/profile change.
Tests/test fixes, type/build/gates/formatters/native/rendered/restart verification remain
deferred; parent syntax/diff and independent source review do not certify Story acceptance.

### Source-only confirmed-selection refresh receipt

Governing c56a722 preceded executor219's single-binding delta. Architect218 identified
the real counterexample: successful observe/save selects a section, then an unchanged
metadata-only refresh erases the observation and selection without movement or failure.
Refresh now carries only the live published observation, checks actual page/count/crop
bounds and remaps against the fresh outline. Context and observation checks veto a
superseded preparation; initialization/restoration alone never establishes observation.

Independent220 initially BLOCKED: throwing supersession inside read access could bypass
original identity/actual lease postchecks after nested observation plus access revocation.
Parent corrected only this preparation: supersession returns an optional nil result
through unchanged access postchecks; staleConfirmation is thrown only after successful
access. Thus original denial/clearing errors take precedence, while a newer valid state
is not erased by entering the publisher's catch. Original operation errors still propagate.
Keep the initial BLOCK; corrected re-review returned OKAY — SOURCE CLEAR. It checked the
actual existing context CAS sequence advance and lease postcheck excerpts, same-location
observation, failed-observation clearing, invalid/unmapped location, terminal invalidation,
publisher interruption and initial nil/restoration paths. These are source-derived paths.

Parent frontend parse/diff passed before review (artifact://3502) and after correction.
UI/service/DB/session APIs and durable save/CAS are unchanged; refresh adds no navigation,
save, lease, counter, owner, profile or physical ACK. Tests/test fixes and native/rendered/
keyboard/VoiceOver/restart/type/build verification remain deferred by implementation-first
instructions. No Story/Epic acceptance; canonical count remains 0/26.

## Current-source Contents location and accessibility

Scope: MetadataOutlineView.swift only. Contents currently exposes title/current-state
copy and visual indentation but omits the validated destination's page from its row and
its accessibility value; it also lacks the selected trait for the observed active row.
Show one-based page numbers only from existing confirmed row locations, expose section
depth/page/current-or-unconfirmed state, and mark only the actually observed active row
selected. Hide the decorative current-location icon from duplicate accessibility reading.
Navigation hints describe intent rather than claiming arrival; native Buttons retain
keyboard/focus behavior, with unlocated rows disabled and no automatic focus movement.
No new PDF operation, guessed geometry, destination, restoration, persistence or
publication contract. ReaderMetadataBinding.swift remains unchanged, including its
existing interruption guards. Existing candidate provenance/conflict/missing fields
remain unchanged. No tests, builds, formatters, gates or runtime execution in this slice.
Parent source review and permitted checks remain required; rendered hierarchy/page
copy, keyboard/VoiceOver, actual navigation/observation and restart remain unproved.
Canonical acceptance is unchanged.

## Synchronous presentation-publication interruption correction

Baseline34071b09ac1f6accbd52ae6d80cd8d1724b567b2 binding prepares and validates
metadata under actual Reader read access, but its initializer/refresh/observePosition
then assign @Published state outside that access. Combine willSet subscribers can
synchronously close/invalidate the actual session during the assignment: invalidate's
nil write can finish before the outer assignment installs its obsolete nonnil state.
This violates the existing synchronous presentation-erasure contract; it does not
reopen any resolved Workspace request/revision finding. Exact source scope:
Application/ReaderMetadataBinding.swift only. Centralize snapshot installation under
fresh actual session.withReadAccess and existing pre/post validate; serialize its
synchronous callbacks with one ephemeral publishing flag, rejecting recursive refresh/
observation before effects. If installation validation throws, repair state to nil after
the original setter finishes and rethrow the original error. No new schema, owner,
lease API, queue, timer, fabricated closure/ACK, context CAS or navigation success.
Use the same installer for initialization, refresh and persisted observed position;
restored location remains a candidate, saved position precedes advertisement, and
existing failed-observation handling cannot resurrect a cleared state. Preserve
original Paper/generation/SHA/reference/revision, weak PDF and session validations.
Parent only minimum existing actual outline/persistence and reentrant close/native
mount scenarios. New publisher-interruption regressions, independent review, full/
native/runtime checks remain deferred under implementation-first; none is acceptance.

### Parent metadata-publication source receipt

Committed Specad9aeea6b53bb6c98a846c73a98d1de17169fb94 precedes the single
binding-source correction. Initialization, refresh, successful persisted observation
and failed-observation snapshot replacement all use the same installer. A fresh actual
read pin and the original pre/post identity/document/GRDB validation enclose the
Published setter; synchronous refresh/navigation/observation reentry denies before
effects. Interrupted installation clears state after that setter finishes, preserving
original operation errors and already-durable CAS facts, never reviving a closed binding
or pretending persistence rolled back. The publishing flag supplies no PDF/persistence/
closure authority. No caller/schema/service/SDK/budget/physical-cleanup owner changed.
Initial three existing cases passed (artifact1555; build4.50 seconds, existing weak-var
warnings retained). After also fencing failure-state replacement, final four existing
actual outline/observed-position, getter/navigation close, actual Reader mount/revision
replacement and SQL/CAS failure scenarios pass exit0, build2.53 seconds. One-source
binary diff SHA256 against Spec: `ea491c6ed2975ba8df9d5ebeced8790be9961540789987ee8b57dd2f12dbe676`.
These existing cases do not trigger a new Published subscriber close/recursive-action
branch. New publisher-interruption regressions and independent review remain required
but deferred; full/native/visible/restart/calibrated/privacy gates are not promoted.

## Authority and admission

Issue#24 / issue/24-story-1-22; basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source, no repeatedunchangedSHAapproval; no actualgate/live/paid/credential/remote/distribution inference.

Architect54 exactlyROOTepics1018–1050+1181–1190(samefile), own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json, PaperLensApp.swift. Canonicalrootnotcopied. Planning ONLY/not implementation-ready; actual1.20–21/realReader/storage absent, product BLOCKED/StoryDone=false. Atplanning1.13initial20PASS/review48BLOCK/repairunaccepted; local14dd7b3/c93e873 nonproduct. P1/P2/P3/P6unproved, blankCapture FAIL. Main topology not Reader.

## Metadata and navigation

ActualcurrentPaper source/acceptedextractiontitle/year/abstract/topic, missing `미확인`; no filename/filedate-inferredyear/generatedabstract/inventedtopic. Source topics not automatically usertags. Immutableprovenance; source/extractionconflictprecedence/representation UNKNOWN, not guesseddefault.

ActualvalidatedContents andrealPDFKitadapter. Selection only navigationintent; validate currentPaperownedPDF/destination. Active section+durablelastRead onlyconfirmedactualposition, never rowselect/dispatch alone. Missing/malformed/outsidePDF/stalePDF-revision destination typedfailure/no falsemove/newlastposition; Koreanreason/PDFremainsreadable. Manualnav reflectsactualsectionifmappingresolves otherwiseunknown. ContentsnotpresumedsentenceEvidenceAnchor.

Absentmetadata/Contents/parsefailure retainsvalidinfo+PDF, optionalinfoabsence notReaderfailure. NO parsingRetry/Cancel/recoveryauthority inOutline; actual1.21 surfaceownsrecovery, Outlineopenneverstartsparse/autoretry.

Application/persistence savescurrentlivePaper associations/location/section; UIephemeralonly. Revisit/restartrevalidatescurrentPDF/Contents, invalidcontextnotrestoredsuccess. Failedsave truthful/newerconfirmedpositionprotected. Deleteinvalidatesdisplay/outstandingwork andremovesownedmetadata/context; cache/files/remnantsneverreconstruct. Paper/revision switch/restart/delete versus load/nav/save suppress supersededop/currentgeneration/provenance mismatch.

## Conditional owners and proof

UNKNOWN actualmetadata/Contentsoutput/provenance/confirmednavigation/locationAPI/persistence/errors/files. No Provideroperation/generatedmetadata/Readercontextpayload/newcache/numericguess/schema/helperCI/parallelvisibilityowner/futureTranslationpagesync.

Same-Specamendment≤5exactsource+pairedtestpaths perphase: existingApplicationmetadata/readcontext+persistence/provenancetests; realReaderOutline/PDFKitnav+integrationtests. Responsibilityslotsnot scaffolds. Needactualpredecessors before productcode, no topologyUIsubstitute.

Complete/individuallymissingfields+provenance/admittedconflict/otherPaperisolation/nofabrication. Realvalid/invaliddestination/confirmedversusfailedmove/manualactiveSection/latecallback. Actualsavefailure/revisit/restart/currentrevision/invalidsavedposition/deletewhileload-nav-save→no returnedmetadata/context, unrelatedPaperintact. EverycurrentPaperdatum lifecycletested, notjustOutline.

NativeCanvassemantic/Koreanstate+action/noncolorcues/actualcontrast/longtext/native scaling/windowresize/keyboardVoiceOverroles-currentsection-labels. Dialog/draweropenerfocusreturn; accessibleRetryCancelDelete in OWN surfaces, no recoveryduplicatedOutline/no deferredpolish.

Architect54 historical planning-only finding is superseded for this exact source phase by the 2026-10-09 explicit implementation assignment. Scope is exactly this Spec, Application/ReaderMetadataService.swift, Infrastructure/ProductDatabase+ReaderMetadata.swift, Features/Reader/MetadataOutlineView.swift and Tests/Product/ReaderMetadataTests.swift. No tests/gates/builds/formatters/commits/remotes or renderer trials are authorized.

### Actual source phase (2026-10-09)

Implement source-bound candidate metadata with immutable provenance and explicit unresolved conflicts, not generated producers or implicit precedence. ReaderMetadataIdentity is a narrow input mapped by the parent from final extraction/Reader APIs, not a second revision authority. Infrastructure atomically joins final extractionVisible/extractionRevision with ready Paper generation/SHA/reference and active revision; parent binds actual metadata producer/current Reader/Paper/revision read lease and registers registerReaderMetadataMigrations in the sole owner. Durable confirmed context uses current revision guards, session fencing and compare-and-swap sequence to reject late saves. PDFKit adapter traverses actual PDFOutline, validates destination page ownership and crop bounds, and maps only observed currentDestination to active sections. Outline has no parsing recovery or AI action. Tests are authored for real DB guard/restart/deletion and pure destination/absence behavior but not executed; native/runtime acceptance remains unproved.

Consumer APIs: ReaderMetadataIdentity(paperID:generation:pdfSHA256:pdfReference:revisionID:); ReaderMetadataService.metadata(for:), accept(_:for:), beginSession(for:), saveObservedPosition(in:using:expected:for:) async. The final save API observes actual PDFView.currentDestination itself, runs the durable save off MainActor, and returns the next CAS context only after successful persistence. Parent must hold/drain the current Reader read lease across navigation/observation/save and discard superseded returned presentation. BeginSession returns a restoration candidate; ReaderOutlineAdapter.validatedRestoration must validate against the current real document, and activeSection must be recalculated rather than trusting saved section text. Native MetadataOutlineView receives identity-bound presentation, actual PDFView, adapter, observed active section and current authorization closure; it never saves selection intent.

Register extraction migrations before registerReaderMetadataMigrations: triggers reference extractionVisible. Current joins match the source read at functional-story-1-20-parallel-20261009/Infrastructure/ProductDatabase+Extraction.swift, not the peer's superseded proposed API. Parent must verify final integration schema. Trigger invalidation physically removes owned metadata/context on active revision replacement/removal and Paper deletion/generation/PDF-reference changes. No independent database startup or fallback tables exist. Only source inspection/search was performed; all authored tests, native accessibility/contrast/keyboard checks and builds remain unrun by explicit instruction. StoryDone is not claimed.

### Admitted PDFKit binding phase (2026-10-10)

The explicit independent-session assignment owns only this Spec,
`Application/ReaderMetadataBinding.swift` and
`Tests/Product/ReaderMetadataBindingTests.swift`. Parent owns spec/evidence commits,
target membership, integration, formatting and gates; this session must not run them.
Historical absent-owner receipts do not block the already integrated Reader/DB owners.

Implement a MainActor binding over the existing ReaderSession and
ReaderMetadataService, with weak PDFView/PDFDocument references and data-only
published presentation/outline rows. Parent supplies the exact actually published
revision identity, not a generated revision. Each operation checks Reader ownership,
document identity and the service's atomic current-revision guards before and after
PDFKit access. Parent must invalidate synchronously in Reader discard, before PDF
detach/lease release, and on revision replacement. No new queue, schema, parsing,
provider request, budget constants or recovery authority is introduced.

Use public document title attributes as source candidates alongside stored metadata;
retain conflicts and provenance without persisting a presentation merge over accepted
extraction metadata. Creation/modification dates are not publication years, keywords
are not topics, and subject is not an abstract. The existing snapshot has no author
field; this phase does not change that contract or invent author presentation.

Recreate the existing real ReaderOutlineAdapter inside each leased operation; never
retain its strong PDF destinations in presentation. Navigation is intent only.
Observe PDFView.currentDestination and revalidate after potentially reentrant reads
before saving with the existing internal synchronous service CAS method. This keeps
observation and the GRDB write inside ReaderSession.withReadAccess without inventing
an async lease pin API. Serialize observation against reentrant saves; publish only
after persistence and post-operation validation. Failed saves do not advertise a new
durable position; stale identity/revocation clears all presentation synchronously.
Restored locations remain validated candidates, not observed movement.

Parent must add the two Swift files to explicit SwiftPM/Xcode source lists, mount only
after extractionVisible publishes the matching revision, route outline button actions
through binding.navigate(sectionID:) (the existing view's authorize-then-direct-PDFKit
path does not hold the lease through navigation), and forward actual PDF position
notifications to observePosition(). Refresh on metadata changes; invalidate on close,
delete, revision switch and before PDF detach. No tests/builds/formatters/runtime or
acceptance evidence is produced by this source-only session.

### Parent-mounted admitted Reader controls

Workspace now supplies its same-database ReaderMetadataService and the atomic
publishedMetadataPaperIdentity snapshot to NativeReaderView. Missing published extraction
identity leaves Reader operational with an explicit unavailable metadata/outline state.
The actual admitted ReaderPresentation mounts the weak binding, forwards real PDFKit
position notifications, and synchronously invalidates metadata and annotation contexts
before autoreleasepool PDF detach and actual read-lease release or identity replacement.
Outline controls call binding.navigate; intent is not observed movement. Presentation
remains data-only; author is unknown and creation/modification dates are not publication
years. No new revision, lease, persistence owner or extraction fallback was introduced.
Parent verification: 211 ProductTests with zero failures (artifact://871) and full unsigned
native Release arm64/macOS15 BUILD SUCCEEDED (artifact://872; artifact://873), namespace
product-native-compile-20261010-f. Windowless owned-PDF tests and compilation are not
visible UI/accessibility evidence. Live revision publication composition remains separate.

### Live current-revision Reader caller — bounded local slice

Current workspace captures metadata identity only at Reader open. The existing native
Reader supports replacement, but no caller supplies a newly published extraction while
that same Reader remains mounted. Wire the already mounted persisted ParsingStatusView
to request an actual metadata-identity refresh when its observed usable revision changes.
Reuse its existing polling; no new timer/store, generated revision or provider work.

The workspace refresh must fetch publishedMetadataPaperIdentity from its sole GRDB
owner, not trust a callback-supplied identity. Capture the actual current Reader session,
Paper ID/generation before suspension; after read, fence cancellation and require the
same session object and Paper/generation. Same-Paper close/reopen cannot accept an old
completion. Validate actual Reader read access and matching Paper/hash facts before
replacing only OpenReader.metadataIdentity, preserving the same ReaderSession and
annotation identity. Same identity is no-op, changed/nil actual identity flows through
existing NativeReaderView.onChange to synchronous metadata/annotation invalidation and
weak binding replacement, never reopening a PDF or inventing membership. Query/ownership
failure must not advertise new metadata; retain truthful error/denial and cleanup.

No genuine producer/calibration or product activation is admitted by this UI caller.
Absent extraction stays unavailable and leaves original Reader usable. Do not mount a
new Reader owner or add source defaults, successful fake completion, parsing/Retry dispatch.
Exact worker files: ProductWorkspaceView.swift, ParsingStatusView.swift,
ProductWorkspaceTests.swift and this Spec. Parent owns aggregate/native verification,
independent review/evidence/local commit. Tests use actual owned GRDB publication and
Reader lease/session, covering nil-to-published, replacement, stale/closed/reopened/deleted
session fences and retained annotation/Reader ownership; no app/helper/renderer trial runs.
Visible UI/accessibility and runtime parsing/AD8/P1/P2/P3/Story completion remain unproved.

#### Source handoff at pre-source HEAD 5694ac1 (2026-10-10)

The required MainActor ParsingStatusView callback carries refresh intent only and captures
the mounted OpenReader, including its exact session object. Its existing persisted poll
signals usableRevision changes (including removal/error); no second polling owner exists.
ProductWorkspace.refreshPublishedMetadata(for:) captures that Reader before the actual
detached GRDB read. Internal read/apply stages allow tests to delay an actual DB result,
not inject a fabricated identity. Apply fences cancellation, Paper/generation and exact
session, validates live read access/current Paper/annotation SHA, and rechecks the current
published pointer inside that access before changing metadata only. Query failure clears
metadata advertisement with a truthful failure; lost ownership closes the current Reader.
Nil current publication keeps a valid original Reader usable with unavailable controls.

Authored tests in ProductWorkspaceTests use the actual owned Library, ReaderSession and
canonical synthetic extraction validation with the existing locked fixture budget. Parent
must run focused ProductWorkspaceTests plus aggregate/native/source review; worker tests,
builds, gates, lint, formatting and runtime verification are NOT RUN by instruction.
No visible UI, producer calibration, app/helper/renderer or Story acceptance is claimed.

Authored coverage: live nil→published→replacement→removal retains the actual session,
annotation identity, read token and saved position; identical pointer emits no workspace
replacement. Captured real reads and old callbacks cannot retarget same-Paper/generation
reopen; captured publication/removal is rechecked under read access and cancelled work
cannot advertise it. Real GRDB query failure clears metadata without guessing a revision;
closed/deletion-revoked sessions and changed Paper hash/generation reject advertisement.
No test fetch hook, substitute store, new read lease or identity assembled from a callback
was introduced. The internal read/apply seam uses production GRDB reads in both stages.

#### Review73 initialization corrections before follow-up implementation

Source review73 requests two MEDIUM fixes. First nil/error poll currently compares nil
to its nil initial history and misses removal of the identity captured at Reader open.
Also workspace exposes a not-yet-opened ReaderSession before native admission; sibling
status task ordering is not guaranteed, so withReadAccess failure can prematurely close
that legitimate pending Reader. Preserve focused16/zero981, union282/zero989 and native-t
990 as pre-correction evidence; they do not cover these initialization interleavings.

Reconcile the FIRST accepted poll outcome, including nil/error, independently of equality.
If reconciliation is awaiting actual Reader admission, retain that intent and retry via
the same existing poll; subsequent reconciled outcomes remain change-based. Callback
completion/deferral is UI scheduling only, not metadata publication or closure proof.
Do not simply ignore all nil currentPaper failures, since closed/revoked ownership must
still close/deny. Add a small read-only actual admission-state surface to existing
ReaderSession: pending admission, admitted with its actual sessionID, and closed/failed.
Drive it only from actual open success/failure/revoke/close, including pre-lease failures;
it cannot grant read access, fabricate an owner, alter claim/release or create a new lease.
Where applicable fence delayed results by the actual admission ID as well as session
object/Paper/generation, including reuse of the same session object after close/reopen.

Scope expands by exactly PaperLensApp/Application/ReaderSession.swift (five worker files
total); NativeReaderView and binding owners remain unchanged. Tests cover first nil/error
reconciliation and pre-admission deferral followed by real admission, while genuine close,
revocation and failed admission still deny. No new polling timer, renderer/app/helper run,
default-success callback or fake identity. Existing atomic published pointer, read access,
hash/generation/cancellation fences remain mandatory. Parent repeats changed-source
verification and review73, preserving all protected/runtime/Story boundaries.

#### Correction follow-up: old error must not resolve a new admission

Review73 confirms the two prior MEDIUM defects resolved but finds another concrete
MEDIUM: failure under admission A returns completed=true after the same session object
reopens as B. This dismisses the still-mounted reconciliation intent without querying B.
Split cancellation/non-current-mount dismissal from actual admission mismatch. A current
nonclosed replacement admission returns deferred=false scheduling completion, so the
existing poll retries; old errors never clear/close/advertise data for B. Actual closed
ownership remains denied. Preserve focused20/zero991, union286/zero993 and native-u994
as pre-follow-up evidence, not final coverage of this newly identified error branch.

Also retain a distinct SwiftUI mount identity for each actual OpenReader session object.
Paper/generation alone can reuse an old StateObject when same-Paper close/reopen occurs
without an intermediate render commit. Use actual ObjectIdentifier(session) alongside
Paper/generation, not mutable admission UUID, so metadata-only replacement leaves the
existing PDF/lease mount stable while a genuinely new session gets a new mount. No new
owner, generated revision or default-success state. Fence overlapping manual/poll refresh
completion by its actual request generation before publishing status or resolving newer
reconciliation intent; do not introduce another polling timer.

Same five-file scope and unchanged native binding. Tests cover delayed actual query
failure across real same-object reopen, stable metadata-only/different new-session mount
identity and stale refresh scheduling as shared production logic. Parent repeats focused/
union/native/source review; no app/helper/renderer/protected trial or Story acceptance.

#### Parent concrete overlapping workspace error completion

After review73 source-only approval, parent found a separate same-admission interleaving:
metadata callback1 captures a real failed DB read and waits; callback2 applies a healthy
current pointer and resolves latest status intent; callback1 later clears that metadata.
The status-view request guard AFTER callback does not fence callback side effects inside
workspace. Identical healthy polls can then stay resolved with false unavailability.
Preserve23/zero996,289/zero998,native-v999 as pre-correction evidence.

Capture a workspace-local request ID for each actual current-mount metadata read BEFORE
suspension. Both success and failure application must require the latest actual request,
in addition to cancellation/session/admission/hash/current-pointer guards. Stale requests
must not clear metadata, change failure, close a Reader or resolve current pending intent.
New session/return must invalidate old work; obsolete mount intent remains dismissible.
Use shared production capture/read/apply seams and actual GRDB failed/healthy reads for
deterministic coverage; no fabricated fetch, identity, success flag or replacement store.
Same five-file scope, no new timer/owner/permission. Parent re-verifies only changed
source and reviews this exact new interleaving; existing resolved findings remain reused.

#### Correction source handoff from committed Spec c6b7506

ReaderSessionAdmissionState is read-only scheduling data: pending before admission,
admitted(actual private sessionID UUID) only after successful actual open, and closed
on pre-lease failure, failed open, revoke or close. No read permission, lease acquisition,
claim/release or PDF lifetime authority is replaced by this state. Workspace defers pending
admission without querying/closing it; admitted refresh still requires withReadAccess.
Captured real DB reads fence actual admission ID before apply and before advertisement,
in addition to cancellation/Paper/generation/exact session object. Same-object reopen
cannot accept an old admission result. Closed/revoked Reader still resolves as denial.

The required MainActor status callback now returns Bool: false means retain this refresh
intent awaiting actual admission and retry through the existing poll; true means resolved
or dismissed, NOT successful publication. ParsingMetadataReconciliation, used by the
production status view, reconciles the first outcome including nil/error, retains deferred
intent across identical polls, and becomes change-based after resolution. Error is a
distinct scheduling outcome, never a fabricated metadata identity.

Four additional tests are authored: first nil/error clears open-time metadata using real
GRDB query/removal failures; pre-admission polling defers then actual owned-PDF open
admits exactly once and preserves its read token; missing provider/nonready pre-lease
open failure becomes closed instead of indefinitely pending; same ReaderSession object
close/reopen rejects a captured real read from its old actual admission UUID. The original
six refresh tests remain intact. Correction tests/builds/gates/lint/formatting/runtime
are NOT RUN by worker instruction. Parent reruns focused/union/native verification and
review73; pre-correction evidence remains historical, visible runtime/UI unverified.

#### Follow-up source handoff from committed Spec 64bd6a9

PublishedMetadataOutcome captures real GRDB success/failure and actual admission before
suspension. applyPublishedMetadataFailure shares production error application with tests:
cancelled/noncurrent mount is dismissed (true); still-current different nonclosed admission
defers (false); actual closed ownership remains denial. Old A errors cannot modify B's
metadata/error or dismiss its pending polling intent. No throwable Sendable wrapper over
a MainActor session, fake getter/store or successful fallback is introduced.

OpenReader.mountIdentity is Hashable Paper/generation/ObjectIdentifier(actual session).
The root Reader container uses this key; metadata-only replacement is stable, but a new
session object remounts even without an intervening Library render. Actual admission UUID
does not participate in this mount key, so initial native admission cannot remount itself.

ParsingMetadataReconciliation.beginRequest issues a per-refresh request UUID. Production
poll/manual refresh checks it after DB await, after context await and before publication;
after callback await, stale requests cannot resolve newer pending intent. No timer/queue
is added. Shared production request guards are tested using actual status reads and real
workspace callback deferral/dismissal, not fake successful callbacks or counter defaults.

Three follow-up tests are authored for delayed real GRDB query failure across same-object
real reopen, metadata-stable/new-session-distinct actual mount keys, and overlapping actual
poll reads with stale callback completion. Prior ten refresh/admission tests remain intact.
Worker verification is read-only source inspection; tests/builds/gates/formatting/runtime
are NOT RUN by instruction. Parent repeats focused/union/native and review73; 991/993/994
are pre-follow-up evidence only. Runtime/UI/Story acceptance remains unverified.

#### Workspace side-effect fencing handoff from committed Spec 5f78347

ProductWorkspace.metadataReadRequest records the latest actual metadata query UUID before
suspension. Each real readPublishedMetadata or readPublishedMetadataOutcome call stamps
exactly once; their private shared read takes captured admission/request and never mints
at application. PublishedMetadataRefresh and PublishedMetadataFailure carry request UUIDs.
Post-apply errors use the same refresh admission/request, never an unstamped error context.
Success/error application checks latest request before read-access cleanup or mutation,
and again before metadata advertisement/error cleanup. Stale current-mount work returns
false (defer), obsolete/cancelled mount true (dismiss); neither signifies publication.
New workspace session and return invalidate the latest request. Existing session-object,
actual admission UUID, GRDB current pointer, SHA/generation and read-lease guards remain.
Status/ReaderSession/native owners require no additional changes for this correction.

Two tests authored: an actual query fails while the owned extractionVisible table is
temporarily renamed, then the same transaction-owned schema/data is restored and a newer
healthy actual query advertises R; old failure returns false without clearing R/error/
Reader/token. A stale successful read cannot reconcile a changed pointer or invoke Reader
cleanup after a newer request; the latest request still reconciles current publication
and actual ownership denial. No fake identity/getter or budget/admission substitute.
Worker tests/builds/gates/formatters/runtime are NOT RUN by instruction. Parent repeats
focused/union/native and exact reviewer73 interleaving review; 996/998/999 are historical
pre-correction receipts, not proof of this change. Visible UI/Story remains unverified.

#### Live metadata caller — final parent verification

Final25 focused Workspace tests passed (artifact1000), including15 new actual owned
GRDB/Reader/session/admission/query-fault/overlap/mount cases. Full Product union291
passed with zero failures (artifact1001). Fresh unsigned native Release arm64/macOS15
compiled in native-w (artifact1002); app/helper/renderer binaries did not run. Unchanged
NativeReaderView/ReaderMetadataBinding/DB/schema/Package/native membership are reused.
Four-source-file binary delta against final correctionSpec5f78347:
6b48d58e4ba554165b8bd257f5361866544e9775d5ddb7b0bf885082689436cf.

Review73 final SOURCE-ONLY CLEAR / APPROVE resolves the first-nil/error, pending Reader
admission and old-admission failure findings; parent overlapping workspace error side
effects are independently cleared after actual request fencing. Preserve981/989/990,
991/993/994,996/998/999 as historical pre-correction receipts. Successful tests/compilation
do not establish visible UI/accessibility, actual parser/calibration, AD8/P1/P2/P3 or Story
completion. No paid/live/private SDK, trial renewal, push/PR/remote/release action occurred.
