# Story 1.18 Build Spec — URL Import and shared Library entry

## Existing direct PDF-button focus wiring (baseline b8b3bd3)

The next paired Story1.17 phase uses the surviving PDF 선택 Button, not the closed
NSOpenPanel or a substitute toolbar. Required URLImportView inputs are the root's
FocusState<Bool>.Binding, a keyed Binding<UUID?> for local-intent invalidation and
chooseLocalPDF(UUID). Attach native focus to that existing button. Its accepted action
captures a fresh UI intent after the current-control guard/interruption, retains it
in existing drag state and calls the root with that UUID. Every later accepted child
interruption—including URL input, paste, destinations, service events, drag/drop and
disappearance—reports its own retained UUID before advancing the drag fence, then
clears it. Equality-only root invalidation cannot revive old or invalidate new intent.

The one production constructor in ProductWorkspaceView supplies real bindings; no
no-op default or synthetic dismissal/completion. The existing root joins actual
prepared confirmation UUID, immutable native-slot appearance/dismissal identity and
awaited existing-owner cancellation task before one-shot Cancel-only focus return.
Native events may precede the picker task result. Continue permanently disqualifies
restoration. Detailed shared model/presenter contract is in the paired Spec1.17 phase,
committed before source. Existing URL Add/Paste focus, service owner, Retry, destination,
network and physical obligations stay unchanged. No local-opener intent for drop or
LibraryBrowser/Retry; no tests/native keyboard/VoiceOver or physical-ACK claim.

## Native opener-focus source continuation (baseline a22d139)

URLImportView uses native FocusState on its existing URL 추가/URL 붙여넣기
buttons. Opening URL entry captures a fresh UI presentation identity, original
mount and existing interaction fence. The matching content onAppear records actual
presentation; native onDismiss, never binding false alone, consumes the receipt.
Cancel restores URL 추가 only with matching mount/interaction and no new input,
confirmation or invalid-input alert. Submit captures the entered text and invokes
the unchanged recognition path only after entry actually dismisses. If recognition
presents confirmation/alert, entry dismissal does not restore focus through it.

Recognized URL confirmation captures that original add/paste opener and its actual
confirmation UUID. Matching onAppear plus explicit/interactive pre-admission
Cancel and actual native onDismiss are required for restoration. Cancel's existing
owner synchronously cancels recognition admission and returns to idle without any
grant, writer, stage, network or durable import effect. UUID replacement, unmount,
unrelated interaction, non-idle state, another dialog or alert deny restoration.
Existing service-publication interruptions advance the receipt's interaction only
when it was current and still belongs to the same confirmation or its cancelled
idle transition; they cannot revive an invalidated receipt. Continue has no focus
return: download/service state is not physical cleanup/closure proof. Drop has no
button opener; Retry's original failed-state control disappears on confirmation
and is not replaced by a newer control. Invalid-input alerts and external PDF
pickers lack an admitted dismissal callback in this scope and are unchanged.

This is UI identity bookkeeping, not new admission/cleanup/resource authority.
Destination, Retry, reservations, writer, network/durable schemas and Workspace
published fences are unchanged. Initial input focus remains native. No tests/test
authoring/builds/gates/formatters/runtime/network were run; parent owns source
checks/review. Actual native focus timing, keyboard/VoiceOver and Story/Epic
acceptance remain unproved.

## Current URL presentation continuation (baseline 2c855ee)

Story1.18/Issue20 reuses `issue/epic-1-product-vertical-integration-20261010` and the
existing HTTPS/service ownership contracts. The explicit implementation-first assignment
limits changes to this Spec, Story1.17 Spec and the three existing Library presentation
files. URLImportView currently supplies entry, paste, native PDF selection and supported
URL/PDF drop over Library. HTTPS/arXiv admission remains service-owned; invalid input
shows a safe alert without exposing the raw URL. The UUID-backed destination picker
captures its current folder into confirmation; labels are not admission identities.
Cancel/Continue retain current confirmation/mount/interaction gates and native shortcuts.
Downloading is labelled and cancellable; ready offers explicit Reader opening while
Library stays mounted. Failure supplies a reason and explicit Retry, which reopens a
fresh confirmation through the existing genuine same-Job or pre-admission path.

Concrete presentation defect: the confirmation formerly promised a new independent
copy even when its existing purpose was genuine same-Job Retry. This continuation reads
that already-captured purpose only for presentation: Retry now states that it retries
the selected Paper's failed work without adding another Paper or replacing a duplicate.
Ordinary new-import independent-copy disclosure remains intact. No Retry ownership,
record query, reservation, destination or lifecycle contract changes. The URL entry
field gains initial native focus; the picker uses Korean 미분류 default wording, and
folder-load failure gains an icon alongside its text. All existing drag/input fences
and service effect paths are unchanged.

