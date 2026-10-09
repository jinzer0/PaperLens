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
validation. The existing sole-GRDB publication transaction checks it at transaction
entry, between inserts, before visibility and just before transaction return;
failures roll back all publication.
The parent owns the Infrastructure publication signature and affected caller adaptation.
No scope callback, provider configuration or ownership closure crosses XPC.
Rejected duplicate/identified begins retain a captured received-handle debt owner when
checked closure is uncertain. Preserve the accepted operation; never retry a potentially
reused descriptor or manufacture End. Acquired opaque PDF references must match original
request UTF-8 exactly, in addition to all other identity/configuration guards.
Parent-owned tests/build/review follow these source corrections. The initial four-file
delivery and Review53 BLOCK are preserved; no helper/runtime or Story promotion follows.

### Review53 owned source correction receipt (not integration evidence)

Against the pre-implementation correction commit `9948634`, the producer now closes
the sender after verified helper drain without releasing the child read pin. Consumer
return/unwind and raw-array disposal precede pin release; captured ownership refuses
pin release before recorded disposal, and accounting refuses completion before pin
release succeeds. Reentrant cancellation drains native/sender resources only while
the consumer remains active. Uncertain closure/release retains the session debt.

The immutable, Sendable, Main-only `ExtractionConsumptionScope` requires a throwing
guard. It retains the captured input's original deadline/allowance callback and a
locked cancellation flag, so a detached DB transaction observes cancellation without
depending on its own Task state. Validation checks before/after canonical units and
at entry/exit. `ExtractionRevisionService` passes the scope guard to the parent-owned
`publishExtraction(_:sentences:checkBudget:)` as a required `@Sendable () throws -> Void`.
The parent must check it inside the real GRDB transaction at entry, between inserts,
before visibility and just before transaction return, and adapt all callers/conformers.
The required callback has no default; thrown failures roll back all publication. That DB guard
is NOT closed by this source receipt; Infrastructure remains parent-owned and untouched.

Duplicate/identified begin rejection retains the actual received FileHandle and wire
key in serial native-owner debt on checked-close failure, without changing the accepted
operation, re-closing uncertain FDs, or constructing End. Acquisition adds original
request UTF-8 reference matching to the existing full identity/configuration guards.
Shared reply-shape validation is used by the actual producer and local unit tests.

`Tests/Product/PDFiumExtractionProducerTests.swift` contains bounded synthetic-only
regressions for sender/pin/disposal/accounting ordering, reentrant release, cancellation
and original deadline guards across detached consumption, guard failure after a
canonical unit, canonically equivalent acquisition reference rejection before helper
start, immutable secure request coding and invalid reply shapes. Genuine local fixture
FDs are used; no production binding, renderer, vendor or helper trial is introduced.
Tests/builds/gates/formatters/commits/runtime were explicitly not run in this delivery.
Parent owns Package/Xcode membership, existing signature adaptations, DB transaction
wiring, focused checks and final integration. Source corrections are not StoryDone.

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

### Parent integration verification — 2026-10-10

Committed parent Specs `497db66` and `fb3fa60` precede integration of authored `08dd3e6`.
The parent wired required captured-budget checks inside the sole GRDB publication
transaction at entry, each insert, visibility admission and immediately before return.
Budget failures roll back new revision/sentence/FTS/visible pointer/successful Job state;
the old usable extraction remains. Explicit Retry uses the same `consumeReserved`
consumer scope, including post-commit cleanup debt without rewriting committed success.
All old array-returning producer paths are removed; fixture callers use explicitly
synthetic bounded allowances, not production defaults. Missing producer rejects before
reservation. Secure coder delegation uses explicit throwing init/catch-return-nil.

`swift test --filter ProductTests`: 220 tests, zero failures (`artifact://894`), including
eight bounded producer fixtures, nested secure batch/terminal round trips and actual
GRDB rollback at all four one-row budget checkpoints. Original compiler failure
`artifact://883` and intermediate 219-pass `artifact://885` are retained. Complete unsigned
Release arm64/macOS15 scheme compilation with the actual helper source succeeded in
fresh `.build/product-native-compile-20261010-g` (`artifact://891`). AppIntents/debug-map
and unnecessary-await warnings remain. No app/helper binary was executed or signed.
Review56 is CLEAR / APPROVE: the original three HIGH and one MEDIUM are RESOLVED,
with no new concrete HIGH in its changed five-file source scope. Source/test/compilation is not runtime admission,
calibration, visible UI/AD8/P1/P2/P3 or canonical Story acceptance. Production supplied
read-pin/resource/geometry composition still requires actual owners, never fake callbacks.

### Actual Library child-pin owner slice before implementation

The next bounded local source slice implements the missing physical Library input pin,
not parser activation or a resource/calibration substitute. Exact worker ownership:
`Application/LibraryReadLeaseProvider.swift`, new
`Application/LibraryExtractionReadPin.swift`, new
`Tests/Product/LibraryExtractionReadPinTests.swift`, and this Spec. Parent owns Package/
native source membership, actual verification, narrow integrity review and local commits.

