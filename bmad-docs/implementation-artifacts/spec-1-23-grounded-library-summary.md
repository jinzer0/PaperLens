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

## Canonical independent-owner geometry binding (after411fb01)

Bounded121 source assessment identifies a real reusable decoder, not a missing wire
format: CanonicalExtractionGeometryValidator already compares independent owning
anchors, entire original UTF-8 quote, page geometry, every quad and explicit precision.
Implement its LibrarySummaryGeometryValidating conformance in the existing
`PaperLensApp/Application/CanonicalExtractionGeometry.swift` only. Share the existing
decoder/version/domain reconstruction and owner-validation core; retain extraction
callers' identity projection and every existing denial. Summary resolution must first
match hit revision/page/sentence to the requested PDFSentenceIdentity, then validate
the full canonical anchor against independent owners and require exact hit-text UTF-8.
No second codec/store, default precision, inferred numeric Paper generation, persisted
bytes reused as their own authority, latest-revision substitution or provider call.

Parent owns `Tests/Product/CanonicalExtractionGeometryTests.swift` and
`Tests/Product/LibrarySummaryServiceTests.swift`: direct valid/mismatched hit tests,
full-extent/truncated-quad/normalization/page/precision/membership denials, and actual
sole-GRDB summary reserve/publish/reopen/restore using canonical bytes plus independently
constructed owned-fixture anchors. Include full frozen tails and retained older revision;
no fixture/profile/calibration or successful fake production binding claim. Run isolated
focused/full Product tests, fresh unsigned native compilation and independent source
review before the exact local source/evidence commit. Worker skips all gates/formatters/
commits/remotes/workflows/trials. Production Library injection remains a separate owner
integration requiring genuine complete anchors and explicit precision for saved revisions
after restart; neither this conformance nor its tests establishes that owner, visible UI,
calibration, certified Provider enforcement, Agent purge, StoryDone or Epic acceptance.

### Parent canonical binding implementation receipt

After committed44663a9, worker122 changed only the existing canonical validator;
parent added six direct/sole-GRDB tests in the two named files. Shared decoder and
independent complete owner comparisons are preserved; stored assertions do not become
their own authority. Focused34/zero1419, full isolated439/zero1425 and fresh unsigned
native-ax1427 pass. Independent123 SOURCE-ONLY CLEAR / APPROVE found no blocking gap.
Three-Swift-file binary diff SHA256 versus44663a9 is
`dcd86b677da461e69a0fee2ed2979828ec856a0e3a9fbaa4accc8438b7c0e6cd`.
Reopen tests retain fixture owner objects, not a production process-restart owner.
Correlated frozen/text/geometry forgery is directly exercised at reservation; every
boundary checks unranked full geometry through the same core. Production saved-revision
owner recovery/precision/injection, Library presentation, calibration/live Provider/
Agent purge/visible UI/Story acceptance remain unproved. No binary/trial/remote execution.

## Original independent-owner archive

Implement the existing restart-owner prerequisite in exactly CanonicalExtractionGeometry.swift,
LibrarySummaryService.swift and ProductDatabase+LibrarySummary.swift. No new resource owner,
pool/database/cache or geometry codec: archive passive original owner facts in sole GRDB.
Only the existing CanonicalExtractionGeometryValidator can capture its private original
owningAnchors and actual explicit precision; never derive owner records from candidate
extractionSentence.geometry, summary/frozen bytes or decoded result geometry. Capture every
full frozen sentence including unranked tails, using the existing canonical encoder for
original complete anchors. No guessed/default precision, generation or calibration.
Internal bounded capture/recovery values retain encoded original anchors and explicit
PDFGeometryPrecision.maximumErrorPDFPoints. Positive maximumBytes262144 is a storage
metadata quota, not physical/profile admission. Bound counts/quote/quad encoding before
allocation and reject over-quota storage before Provider effects.
Add ordered GRDB migration with immutable owner header/anchor rows keyed by existing
librarySummaryJob; delete through its FK cascade at actual tombstone. Reserve validates
full current grounding then atomically stores job and original canonical owner facts;
noncanonical validators cannot manufacture archived ownership and deny new reservation.
Failed/old retained summary jobs retain their original data; no legacy backfill/reconstruction.
Restore with no externally injected owner loads that job's original rows, checks bounded
length/count/identity/full membership and reconstructs Domain anchors through the SAME
canonical decoder and captured precision, then runs existing complete summary validation.
Explicit fresh independently supplied geometry remains a valid authority input; it is
not obtained from candidate bytes. No missing-record fallback or automatic parse/Provider
request. Stored facts grant no fresh read/publication/action permission.
This implements recovery for originally registered genuine owners, not production creator
injection/calibration or generated UI. Those require genuine upstream complete anchors.
User implementation-first applies to workers: no new/correction tests, broad suites,
native builds or review lanes. Parent minimum required confirmation only; all deferred
proof and genuine producer/profile/UI/Story limits stay explicit and false.