Remaining product/runtime prerequisites: actual focus return to each opener (the
historical continuation below did not implement it; source extension above is not
runtime proof), keyboard and VoiceOver interaction across entry/confirm/
Retry/Cancel, resize/contrast/scaling and drop feedback; current actual HTTPS download,
independent-copy publication, same-Job retry/republication, cancellation/drain/debt,
delete/restart/crash barriers; admitted P6 measurement/profile evidence separately.
Parent owns permitted source review/compiler checks. Worker skips all tests/test
authoring/builds/gates/formatters/runtime/network/protected trials, commits and remote
actions. No current-source runtime PASS or full Story/Epic acceptance is asserted.

## URL start-publication cancellation fence

Baseline d82abc85135af4b7860b5a46284990a65bcec64b: continueImport consumes
the confirmation then publishes confirmation=nil/downloading before installing its
Task. A synchronous Combine callback can call cancelDownload while both writer and
operation are nil: the cancellation disappears, allowing the later grant/download.
The same callback can prepare another intent because operation is still nil. This is
a concrete source ordering gap, separate from actual producer closure/Retry authority.
Exact source scope: Application/URLImportService.swift. Fence the synchronous start
interval before any publication. Deny prepare/recursive Continue and stale confirmation
Cancel during this consumed-start interval; actual download Cancel instead records a
pending cancellation and still immediately revokes/cancels any existing owner/task.
Transfer that cancellation into the just-installed exact Task before Main returns;
existing Task.checkCancellation before grant remains the no-effect admission barrier.
Do not infer physical closure from the flag; unchanged real capability handles grant,
postgrant revocation, download registration/drain, publication and abort/cleanup debt.
No grant API, admission phase, DB/history/SameJobRetry/resource/producer/UI change or
new capability. Missing writer still fails synchronously with zero grant effects.
Parent minimum existing Cancel/once-Continue/fresh-confirmation and lifecycle no-effect
admission cases/source compilation only. New publisher-callback regressions, independent
review/full/native/visible/protected trials remain deferred, not waived or accepted.

### Parent URL start-publication source receipt

Spec8bdefd08e31fbf6819faec781ab320aa4bbc506e preceded URLImportService-only
implementation. starting is set before published confirmation/state setters; pending
download cancellation survives until the exact new Task is installed and cancelled.
Recursive prepare/Continue and obsolete confirmation Cancel deny in this interval.
No Task/grant/producer/physical closure authority comes from these ephemeral flags.
Existing before-grant Task cancellation check, actual postgrant capability cleanup and
download registration/drain/publication logic remain unchanged. Existing3 admission
scenarios pass exit0/build4.43s, artifact://1558: Cancel-before-Continue/missing writer
zero effects; once-Continue/fresh confirmation; actual lifecycle denies prepared and
cancelled grants without reserving any Paper. They do not exercise the new synchronous
subscriber-cancellation/recursive-start branch or actual download/closure runtime.
Source delta SHA256 against Spec:
`3cdbbeeae66d8a8b537fb336d5e9509003434631ccf2be02ab461d094773ea7f`.
Existing deprecated onChange and unused validation-result warnings remain unsuppressed.
New regressions/independent review/full/native/formatter/visible/protected trials stay
deferred. Canonical Story/Epic unaccepted; no remote action.

## Current source phase — actual HTTPS physical ownership repair

Explicit assigned source-only order reuses Spec 46711a8 and baseline 28a43e1
(parent-reported Product 1185/native-ai 1182/review 96 clear); those are baseline
evidence, not verification of this change. Exactly four writable integration paths:
`PaperLensApp/Adapters/HTTPSPDFImportAdapter.swift`, `Tests/Product/URLImportTests.swift`,
`Tests/Product/LibraryURLImportWriterTests.swift`, and this Spec. No root docs changed.
Parent owns verification, review, evidence and commit. No worker test/build/gate/lint/
formatter/commit/network/SDK/helper/renderer/paid/remote/trial execution is performed.

HTTPSPDFProducer now receives the original admitted import lease, and a process root
registry retains the actual producer before any file/session effect. Registry locks
only retain/release references and expose read-only IDs; destruction, callbacks, file
IO, cleanup and lease release occur outside those locks. The actual FileHandle disables
ARC closure. Exactly one checked-close attempt fences later callbacks; successful body
sync and descriptor fchmod(0400) precede that attempt. Final URLSession invalidation
alone supplies network drain, and only its conjunction with known file closure releases
quota. Before-FD setup failure explicitly releases the lease without removing a foreign
stage; unknown close keeps actual handle, producer, stage URL and original lease rooted
indefinitely, even after returning closureUnknown. No retry, FD probe, ARC destruction,
timer, cancellation or manually closed fixture FD becomes acknowledgment.

The public download API is unchanged. Internal configured downloads require explicit
HTTPSPDFFileEffects: actual-FD observation, checked FileHandle close, actual session
observation and final invalidation observation. Production binds real close; existing
configured callers in both assigned test files are updated without a compatibility
default. Non-file/decoded-NUL/invalid filesystem representation rejection precedes
resource admission and stage effects; existing owned-directory/symlink checks remain.

