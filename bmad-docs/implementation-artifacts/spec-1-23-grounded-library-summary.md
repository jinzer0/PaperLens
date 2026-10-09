# Story 1.23 Build Spec — Grounded Library Summary

## Independent source-only slice (2026-10-10)

Human session instruction limits edits to LibrarySummaryService.swift,
ProductDatabase+LibrarySummary.swift, LibrarySummaryServiceTests.swift and this Spec.
Parent commits specifications, registers migrations/source lists, runs all gates and
wires Library plus the certified live adapter. This session runs no gates or commits.
Implement sole-queue immutable request/context/result storage with guarded atomic
Job success and visible pointer replacement. Saved context is reconstructed locally
for existing ProviderRequest result validation; restoration never generates or sends.
Canonical geometry decoding is an injected synchronous validating boundary: absent
decoder denies send/publication/restore. No opaque geometry BLOB is treated as proof.
Parent owns serialized JobRecoveryPolicy snapshots and real permit/closure execution;
publication consumes its already-admitted publication permit, without synthesizing
rename/closure success. Adapter consumes AuthorizedProviderRequest and returns
ValidatedProviderResult under existing certified enforcement; no new wire fields.
Previous results and their extraction revision references remain retained. This is
an application/persistence slice, not StoryDone, live certification or UI acceptance.

Parent integration: add both Swift sources and paired test to Package/Xcode source
lists; register `registerLibrarySummaryMigrations(in:)` after extraction migrations
(summary tombstone cleanup must precede extraction revision removal). Retain all
referenced extraction revisions. Call `recoverInterruptedLibrarySummaries(currentEpoch:)`
without dispatch replay. Serialize current epoch/input/config authority and publication
permit admission through commit, adopting the policy's successful publish snapshot
only after SQL commit. Failed/interrupted jobs do not prove adapter closure or purge;
parent must drain actual permits/cleanup before admitting a fresh invocation.
`LibrarySummaryProviding.execute(_:identity:)` consumes authorized requests plus
frozen local lineage and returns `ValidatedProviderResult`; actual certification,
credential/config binding and real closure remain mandatory adapter responsibilities.
`LibrarySummaryGeometryValidating.resolve(_:identity:)` must decode the production
canonical encoding and validate full quote extent; no current opaque BLOB inference.
Identity requires explicit `requestPaperGeneration: Int` from the trusted identity
owner alongside the local generation UUID, with no generated/default numeric mapping.
Tests contain controlled synthetic storage/geometry only; eleven authored tests have
not been executed, compiled, formatted or reviewed by an independent parent gate.

## Authority and admission

Issue#25 / issue/25-story-1-23; basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. OwnSpecbeforecode/no repeatedunchangedSHAapproval(parentreconciledgenericproposal wording); no gate/live/paid/credential/remote/distribution permission.

Architect55 exactlyROOTepics1051–1082+1181–1190, own SOLUTION-DESIGN,1.13Spec, ProviderRequest/contract.json, PaperLensApp.swift. Rootonlynotcopied. Planning ONLY/not implementation-ready; product BLOCKED/StoryDone=false. Accepted1.13/usable1.20/1.22/actualProvider/applicableP3 required, noneinferred. Atplanning1.13initial20PASS/review48BLOCK/repairunaccepted; local14dd7b3/c93e873 notproduct. P1/P2/P3/P6unproved/blankCapture FAIL.

## Bounded source and claim grounding

Applicationownsinputs/Job/config/publication/persistence. Freeze PaperUUID/generation/PDFSHA/extractionrevision/language/orderedEvidenceBundle/configgeneration. ExistinglibrarySummary source{outputLanguage},input{outputLanguage,evidence}; NO Readerpage/selection/Highlight/Note/rawPDF/path.

SOLE sharedauthority: summaryItems8/summaryEvidenceBytes8192/inputCharge8192/outputTokens512/outputBytes2048/controlReserve4096; rankedPrefix/frozenProvenance/renderedBudget/query `main contribution results conclusion`. Reuseactualcontract, notduplicatepolicyconstants/adapterrerank-truncation. Result{summary:{text,kind,evidenceIndices},insufficiency} andsummaryLine/citationRelations/resultInsufficiency validators unchanged.

EachPaperCLAIM selectedmatchingEvidenceAnchor(s)/canonicalsentences OR validinsufficiency. Paper/inputrevision provenance ALONE NOTgrounding. Resolveindices againstsavedorderedbundle; wrongPaper/revision/quote/missinganchor notgrounded. Preserveclaimlinks/insufficiencythroughsave/Library/restart; no Brief/researchclaims/recommendation substitute.

UNKNOWN actualliveadapter/selector/language-choice/inputencoding/DBschema/LibraryAPI, no inventedwirefields. Dispatchactualauthenticatedrequests onlyauthorizedcredentials/budget, not fromplanning.

## Publication cache and lifecycle

Accepted1.13fresh Job/attempt/fence/correlation/epoch/input reservation/durableintent-before-send. Typedresultthen currentrunning/attempt/fence/input/config/Paper/epoch/permitguard. Oneguardedtransaction immutableusable+groundingbindings+Jobsuccess+pointer, no partialpublish. Restorecommittedresult/evidence WITHOUTregeneration/providerdispatch. Previoususableonfailure/heldrevisionrefsretained; never retagoldsummary/newrevision/fakecurrentusability.

Actualpreparing/unavailable/failure/insufficientstates+actions, empty/whitespace notusable, PDFreadable. ExplicitRetry currentprereqs/freshlineage/no duplicatepending-running/ambiguousautoreplay. Delete revokes/drains scopedresults/Agenttemporarypurge; late/staleneverpublish, terminalcancel notclosure. Freshcleanupop/immutabletarget/no stale-debt discharge; applicableFSwriter/publication/synchronousguardcleanup outside shortarbitration. Unknownclosure retainsbarrier.

## Conditional phase and required proof

≤5exactexistingpaths aftersameSpecownershipamendment: Applicationsummary/solepersistence/actualProvideradapter/Librarysurface/pairedbehavior-integrationtests. Allpaths UNKNOWN, requiredwiringphasesnamedbeforeedits, no alternatecache/recovery/schema/helperCI/fakeUI.

Prohibitedinput/exact-oneoverUTF8/order/provenance/citations/empty-multiline failures; validnoEvidence/budgetLimited; PaperrevisionwithoutAnchorfailsclaimgrounding ALSOafterrestore. Actualsave/reopen/restart zerogenerationcalls, retainedoldresult/revision/crashatomicity. NoProvider/extraction/ambiguous/interruption/freshRetry/competingrequests/eachguard/late-delete cases. ActualAgentpurge/closurefailure/retry/synchronouscleanup, not syntheticproofsubstitute.

NativeCanvassemantic/Koreanstateaction/noncolorcues/actualcontrast/scaling/resize/keyboardVoiceOverlabel-role-state/dialogfocusreturn/accessibleRetryCancelDelete. CurrentallPaperfailure-restart-delete races inthisStory/no deferredpolish/futureAI-successscreens.

Architect55 COMMENT/WATCH/read-only fivefiles/no tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done actualprereqs/realgroundedgeneration/durablelifecycle/UI/parentverification/independentreview. Planningpassesnone.