The provider constructed from the existing LocalLibraryLifecycle acquires a fresh
registry token for the admitted ReaderPaperSnapshot before real readonly file opening,
with existing before/after durable validation and revoke semantics. The new captured
LibraryExtractionReadPin has a required original operation UUID, the actual registry
token/physical handle and a per-token closure observation from that same registry.
No second registry, database, selector, guessed root or caller-declared closed flag.
It exposes validated one-time readonly sender-FD duplication outside state arbitration,
using an active read pin so actual original closure cannot race duplication; returned
handle ownership transfers to the existing PDFiumPinnedInput, never an openable path.
Revocation blocks new work/duplication but does not release this asynchronous consumer
pin: actual producer drain/disposal still precedes captured pin release.

The captured operation's async release requests closure once and awaits its own actual
registry-close outcome, not all Reader pins for the Paper. Verified physical close
records success only afterward; uncertain closure remains permanent debt, throws and
cannot be retried. A concurrent live Reader must neither be released nor prevent proof
of this child pin's actual closure. A wrong operation ID changes nothing. Constructor/
open/duplication/close failures preserve actual ownership or checked cleanup debt.
Readiness does not claim parser budgets: required actual resource accounting, original
deadline and supplied geometry/precision remain separate Main dependencies and must
deny producer admission when unavailable. No fake success callback or preset gauge.

Owned-file regressions cover readonly duplication/one-time transfer, deletion waiting
for actual child release, revocation/late duplication denial, wrong-operation no effect,
independent Reader lifetime, uncertain close retention/no retry and release reentrancy.
No helper/app/renderer/SDK execution, trial renewal, credentials, network or runtime
Story/P1/P2/P3/AD8 certification is admitted by this source slice.

### Actual Library child-pin source handoff

Source authored after committed Spec `0043513`, against the `a92b5ec` Reader
unknown-close baseline. Exact four-file lane only; no StoryDone or runtime admission.
`LibraryReadLeaseProvider` now shares one private acquisition routine between Reader
and extraction: reserve on the lifecycle registry, validate durable ready snapshot,
open actual readonly PDF, validate durable snapshot again, then install the owned FD.
No new database, root, registry, path-returning interface or ReaderSession API.
The shared open uses `O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, and the original handle
disables deallocation-close so registry destruction cannot blindly retry unknown closure.

Exact new public API:
```swift
@MainActor public func acquireExtractionReadPin(
  for snapshot: ReaderPaperSnapshot, operationID: UUID,
  onRevoked: @escaping @MainActor () -> Void
) throws -> LibraryExtractionReadPin

public final class LibraryExtractionReadPin: @unchecked Sendable {
  public let operationID: UUID
  public func validate() throws
  public func takeSenderPDF() throws -> FileHandle
  public func release(operationID: UUID) async throws
}
```
Typed errors are `LibraryExtractionPinError.wrongOperation`, `.senderAlreadyTaken`
and `.duplicateFailed(Int32)`; revocation uses existing ReaderError and uncertain
physical cleanup uses existing LocalLibraryError.producerClosureUnknown.

The registry creates each token's ephemeral closure observation; only checked physical
close completes it successfully. Reentrant/concurrent release joins this same outcome,
independently of ordinary Reader tokens. The existing `!entry.closureUnknown` physical
effect guard remains. Close failures permanently retain ownership/debt, never retry.
Duplication uses actual `F_DUPFD_CLOEXEC` outside arbitration with an active read counter;
release cannot close the original while duplication or rejected-sender cleanup runs.
One attempted duplication consumes sender admission, including syscall failure. Transfer
linearizes at the post-duplication locked admission check: release/revoke winning before
that check denies transfer and checks sender cleanup before retiring the active read.
A transfer winning that check is already admitted; producer disposal remains required
before releasing its child token. Rejected-sender unknown cleanup retains both handles
and fails the token observation, never declares the original closed. Sender handles have
no deallocation-close fallback; ownership must transfer directly to PDFiumPinnedInput.
Revocation alone does not close an installed asynchronous child.

Eight authored owned-file tests cover readonly/CLOEXEC and single transfer, wrong-operation
no effect, independent Reader lifetime, deletion callback/drain, bounded concurrent dup/
release barriers, uncertain original close/no retry, rejected sender cleanup debt/no retry,
duplication failure/reentrant close, and durable snapshot identity. Close fault injection
uses the registry-owned physical effect, not a FileHandle subclass. Fixtures are synthetic;
no user documents or helper calls are involved.

Parent must add `Application/LibraryExtractionReadPin.swift` to both Package.swift's
PaperLensProduct sources and native PaperLens source membership, and register
`Tests/Product/LibraryExtractionReadPinTests.swift` in ProductTests when explicitly listed.
Bind actual caller's captured operation/snapshot, transfer `takeSenderPDF()` directly to
PDFiumPinnedInput, and bind its release callback to `pin.release(operationID:)`; revoke
requests actual producer cancellation/drain, not immediate child release. Required actual
resource accounting, original deadline, and supplied geometry/precision remain separate
Main owners; absent owners must reject helper admission.

Only source inspection was performed. All tests/builds/gates/lint/formatters/commits,
remotes/workflows/SDK/helper/app/renderer/runtime/delegation were explicitly skipped.
Parent owns focused execution, fresh native compile-i, independent integrity review and
local evidence commit. No test PASS, resource calibration, P1/P2/P3 or StoryDone claimed.

#### Parent actual child-pin verification

Parent registered the new actual source in Package/native targets and the eight fixture
tests in ProductTests. Initial focused run `artifact://906` had one failure: the fixture
provided no Agent purge but expected deletion success. The repaired assertion requires
exact `agentPurgeUnavailable`, durable deletionFailed/debt and retained original; local
registry drain proves only child FD closure, never Agent purge. The original failure is
retained. Current union passes 229 tests/zero failures (`artifact://908`), including all
eight child-pin cases (lines 142–160). Fresh unsigned Release arm64/macOS15 native-i
compilation succeeds (`artifact://912`). Project plutil syntax also passes.
Review59 is CLEAR / APPROVE for this actual shared-registry lifetime/FD-owner slice.
Required resource/deadline/geometry acquisition composition is still separate; no app/
helper binary execution, trial renewal, calibration/P1/P2/P3/AD8 or Story promotion.