Authored source-only URLProtocol tests cover actual close-once success, descriptor mode,
lease held at final invalidation then released, body rejection, cancellation and early
actual session invalidation, invalid path rejection before effects, and close failure
before actual close. The unknown test captures its numeric FD while valid, verifies
fcntl-open/bytes/namespace/quota/root retention after dropping task and facade, and uses
the actual contract pool limit to fill only remaining capacity with distinct leases.
Manual OS teardown is not an owner ACK; the logical debt is intentionally permanent.
Run that irreversible debt case in an isolated test process when parallel fixtures
would contend for the process-global import pool. Existing writer publication/deletion
tests remain; conservative typed writer debt coverage is not claimed as FD fault proof.
No same-UID isolation or hard allocator/RSS bounds are asserted. Journals, SameJobRetry
and the full physical-receipt lifetime bridge remain unfinished.

### Parent physical ownership verification and independent review

Three-source binary diff against 46711a8 SHA256:
2c029d3c7045d6333e6f5e4a72dc31f78baca449d991826fdd0a977d0d2dceb0.
Initial focused21/1 artifact1192 and21/1 artifact1193, isolated1/1 artifact1194 retained.
Parent corrected decoded path/NUL/empty file URL validation before effects and mapped
directory-metadata rejection to writerUnavailable; added explicit NUL/missing-directory
cases rather than weakening assertions. Final focused21/0 artifact1195, Product373/0
artifact1206, fresh unsigned native Release arm64/macOS15 BUILD SUCCEEDED artifact1207,
namespace product-native-compile-20261010-aj. Review98 SOURCE-ONLY CLEAR / APPROVE,
no actionable finding. Actual descriptor/lease/delegate-drain fault proof uses owned
URLProtocol files, not external network/SDK/provider/helper execution. Unknown fixture
logical debt intentionally remains rooted after manual numeric FD cleanup, which is
not ACK. No same-UID isolation, hard-RSS/profile, physical UI or Story acceptance claim.
Package/project/policy/DB/lifecycle/journal sources unchanged. Warnings unsuppressed;
no formatter, remote/release/renderer/live/paid/protected trial execution. Actual durable
owner receipts, coordinated journaled lifecycle cutover and same-Job Retry still pending.

## Actual closed-stage validator read ownership prerequisite

Forward producer-receipt wiring inspected the actual separate stage revalidation in
LibraryURLImportWriter.validate: its readonly FileHandle still uses ARC closure and has
no real import-pool lease. A throwing checked close returns closureUnknown but loses the
actual validation FD at stack exit. Repair this concrete dependency before owner cutover;
do not re-audit the already verified HTTP producer, selected input or local copier.

Reuse the existing import resource pool for this distinct actual read operation, admit
before opening, and transfer the lease into an independently rooted actual validation
owner. Retain its original readonly nofollow/nonblocking/CLOEXEC FD and FileHandle with
closeOnDealloc:false before read/fstat effects. Single checked close on every work result;
known closure releases exact lease outside registry locks, unknown retains FD/lease/stage
obligation indefinitely and outranks work failure. No ARC/probe/manual cleanup/retry ACK.
Failed pre-open admission performs no read; pre-open failure can release never-owned-FD
admission. All post-open errors route through the same checked close. No second pool or
guessed budget/profile; preserve current type/mode/link/size/magic/hash/cancel/elapsed/
read-buffer/body bounds and before/after descriptor/path identity checks. Reject decoded
NUL/invalid filesystem representation before lease/FD and remove forced C-pointer unwrap.
No same-UID isolation or hard-RSS guarantee.

Internal validation requires explicit ActualURLStageValidationEffects(acquired:checkedClose:)
or equivalently named immutable Sendable binding; production calls actual FileHandle.close.
Parent supplies this real binding at the single lifecycle caller. No compatibility overload
or inferred closed flag. Worker writes only LibraryURLImportWriter.swift,
LibraryURLImportWriterTests.swift and this integration Spec; parent owns lifecycle caller,
gates/review/evidence/commit. No schema/Package/HTTP producer/history changes.

Owned closed stages come from the actual URLProtocol downloader; fixture injection is
only at checked validation close. Prove once-close success/cancel/work failure, retained
actual validation FD/stage/capacity after throwing close and facade loss, and no namespace
removal/ready publication on uncertainty. The existing HTTP unknown test already permanently
holds one of two process-global admissions: run distinct unknown scenarios in separate
test processes when needed; never reset pools or manufacture ACK to make gates pass.
Manual OS fixture cleanup is not receipt. Worker skips tests/build/format/commit/live/SDK/
helper/renderer/paid/remote/trial actions. This is a physical prerequisite, not durable
actor/journal/Retry activation or Story certification.

## Previous source phase (2026-10-09 explicit human order)

The actual-owner binding phase mutates exactly this Spec,
`Application/LocalLibraryLifecycle.swift`, `Application/LibraryURLImportWriter.swift`,
`Application/URLImportService.swift`, and `Tests/Product/LibraryURLImportWriterTests.swift`.
The HTTPS adapter, database, Package/project and UI are read-only in this phase;
their wiring and union verification belong to the parent. Earlier planning-only
admission is superseded for these local sources, not runtime proof or timing. No tests/builds/gates,
formatters, commits, network requests, credentials, or existing document reads run.

