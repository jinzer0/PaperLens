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
close before geometry/publication; retain the actual child read pin and resource ownership
through canonical validation, consumer/transaction completion and raw/canonical array disposal.
Release the pin only after those consumer milestones, then finish operation accounting.
Supplied actual precision/page mapping/paired canonical codec
remain required; no calibration, identity transforms or second codec is manufactured.
Missing real acquisition/resources/geometry bindings deny admission before input effects.
Source implementation/compilation is not helper activation, AD8, P1/P2/P3 or StoryDone.

### Review53 correction contract before further implementation

Keep helper drain, checked sender closure, child-pin release and final accounting as
separate captured milestones. Cancellation/error paths retain the pin until consumer data
is disposed; uncertain native/sender closure still retains unresolved ownership debt.
Pass an immutable Main-only ExtractionConsumptionScope with a required throwing
checkBudget guard into the local consume callback. The guard checks the originally
captured deadline/resource allowance and cancellation, not a new quota or renewed budget:
withBatches(identity, consume: ([ExtractionBatch], ExtractionConsumptionScope) async throws).
The existing validation loop checks this guard between canonical units and before/after
validation. The existing sole-GRDB publication transaction checks it at its guarded
publication boundary and before successful commit; failures roll back publication.
The parent owns the Infrastructure publication signature and affected caller adaptation.
No scope callback, provider configuration or ownership closure crosses XPC.
Rejected duplicate/identified begins retain a captured received-handle debt owner when
checked closure is uncertain. Preserve the accepted operation; never retry a potentially
reused descriptor or manufacture End. Acquired opaque PDF references must match original
request UTF-8 exactly, in addition to all other identity/configuration guards.
Parent-owned tests/build/review follow these source corrections. The initial four-file
delivery and Review53 BLOCK are preserved; no helper/runtime or Story promotion follows.

### Owned source delivery (unverified)

The four admitted files now contain the native producer source, not a fixture-backed
product result. The independent transport is `PDFiumExtractionService` with the three
specified selectors; `PDFTopologyService` is public so the public inherited protocol is
valid. Both product endpoints use `PDFiumExtractionInterface.make()` for identical
secure allowed-class registration, including nested arrays, glyphs, quads and UUIDs.
The new protocol and all DTOs have explicit stable PaperLens-prefixed Objective-C runtime
names so separately compiled Main/helper modules do not archive incompatible class names.
Topology smoke selectors, fixture admission and signing requirements remain distinct.

The helper uses actual descriptor access/size checks, read-only mmap, SHA256 over the
mapping, and direct locked public PDFium symbols. Header review used only the controlled
parent source at `.build/topology/full-acquisition-arm64-ae7a27c9-e584-40ef-a164-e9631d68d11a/pdfium/src/public/`:
`fpdfview.h`, `fpdf_text.h`, `fpdf_edit.h` and `fpdf_transformpage.h`. FS_RECTF is four
Floats in left/top/right/bottom order; FS_MATRIX is six Floats in a/b/c/d/e/f order.
Box accessors write Floats; character boxes write Doubles; opaque pointers and Darwin
size_t/unsigned-long/int widths are declared explicitly. No optional symbol lookup,
vendor acquisition, compilation or vendor execution was performed.

One queue and a process-wide reservation cover native library lifetime between pulls
and through document/map/received-FD cleanup. An independently locked cancellation
flag is checked during work; connection invalidation only requests serial cleanup.
Uncertain FD closure is not retried against a potentially reused descriptor. Unresolved
native handles remain retained even after connection invalidation. Pull uses one page
workspace, one batch and one sentence lookahead. Unicode/native/UTF16 mapping and
Foundation enclosing sentence ranges retain exact source text; visible unmappable,
non-axis-aligned, mirrored, collapsed or oversize geometry fails instead of being dropped.
Whitespace may omit geometry only following a successful collapsed native character-box
observation; generated flags and matrices still come from actual native calls.

Application API changes requiring parent integration:

- `ExtractionBatchProducing.extract` is removed, replaced by
  `withBatches(_:consume:) async throws` with a required Sendable async consumer.
- `ExtractionGeometryValidating.validateAndEncode` now requires `expectedText`.
- `PDFiumExtractionProducer.init(acquireInput:)`, `withBatches` and
  `cancelAndDrain(operationID:)` implement the required captured-operation scope.
- `PDFiumPinnedInput` takes the exact required constructor callbacks. It owns the
  transferred sender FileHandle (not publicly exposed), verifies actual FD identity,
  closes it with checked errors and captures idempotent pin/resource release states.
  No callback defaults or caller-declared closed flags exist. Input limits are compared
  to the parsed ProviderRequest authority; resident allowance cannot exceed its RSS cap,
  and remaining original deadline cannot exceed its parser elapsed cap.
- `PDFiumPageMapping`, `PDFiumGeometryBinding`, `PDFiumGeometryInput` and
  `PDFiumGeometryValidator(binding:)` supply the required actual mapping/precision/paired
  codec boundary. The validator compares exact expected text, complete glyph provenance,
  delivered identity, transformed quads and supplied Reader transform/inverse. It does
  not invent published membership or a canonical codec.

Main keeps the full original ExtractionIdentity/ProviderConfiguration. It verifies the
signed connection PID, wire keys, actual hash/size/page observations, batch order, global
consecutive sentence IDs and final totals. Confirmed helper drain precedes checked sender
close and actual child-pin release; the resource owner remains captured through consumer,
sole-DB publication and disposal. Concurrent drain callers await the same actual release
tasks. Timeout fails only the waiter: the captured session/debt remains. A late same-session
cancel response can record verified drain proof, but cannot publish, release ownership on
its own or modify a newer operation. Retrying drain after the scope has disposed its data
can release the original retained resource owner. Ordinary failures before publication keep
the old usable revision via the existing sole reserve/publish/fail DB contract. An actual
post-commit resource-release error remains cleanup debt and propagates without falsely
marking an already committed publication as a failed Job.

Parent must adapt affected test conformers/callers and Package/project membership, bind
actual Main read-pin/resource acquisition and original-config checks, and supply actual
1.19 precision/page mapping/paired encoding. These are required bindings, not successful
defaults. Missing producer/geometry binding is rejected before DB reservation. No DB,
Domain, cache, FTS, Provider or other SDK owner was changed in this producer lane.

Resource/proof limitations remain explicit. Helper RSS is measured with successful actual
MACH_TASK_BASIC_INFO observations, not inferred from a quota. Batch byte checks count the
typed field payload from actual UTF8 text and primitive field widths; they do not certify
Foundation/XPC serialization overhead or allocator peaks. Native calls and allocator
transients remain uninterruptible/hard-bound-unproved until protected runtime evidence.
If admission fails before actual SHA/page-count observations exist, the required nonoptional
End fields cannot honestly be manufactured: no End is sent, and Main retains pin/resource
debt pending a valid same-operation End or the existing owner's independent process-exit
proof. Parent must exercise and integrate that failure-debt path; transport failure alone
does not authorize release.

No tests were authored in this exact-four-file lane. Tests, builds, gates, lint, formatting,
commits, remotes, helper/app execution, trials and workflows were explicitly forbidden and
were not run. Parent owns native compilation, focused DTO/malformed-protocol/FD/geometry/
boundary/cancellation/deletion/publication tests, independent HIGH integrity/lifetime review
and evidence commits. This receipt is source authorship only: StoryDone remains false and
no AD8/P1/P2/P3 or runtime resource certification is asserted.
