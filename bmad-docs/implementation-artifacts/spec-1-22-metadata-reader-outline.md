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