`LocalLibraryLifecycle.grantURLImportWriter(for:) async throws -> any URLImportWriter`
requires a confirmation whose Continue was consumed exactly once by URLImportService.
Prepared or cancelled confirmations cannot grant. The confirmation retains optional
`destinationFolderID: UUID`; `prepare(_:destination:possibleDuplicate:destinationFolderID:)`
defaults that identity to nil and never derives it from the display label. Retry retains
the confirmed UUID and requires a new consumed confirmation. Reservation creates one
actual Paper and ImportJob, with source input/current epoch and the existing recovery
lineage, writer and publication permits; publication uses those same identities and the
sole database's reserveImport/publish folder arguments. No call to importPDF, second
Paper, second job, alternate store, AI prerequisites or raw URL metadata is involved.

The factory creates an exclusive private namespace using mkdir, and cleanup only
removes a namespace actually created by that capability. The real HTTPS adapter alone
constructs ClosedHTTPSPDFStage. Publication consumes once, checks same namespace,
non-symlink regular single-link immutable file, byte budget/count, magic and recomputed
SHA256 before existing guarded rename/database publication. Failed publication is
aborted under its existing permit. Short lock-protected capability state checks and
revoke do not perform file/database effects. The service registers the exact download
child task's cancellation before that main-actor child begins. Revocation before
registration immediately cancels it. The concrete capability retains that exact task;
abort waits for its result and preserves its closureUnknown report even when called
with another reason. Deletion cancels the same producer census and
waits until adapter file-close/session-invalidation drain and abort/publication finish,
not Task.cancel acceptance. Unknown file closure retains permit and cleanup debt,
blocking namespace purge on repeated same-saga deletion attempts. Missing Agent still
prevents deletion success. Existing local copied-hash checks and Reader lease barriers
are unchanged.

Authored tests use owned temporary databases/files and injected URLProtocol only:
unconsumed/cancelled denial, one Paper/job and unchanged lineage on publish, typed
folder destination/removal, changed bytes/hash, foreign closed-stage rejection,
repeated publish/abort fencing, prior revoke, real stalled transport cancellation/drain,
unknown-closure conservative debt and repeated same-saga deletion. No stage receipt is
fabricated. These tests are not run in this phase. Parent must include the new writer
and test files in Package/project, bind the actual lifecycle grant closure, pass the
selected folder UUID from Library UI, and verify the union. Physical UI/Reader, actual
file-close fault injection and P-6 runtime evidence remain unproved by this phase.

Transport uses the actual ProviderRequest route, response, resource and pool authority;
an ephemeral URLSession serial delegate streams directly to an exclusively created
caller-owned stage. Redirects are never automatically followed: each response is
admitted and its target revalidated before a new task. Producer closure includes file
close and session invalidation/drain; only then may a ClosedHTTPSPDFStage be returned.
URLImportWriter is a required caller capability: owned stagingDirectory,
assertCurrent, synchronous revoke, publish(closedStage), and abort(reason). The parent grants this from the sole
LocalLibraryLifecycle after current writer admission and connects publication through
its distinct publication permit/guarded rename/DB commit. abort must retain closure
debt (no namespace removal) for closureUnknown and cleanup debt on failure. No capability means no file,
request or Job effect. No alternate database or publication store is introduced.

The service consumes one confirmation before asking for the capability; cancellation
before Continue has no Job. The sheet keeps Library underneath, displays the actual
destination and possible-duplicate warning, and exposes only explicit Reader opening
after success and explicit fresh-confirmation Retry after failure. Physical UI,
delete/restart races and P-6 timing remain unproved until parent integration/runtime
evidence; authored deterministic URLProtocol and temporary-file tests are not run.

## Authority and admission

Issue#20 / issue/20-story-1-18; basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source; no repeated unchanged-scope SHA approval, no credential/live/paid/remote/distribution or gate permission inferred.

Architect50 read exactly ROOTepics885–920, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift; commonUI excerpt same canonical file supplied separately. Root-only not copied. Planning ONLY/not implementation-ready. Actual1.13/1.17/productImportP3 required; product BLOCKED/StoryDone=false. Real Library/Reader/persistence/connections absent; at planning1.13initial20PASS/review48BLOCK/repair49unaccepted. Local14dd7b3/c93e873 nonproduct, actualP1/P2/P3/P6 unproved, blankCapture FAIL. P6 actual pass before timing branch.

## Mounted persisted destination binding — parent verified

The actual workspace URL surface queries the existing FolderImportService and displays stored folders plus explicit Unfiled. Preparing a URL captures that selected UUID and actual label in the immutable confirmation; labels are never parsed into identities. Changing or reloading the picker does not rewrite an already prepared intent. Grant and publication still validate the same confirmed destination transactionally; removed folders reject without a second Paper/Job. Predownload duplicate status remains unknown and the UI conservatively warns of possible duplication, never inventing a hash/uniqueness result.