### Already-cancelled parser admission correction

Direct parse currently launches detached durable reservation even when its caller was
already cancelled. Check the original caller's cancellation before spawning reservation,
after existing required producer/geometry admission. An already-cancelled action creates
zero invocation/attempt/revision rows and dispatches no producer. This does not promise
atomic cancellation after admission or interrupt SQLite/native calls. Exact bounded
change: ExtractionRevisionService.swift and ExtractionRevisionTests.swift; parent
updates this existing Spec/evidence and runs the changed behavior/Product union.
No budget renewal, new owner, helper execution or Story/runtime certification.

Parent added the original-task cancellation guard and a cancelled-task/dispatch-census
regression. Product union passes 230 tests/zero failures (`artifact://913`); native-j
unsigned Release arm64/macOS15 compilation succeeds (`artifact://914`). No invocation,
attempt or revision row is created in the already-cancelled fixture. This proportional
behavioral check does not reopen unchanged HIGH lifecycle reviews or promote Story gates.

### Actual Main resource-accounting source slice before implementation

Implement Main's missing captured parser resource owner by reusing the existing
ProviderRequest, RequestResourcePool(kind: parser), RequestResourceLease and
RequestResourceBudget(kind: parser), never a parallel quota/selector/store. Exact worker
files: new Application/PDFiumExtractionResourceOwner.swift, new
Tests/Product/PDFiumExtractionResourceOwnerTests.swift and this Spec. Parent registers
Package/native source membership, verifies, reviews the actual lifetime and commits.

Capture the required original operation UUID and full ExtractionIdentity once. Limits
derive exclusively from the parsed existing policy; original monotonic start/deadline
must use checked arithmetic and cannot reset on retries/checks. Acquire the actual
process-scoped parser lease or deny admission. Main residency checks use successful
public MACH_TASK_BASIC_INFO observations of the actual Main process, not guessed RSS,
copied constants, record-size estimates or a zero fallback. Fail closed on observation
errors, expiry, cancellation, backwards clock, invalid limits or released ownership.
Check the same captured elapsed/residency authority during later consumer callbacks.
Only captured-operation finish releases its actual resource lease, idempotently after
the existing producer's disposal/pin-release milestone; wrong IDs change nothing.
Unknown cleanup retains the owner/lease; deallocation must not be used as closure proof.

This owner covers Main residency, original elapsed budget and actual process pool.
Native helper cumulative checks and canonical array checks remain with their existing
owners. No combined Main/helper RSS, hard allocator/uninterruptible-call bound,
watchdog coverage, calibrated geometry or runtime enforcement certification is inferred.
The actual input factory still requires all genuine dependencies before helper admission.
Internal explicit synthetic clock/residency injection is tests-only; production uses
real monotonic time/kernel observation. No production noop/default-success callback.
Owned-unit tests cover busy pool, original-deadline/monotonicity, actual positive kernel
observation, fail-closed observer/cancel/limit paths, wrong-operation/no renewal and
idempotent post-disposal finish. No app/helper/SDK/renderer trial or Story promotion.

Parent union919 exposed concurrent independent imports rejected as importCapacity.
The initially reviewed normal-lock candidate is withdrawn: existing committed Spec1.7
lines96–97 explicitly requires a nonblocking process pool, and paired Python acquire
also denies immediate lock contention. Preserve both source implementations unchanged.
The concurrency fixture must accept only this documented importCapacity admission
denial, join already admitted work, verify denied admission created no extra Paper/Job,
then explicitly prepare/confirm a fresh owned-fixture action. Never silently retry the
consumed confirmation in product code or raise quotas. Preserve original failure919,
candidate build/test924/925 and reviewed-but-withdrawn candidate provenance. Exact
additional test scope: Tests/Product/FolderImportTests.swift. No admission/architecture
contract change or new runtime permission is inferred.

