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

## 2026-10-10 actual PDFium producer source phase

Whole-Story source authority and independent contract40 admit these exact four files:
PaperLensApp/App/TopologyFixtures.swift, PDFiumXPC/main.swift,
PaperLensApp/Application/ExtractionRevisionService.swift, and this Spec.
Parent commits this amendment before worker source edits and owns every affected test
conformer, Package/project membership, shared-caller integration and final verification.
Architecture, acceptance, numeric resource policy and protected trial allowances do not change.

Add an independently named PDFiumExtractionService inheriting PDFTopologyService;
beginExtraction(request,pdf,reply), nextExtractionBatch(operationID,sequence,reply),
cancelExtractionAndDrain(operationID,reply). Preserve distinct topology smoke selectors
and checks; product admission never uses fixture-map/profile/canary/network checks.
One extraction per connection, one outstanding pull and one process-wide native library
session span initialization through real cleanup. Topology native calls cannot interleave.

Wire uses immutable final NSObject/NSSecureCoding DTOs and matching allowed-class lists
on both ends. Reject missing fields, unsupported schema/ranges, nonfinite coordinates,
illegal reply combinations and identity/sequence mismatch. No JSON, Any dictionaries,
ProviderRPC, arbitrary openable paths, credentials/configuration or closures cross XPC.
Key carries original operation/Paper/generation/revision/Job/attempt/fence/correlation/input/
epoch UUIDs, exact SHA and opaque reference; retain complete ProviderConfiguration in Main.
Requests carry actual byte count, original monotonic deadline and immutable limits from
existing parsed ProviderRequest parser/pool/limits authority plus actual reserved allowance.
Limits contain input/pages/sentences/sentence-bytes/text-bytes/quads/batch-bytes/batch-count/
resident-bytes; no new numeric policy, copied caps, guessed gauge or no-op reservation.

Use checked real read-only FD and regular-file size/access, SHA-256 and bounded read-only
mmap retained through FPDF_CloseDocument. Call locked public PDFium document/page/text/
box/matrix/rotation APIs with exact C pointer/primitive ABI. Extract real Unicode/native-to-
UTF16 provenance and Foundation sentence ranges. Deliver actual page metadata, native
glyph spans/matrices/generated flags and raw quads; never label raw coordinates canonical.
Initial actual geometry supports positive axis-aligned native matrices only; unsupported
orientation, unmappable visible text, missing geometry, oversized sentence/page/result or
empty usable document fail, not fallback/drop/truncate/OCR/PDFKit extraction.

Pull retains at most one page workspace and response batch, checks original deadline and
actual resources before/after native calls/loops, and never publishes incremental results.
Typed completed/cancelled/failed end is emitted only after text/page/document/mapping/FD/
library cleanup. Checked close failures retain debt/no end. Timeout/interruption/invalidation
is not closure proof. Independently observable cancellation requests serial captured-operation
drain; never close live PDFium handles concurrently. Native allocation/uninterruptible-call
hard bounds still require protected runtime proof, not source claims.

Replace array-returning extract with scoped withBatches(identity,consume); add expectedText
to validateAndEncode. Main owns actual child read pin, extraction sender FD and existing
operation/resource accounting, supplied through required callbacks that cannot default to
success. Immutable PDFiumPinnedInput owns checked close/idempotent captured operations;
uncertain close retains actual owner debt. Validate all delivery/end facts, checked sender
close and child-pin release before geometry/publication; retain resource ownership through
consumer/transaction/disposal. Supplied actual precision/page mapping/paired canonical codec
remain required; no calibration, identity transforms or second codec is manufactured.
Missing real acquisition/resources/geometry bindings deny admission before input effects.
Source implementation/compilation is not helper activation, AD8, P1/P2/P3 or StoryDone.