Parent verified the 129-test union with zero failures and unsigned arm64 native compilation including these controls. Existing actual writer tests cover confirmed folder publication and removed-destination rejection. Picker/drag/paste/confirmation physical UI and timing are not thereby verified; StoryDone=false and protected gates remain unchanged.

## Routes and confirmed import

Use shared sourceKinds localPDF/arxivAbstract/arxivPDF/httpsPDF and actual arXiv host/identifier/prefix/canonicalBase, preserve version; abstract resolves PDF, no webpage fallback. Drag/paste/local-file entry shares confirmation. Supported drag retains Library beneath whole-surface tint+label; unsupported zero import.

Actual destination/default/possibleduplicate warning; no invented predownload content hash/metadata. No Paper Job before explicit Continue; Cancel no add, one consumed intent on Continue and STAY Library. Success explicit Open Reader, failure safe reason/explicitRetry, never automatic navigation. Continuedduplicates freshPaperUUID/independentimmutablecopy, no blob/refcount/link; no source bookmark.

## Transport and ownership

HTTPS input/every resolved redirect/embedded credentials revalidated. Shared status/MIME/identity-encoding/%PDF- policy and real closedstaging/type+magic before durablepublish/parserdispatch. Reject invalidroute/redirect/nonPDF/exceededresources, noHTTP/ATS exception/truncate/best-effort.

One ProviderRequest numeric authority: urlBytes/resources.import/pools.import; bodyBytes uses pdfBytes NOT RPC bodyBytes. Cumulative redirect/headerBytes/headerCount/bodyBytes, gauged readbuffer/idle and monotonicelapsed; parser/RPC/process pools remain separate. Bound actual reads/aggregate redirectresponses, not advertisedlength. Exact actual transport/storage/UI APIs/unknownlimits/input versions UNKNOWN, no copiedconstant/newbudget. RawURL excluded fromdiagnostics/exceptions/crashprojection.

Reuse accepted1.13 state/immutablefreshlineage. Writer before Paperaccess through finalclose/cancelcleanup; closedvalidatedstage→distinctpublicationpermit throughrename/guardedDB/resultcommit or synchronousfailed-guardremoval. CurrentJob/attempt/fence/input/Paper/config-applicability/epoch/permitguard. Effects/FS/DB/callback/drain outside shortarbitration. Retry currentprereq/freshidentities/oldusablepreserved/noambiguousautoreplay; startup running→failed/interrupted/no fence renewal. Per-cleanup/removal freshop+immutabletarget, unknownclosure/failure retainsdebt. Deletion revokes/drains/removes scopeddata, ordinaryRetrycannotreactivate.

## Separate timing and common UI

ActualP6 before timing amendment. Approved ImportAcceptedAt→FirstInteractivePageAt, singleinstrumentation-started nav-or-zoom/main-threadexpectedvisibleupdate; fourinputs/twoCPUartifacts/fixedfixtureprofile. Manual/open/controlenabled/raster/thinktime notwitness; arXiv30s SOFT disposition, AI nevergatesPDF. RealReadermeasurement versus Library-stay mapping UNKNOWN, not automaticproductnavigation/new event/probe.

Native Canvas semantic/Koreanstate+action/noncolorcues; actualcontrast/textscaling/resize/keyboardVoiceOverlabel-role-state, dialog/draweropenerfocusreturn/accessibleRetryCancelDelete. CurrentallPaperdata failure/restart/delete races here, no finalpolish/futureAIstubs.

## Conditional proof and paths

After prerequisites map≤5exactsource+testpaths per same-Spec phase: Application+realtransport/storage+races; Libraryinput/confirmation/UItests; P6-only timing integration/tests. Owners UNKNOWN, no scaffold/helper/CI/schema split/fallback. Requiredwiring named beforeedits.

Actualroutes/foursurfaces/defaultduplicate/cancelzeroJob/singleconfirmation/stayLibrary/explicitReader+Retry; exact/oneover streaming+redirect budgets/redaction. Realindependentcopy/writerclose/failedcommitcleanup/delete/Retry/late/restart/crashbarriers, not mockedpermit/terminalACK. Then actualP6 events/profile/disposition separately.

Architect50 COMMENT/WATCH, five-source read-only only, no tests/gates/formatter/build/GUI/SDK/auth/network/commits. Done needs realowners/gates/physicalUIverification/independentreview; planning passes none.

## Actual HTTPS FD and quota closure prerequisite

Forward lifetime-bridge inspection found a concrete ownership defect in the current real
HTTPS adapter: download unconditionally defers lease.close(), producer uses an ARC-closing
FileHandle, and completion/invalidation nils output even after checked close throws.
closureUnknown therefore retains namespace metadata but loses actual FD/quota ownership;
invalidation can also retry close. Repair this actual production path, not an audit or new
SDK/renderer trial. Reuse the existing ProviderRequest import pool and true URLSession drain.