Final Parent verification: compiler915/916 failures are retained; repaired throwing task
join and XCTest MainActor captures, without suppressing Swift concurrency checks.
Fourteen focused tests pass917. Review61 found an original HIGH: finish erased consumed
operation identity, permitting recaptured original deadlines. Persistent consumed UUIDs
now survive finish without retaining released owners/leases; successful/expired and
barrier-controlled replay regressions deny renewal. Final review61 CLEAR / APPROVE also
checks the explicit fresh-confirmation fixture and withdrawn normal-lock candidate.
Final Product union passes246/zero failures928 (sixteen Main resource cases), existing
wire contract passes32/zero930, and fresh unsigned Release arm64/macOS15 native-m
compilation succeeds929. Actual source preserves both original Swift/Python nonblocking
pool implementations. Earlier244/one failure919 and candidate924/925 remain historical.
These are real Main accounting/source/owned-unit proofs, not combined RSS/watchdog,
input-factory/geometry activation, helper execution, calibration or Story acceptance.

### Actual input acquisition composition before implementation

Compose the now-real Main resource owner and Library child pin into PDFiumPinnedInput.
Required API: LibraryPDFiumInputAcquirer(lifecycle:) and async acquireInput(resources:
PDFiumExtractionResourceOwner, onRevoked: required MainActor callback). No resource
closure substitute/default gauge, separate database/registry/root or credential access.
The resource owner supplies original identity/operation/limits/deadline, cannot renew.
Require its original epoch to match the retained lifecycle and a sole-GRDB snapshot
which proves exact running extraction lineage, ready Paper/generation/SHA/reference,
current durable slot/generation/model. Validate again around actual Library pin opening;
opaque references compare original UTF8 bytes, never canonically normalized strings.
Do not nested-read GRDB from budget callbacks inside publication: those callbacks use
actual registry validation and real resource observation; publication repeats DB guards.

Actual readonly sender ownership transfers once into existing PDFiumPinnedInput. Bind
captured release to pin.release(operationID:) and finish to the real resource owner.
Before return, failure disposes a created sender by checked close, then only after known
sender/original-pin closure releases its actual resource lease. Any uncertain sender
close retains actual handle/key in the same Library registry, fails the token observation
and retains the resource owner/lease; no blind retry, ARC closure or fake End. Failures
before acquisition may release only that unused resource capture. Revocation callback
is required and does not itself release the asynchronous child; no helper is started here.

Parent owns tiny same-registry uncertain-sender-retention adapters in LibraryReadLeaseProvider
and LibraryExtractionReadPin. Worker exact four files: new LibraryPDFiumInputAcquirer.swift,
ProductDatabase+Extraction.swift, new LibraryPDFiumInputAcquirerTests.swift and this Spec.
Parent registers Package/native/tests, runs real owned-file+GRDB+resource regressions,
fresh unsigned native compile and independent lifetime review before local commit.
Tests cover exact current identity/epoch/model, missing reservation rejection before FD
effects, original-budget expiry, readonly actual transfer, real pin/accounting drain and
unknown constructor cleanup ownership. No app/helper/SDK/renderer execution or calibration.
Geometry/precision/canonical-codec composition remains separately required; no product
activation, hard combined-RSS/watchdog proof, renewed protected trial or Story acceptance.

### Actual Main resource-owner implementation handoff (unverified source)

Added `PDFiumExtractionResourceOwner` with public readonly `identity`, `operationID`,
`limits`, and `deadlineUptimeNanoseconds`; required production initializer
`init(identity:operationID:authority:)`, throwing `checkBudget()`, and throwing
`finishOperation(_:)`. Production uses DispatchTime uptime and successful positive
public `task_info(MACH_TASK_BASIC_INFO)` residency of `mach_task_self_`. Tests alone
can explicitly inject `testingClock` and `testingResidentBytes` through the internal
initializer. All caps come from the supplied existing ProviderRequest; admission and
metric observations reuse its actual parser pool, lease and resource budget.

Successful allocations retain the owner and therefore its actual lease in private
operation-indexed lifetime storage. This is not another quota: counts/admission remain
exclusively in RequestResourcePool. The storage's short lock only inserts/removes
references; a separate per-operation effect lock serializes complete before/after
clock, cancellation and kernel observations with finish. Constructor failure, before
any input handoff, closes only its newly acquired lease. Successful capture never uses
ARC as closure evidence. Cancellation, observer/budget failure and backwards time are
sticky and do not release the lease; only correct-ID explicit finish closes it once.
Later correct-ID finish is idempotent; wrong IDs cannot change ownership or budget.

