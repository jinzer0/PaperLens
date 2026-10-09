# Story 1.22 Build Spec — Metadata and Reader Contents

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