Transfer the acquired lease into an independently rooted actual producer owner before
effects; stage handle uses closeOnDealloc:false. Single checked close is attempted once
across completion/invalidation/cancel/setup-failure paths. Known closure plus final actual
session invalidation releases the original lease outside registry locks. Unknown close
retains the exact FileHandle/lease/producer beyond stack, task and façade loss; no nil,
ARC, numeric FD probe, retry, cancellation, timeout or manual fixture teardown is ACK.
Do not return a ClosedHTTPSPDFStage on uncertainty or remove its namespace/stage. All
callbacks after closure are fenced from writes/new success; actual network invalidation
does not certify file closure. Preserve fixed response/body/redirect/budget policies and
known-close failure cleanup. Seal successful output through its actual descriptor before
checked close; no same-UID isolation or hard-RSS/resource-profile claim.

Internal explicit fixture effects observe actual FD and inject checked-close failure;
production binding calls the real FileHandle.close(). Owned URLProtocol tests only, no
external requests: once-close, unknown retained FD/actual pool capacity/stage across final
drain/façade loss, known-success/failed-body/cancel cleanup/release, no synthetic closure.
Manual fixture FD cleanup is explicitly not acknowledgment. Reject decoded NUL/invalid
filesystem representations before stage/lease effects, remove force-unwrapped path access.

Exact writable scope: Adapters/HTTPSPDFImportAdapter.swift, Tests/Product/URLImportTests.swift,
Tests/Product/LibraryURLImportWriterTests.swift and this integration Spec. Parent owns gates,
review and commits; worker skips all tests/builds/format/commits/SDK/helper/renderer/live/
paid/remote/trial execution. No new Package/schema/selector/pool/gauge/history or actual
journal-owner cutover; this closes a physical ownership prerequisite without Story proof.

## Actual closed-stage validation FD/quota prerequisite

Forward dependency after committed Spec `ffedb34` and baseline `5436b8f378`:
the actual LibraryURLImportWriter validator used an ARC-closing read handle and no
import-pool admission. A throwing checked close lost the physical handle at stack
exit. This repair is separate from the completed HTTP producer ownership repair
(`90b7189`); it does not reopen that audit or complete the full journal cutover.

Required internal API (no default effects or compatibility overload):
`static func validate(_ stage: ClosedHTTPSPDFStage, directory: URL,
cancellation: ImportCancellation, effects: ActualURLStageValidationEffects) throws`.
Immutable Sendable effects expose `acquired: @Sendable (Int32) -> Void` and
`checkedClose: @Sendable (FileHandle) throws -> Void`; `.actual` observes nothing
on acquisition and calls the real `FileHandle.close()` on close. Parent binds the
single LocalLibraryLifecycle production caller with `effects: .actual`.

Before admission/open, reject non-file/foreign directory, decoded NUL, missing
filesystem representation, symlink path and cancelled input. Path rejection uses
the fixed safe URLImportError.rejected, never user-path error projection. Existing
ProviderRequest numeric authority and nonblocking import pool remain unchanged.
Admission precedes open. A private operation root owns immutable stage/id and the
original lease before effects. Open uses O_RDONLY/O_NOFOLLOW/O_NONBLOCK/O_CLOEXEC;
install a closeOnDealloc:false FileHandle in the root before observation/fstat/read.
No-FD failure explicitly releases the unused lease. Post-open validation rechecks
actual descriptor type/400 mode/current UID/single link/size, signature, digest,
budget, cancellation and after-read descriptor/path inode facts. Typed stage is
not current read authority.

Every post-open failure or success attempts checked close once. Unknown close
outranks work failure and retains the exact handle/stage/original lease beyond
stack/task/facade loss. No ARC close, retry, probe, manual ACK or namespace erase;
no ready success. Known close releases the original lease/root outside the short
reference-only registry lock, then returns/rethrows the original work outcome.
Only read-only rootedValidationIDs are exposed internally to fixtures.

Authored tests in LibraryURLImportWriterTests use the existing private
`stage(_:stall:)` URLProtocol download helper to obtain real sealed stages; no
synthetic/public stage initializer. `URLValidationObservation.effects(failClose:
cancelOnOpen:)` captures numeric FD/read flags/mode while valid and attempts a
real close unless injecting failure before close. Cases cover known-close success
and publication reopen, tampered digest/magic/mode/type/missing file, original
signature/cancellation errors, post-open cancellation, invalid directory/NUL/
foreign paths and effect-free exhausted actual capacity. Invalid stage metadata
cannot be manufactured through the private stage initializer; owned-stage
filesystem tampering supplies the negative content/type cases instead.

`testUnknownValidationCloseRetainsActualReadFDStageAndQuotaAfterFacadeLoss`
creates exactly one irreversible validator debt, verifies a still-open read FD
after validation frame/task/writer/lifecycle loss, actual declared global capacity,
stage retention and closureUnknown priority over cancellation. Manual OS fixture
FD cleanup is not logical acknowledgment; the root and lease remain. The fixture
does not remove its unknown owned namespace. It is direct validator evidence,
not injected actual lifecycle no-ready/debt integration proof by itself. Parent
added an explicit owned-validation fixture factory and a separate actual lifecycle
regression, as recorded below; the production factory still binds actual close.