Authored owned-unit tests cover actual pool contention, every copied policy cap,
exact original deadline without renewal, sub-millisecond backwards time, checked
deadline overflow, zero/overflow/error residency, positive real Main kernel observation,
constructor cleanup, sticky observation and cancellation failures, cancellation during
observation, wrong-ID finish, idempotent finish without releasing a subsequent owner,
released checks, and uncertain cleanup retaining the actual lease after facade drop.
The observation/finish race uses explicit semaphore barriers with bounded waits, no
sleeps; expiry during the blocked observation must fail before finish can close it.

No commands, compilation, tests, formatters, gates, commits or runtime trials were run
in this worker slice. Parent must register Package/native/test membership, run focused
PDFiumExtractionResourceOwnerTests plus the Product union/native compilation, and review
the actual retention/finish contract before committing evidence. No passing-test claim
is made here. The genuine input factory and geometry composition remain required and
unactivated: this source does not supply those dependencies or admit a helper. Finish
is a trusted post-disposal/pin-release callback, not independent detection of disposal.
Unknown cleanup intentionally can hold process admission indefinitely. Checks are
point-in-time Main residency/original elapsed observations, not combined Main/helper RSS,
watchdog coverage, an allocator limit, an uninterruptible-call bound, P1 or SDK/Story
certification; native helper cumulative accounting remains owned by the existing helper.

### Actual Library input-acquisition implementation handoff (unverified source)

The committed acquisition contract (baseline `5bda8dd`) is implemented by public actor
`LibraryPDFiumInputAcquirer.init(lifecycle:)` and
`acquireInput(resources:onRevoked:) async throws -> PDFiumPinnedInput`. The required
arguments are the actual `PDFiumExtractionResourceOwner` and an escaping MainActor
revocation callback. The retained lifecycle supplies its sole database, epoch and
actual Library provider/registry; no alternate root, database, selector, resource
callback owner, geometry capability or helper connection is introduced.

The new internal sole-adapter method `extractionReadSnapshot(_:)` runs existing
`guardExtractionAttempt`, including the full running lineage and ready Paper facts,
and an explicit current slot/generation/model check within one `adapterRead` snapshot.
It constructs actual ready Reader facts directly from that same transaction, without
nested reads, Reader claims or position changes. Reference checks use exact UTF8 bytes.
Admission requires the captured epoch to match the lifecycle before opening a pin.
The acquirer repeats snapshot/registry/budget validation around MainActor pin opening,
sender transfer and the real constructor, including a final snapshot before return.

One actual readonly sender transfers to the existing `PDFiumPinnedInput` with the
owner's unchanged operation, identity, limits and original deadline. Its budget
callback invokes only actual pin validation and resource observation, so publication
can call it inside its writer transaction without a nested GRDB read. Release captures
`pin.release(operationID:)`; finish captures `resources.finishOperation(_:)`. The
existing input disposal state machine orders sender/consumer disposal, own-pin closure
and resource finish. The required revocation callback is forwarded unchanged; it is
not treated as closure evidence. Repeated operation admission is fenced on the actual
resource owner under its effect lock, including across separate acquirers, and fails
busy without releasing an allowance already handed off.

Acquisition failure checked-closes any acquired sender before releasing its original
pin and only then finishes resources. A failed checked sender close atomically retains
the actual FileHandle in the same registry through the parent's internal
`pin.retainUncertainSender(_:)`, permanently fails the token's closure observation,
and returns `producerClosureUnknown` without releasing pin/resources or retrying.
Unknown transfer/provider cleanup and original-pin closure likewise retain resources;
only known unused pre-pin failures finish immediately. Otherwise the original error
is preserved. The parent's provider adapter must surface unknown failed-open cleanup
as `producerClosureUnknown`, not hide it behind its original acquisition error.

Authored tests use private synthetic imported files, actual GRDB and the actual parser
pool with explicit test-only time/residency observations. Cases cover all copied caps,
full original identity, readonly/CLOEXEC sender, full running lineage, missing reservation,
stale lifecycle epoch, model-only change, exact UTF8 reference rejection, original-budget
expiry, checked constructor failure, real constructor expiry/empty-file rejection,
final-snapshot races, callback execution inside a writer transaction, independent Reader
survival, revocation denial, no early finish/repeated capture, and actual disposal/drain.
Unknown cleanup tests check registry strong retention after dropping test sender holders,
live FD/token/pool debt and no physical blind retry. Explicit owned-fixture teardown is
not an acquirer retry or successful End receipt. Internal hooks inject failure around
the real constructor/checked sender close; production always uses the real constructor
and throwing FileHandle close, with no default-success resource/close replacement.

Exactly four worker files changed: the new acquirer and its tests, the extraction DB
adapter, and this existing Spec. No commands, tests, native compilation, gates, lint,
formatters, commits, remotes or runtime workflows were run. Parent owns Package/project
registration, current caller binding, focused new/actual-pin/resource-owner/Reader and
extraction regressions, Product union, fresh unsigned native compilation, independent
lifetime review and local commit. Source inspection is not passing-test evidence.
Parent must also verify failed-provider cleanup propagation and own-pin unknown-close
retention. Actual resource captures now enforce single-input transfer across separate
acquirer instances rather than relying on callers to preserve that restriction.