### Implementation-first archive delivery

Worker142 implemented the three scoped sources; parent added same-snapshot restore entry
for Library callers, conservative pre-encoding quote/quad/member bounds and typed SQL
anchor-key inspection before decoding. Original private owners/explicit precision are
persisted atomically with the existing Job and recovered through the existing codec;
no candidate-derived authority or second store. Worker143 integrated actual saved result
and ordered full evidence quotes into existing Library list/grid/detail (Spec4bb1a7b).
Exact six-source binary diff against4bb1a7b SHA256:
`f233f8f6013bfeaff551a8fb63875dec9d791e9b457177ab74a848e7a5baa2d9`.
Minimum existing canonical save/reopen case passed (artifact1520 and final source rerun
exit0); existing atomic year/metadata Library fact case passed exit0. SwiftPM compiled
the changed product/UI source. The canonical case uses explicitly supplied fixture
owners on restore: it does NOT verify geometry-free archive restart, corruption, quotas,
deletion cascade, visible controls or genuine calibrated producer/profile activation.
No new/correction tests, broad union/native gate or independent review were performed;
legacy noncanonical reservation fixture expectations remain intentionally unmodified
and require genuine independent Canonical owners before future broad verification.
0/26 Stories and Epic acceptance remain false; no protected execution or remote action.

### Geometry-free owner archive focused regression

Three new LibrarySummaryServiceTests original-owner archive cases passed parent
SwiftPM `--parallel --num-workers 1 --filter LibrarySummaryServiceTests.testOriginalOwnerArchive`.
They reopen sole GRDB without injected geometry or provider after visible revision/config
change, retain saved identity/result/full ordered quotes and unranked membership plus
explicit synthetic fixture precision, and reject missing header, wrong-typed precision,
corrupt canonical anchor, missing unranked tail and stale generation/visible pointer.
No provider effect or replacement Job/result is introduced. This is database reopen,
not process/native restart or independently calibrated production-owner proof. Actual
deletion cascade, quotas, archive source review, creator/profile activation and visible
Summary remain outstanding; no Agent purge/closure acknowledgment is fabricated.

Focused storage follow-up56d2c24 passed artifact1634: actual SQLite FK paper-row
deletion cascades all five Summary tables; a single over-quota anchor INSERT fails
its real CHECK with rollback, and representable aggregate overflow rejects before
anchor decoding. This is metadata storage behavior, not application deletion/purge.
The first full24 service suite failed10 (artifact1635): nine obsolete noncanonical
FixtureGeometry positive fixtures and one obsolete absent-saved-result expectation.
Those fixtures now seed independently constructed original Canonical anchors once
before exposure, retain explicit synthetic precision and never rewrite deliberate
corruption at reserve/publish/restore. The obsolete decoder is removed; exact typed
forgery/rollback/CAS/no-replay assertions stay active. A missing saved result returns
nil without Job/result/visibility/owner effects; saved missing archive still denies.
The updated complete24 LibrarySummaryServiceTests passed artifact1640. No tests are
skipped or product guards weakened; no production geometry or acceptance claim.