Isolation requirement for parent gates: irreversible validator/HTTP unknown-close
cases execute in distinct fresh test processes. Parent used SwiftPM per-test
process mode `--parallel --num-workers 1`, including every selected test and all
three irreversible cases. No case was skipped, quota reset, fake ACK or relaxed
capacity introduced. Running these cases together in one process would retain
the declared cap-two pool before later ordinary imports.

Worker evidence: source inspection and authored changes only; all tests/builds/
gates/lint/format/commits skipped under the assignment. Parent owns production
binding, verification/review/commit. Exactly three worker-writable paths are this
Spec, Application/LibraryURLImportWriter.swift and its Product test file under the
integration worktree. HTTP/DB/journal/policy and root documents are unchanged.
False Story completion, P1/timing/profile/resource-isolation claims remain false;
full journal-owner cutover and physical UI/production evidence remain pending.

### Parent integration and verification — actual URL validation lifetime

Parent bound the sole lifecycle validation call through immutable required effects,
with `.actual` in production and existing copy fixtures. The explicit internal
owned-validation factory injects checked-close failure only for owned test inputs.
A sixth new test invokes actual writer publication, then aborts with `.cancelled`,
and verifies not-ready state, GRDB cleanup debt/reopen, unchanged stage bytes,
retained actual FD/lease/root after facade loss and denied namespace removal.
Deletion denial in this fixture is `agentPurgeUnavailable`, not successful purge
or proof of physical closure. Manual numeric-FD cleanup is never logical ACK.

Review102 initially found P1: a later abort reason could downgrade publication
closureUnknown. Parent made that uncertainty sticky under the existing writer
lock and changed the actual lifecycle regression to exercise cancellation abort.
Narrow rereview102 returned SOURCE-ONLY CLEAR / APPROVE, findings empty.
Earlier passing evidence remains recorded: focused26 artifact1228, focused27
artifact1230, Product384 artifact1237 and unsigned native-al artifact1239.
Final focused27 passed artifact1241; all384 Product tests passed artifact1244
with `--parallel --num-workers 1 --filter ProductTests`, no skipped tests.
Fresh unsigned Release arm64/macOS15 native-am BUILD SUCCEEDED artifact1245;
application/helper binaries were not executed and warnings were not suppressed.
Three-source binary diff against committed Specffedb34 has SHA256
`bca0a181783823cf044a014a4072dc61070cf90c4c5a66bb2fc71f49dea84887`.
Package/project, HTTP adapter, DB/journal/policy and paired resource contracts
remain unchanged. Full physical-receipt journal cutover, same-Job Retry, profile,
helper/runtime, physical UI and Story acceptance remain unproved.

## Library async input interruption — implementation-first delivery

At22bb9df, accepted NSItemProvider drop completion lacked mounted/current-interaction
checks even though hover observation had a UUID fence. URLImportService.prepare can
replace an existing confirmation while no operation runs; a delayed old drop could
therefore install after Library disappearance or a newer input/confirmation. Correct
the concrete UI path in existing Features/Library/URLImportView.swift only; backend,
HTTP, writer/resource ownership, journals and Reader remain unchanged.
Worker146 extends the existing drag observation with mount/interaction/pending-drop
fences. Actual provider/mount/interaction captured on drop, consumed before routing;
old callbacks cannot retint or accept after unmount/new hover/new direct input/folder
interaction/sheet cancellation/Continue/Retry/explicit Reader opening. Existing URL
confirmation identity is checked at dismissal; UI prepare refuses to replace it.
Folder reload also rejects interrupted observations. These UUIDs are display/action
interruption fences, not physical/input/writer/publication authority. Genuine current
PDF/HTTPS still routes to existing confirmation; disappearance does not cancel an
actually admitted download. Library content and pass-through tint remain in place.
Combined three-source digest and parent minimum cases are recorded in Spec1.16 and
artifact1535: two existing nominal cases passed, changed source/UI compiled. Neither
case exercises NSItemProvider callbacks, mount/newer-interaction/sheet cases or visible
tint/focus. User implementation-first defers new/correction tests, broad/native gate,
formatter and independent review. Current/stale drops and native sheet interactions
remain runtime-unverified. No network/provider/helper/renderer/clipboard/remote trial;
canonical completion0/26 and Epic acceptance remain false.

## Fresh-confirmed same-Job URL Retry — bounded implementation

Ordinary failed URL Retry requires a genuine current failed ImportRecoveryRecord
obtained by Main's sole database for the exact originally granted execution, after
actual abort/drain/cleanup. Bind an internal one-shot read-only failed-record query
to that original confirmation after durable reservation acknowledgment, before
writer-opening effects. Compare all ten actual execution identity fields when
capturing; a display UUID, service error, callback flag or confirmation cannot
manufacture failed history or physical closure authority.