Product composition remains unactivated until genuine geometry/calibration dependencies
are available. No renderer/helper/app/SDK execution, privacy-boundary relaxation, renewed
protected trial, combined-RSS/watchdog proof, release authorization or Story acceptance
is claimed. Native compilation alone will not establish execution evidence.

### Parent integration verification — 2026-10-10

The common atomic paper guard now includes current durable model as well as slot and
generation; reservation, publication and input snapshot reuse it. The snapshot has no
parallel configuration query. Actual registry sender debt adapters and resource-owner
single-input fencing are integrated with Package/native membership. No new selector,
quota, database, successful fake cleanup or resource observation was introduced.

Review63's original HIGH identified a hidden original-FD acquisition cleanup outcome.
The provider now captures its actual closure observation before installation/removal,
handles post-open validation and revoked installation in one catch, derives opening
state from the registry, closes only once, and requires terminal receipt success before
preserving the original error. Pending/failed cleanup reports producerClosureUnknown,
so the factory retains the actual resource allowance. Known no-FD and physical-close
success remain releasable. Final review63 is SOURCE-ONLY CLEAR / APPROVE.

Eleven input cases, including cross-acquirer reuse and post-open/revoked-install uncertain
cleanup, passed within 257 Product tests (zero failures, artifact942). Intermediate255
passed (artifact936). Failed257/one (artifact940) is retained: macOS raises when querying
a disposed Foundation FileHandle; the test now checks the captured numeric FD with
fcntl/EBADF before suspension. This changes the observation, not closure behavior.
Fresh unsigned native arm64/macOS15 Release compiled successfully in native-o
(artifact941); earlier native-n (artifact937) is preserved. No application/helper binary
ran. Original Main source phase ordering is unchanged except the new factory member.
Eight-source-file binary delta against preimplementation5bda8dd is
45ed07535a2c8407735d0b46cd62f3d903387fb65604d45941d25c7257457511.

Genuine input acquisition is composed; required genuine geometry/calibration and product
activation remain incomplete. Main-only residency is not combined RSS or hard-bound
proof. Existing Story/Epic/protected acceptance stays false; no trial was renewed.

### Next local slice — sole canonical codec binding

The existing PDFium geometry validator currently accepts arbitrary caller encoding and
only checks nonempty bytes. This is not a composed canonical persistence codec, even
though production activation remains denied. Remove that callback from the required
geometry binding and use the existing CanonicalExtractionGeometry version1 sorted-key
encoder, shared with its ownership-aware validator/decoder. Do not create a second
format, published membership, precision default, page mapping, runtime calibration or
production activation. Native-delivered text/glyph/identity/matrix/page/roundtrip checks
remain mandatory before canonical encoding. Existing owning-anchor decode validation
must accept the actual output and reject wrong ownership/text/geometry.

Bounded source scope is CanonicalExtractionGeometry.swift, ExtractionRevisionService.swift,
CanonicalExtractionGeometryTests.swift and this Spec; parent owns aggregate verification
and existing evidence. Regression cases must use explicit owned fixture precision/mapping
and typed native glyph provenance, decode the output through the existing ownership
validator, and prove invalid text/provenance/identity/mapping fails rather than becoming
nonempty arbitrary bytes. No helper/SDK/app execution, external calibration claim,
protected-trial renewal, new database/authority or geometry fallback is admitted.

### Sole canonical codec binding — authored source handoff

Authored against preimplementation Spec commit2f20b6a after input-factory featurec98764f.
Exactly four files are changed in this slice:
- `PaperLensApp/Application/CanonicalExtractionGeometry.swift`: internal static
  `CanonicalExtractionGeometryValidator.encodeCanonicalAnchor(_:) throws -> Data`
  holds the existing version1 `EncodedAnchor` JSON encoder with sorted keys.
  Ownership-aware `validateAndEncode` calls it only after ownership and original
  UTF-8 quote validation; the existing ownership-aware decoder is unchanged.
- `PaperLensApp/Application/ExtractionRevisionService.swift`: public
  `PDFiumGeometryBinding.init(precision:mapPage:)` retains required explicit
  `PDFGeometryPrecision` and throwing Sendable `PDFiumRawPage` mapping. The arbitrary
  `encodeCanonicalAnchor` field/initializer argument and nonempty-byte acceptance
  are removed outright. `PDFiumGeometryValidator` invokes the shared internal codec
  only after its unchanged native identity/raw-page/rotation/text/native-character/
  UTF-16/matrix/quad/bounds/roundtrip checks and immutable Domain anchor construction.
