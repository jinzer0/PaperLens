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