Keep ordinary new-import intent separate from genuine captured same-Job Retry.
Retry creates a fresh validated HTTPS confirmation with current destination and
captured failed record; Cancel makes no reservation and Continue consumes it once.
Main retains the same Paper/generation/Job, generates six fresh execution IDs and
uses its current epoch. Share the existing defended reservation transaction through
a private helper, preserving exact bounded encoded-history CAS, current row/folder
checks, namespace absence, journal retry/claim/writer admission, terminal headroom,
write-scope/schema/counter/readback defenses and rollback. The existing per-Paper
FIFO spans reservation through acknowledged record/cancellation installation only.

Keep the existing local Retry entry's nonnil confirmed SHA requirement. Add a
narrow HTTPS-confirmation-only reservation entry: require genuine once-granted
validated HTTPS confirmation and its captured retry record, use its destination,
and supply nil predownload SHA as existing first URL import does. Do not remove the
local guard, invent a hash, change journal format or use missing hash as authority.
Reuse the actual existing URL writer, producer, validator owner, closed stage,
publication receipt, cancellation, abort and reconciliation paths unchanged.

Unknown closure, cleanup/removal debt, outstanding permits, ambiguous dispatch,
stale/replaced/succeeded/deleted/legacy/invalid history, removed destination and
residual namespace deny Retry. Retain original unknown FD/lease/stage/scope roots;
do not clean a namespace to make admission pass or infer closure from bookkeeping.
A bound same-Job denial never falls back to a new Paper/Job. Before actual grant
there is no same-Job authority to fabricate. Failed reservation leaves prior
history unchanged; failures after reservation use the actual same-Job abort path.

Implementation uses existing URLImportService.swift, LocalLibraryLifecycle.swift
and ProductDatabase+ImportRecovery.swift; ImportRecoveryJournal.swift already has
optional HTTPS SHA and its existing factory/codec must remain unchanged unless a
concrete in-contract integration need is found. The confirmation-bound query keeps
the existing grantWriter callback signature; confirm actual caller wiring before
claiming source integration. No new owners/pools/quotas/schema/SDK/provider trial,
privacy/permission/profile/architecture relaxation, remote or release action.
Tests/builds/independent review/formatters/runtime and acceptance remain deferred
under the implementation-first instruction. This amendment precedes source edits
and does not promote Story/Epic acceptance or certify physical runtime behavior.

### Focused owned regression after source commit99ca2f7

The two existing confirmation tests and the new
`testActualAbortedURLRetryRetainsJobAndRequiresFreshConfirmationWithoutNetwork`
passed with SwiftPM `--parallel --num-workers 1` (artifacts1608/1609).
The new case uses a temporary sole-GRDB database and actual Main URL writer
reservation/abort, then verifies fresh confirmation, rejection of old confirmation,
same Paper/generation/Job, six fresh execution IDs, one failed Library record and
Cancel preserving the exact failed journal. It throws before download; no live
network, provider, SDK, user PDF or closure-uncertainty trial is performed.
Compilation and these three cases do not prove HTTPS download/republication,
restart, denied-history branches, UI/accessibility, independent review or canonical
acceptance. Existing unused-result/weak-mutability warnings remain unsuppressed.

### Independent review163: pre-acknowledgment Retry retention correction

Source review requests changes: synchronous Continue then Cancel before the child
grants a writer clears the genuine retry record and strands another same-Job Retry,
although the original encoded history is unchanged. A refused reservation has the
same problem. Preserve the prior genuine expected record only while the original
confirmation's once-bound failed query has not been installed by Main after actual
replacement reservation acknowledgment. The query-bound flag is a callback fence,
not physical closure or persistence authority; fresh Continue still requires all
existing exact durable CAS, namespace and folder admission checks. After query
binding, failed capture must never restore prior history or create another Job.
Keep the original error and no automatic execution. This bounded correction edits
URLImportService only, with owned pre-grant cancellation/refusal regressions in
LibraryURLImportWriterTests. No new owner/schema/profile/permission/trial.

Correction verification: artifact1622 passed the actual Main/GRDB same-Job case
extended with synchronous pre-grant Cancel and an owned RAISE(IGNORE) reservation
refusal. Both preserve the original exact encoded failed history, allow another
fresh confirmation, and then complete a genuinely reserved same-Job abort. Review163
follow-up returned SOURCE-ONLY CLEAR and resolved P2; acknowledged query binding
remains sticky when capture is consumed, so post-ack failure cannot restore old
history. Post-ack capture-denial runtime and actual HTTPS publication remain unproved.
Artifact1625 passed20 current focused cases: complete ReaderMetadataBindingTests
(including three synchronous publication interruption cases) and three URL cases.
Metadata's first new-case build failed on a throwing Combine subscriber (artifact1619);
explicit do/catch fixed only test assertions; artifact1620 then passed all three.
No warning suppression, trial renewal or canonical acceptance promotion.