- `Tests/Product/CanonicalExtractionGeometryTests.swift`: four focused tests authored
  using typed `PDFiumRawPage`, `PDFiumGlyph`, raw quads and actual
  `ExtractionSentenceIdentity`, explicit synthetic precision and coordinate mapping.
  Good encoding is decoded with an independently supplied actual owning fixture
  anchor, compares identity/original UTF-8 quote/page/ordered quads/version and exact
  canonical encoder bytes, and rejects empty owning membership. Negative cases cover
  every identity component, wrong raw page, mapping page/rotation and raw rotation,
  canonically equal but byte-different source text and reconstructed glyph text,
  native-character and UTF-16 gaps, unsupported glyph matrix, out-of-page mapping
  and reader roundtrip loss. Invalid surrogate length and missing nonwhitespace quad
  are rejected by the typed glyph initializer before validator/codec admission;
  whitespace without a quad is exercised by the valid fixture.
- This existing Spec records the authored handoff; no new document or membership,
  Package/native source registration, database, UI or geometry mapping implementation
  is added.

Source-only limitations: no tests, builds, gates, lint, formatter, SDK, helper/app
execution or external retrieval were run for this authored slice. Parent owns focused
CanonicalExtractionGeometryTests, aggregate Product/native compilation verification,
independent review, evidence and local commit. Tests are authored, not claimed passing.
Fixture mapping/precision is not calibrated native geometry, owning membership is not
fabricated by codec reuse, and production geometry/activation remains blocked. No
AD8/P1/P2/P3/StoryDone acceptance, runtime resource proof, privacy relaxation or renewed
trial follows from source, tests or compilation.

### Sole canonical codec — parent verification

Four new typed-native/canonical codec cases passed within 261 Product tests, zero
failures (artifact945). Fresh unsigned native arm64/macOS15 Release compilation
passed in native-p (artifact946); no application/helper binary ran. Independent
review65 returned SOURCE-ONLY CLEAR / APPROVE for the exact three-source-file delta:
5fb7d2a2bc62190d68d07a87a01382889ade348bf79fae08bf4584ce86c548e8
against preimplementation2f20b6a. Existing input/pin/resource reviews are reused.

Canonical serialization is now genuinely composed. Native mapping/calibration and
production activation remain incomplete; owning membership is not inferred from
encoded bytes, synthetic mappings or successful codec roundtrips. Story/Epic/protected
acceptance remains false. No protected trial, remote or release action occurred.

### Real Main parsing ownership graph — bounded next source slice

Compose the already verified genuine lifecycle/input acquirer, captured Main parser
resource owner, typed producer, sole geometry validator/codec and existing service/Retry
coordinator in one Main-owned factory. Require explicit geometry binding; missing binding
rejects construction before any resource lease, Job reservation or helper effect. Do not
create or certify mapping/precision/calibration. Production App activation remains denied
until its genuine calibrated dependencies and protected execution admission exist.

The graph reuses lifecycle.database and lifecycle.epoch and the caller's actual authority.
Each producer acquisition captures resources with its original identity/operation and
acquires the actual lifecycle pin. On physical Library revocation, synchronously poison
that original resource budget, then request cancellation of that exact producer operation.
No cancellation request is helper drain/FD closure/accounting finish or successful Job.
Preserve first sticky budget failure; wrong operation cannot mutate another allowance.

Producer cancellation admission must cover its awaited input-acquisition phase, not just
already-begun sessions. Record only the currently generated acquisition operation; stale
or foreign operations reject rather than create a cancellation cache. After successful
acquisition a pending cancellation poisons that returned input before any helper begin.
Already-started cancellation reuses existing same-operation native drain/failure/debt;
never drop uncertainty, renew deadlines, fabricate End or release the captured resources.
All existing scoped consume/publication/Retry contracts remain unchanged.

Exact worker scope: new Application/MainPDFiumParsingComposition.swift, existing
Application/PDFiumExtractionResourceOwner.swift and Application/ExtractionRevisionService.swift,
new Tests/Product/MainPDFiumParsingCompositionTests.swift, and this Spec. Parent owns
membership, verification, independent review and existing evidence/local commit. Tests
may invoke the graph's actual input-acquisition path with owned immutable GRDB fixtures,
real Main Mach observation and real FDs, and cancellation/request admission without
starting/resuming an XPC connection. No fake producer/counter/database/root/selector,
no default-success callback/gauge, and no app/helper/SDK/renderer or paid request runs.
Missing-binding zero-effect tests and wrong-operation/sticky cancellation, actual pin/
resource disposal/revocation, same epoch/config and source graph wiring are local proof
only; geometry calibration, native helper execution and Story acceptance remain false.

### Real Main graph — authored five-file handoff (parent verification NOT RUN)

Implementation follows the preceding committed Spec at df5426c. Exact authored files:

