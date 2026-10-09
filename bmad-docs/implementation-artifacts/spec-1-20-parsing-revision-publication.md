# Story 1.20 Build Spec — Parsing revision publication

## Authority and admission

Issue#22 / issue/22-story-1-20; basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source, no repeated unchanged-scope SHA approval; no live/paid/credential/remote/distribution/gate inference.

Architect52 read ROOTepics952–984 and own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json, PaperLensApp.swift only; commonUI excerpt samefile separately supplied, nevercopiedroot. Planning ONLY/not implementation-ready; product BLOCKED/StoryDone=false. Actual1.19/1.14/1.15+applicableP1/P2/P3 absent,1.13initial20PASS/review48BLOCK/repairunaccepted at planning. Local14dd7b3/c93e873 nonproduct; blankCapture FAIL/noP6. Helper/persistence split forbidden before actualP2.

## Worker and atomic revision

## 2026-10-09 actual adapter phase (source-order amendment)

Latest explicit human instruction admits exactly this Spec, Application/ExtractionRevisionService.swift,
Infrastructure/ProductDatabase+Extraction.swift, Features/Reader/ParsingStatusView.swift,
and Tests/Product/ExtractionRevisionTests.swift. The earlier clauses “Helper/persistence split
forbidden before actualP2”, “not inventedtables”, and “No actual implementation before
prerequisites” are changed ONLY in source order: implement a minimal feature migration and
guarded transactional adapter before physical P2 proof. No P2 PASS or StoryDone follows.
The sole ProductDatabase owner registers registerExtractionMigrations; no queue/startup owner
is added. Parent owns package integration, producer binding, read leases and deletion drain.
Sentence text/page/ID use the existing ProviderRequest authority. Geometry has no guessed
fields: a typed geometry input plus validateAndEncode contract must be bound to actual 1.19;
absent producer or validator is an explicit failure. The returned canonical encoding and quad
count must come from that validator; this lane supplies no successful generated batch.
Batch sequence/completeness, immutable Paper/generation/PDF/reference/input/configuration,
job/attempt/fence/correlation/epoch and running state are checked before publication.
One sole-queue transaction inserts revision, full text, canonical geometry and FTS rows,
switches visibility and marks success. Failed attempts preserve old usable revisions.
Queries capture revision and rows in one read transaction; old revisions are retained, not
reclaimed here. Tombstone cascade removes all extraction rows and FTS; deleting Paper is
immediately inaccessible. Persisted status is rendered by native SwiftUI, not dispatch state.
Local tests are written but ALL tests/builds/gates/formatters/commits/remotes are skipped by
explicit instruction. Actual producer calibration, runtime proof and parent integration remain
unverified, not fake PASS.

Current Paper-owned immutablePDF/read-only ownedinput→no-network PDFiumXPC boundedtyped sentence/canonicalgeometrybatch. Worker NEVER writes DB/FTS/cache/accessesSecrets/arbitrarypaths/publishes. Application validates1.19 identities/relations/bounds/completedelivery, no transportterminal=extraction.

ProviderRequest resources.parser/pool/limits numeric authority cumulative/gauges/elapsed/RSS, no copiedconstants or ProviderRPCasPDFiumprotocol. WorkerpublicAPI/framing/payload/completeness/tolerance UNKNOWN; pinbeforecode/noplaceholder.

Application completes all sentence/geometry/matchingFTS inactive revision, incrementalrows NEVER visible. One guardedtransaction atomically publishescompleteactive/usablepointer+Jobsuccess/result; build/FTS/commitfailure rollsback, nofilesystem/contenttablefallback. ActualDBschema/FTSlinkage/migration/completion/transaction/crashAPI UNKNOWN; onesoleDatabaseQueue/migration/visibilityowner, not inventedtables.

Search atomicallyacquires oneactiverevision+retention againstactivation/reclamation; EVERYFTS/content/geometrylookup samepinnedrevision. Inflightsearchcannotmix/repin; nonecomplete meansnosearchableextraction. Failed/stalereparse keepspriorusable/provenance. Successfulnewrevision keepsoldwhileheldrefs, onlyunreferencedcleanupcandidate. Deletion revokesnewaccess/drainsownedrefs beforecascade, refsnotresurrectionauthority. Exactreference/handleaccounting UNKNOWN.

## Recovery and deletion

Accepted1.13 immutablefresh Job/attempt/fence/correlation/input/epoch/Paper/reservedbeforemutation, applicableconfigexplicit. Currentrunning+allpublicationguards, startupinterrupted/nooldfencerenewal/explicitRetry/usablepreserved. Shortstatearbitration noFS/DB/callback/blocking/drain; executeeffectsoutside/revalidate.

If actualPaperFSproducer: writerfirstaccess→close/cancelcleanup, publicationthroughguardedcommit/synchronousfailedguardcleanup. Do NOT invent revisionfiles/renames forDB-onlystorage. Rejectedinactiveownedresults cleanedbeforepermitrelease; uncertaincleanup debtretained, startupscavenging notsubstitute. Delete revokesdispatch/access/permits, drains thenremovesALLPaper sentence/geometry/FTS; late/restart/ordinaryRetryneverreactivate. Freshperinvocationop+immutabletargetcompletion, stale/duplicatecannotcleardebt.

## Conditional phases and required proof

≤5exactsource+pairedtests per amendedphase AFTER prerequisites: actualworker/typedcontract; Application/solepersistencemigration/FTS atomicbuild; pinnedsearch/reference/deletion. PathsUNKNOWN, no schema/helper/CI/newcache/newpolicy/fallback/scaffold. No Chat/Translation/Brief/Reader/Library/timing feature expansion. BindpublicAPIs/callsites beforeediting.

Actualworker immutablePDF/no-network/no DBFTScachewrites, malformedprotocol/batch/type/exact+oneoverbounds. Pause inactive steps→oldcompleteor-none queries; FTS/build/commitfail neveractive/succeeded. Holdoldsearch acrossswap→consistentoldrowsuntilrelease/newqueriesnewrevision. Realcrashbefore/afterwrites/activation→completeatomicstate/no oldresume.

Barrierdispatch/batch/validation/commit mismatcheachguard, reverse/late/reparse resultsnevermove winner. Deletewithheldpermits/refs/cleanupfail/retry/staleop→actualdrain+capturedscopecleanupbeforeabsence/noresurrection. No mathematical/pure/localGRDB-only productproof.

ApplicableUI NativeCanvassemantic/Koreanstateaction/noncolorcues/actualcontrast/textscaling/resize/keyboardVoiceOver/focusreturn/accessibleRetryCancelDelete and ALLcurrentPaperfailure-restart-delete races, not deferredpolish. NoUIstubtofakecompletion.

Architect52 COMMENT/WATCH/read-only fiveinputs/no tests/gates/formatter/build/GUI/SDK/auth/network/commits. Done requires actualowners/gates/physicaldurableproof/parentverification/independentreview, no planningpromotion.