- `PaperLensApp/Application/MainPDFiumParsingComposition.swift` (new): MainActor graph
  requires the actual lifecycle, actual ProviderRequest authority and explicit optional
  `geometryBinding` argument, with no default. Nil throws geometryUnavailable before
  constructing the acquirer/producer or acquiring a lease/reserving a Job. Retains one
  actual LibraryPDFiumInputAcquirer, PDFiumExtractionProducer, PDFiumGeometryValidator,
  ExtractionRevisionService and ParsingRecoveryCoordinator. Uses lifecycle.readLeaseDatabase
  (the existing lifecycle.database) and lifecycle.epoch; no replacement database or epoch.
  Internal `acquireOwnedInput(identity:operationID:)` is exactly the path used by the real
  producer closure, capturing a real PDFiumExtractionResourceOwner with original identity,
  operation and authority. A MainActor weak-pointer relay is bound before graph exposure;
  it synchronously poisons resources on actual pin revocation and asynchronously requests
  that same producer operation. `cancellationRequestFailure` retains first request error;
  neither callback return nor request admission claims helper drain or resource closure.
- `PaperLensApp/Application/PDFiumExtractionResourceOwner.swift`: new public
  `requestCancellation(operationID:) throws` rejects wrong IDs before mutation and closed
  captures with cleanupIncomplete, and records sticky cancelled under the existing
  effectLock only if no earlier failure exists. Does not release/reset/renew any allowance,
  quota, deadline or consumed-operation identity. Existing explicit finish is unchanged.
- `PaperLensApp/Application/ExtractionRevisionService.swift`: producer public
  `requestCancellation(operationID:) throws` means request admitted, not drain acknowledged.
  Only current awaited acquisition operation and one pending flag are tracked, set before
  awaiting acquisition and cleared on success/failure. Foreign/stale IDs reject without
  caching. Pending successful return is input-cancelled before any run-budget/helper begin.
  Active session requests poison the actual input, set cancelRequested, and schedule the
  existing signalCancellation/cancelAndDrain path with original key/deadline and retained
  cancellationFailure. Existing running/sessions.isEmpty exclusion, task-cancellation
  handling, known-close disposal and uncertain-cleanup debt are preserved.
- `Tests/Product/MainPDFiumParsingCompositionTests.swift` (new): five authored owned
  GRDB/Library/imported immutable-PDF tests use actual Main Mach observation and monotonic
  resource construction, not synthetic/default-success gauges. Cases cover nil binding
  with unchanged parser pool and extractionInvocation count; full original identity,
  explicit current model and actual epoch, actual input byte count, premature finish
  denial, disposal and consumed-operation nonrenewal; physical registry revocation with
  retained pool/pin debt until real disposal; foreign resource operation rejection and
  sticky cancellation; pending producer request admission/rejection and stale rejection.
  The pending test's controlled factory acquires via graph.acquireOwnedInput, suspends
  with a real held input, then physically disposes it and unconditionally throws before
  returning an input. Every path either throws or stays suspended; it cannot reach
  NSXPCConnection.resume even if an assertion fails. No fake producer or replacement
  ownership/accounting is supplied. Explicit coordinate/precision fixture is not
  calibration. Read-only/regular FD checks are enforced by actual pinned-input construction;
  no new descriptor-exposure API is added for tests.
- This Spec records the authored handoff only, not passing-test or native evidence.

Worker performed source inspection only. No tests, builds, gates, lint, formatter, native
compile, helper/SDK/app/renderer invocation, runtime/network, delegation, workflow, commit
or remote action ran. Parent owns Package/native membership, permitted owned-FD focused
tests, Product union/native compilation, independent composition review, evidence and
local commit. Parent should run the five new cases and existing Library input/resource/
producer/publication/Retry cases after membership update. The successfully returned
pending-cancel input branch and active-session signal/drain branch remain source-only,
runtime unverified here; testing them must not accidentally resume XPC. Direct graph
acquisition has no producer session, so its asynchronous producer cancellation denial is
request-failure information, not closure evidence. Existing source63 physical sender/pin/
resource cleanup, source65 canonical codec and source61 consumed-ID protections remain
the underlying owners. No AppWorkspace, database schema/geometry implementation, authority,
calibration, product activation or nonblocking parser-pool change. All protected/live/
remote/privacy/P1/P2/P3/AD8/Story/Epic gates remain false.

### Real Main graph — parent verification

Five new graph cases passed (artifact968), including actual positive Main Mach residency,
real original resource constructor and owned GRDB/pin/FD acquisition/disposal. The guarded
pending factory unconditionally throws before input return; no helper connection resumes.
The combined Product union passed 276 tests, zero failures (artifact972). Fresh unsigned
native Release arm64/macOS15 compiled in native-s (artifact976). Main source phase order
is unchanged except the single new graph member56; plutil and parsed membership passed.
Six-source-file binary delta against preimplementationdf5426c:
db422fa510267c621c9fe12571cbd3993d4dee9a45d17e8b744df40143f1f311.

Independent review71 returned SOURCE-ONLY CLEAR / APPROVE, reusing unchanged61/63/65
ownership/codec findings. Successfully returned pending-cancel and active-helper request/
drain branches remain runtime-unverified, source-reviewed only. Required geometry is
explicit, not supplied or certified by this graph; production App parsing remains inactive.
No helper/app/SDK/renderer/paid/remote action ran. Positive Main-only residency and source
composition do not certify combined RSS, hard bounds, AD8/P1/P2/P3 or Story completion.
