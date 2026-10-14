# Story 1.14 Build Spec — Actual Library, local PDF import and deletion

## Safe Korean workspace failure presentation

Baseline33979f9f42085100a5387a03f53461de7a05ea42 uses arbitrary caught Error
descriptions in workspace UI for PDF preparation, fresh same-Job retry preparation,
Reader opening, published metadata observation and position saving. Replace only
these displayed String values with operation-specific Korean failure and next
action; do not expose raw file paths/SQL/provider/worker diagnostics or parse error
descriptions. No inferred cause, guaranteed successful Retry or rollback claim.
Preserve original thrown errors, read/session/identity checks, startup/admission,
source-scope cancellation, imported refresh, same-Job retry purpose, callback fences
and committed CAS truth. Exact source: Features/Library/ProductWorkspaceView.swift,
existing catch/report message assignments only; no new helper/store/queue/schema,
public API or side effect. Canonical Story1.14/1.15/1.17/1.22 common Korean recovery
presentation is traced without extending their authority or acceptance criteria.
Latest human instruction defers verification/new or correction tests for all parallel
lanes; parent/worker skip tests/builds/gates/formatters and independent review for this
presentation-only source slice. Existing tests stay unchanged pending that deferred
verification. Compilation/rendered error/keyboard/VoiceOver/restart proof is unrun;
all required acceptance/runtime/privacy gates stay open, Story/Epic false.

### Source-only parallel delivery

Executor150-WorkspaceKoreanFailurePresentation (agent://150-WorkspaceKoreanFailurePresentation)
authored only ProductWorkspaceView.swift under committed Spec5ac9505e02a1ec6f90900b4e63daea54909112ca.
Seven existing presentation assignments now use operation-specific Korean failure and
next-action literals: picker/drop preparation, same-Job Retry preparation, imported
Reader open, imported-state read, published metadata failure and position-save report.
No arbitrary caught Error text appears in those values; original throws/forwarding,
actual source-scope cancellation, admission/session/request fences and CAS/action
flow are unchanged. Source delta SHA256:
`a7c72ba47752327854f0205809e7967c6a13debb8bc10071ed7908789ec46b3e`.
Parent and both workers skipped tests/test changes/builds/gates/formatter/independent
review/visible runtime per explicit human implementation-first instruction. No new
closure/store/producer/privacy authority, credential/protected trial/remote action or
acceptance promotion. Source-only delivery does not prove privacy-safe rendering,
compilation, actual recovery actions or Story/Epic completion; required proof deferred.

## Authority and admission

Issue#16 / `issue/16-story-1-14`, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Reuse this Spec; routine deltas accompany implementation/Evidence without separate precursor commit or unchanged-scope SHA approval. Material scope changes still require governance. Authority does not pass gates or permit credentials/paid/live/remote/distribution.

Architect43 read exactly ROOT epics.md:750–782, own SOLUTION-DESIGN, Story1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift; root-only canonical source not copied. Parent reconciled proposal's per-SHA approval wording with Whole-Epic authority. Trace AD-1/5/6/7/10/11, FR-001–003/005/007/030–034, UX-DR1/4–8/26/35.

Newest explicit human directive authorizes actual source creation now: implementation owners are TO DEVELOP, not human prerequisites. Missing P1/P2/P3, credentials, hardware and real1.10–12 integration defer their corresponding runtime acceptance, not independent source creation. StoryDone=false; no gate pass is claimed. P6 remains unproved/blankCapture FAIL. Actual authenticated entry remains required; the parent owns Main/package/project/auth integration. This amendment precedes source edits; this worker is explicitly forbidden commits and verification runs, which are sequenced to the parent rather than fabricated.

Bound owners: Application/LocalLibraryLifecycle.swift owns actual local import/list/delete and short JobRecoveryPolicy arbitration. Infrastructure/ProductDatabase.swift is the sole pinned GRDB persistence/visibility owner (b83108d10f42680d78f23fe4d4d80fc88dab3212; prepared parent GRDB framework), with minimal Paper/importJob/deletion and providerConfig UUID slot/Int64 CAS metadata only, no secrets or second SQLite engine. Features/Library/LibraryView.swift consumes that lifecycle with native selection and explicit confirmation. Tests/Product/LocalLibraryLifecycleTests.swift uses private synthetic files and real databases only. These four source/test files plus this Spec are the exact five mutable files. Caller-owned private root contains library.sqlite and UUID-owned paper namespaces; attempt stages and immutable final PDFs are never inferred into records. Epoch/reservation/fence/input and permits guard publication. Restart interrupts unfinished work and retains deletion/cleanup debt without replay. Typed AgentLibraryPurging is an integration dependency; absent implementation blocks deletion, not successful no-op. Reader geometry/timing belongs to1.15/P6; no generic future schema/helper/CI split.

## Required end-to-end behavior

1. Fresh full-window onboarding offers native API-key and official Codex browser/device paths equally. Real authenticated current typed connectionTest plus selector promotion is prerequisite. Explicit Continue enters actual empty Library, never automatically. Failed/stale/synthetic/model/identity/import-only results cannot enable entry; no UI-selected second authority.
2. Selecting/cancelling a local input creates no Paper/Job. Explicit confirmation allocates fresh Paper UUID/generation and minimal Import Job; obtain writer permit BEFORE first access within valid security scope. Copy bounded source to attempt-owned stage; validate declared PDF type/magic, close handles and return typed outcome. Independent immutable Paper-owned physical copy, no source alias/link/bookmark/shared blob. SHA is content identity, not lifecycle identity.
3. Apply1.13 immutable input and fresh attempt/fence/correlation/epoch reservation before mutation. Closed validated stage alone acquires distinct publication permit; hold through rename/guarded durable PDF-reference+Job-success+usable-pointer commit or synchronous failed-guard removal. Guards include current running attempt/fence/input/Paper/epoch/permit and applicable config, never wildcard. Local import dispatches no AI request.
4. Writer spans access through close/cancellation cleanup. Revoked writer removes bytes before release. Close source handles/release scope on all paths, no retained bookmark; restart Retry may require source reselection. Library renders actual durable progress/success/failure, not optimistic filesystem presence.
5. Delete durably revokes Paper/current generation and new dispatch/writer/publication before cancellation effects. Pending/running fail paperDeleting, no ordinary Import Retry. Drain admitted writers/publishers; actual Agent-owned purge/closure/absence and owned stage/final/cache removal plus durable cascade/contentless tombstone BEFORE success. Main never scans Agent zone; terminal/cancel is not drain.
6. Any drain/purge/removal/absence/finalization failure remains unopenable `삭제 미완료`; only same idempotent saga `Retry Deletion`. Never reactivate tombstone, reconstruct from files/startup/late callbacks or share cleanup across Papers. A later import uses new UUID/copy.
7. Restart running→failed/interrupted without renewing fence/replaying ambiguous dispatch; preserve historical outcomes/usable result/cleanup debt. Restore truthful actions, missing referenced PDF becomes failure, orphan stage never becomes Paper. Deletion restores same saga, no Open/Import Retry.

Short state arbitration only reservation/decision/accounting. No FS/DB/transport/blocking callbacks/drain under state; execute effects outside and revalidate lineage. No raw keys/paths/documents/bodies in diagnostics or false erasure claims. No Open Reader until actual Reader exists. URL/folder/duplicate/Reader/parsing/Translation/Chat/Brief/summary are excluded, no stubs.

## Functional delivery and integration

The exact owners above implement the independent functional vertical now. Native API-key and Codex admission integration and actual Agent purge are sequenced by the parent after this DB contract is finalized. LibraryView cannot authenticate or bypass Main admission. No nonfunctional Open Reader action is presented. All canonical AC above remain unchanged; unavailable integration prevents acceptance/success only at its real boundary. Worker runs no tests/builds/gates/formatters/auth/network and opens no user documents; parent performs union verification with synthetic fixtures and the prepared pinned GRDB framework.

## Required proof, not observed here

## Shared Reader/folder source phase (parent verification pending)

The existing lifecycle now owns one synchronous read-lease registry, bound by
`LibraryReadLeaseProvider(lifecycle:)` to that lifecycle's sole ProductDatabase.
The provider implements the finalized MainActor ReaderLeaseProvider/ReaderReadLease
protocols; exact ready UUID/generation/pdfReference validation and an open physical
original handle precede usable admission. Reservation and deletion admission closure
are serialized under short accounting-only locking, with DB/filesystem work and
MainActor revocation callbacks outside it. Delete closes admission before durable
revocation, synchronously discards actual Reader content through its callback, and
awaits lease closure plus active synchronous read exit before namespace removal.
Reentrant close cannot release a read still executing. Unknown physical closure
retains debt; failed deletion never reopens admission and retry uses the same saga.
Missing actual Agent purge still fails rather than manufacturing successful deletion.

The same importer exposes `importPDF(from:expectedSHA256:destinationFolderID:)`,
with nil defaults for native picker use. Confirmation compares the expected digest
with the actual copied-byte digest after physical writer closure and before any
publication permit. Mismatch records import failure and publishes no ready Paper.
It explicitly passes destinationFolderID to the parent's existing
`reserveImport(_:title:destinationFolderID:)` and
`publish(_:stage:final:sha256:destinationFolderID:)`. The sole DB owner validates
destination in both transactions and assigns placement after ready update in the
publication transaction. No second importer, reader DB, auth authority, renderer,
or successful missing-binding fallback is added. Parent composes provider/session/UI.

Mutable additions are Application/LibraryReadLeaseProvider.swift and
Tests/Product/LibraryReadLeaseTests.swift; lifecycle and this existing Spec are the
only other worker edits. Synthetic GRDB/file regression sources are authored, not
executed. Parent runs union-ready verification; no worker tests/builds/gates,
formatters, commits/remotes/workflows or PDFView/app renderer execution are claimed.
Canonical AC, StoryDone=false and privacy/profile/paid/renderer limits remain intact.

Both genuine onboarding paths and explicit Continue; failed/stale probe and CAS races stay outside Library. Confirmation Cancel zero Paper/Job/files; source change/removal proves copy independence; type/magic/resource exact and one-over cases. Real scope/read/write/close/rename/DB failure cleans/releases in correct order, failure retains debt.

Deterministic barriers at permit/copy/close/rename/commit versus deletion in both orders: held producers block removal; state remains available during outside-lock waits. Actual Agent failure/unknown closure cannot yield success. Crash before/after acceptance, staging, rename, DB success, deletion revoke/purge/tombstone restores correct actions, not old lineage. Duplicate/late results/restart/Retry never resurrect; referenced-missing and unreferenced-present artifacts are not usable Papers.

Architect43 COMMENT/WATCH, read-only five-source proposal, no tests/build/formatter/GUI/SDK/auth/network/commits. Planning checks are not product evidence; Done needs actual dependencies/physical durable UI lifecycle, scoped parent gates and independent review.

## Actual source contract (unverified worker delivery)

- `ProductDatabase.open(at:)` opens the caller-owned private root; `libraryRecords()` reads actual records. `providerConfiguration()` returns `ProviderConfiguration(slotID: UUID?, generation: Int64)` (nil slot/0 initially). `compareAndSwapProviderConfiguration(expected:replacementSlotID:)` increments generation on both connect and disconnect and rejects stale/ABA or exhausted generation. Metadata contains no secrets. Main/connection owner performs actual probe and slot promotion before entering Library.
- `LocalLibraryLifecycle.open(database:agentPurge:)` restores interrupted work before exposure. `importPDF(from:)` is explicit confirmation admission and returns a durable UUID even for recorded import failure. `list()`, `delete(paperID:)`, `retryDeletion(paperID:)` are real use cases. An already finalized tombstone is idempotent; failed deletion preserves the same deletion UUID. The lifecycle uses the actual JobRecoveryPolicy claim, writer closure, publication transfer/rename/publish/release, revocation, cleanup and namespace-removal contracts, not a parallel public policy.
- Copy uses the bundled ProviderRequest local PDF signature and import resource budget/pool, declared native PDF type, bounded chunks and SHA256 of actual bytes; validated stage is closed and made read-only before immutable publication. A close failure retains unknown closure/debt and cannot authorize removal in the live process. Every blocking filesystem/database effect executes outside Application actor arbitration. DB guarded transaction binds all reserved lineage identities and permit IDs, then renames and publishes the durable PDF reference plus import success together; failed transaction/guard triggers synchronous owned-byte cleanup before permit release. Restart does not replay or derive records from files.
- `AgentLibraryPurging.purgeLibraryPaper(paperID:deletionID:)` must return a matching `AgentLibraryPurgeReceipt` only after actual Agent producer closure and namespace absence. Missing implementation throws and durably remains 삭제 미완료. No default successful adapter is supplied. Main must wire the real peer; synthetic actual separate-namespace purge exists only inside tests.
- `LibraryView(lifecycle:)` uses actual durable records, native PDF picker and confirmation/cancel, ongoing copy progress, persisted failures, Delete and Retry Deletion. It has no Open Reader or alternate connection authority. Parent owns package/Xcode/Main wiring and authenticated-entry integration.
- Parent verification input: module `ProductLibrary` compiles the Application policy/lifecycle and Infrastructure DB sources against pinned GRDB and ProviderRequest; tests `Tests/Product/LocalLibraryLifecycleTests.swift` use `@testable import ProductLibrary`. Run `swift test --filter LocalLibraryLifecycleTests` after parent target/link/runtime wiring, with prepared framework runtime path `.build/topology/grdb-xcode-unsigned-e53f5631-f280-4d80-9b66-78c81aaa1372/products`. Also compile LibraryView in the app and exercise native cancel/confirm behind actual authenticated entry. Tests cover actual private copy independence/restart, validation exact/one-over, purge absence/failure/mismatch/drain, same-saga restart retry, interrupted/orphan/missing files, guarded late/foreign publication and real rename failure, and provider CAS restart/ABA. They have not been executed; full crash/barrier/native UI/hardware and real Agent acceptance remain unobserved. StoryDone remains false.

## Actual copier physical-obligation correction — bounded prerequisite

At verified845fbb5 actual copyValidatedPDF438–502 still unconditionally releases its import
lease/security scope on producerClosureUnknown and does not retain input/output handles.
Foundation input open follows URL attributes without pinning the actual object, so a swap
to FIFO/symlink can precede a blocking/wrong open. Selected-recognition repairbdffce6 does
not repair this separate actual copier. Independent82 confirmed the concrete live obligation;
safe same-Job Retry cannot infer closure from cleanupDebt/restart or an empty restored map.
Its separate durable input/history/Retry proposal remains unwritten, NOT authorized by this
copier phase. Do not call fresh-Paper import Retry or change policy/epochs/shared contracts.

Correct actual input admission with Darwin lstat + nonblocking readonly/nofollow/cloexec open
and actual fstat regular/device/inode/positive bounded size checks before reads. Preserve
PDF MIME/signature/SHA/cumulative budget/cancellation and actual copied-byte count. Stage
creation/open must be exclusive/nofollow and actual owned regular output validated, not
Foundation overwrite/adoption. No arbitrary-source fallback or permission repair. Same-UID
hostile path stability is not proved merely by these checks; no such isolation claim.

Capture actual input/output handles with closeOnDealloc:false, existing import resource
lease, selected URL/security-scope acquisition and immutable copy operation before effects
that can throw. Root physical ownership beyond local stack and lifecycle facade loss.
One checked close per acquired endpoint; both known closed (or never acquired) before
release of the shared actual lease/scope/root. Attempt other acquired endpoint even when
one close fails. Unknown retains real handles/lease/scope indefinitely, returns the existing
producerClosureUnknown and leaves the existing writer/cleanupDebt/no namespace-removal
path intact. No ARC/fd-number probe/error swallowing/retry or synthesized closure ACK.
No I/O, scope/lease release, callbacks or DB under ownership arbitration locks.
Known-close failures preserve original cause and legitimately release resources.

EXACT worker3 files: Application/LocalLibraryLifecycle.swift, existing
Tests/Product/LocalLibraryLifecycleTests.swift and this Spec. Internal required effect seams
may inject close errors while retaining actual handles and source swap before actual open;
production still calls real FileHandle.close. Read-only debt inspection may support explicit
owned-fixture manual cleanup, never mutate runtime unknown state/ACK. No new testing writer
race/beforeRead API for unverified body/read faults. Parent verifies actual owned FD/GRDB
normal/partial-open/unknown input/output close/source swaps/no ready/cleanupDebt/pool cap
behavior and native compilation, then concrete independent review/evidence/local commit.
Workers skip every test/build/gate/lint/formatter/commit/remote/workflow/delegation/runtime.
No new Job/schema/root/profile/store/resource counter; untouched canonical retry/deletion/
SDK/paid/trial/calibration/remote/Story limits remain. Prior305/native-z are prior evidence.

### Worker83 source delivery against committed76aa97b (not verification)

The separate actual copier now lstat-checks the selected source, opens readonly with
O_NOFOLLOW/O_CLOEXEC/O_NONBLOCK, and fstat-checks regular type, device/inode and positive
bounded size before any read. Stage open uses O_CREAT/O_EXCL/O_NOFOLLOW; actual output
must be regular, current-UID, mode0600, single-link and empty. Descriptor fchmod0400
precedes checked closure and publication. Declared PDF type, actual signature/hash,
cumulative bytes, bounded chunks, elapsed budget, cancellation and actual GRDB progress
remain; final copied bytes must equal admitted actual input size. No same-UID path-stability
or in-place content-mutation isolation claim is added.

Process-rooted immutable copy identity/source/stage and the existing import lease own
closeOnDealloc:false real handles and acquired-scope flag beyond stack/facade loss.
Exactly one checked close is attempted per acquired endpoint, output then input, including
when the first fails. All endpoints closed/never acquired permits outside-lock scope/lease
release and root removal. Any unknown retains all actual owners indefinitely and returns
producerClosureUnknown into unchanged namespace-preserving cleanupDebt/not-ready handling.
There is no runtime FD probe, ARC closure proof, retry, acknowledgement or debt mutation.

Public open/import signatures are unchanged. Internal
openForOwnedCopyFixtures(database:effects:) requires ActualCopyEffects with beforeOpen,
checkedClose, startScope and stopScope; production open selects actual FileHandle.close
and actual URL scope effects. actualCopyDebts is a read-only terminal snapshot, including
identity, source/stage, lease, handles, scoped and per-endpoint known-close flags. Fixture
teardown closes only owned unknown real descriptors before releasing fixture scope/lease;
runtime unknown registry entries remain unchanged.

Seven new existing-file tests are authored: checked endpoint/scope/pool release; direct
FIFO/symlink rejection; full actual-contract pool denial before scope/FD acquisition;
before-open FIFO/symlink/different-inode swaps; throwing output-open/file/symlink collision;
input/output/both close failures across facade loss; and partial-open input-close unknown
with unchanged collision bytes. They use actual private files/FDs and the sole GRDB DB,
exact close-attempt census, durable cleanupDebt, absent final PDF and preserved stage,
plus capacity fill through actual denial. Scope counters model granted fixture scope,
not sandbox-extension evidence for ordinary temporary URLs.

No tests/builds/gates/lint/format/commit/runtime were run by this worker. Parent owns the
focused LocalLibraryLifecycleTests run, existing metadata/deletion/Reader regressions,
native compile, independent review, evidence and exact commit. Read/write/body-growth,
elapsed-budget, synchronize/fchmod failures, real sandbox grants and in-place mutation
remain unobserved branches; no beforeRead/fake writer was added. SelectedSource74/75,
FolderService, outer policy/deletion/publication and schema remain unchanged. Genuine
same-Job Import Retry still requires separate future HIGH durable history/input-ledger
scope; canonical0/26, StoryDone=false and EpicDone=false are unchanged.

### Parent actual copier verification and independent review

Parent added non-file/fully-decoded NUL source rejection BEFORE import lease/scope/FD
effects, plus typed nil-filesystem-representation handling rather than C-pointer unwrap.
One new actual-pipeline fixture joins the seven authored cases. Preserved focused1079:
23tests/two assertions showed legacy Foundation URL.path hides encoded NUL, so both source
and fixture were corrected to path(percentEncoded:false). The actual Foundation observation
was bounded and used a synthetic URL only, no file/request/runtime SDK. Final focused1083:
23/zero; complete Product1085:313/zero, eight new cases relative to prior305. Owned real
GRDB/FD/pool/namespace outcomes establish the tested copier obligations, not real sandbox
extension acquisition/release (fixture grant counters modeled). Fresh unsigned Release
arm64/macOS15 native .build/product-native-compile-20261010-aa BUILD SUCCEEDED1086;
no app/helper execution. Existing compiler/PDFium debug-map warnings not suppressed.
Independent84 SOURCE-ONLY CLEAR / APPROVE includes final decoded-NUL guard and fixture;
no concrete blocking delta defect. Two-source binary diff SHA against76aa97b:
8ff8e4a94101c7c22c6819a11820ad7f2e9b12e64458b7ea41645393384efcb9.
No Package/Xcode/ProviderRequest/Job-policy/schema/epoch/counter/selected-recognition/
FolderService/startup/publication/deletion contract changed. Read/write/body-growth,
synchronize/chmod/elapsed faults and hostile same-UID/in-place isolation remain unproved;
manual physical fixture teardown never acknowledges runtime unknown closure. No SDK,
auth/paid/renderer/helper/live/remote/protected retry ran. Same-Job Retry ledger remains
unwritten and unapproved by this receipt. Canonical0/26/Epicfalse/Storyfalse unchanged.

## Exact durable import mutation fencing prerequisite

Independent82 observed that current failImport guards only Job ID/state and Paper ID/status;
recordProgress additionally compares attempt but not the complete execution. Same-Job Retry
must not be wired until old failure/progress cannot mutate a newer execution. Repair this
existing AD1/CAS requirement now WITHOUT claiming Retry/history implementation or changing
policy/epochs/schema. Existing publication already checks complete lineage; factor one
private same-transaction guard shared by progress/failure/publication over exact Paper ID/
generation/importing/nondeleting and Job ID/owner Paper/attempt/fence/correlation/input/
epoch/writer/publication/running. Reject with staleImport before ANY mutation/effect. Failure
updates Paper and Job atomically and checks both affected rows; cleanupDebt never uses an
unguarded follow-up Paper update. Progress rejects negative/decreasing bytes without updates.
Publication remains distinct guarded rename/commit and confirmed destination validation.
Parent changes EXACT ProductDatabase.swift, LocalLibraryLifecycleTests.swift and this Spec;
no lifetime/copier/policy/history or public API changes. Own real GRDB table-driven tests
mutate each identity independently, verify no Paper/progress/failure/debt change, actual
current failure succeeds atomically, deletion/terminal/current-epoch/reopen fences remain.
Parent focused/union/native and independent changed-source review/evidence/local commit;
no SDK/helper/renderer/userdocs/paid/trial/remote actions or Story certification. Missing
durable input/history ledger is STILL separate development, not inferred from current rows.

### Actual deletion-abort caller reconciliation

Focused27/zero1089; initial union317/one1094 revealed the real affected URL abort caller:
beginDeletion has already recorded exact failed/paperDeleting, so ordinary strict failImport
correctly rejects its importing-state guard. Do NOT restore an unguarded/no-op failure path.
Add explicit recordImportAbort for completed producer abort, deciding inside the same queue
transaction: exact current running/importing uses strict failure recording; exact current
deleting/non-nil valid saga/failed-paperDeleting records ONLY monotonic cleanupDebt when
needed. Preserve deletion status/saga/failure/generation/reference and unrelated debt; clean
producer never clears existing Reader/Agent/deletion debt. Other terminal/rebound lineages
reject, including stale failures after newer execution. Both actual local-copy and URL abort
callers use this explicit semantic; ordinary failImport remains strict. No closure is inferred
from state or debt; caller supplies actual physical result under existing retained permits.
Correction extends EXACT source/test scope to ProductDatabase.swift, LocalLibraryLifecycle.swift,
LocalLibraryLifecycleTests.swift, LibraryURLImportWriterTests.swift and this Spec. Parent
retains failed1094, tests real deleting-phase receipt and malformed/stale/debt-preservation,
then reruns affected/full and fresh native. No false deletion/Agent-purge success or Retry
implementation; source85 review must include actual changed callers before final approval.

### Parent final exact-mutation proof

Final focused36/zero1098 (LocalLibraryLifecycle28 + actual URL writer8); five new methods
plus enhanced existing real transport/deletion test. All ten independently mismatched
identity fields reject progress/failure/abort/publication without byte/row/debt effects.
Owned adversarial SQL replacement/reopen rejects the old execution without claiming a
production Retry; real second-row RAISE(IGNORE) rolls back first-row Paper/debt update.
Negative/decreasing progress and late deletion mutation reject. Exact deleting abort
preserves saga/Job failure/status and existing debt; malformed/stale acknowledgement rejects.
Full Product318/zero1099; fresh unsigned Release arm64/macOS15 native-ac succeeded1100.
Initial317/one1094 and pre-correction native-ab1096 retained, not overwritten/promoted.
Independent85 final SOURCE-ONLY CLEAR / APPROVE covers all five exact source/test/Spec
owners including both actual callers; no blocking defect. Four-source binary diff SHA
against66d0ebe:9c6119eefba37ac52cff587f4ca18bd3ba864a03e70c3b771f5c4fc2c97f6772.
No schema/policy/epoch/root/selector/counter or actual-copy effects change. Ordinary same-Job
Retry/history ledger remains separate unfinished development. No SDK/paid/user-PDF/helper/
renderer/private API/remote/consumed trial execution; UI/Agent/P1/P2/P3/Story uncertified.

## Durable local-import recovery — ordered implementation layers

Independent82's existing-fields-only rejection remains valid. Copier279ab14 and exact
mutationb5779a9 fix two concrete prerequisites, not the missing history/input ledger.
Implement that existing canonical1.13/1.14 contract, preserving stable Paper/generation/Job,
historical captured input/lineage/outcomes/used permit and cleanup operation IDs, and fresh
confirmed Retry identities. Main/sole GRDB remains authority; no policy/shared-contract,
credential/profile/purge/epoch waiver or fresh-Paper-as-Retry substitution.

FIRST complete typed ImportRecoveryJournal in Application and existing-policy fixture tests.
It records an immutable initial ImportIdentity plus explicitly supplied confirmed input facts
(optional expected SHA and optional destination UUID, neither inferred), and an immutable
ordered log of fully typed import-policy events. Full identity also retains reserved writer/
publication IDs even if not yet consumed. Replay uses ONLY JobRecoveryPolicy.create/apply;
any event rejection/corrupt/rebound/applicability/version/UUID/expected-hash error rejects.
No second state machine or direct synthetic Snapshot initializer. Initial create is pending;
claim/writer acquisition/physical result/cleanup/startup/revoke/removal/publication remain
explicit recorded events. Decode/encode/replay are serialization, NEVER physical closure,
publication/input or fresh-action authority. Codec runs after owner's independent admission.
No paths/URLs/bookmarks/documents/credential/model payload. Import roles/source/inapplicable
configuration only; no generic provider recovery codec or ignored unsupported event.

Required API: ImportRecoveryJournal(identity:confirmedInput:) throws;
snapshot() throws -> JobRecoveryPolicy.Snapshot; recording(_ event: JobRecoveryPolicy.Event)
throws -> ImportRecoveryJournal; retrying(identity:confirmedInput:) throws -> journal;
encoded(maximumBytes:) throws -> Data; decode(_:maximumBytes:) throws -> journal.
ConfirmedInput is Sendable with explicit optional expectedSHA256/destinationFolderID fields.
Ordinary recording rejects policy.retry: retrying captures the FULL newly reserved identity
and input facts, retains prior captures, then applies the real retry event. Neither API
allocates/renews UUIDs or performs SQL/effects. All reserved execution/permit IDs must be
fresh; current/used histories stay immutable. Correct startup may advance observed authority
epoch while captured epochs remain old; permits/debt must stay outstanding until actual
recorded checked cleanup, not silently omitted. Revocation/permanent removal deny Retry.
Use an explicit positive caller byte bound before JSON decode and after encode; no default
limit or invented profile/allocator. This bounds codec bytes only, not combined RSS. Reject
unknown JSON keys/version/variants/types rather than compatibility fallback. Pure fixtures
supply declared synthetic bounds; production owner binding belongs to the next layer.

EXACT worker3 writable files: NEW Application/ImportRecoveryJournal.swift, NEW
Tests/Product/ImportRecoveryJournalTests.swift, this Spec. Read-only existing policy and
ImportIdentity declarations. Skip ALL tests/builds/lint/format/gates/commits/remotes/runtime/
SDK/workflows/.gjc/delegation. Parent registers Package/Xcode, verifies faithful normal and
failed/cleanup-unknown/Retry/startup/deletion event histories, then integrates storage and
actual callers sequentially (large evolving contract, no concurrent DB/UI implementation).
Next layer extends existing importJob through the sole migrator; records lacking real
history remain explicitly ineligible, never fabricate old capture or empty debt. Exact CAS
and whole transaction readback bind journal to actual columns. Final native UI uses fresh
reselection/confirmation against the captured failed Job; Cancel no reservation, consumed
intent never replayed, old callbacks fenced. No whole namespace cleanup of usable results.
Each layer stays truthful: journal-only source/fixtures are NOT durable activation or Retry.
Same-Job completion and canonical0/26/P1/P2/P3/UI/Story remain unclaimed until actual gates.

### First-layer source handoff — immutable journal, not durable Retry

Worker86 authored only Application/ImportRecoveryJournal.swift,
Tests/Product/ImportRecoveryJournalTests.swift and this Spec. Internal Sendable journal and
ConfirmedInput expose the specified throwing constructor, snapshot, recording, retrying,
explicit-bound encoded and static decode APIs. ConfirmedInput's initializer requires both
optional facts; wire format requires both keys, including explicit null. Format1 contains
the full initial capture and typed ordered event DTOs; Retry records another full capture.
All stored DTO fields are immutable. Policy Snapshot is computed by create/apply on the
calling thread and is not declared Sendable. No policy or ImportIdentity source changed.

Replay preserves actual policy rejections and additionally checks exact captured lineage,
stable Paper/generation/Job, source/inapplicable applicability, canonical UUID spelling,
lowercase64 expected hash, distinct initial identity categories, all prior reserved IDs,
and reserved writer/publication binding. Fresh Retry identities include input and both
unused permits; current observed epoch is checked by policy, not allocated by the codec.
Result IDs retain the policy's nonempty opaque-string contract, not invented UUID/SHA rules.
Ordinary recording of retry is rejected. Startup observations do not rewrite old captures.
Decode compares the complete decoded/re-encoded JSON tree, with scalar JSON types preserved,
to reject unknown nested keys/variants/types; unknown versions fail. Bounds are caller-supplied
positive bytes only, checked before decode and after encode, not a production memory profile.

Fixtures author controlled synthetic owner attestations, checking complete Snapshot equality
against actual apply at every admitted event and round trip. Cases include success/release,
failed writer/publication cleanup, unknown/open closure and cleanup debt, old-epoch startup,
same-Job fresh Retry, usable-pointer/history retention, late historical send, authority
observation, revoke/removal debt, reserved-ID aliases, wrong role/config/Job/generation,
nested corrupt JSON and explicit byte-bound edges. These are authored checks, not passed
checks: worker ran no tests/builds/gates/lint/format/commits/runtime. Parent owns Package/Xcode
membership, compilation, fixture execution, independent review and all integration/gates.
No durable SQL capture, production budget binding, physical closure/purge, publication,
input/action authority or native Retry activation is claimed by this source-only handoff.

### Strict-format correction before persistence

Review87 found that lossy JSON tree normalization can discard duplicate object members,
including a hidden revocation or unsupported variant. Format1 is now the exact sorted-key
JSONEncoder byte representation emitted by encoded(maximumBytes:). Decode must compare
the original bounded bytes with the typed re-encoding before replay. Duplicate members,
escaped duplicate spellings, reordered keys and added whitespace reject; no alternate
representation or compatibility decoder is promised. This avoids introducing a second
JSON parser. Raw-byte fixtures cover root and nested duplicate keys and hidden events.
This narrows serialization only; it grants no attestation or execution authority.

### Parent first-layer verification and independent review

After Spec93b8219 and canonical correction Specf6547cf, parent registered the journal
in the existing SwiftPM Product target/tests and appended only B00000000000000000000057
to Main native sources. Four-source binary diff against f6547cf SHA256:
f94667df663d8aeef613a35f9bbab5c4a1465c1bfd2e9b47d17f11ad12117138.
Final journal fixtures11/0 artifact1113; Product329/0 artifact1114; fresh unsigned native
Release arm64/macOS15 BUILD SUCCEEDED artifact1115, namespace product-native-compile-20261010-ae.
Pre-correction focused10/1103, Product328/1108 and native-ad/1110 remain historical evidence.
Review87 final SOURCE-ONLY CLEAR / APPROVE resolves duplicate-member MEDIUM; no repeated
unchanged policy review. Existing policy, sole database, lifecycle and physical owners
remain unchanged. No formatter is configured; none added or run. Compiler/debug-map
warnings remain unsuppressed. No app/helper/SDK/renderer/provider/remote/trial execution.
This layer is the tested immutable replay/codec component, NOT persisted recovery,
production byte-budget binding, native same-Job Retry or Story acceptance.

### Next sequenced layer: sole-GRDB recovery transaction primitives

Add nullable recoveryJournal BLOB to the existing importJob through the sole migrator.
Existing rows remain NULL and explicitly ineligible; never synthesize their old history.
The parent adds migration registration and Package/Xcode membership. The immutable journal
exposes a throwing typed current-capture accessor (full ImportIdentity plus ConfirmedInput),
derived from the initial or last Retry capture after replay, not reconstructed from rows.

Implement transaction-local initialization for a newly reserved execution, bounded restore,
and exact old-byte CAS replacement using the same Database supplied by the existing queue.
Each operation requires an explicit positive maximumBytes supplied by its caller; no default
or production profile constant is introduced. Validate all ten duplicated identity columns,
the actual Paper ownership/generation, and nondeleting state before writes. Read bounded
payload length before materialization; NULL, corrupt, rebound or oversized history rejects.
CAS checks affected row count and exact readback inside that transaction; a trigger refusal,
readback corruption or stale prior payload rolls back. A successful codec is not authority.
Initialization is only a hook for the parent's new-reservation transaction, not an API for
retroactively admitting legacy rows. No independent queue/database/selector/counter.

Worker writable files: NEW Infrastructure/ProductDatabase+ImportRecovery.swift, NEW
Tests/Product/ImportRecoveryPersistenceTests.swift, this Spec. Read existing database,
journal and policy only. Worker skips all gates/formatters/commits/runtime/delegation.
Parent owns typed accessor, schema registration, callers, membership, tests and review.
This stage tests genuine owned GRDB persistence and transactional refusal/rollback; it does
not yet wire lifecycle attestations or admit same-Job Retry. Those require the actual owner
events, explicit production byte-bound admission and fresh captured UI confirmation.

### Parent sole-store primitive integration and verification

Worker88 delivered the existing-queue extension and eleven actual-GRDB tests. Parent
registered importRecoveryJournalV1 on the sole migrator, nullable importJob.recoveryJournal
without backfill, SwiftPM source/tests and only B00000000000000000000058 in Main sources.
Internal APIs initializeImportRecovery(_:maximumBytes:in:), readImportRecovery(_:maximumBytes:in:)
and compareAndSwapImportRecovery(expected:replacement:maximumBytes:in:) enforce current
full capture, explicit byte bound, exact prior BLOB, affected rows and exact readback.
Initialization is a new-reservation transaction hook, not retrospective legacy authority.
Ordinary CAS excludes Retry capture transitions; atomic execution-column replacement remains
the next actual owner layer. Capture and extends(_:maximumBytes:) APIs expose immutable typed
facts and reject equal/truncated/divergent/altered-initial histories, never JSON string hacks.

Seven-source binary diff against a8c58cb SHA256:
f853c38ecec7e473c9d6fa64bfce525073ac44be1a72abc3db1e9c30d78ffefa.
Focused24/0 artifact1121 (13 journal,11 persistence); Product342/0 artifact1127; fresh
unsigned native Release arm64/macOS15 BUILD SUCCEEDED artifact1128, namespace
product-native-compile-20261010-af. Review89 SOURCE-ONLY CLEAR / APPROVE, exact five-source
scope; no actionable finding. Actual SQL reopen/rollback proved, not physical closure or
product lifecycle events. Parent corrected the worker's prefix API spelling to the stable
extends contract. Worker accidentally appended its receipt to the launcher-root Spec;
only that exact worker-only added block was removed, preserving the unchanged root body.
The authoritative receipt is here in the integration worktree, not the launcher checkout.
Legacy NULL histories remain ineligible; production reservation/lifecycle journal wiring,
explicit production codec-byte binding, fresh same-Job Retry UI and Story acceptance remain
unimplemented by this primitive-only receipt. No app/helper/SDK/renderer/remote/trial action.

### Next executable slice: journal-aware atomic startup

For prior-epoch running imports whose recoveryJournal is non-NULL, ProductJobRecovery
must restore the actual full captured history, require its exact running import lineage,
record the real startup event, and CAS/read back that journal in the existing whole-kind
recovery transaction together with failed/interrupted Job and Paper debt changes. Never
replace genuine permits, prior results, used IDs or cleanup operations with a synthetic
empty Snapshot. Corrupt/rebound/oversized history or journal update/readback refusal rolls
back imports, extractions and summaries together before lifecycle admission. Legacy NULL
records keep their existing conservative interruption path and remain Retry-ineligible.

Application startup owns an explicit 262144-byte serialized journal-record ceiling passed
to the existing bounded codec/storage operations. This is a newly declared metadata-format
quota, not a measured allocator/combined-RSS bound, provider/parser profile, execution or
closure admission. No codec default or guessed certified resource enforcement is added.
Other production journal writers remain unwired; their owner admission remains separate.

Worker writable files are ProductJobRecovery.swift, ProductJobRecoveryTests.swift and THIS
Spec under the integration worktree only. No launcher-root Spec edits. Preserve all
existing extraction/summary/legacy startup contracts, current-epoch and terminal records,
and transaction/readback guards. Real owned-GRDB fixtures cover retained open/unknown
writer debt, captured-versus-observed epoch, immutable history, corrupt/rebound records,
ignore/corrupt triggers and cross-kind rollback. Parent runs gates/review/commit; worker
skips all tests/builds/formatters/commits/SDK/helper/renderer/remote/trial operations.
This slice does not create old history, prove closure, authorize Retry or complete Story1.14.

### Worker90 authored journal-aware startup (parent verification pending)

Against baseline3b7d2bf and startup-slice Specc90f161, ProductJobRecovery now restores
non-NULL import history inside the existing adapterWrite transaction. Application owns
internal static maximumImportRecoveryJournalBytes = 262144 and explicitly passes this
serialized-record quota to bounded restore, encoding, CAS and final typed readback. Import
selection/readback projects every actual column, bounding the BLOB in SQL and retaining
its storage-type discriminator; oversized/non-BLOB data is never treated as legacy NULL.
All ten captured UUIDs and joined Paper generation/ownership, nondeleting admission,
exact import/running lineage and captured epoch must match. Genuine immutable startup
append is compared with the policy decision, then exact prior-byte CAS occurs before
ordinary Job failure and Paper debt updates. Final readback checks exact bytes and replayed
typed history. Only actually journaled imports allow recoveryJournal to differ in the
exact-row comparison; all other columns remain guarded. Invalid restoration is
invalidLineage, refused/stale CAS is recoveryConflict, and journal/final readback corruption
is readbackMismatch. Throws escape the one transaction; no fallback/catch-and-continue.

Policy clarification resolved with parent: existing startup semantics retain an attested
writer .open as .open while revoking it and requiring cleanup; an existing .unknown writer
remains .unknown. This slice does NOT synthesize an open-to-unknown event or modify policy.
Neither retained closure value proves present physical closure. Known cleanup operations,
failed debt, used IDs, prior results and every earlier Retry capture remain genuine history.
Legacy NULL remains the original conservative transient path and Retry-ineligible;
parsing/summary, current-epoch and terminal startup behavior is unchanged.

Nine new owned-GRDB tests authored in ProductJobRecoveryTests:
- testJournalStartupRetainsOpenWriterDebtAllCapturesAndObservedEpochWithoutRenewal
- testJournalStartupRetainsPriorResultOlderRetryCapturesAndKnownCleanupDebt
- testJournalStartupRejectsCorruptNonBlobOversizedAndNonRunningHistoryWithoutFallback
- testJournalStartupRetainsUnknownWriterWithoutInventingClosure
- testJournalStartupRejectsEveryReboundCapturedUUID
- testJournalCurrentEpochAndTerminalRecordsAreNotReadOrRewritten
- testIgnoredJournalCASRollsBackEarlierImportsOtherKindsAndTriggerMarker
- testCorruptedJournalCASRollsBackEarlierImportsOtherKindsAndTriggerMarker
- testJournalFinalReadbackRejectsPostStateCorruptionAndUnrelatedColumnMutation

Existing malformed-summary, extraction-write-failure and malformed-extraction rollback
tests now seed genuine journals to include rollback of earlier journal appends. Fixtures
use the new-reservation initialization hook and ordinary exact-byte CAS for owner events.
The multi-Retry fixture uses genuine replayed capture events and an explicitly test-only
atomic execution-column transition; it is not a shipped Retry owner or reconstructed
history. All closure/publication/cleanup events are synthetic attestations only. Trigger
fixtures assert earlier import/Paper rollback and extraction/summary/metadata-marker
rollback; final-state triggers exercise corruption after the initial successful journal CAS.

Worker performed source inspection only: no tests, builds, gates, lint, formatters, commits,
runtime or external actions. Parent must run focused ProductJobRecoveryTests and the
existing journal/persistence suites, then owned integration verification/review/commit.
Migration registration and target membership already exist; no new file or membership
change is required. This is startup-only source, not actual reservation/lifecycle journal
wiring, Retry UI/authority, physical closure, external activation or Story success.

### Parent journal-aware startup verification and independent review

Two-source binary diff against c90f161 SHA256:
4d81a631b5dfdc0c0d624dcfa92d2c2bb222173d3c8cef80439b23a1bdddcfb9.
Focused43/0 artifact1142 (19 startup including9 new,13 journal,11 persistence);
Product351/0 artifact1148; fresh unsigned native Release arm64/macOS15 BUILD SUCCEEDED
artifact1149, namespace product-native-compile-20261010-ag. Review91 SOURCE-ONLY CLEAR /
APPROVE, no actionable finding. Root application startup path handles genuine journals;
real owned GRDB transactions/reopen/cross-kind rollback are verified. Physical process
restart, closure, app/UI/helper/provider/SDK/P1/P2/P3 remain unverified. Metadata quota is
serialized-record policy only, not hard-RSS/profile certification. Existing policy,
journal/storage primitives, Package/project and actual copier/lifecycle sources unchanged.
No warnings suppressed, formatter added, remote/release/trial execution performed.
Production import reservation/event writers and same-Job Retry UI remain unfinished;
this startup integration does not admit synthetic legacy history or complete the Story.

### Next safe bridge slice: ordinary reservation and publication transactions

Bounded contract92 requires coordinated local/URL owner cutover after abort/deletion and
physical receipt acknowledgment are available. Do not activate partially wired production
journaling or Retry. First implement genuine ordinary transaction primitives in the sole
database: reserveJournaledImport(identity:title:confirmedInput:), ordinary append of an
immutable replacement against exact expected record, and publishJournaledImport against
an independently admitted closed-stage observation. All use the declared Application
serialized-record quota explicitly, not a new profile/gauge/root or codec default.

Reservation inserts real Paper/Job, initial+claim and acquireWriter in one transaction with
exact readback before producer effects. Confirmed hash/folder facts remain immutable; nil
is not replaced by discovered output. Ordinary append rejects identity/fact/prefix drift,
deletion or stale bytes. Publication requires previously acknowledged rename intent and
the actual owner's validated result/stage, exact full lineage and confirmed hash/folder.
Pre-encode the complete renameFinished(true)/publish/release suffix BEFORE filesystem or
visibility effects. Rename actual owned closed stage, atomically publish reference/hash/
folder/success and full journal, then check exact whole-row/journal readback. No success
suffix is persisted before actual rename succeeds. Checked row refusal/corruption rolls
back SQL/history; an already performed rename is not rolled back by SQLite. Preserve those
bytes and throw for later receipt reconciliation, never delete or fabricate committed
success from this helper. Existing working import APIs remain unchanged until owner cutover.

Typed closed-stage fields are memory-only observations from independently admitted producer
closure/validation, not new read or physical closure authority. Validate lowercase SHA,
positive bytes and exact owned Paper namespace before effects; reject symlink/nonregular
or foreign stage, final overwrite and destination/hash mismatch. No same-UID path-isolation
claim. Actual owned-file/GRDB tests establish rename/publication/reopen, denial before
effects, stale/full-lineage fences, bounded suffix refusal and trigger/readback rollback.

Exact worker writable files: ProductDatabase.swift, ProductDatabase+ImportRecovery.swift,
ImportRecoveryPersistenceTests.swift and this integration Spec. No new membership/schema,
no policy/copier/lifecycle/startup edits, no launcher-root Spec. Parent gates/reviews/commits;
worker skips all gates/formatters/commits/SDK/helper/renderer/paid/remote/trial actions.
Deletion diagnostic schema and full physical-receipt/actor gate bridge are deferred, not
assumed approved or invented. Ordinary transaction tests do not complete owner cutover.

### Ordinary transaction primitives authored after c43bdbd (worker93; gates pending)

Story1.14 / existing local-library-import-delete work unit; bounded implementation follows
contract92 and the committed c43bdbd Spec after cd363c8. No new execution approval, trial,
runtime certification or Story completion is asserted. Only the four integration paths
named above were edited; launcher-root documentation and production owner callsites remain
unchanged. Parent owns tests/build/review/commit and subsequent coordinated owner cutover.

Internal API signatures now authored:

```swift
func reserveJournaledImport(_ identity: ImportIdentity, title: String,
  confirmedInput: ImportRecoveryJournal.ConfirmedInput) throws -> ImportRecoveryRecord
func appendJournaledImport(expected: ImportRecoveryRecord,
  replacement: ImportRecoveryJournal) throws -> ImportRecoveryRecord
func publishJournaledImport(expected: ImportRecoveryRecord,
  closedStage: ClosedImportStage) throws -> ImportRecoveryRecord
struct ClosedImportStage: Sendable {
  let file: URL
  let sha256: String
  let bytes: Int64
}
```

ClosedImportStage has the internal memberwise initializer `init(file:sha256:bytes:)`, no
codec and no persisted path. It conveys an independently admitted, immutable memory-only
producer observation; constructing it is not closure/read authority. Helpers never open
or rehash the stage or caller PDF. Existing exact insertion and guarded row publication
utilities are shared with old reserveImport/publish callers, which remain active until
full cutover; no overload, fallback or legacy NULL-journal backfill is added.

Each helper performs one sole-queue write transaction. Reservation checks captured folder,
inserts caller-provided full identity and actual running Job, narrowly initializes initial
plus claim, CAS-appends acquireWriter, and checks typed history/whole identity and inserted
facts. Ignored inserts are refused by exact row counts, including attempted legacy backfill.
Append validates expected canonical bytes against its typed journal, bounded current exact
BLOB/full lineage, immutable captured facts and prefix using existing CAS; whole-row/folder
readback rejects trigger mutation of execution or Paper facts. No policy Event crosses an
actor boundary through this API; replacement journals are already immutable Sendable values.

Publication admits only the actual importing/nondeleting Paper and running exact Job with
acknowledged publication-permit `.rename`: current lineage, `.renaming`, unrevoked/no cleanup,
validated Result(id: attempt.uuidString). The existing policy deliberately makes publication
permit closure `.unknown` during rename; this helper does not reinterpret that as producer
closure failure or introduce a second policy. Independently closed producer observation,
positive bytes, progress at most observation bytes, lowercase SHA and immutable confirmed
hash/folder are required. Confirmed nil hash remains nil after discovered hash publication.

Before effects, encode the entire renameFinished(true)/publish/release suffix using
ProductJobRecovery.maximumImportRecoveryJournalBytes (262144), exclusively a serialized
metadata quota. Preview never persists a success attestation. Validate exact canonical Paper
namespace, nonsymlink owned directories/root, regular current-UID single-link 0400-sealed
stage and matching stat size; safe single-component names need not be attempt.stage. Reject
foreign/prefix-lookalike namespace, decoded NUL, final-path alias and any existing final
entry before FileManager move. These checks do not isolate hostile same-UID path/in-place
races. Move without overwrite to document.pdf, then exact-old-BLOB/full-lineage journal CAS,
ready reference/hash/folder and succeeded/failure-nil updates. Verify exact row counts,
all otherwise immutable columns, progress, folder and exact bytes/typed whole readback.
SQL rollback after a move preserves final bytes and throws, never deletes bytes or claims
physical rollback/committed success. Later physical-receipt reconciliation remains required.

Twelve additional XCTest methods were authored in existing ImportRecoveryPersistenceTests,
without Package/schema/test-file additions. Fixtures create actual private owned stage files,
FileHandle write/synchronize/checked close, then chmod0400. Synthetic owner observations in
these fixtures are explicitly not production closure authorization. Authored coverage:
reservation exact captures/claim/writer/reopen and no namespace effects; invalid folder,
duplicate/ignored inserts and initialization rollback; ordinary open/closed/publication/
rename intent appends; actual rename, ready Job/reference/hash/folder, complete suffix and
reopen with confirmed nil preserved; typed-byte/fact/prefix/stale mismatch; all ten UUID
drifts, deletion, missing/corrupt/oversize/revoked history; hash/folder/progress/result/intent
and malformed observation denials; foreign/prefix/symlink/nonregular/hardlink/writable/size/
NUL/final-alias/final-overwrite/namespace-symlink denial before effects. Quota case grows
genuine valid same-authority observations until current journal fits the actual production
metadata limit but terminal suffix does not; no test override of the limit. Ignored/corrupt
journal/Paper/Job, immutable-column and folder triggers exercise whole SQL rollback and
preserved moved bytes, including corruption only after success-state update.

Worker performed source inspection only. These tests are authored, NOT executed; no build,
test/gate/lint/format/commit/workflow/delegation/SDK/app/helper/renderer/network/paid/remote/
credential/user-document/trial actions ran. Prior startup351/native-ag/review91 evidence
applies only to its earlier baseline, not this unverified implementation. Parent must run
ImportRecoveryPersistenceTests and affected legacy Library/Folder/URL import tests, Product
suite/native compile and change-focused integrity review before treating the new primitives
as verified. ActualLocalLifecycle/URL writer cutover, abort/deletion/receipt actor bridge,
freshSameJobRetry/UI and production physical receipt acknowledgments remain unfinished.

### Parent ordinary transaction verification and independent review

Three-source binary diff against c43bdbd SHA256:
bdf75312c86feda88d78e6f872158a5d8414be8e1d3357bb5b1a6f4edaf41e98.
Focused78/0 artifact1159 (23 persistence including12 new,28 lifecycle,19 folder,8 URL
writer); Product363/0 artifact1165; fresh unsigned native Release arm64/macOS15 BUILD
SUCCEEDED artifact1167, namespace product-native-compile-20261010-ah. Review94 found no
production correctness defect and one LOW post-insert folder-corruption matrix gap.
Parent added that exact trigger case; changed test1/0 across11 scenarios artifact1171
proves SQL/readback rollback with moved bytes retained. Union/native precede this test-only
extension; production source unchanged and unchanged gates not repeated. Review94 final
SOURCE-ONLY CLEAR / APPROVE closes the gap; no outstanding finding from that review.

Actual owned-file rename and GRDB durable publication/reopen/rollback are verified, not
production local/URL owner cutover or physical receipt acknowledgment. SQLite cannot undo
rename; preserving bytes is intentional. Serialized quota is not allocator/profile proof;
typed stage observation/codec is not authority. Legacy imports remain working with shared
row utilities; old API removal occurs only at complete owner cutover, not via fallback.
No new schema/Package/project/epoch/policy/copier/source-selector or budget profile changes,
no formatter added, warnings suppressed, app/helper/SDK/renderer/remote/trial actions.
Same-Job Retry and canonical Story/Epic acceptance remain unfinished and unclaimed.

### Deletion diagnostic prerequisite inside the existing persistence owner

Contract92 identified that deletionFailed currently overwrites importJob.failure with a
deletion diagnostic. That destroys the retained terminal import cause and paperDeleting
execution fence even though the Paper saga owns the deletion. Resolve with one nullable
paper.deletionFailure field on the existing sole GRDB migrator, restricted to the existing
fixed codes agentPurgeUnavailable/agentClosureUnproved/deletionIncomplete. No new owner,
store, configurable profile or acceptance-criteria change. Existing rows remain NULL; do
not backfill guessed causes or create legacy fallbacks. This is in-scope data-integrity
feature work, not an approval of a new architecture or weakened abort guard.

deletionFailed changes only the exact current deleting/canonical-saga Paper, checked row
count/readback, status/debt/fixed diagnostic. Never modify ANY importJob lineage/state/
failure/history/progress or PDF hash/generation. Wrong saga, invalid reason or trigger
refusal/corruption rolls back; no success from zero changed rows. libraryRecords chooses
the Paper diagnostic for deleting/deletionFailed and the Job cause for import states,
without silent field fallback. beginDeletion keeps its running-only Job interruption
and clears the old Paper diagnostic for a newly admitted retry; all other immutable data
and original saga remain fenced. finalizeDeletion clears the diagnostic in its existing
contentless tombstone transaction. Abort still requires failed/paperDeleting plus exact
full execution and actual deleting saga; diagnostic separation does not relax that rule.

Parent registers the checked nullable-field migration before the worker; worker writable
files are ProductDatabase.swift, LocalLibraryLifecycleTests.swift and this integration
Spec only. Existing actual lifecycle caller uses these same three codes, no new public
API/Package membership. Real owned-GRDB tests prove successful/failed import cause and
history preserved, deleting/failed display uses own cause, reopen, wrong-saga/trigger
rollback, retry clearing and final tombstone erasure. Parent verifies/reviews/commits;
worker skips gates/format/commits/SDK/helper/renderer/remote/trial execution. This prerequisite
does not itself activate the full journaled abort/deletion bridge or same-Job Retry.

### Deletion diagnostic implementation handoff (source-only, after e71cfe9)

The existing production ProductDatabase methods now own the separation; there is no
alternate helper entry point or new public API. The parent-registered sole-owner
localLibraryDeletionDiagnosticV1 migration is unchanged. deletionFailed validates the
fixed reason before entering its single write transaction, admits only the actual
deleting Paper with the exact canonical saga and nonempty generation, and updates only
status/cleanupDebt/deletionFailure. Affected-count and full-row readback compare every
other Paper column and every retained Job column, including recoveryJournal bytes.
Refusal, missing/wrong/malformed saga, invalid state or corrupted readback throws
invalidRecord and rolls back the transaction. No Job failure/state/lineage/progress/history
write remains in this failure path.

libraryRecords uses an explicit CASE: deleting/deletionFailed reads paper.deletionFailure;
all other visible states read importJob.failure, with no COALESCE or legacy inference.
beginDeletion clears the Paper diagnostic, rejects malformed/noncanonical existing
sagas rather than replacing them, retains valid retry sagas and interrupts only running
Jobs. Count/readback guards cover diagnostic clearing, unchanged Paper data and the
running-only Job transition. finalizeDeletion clears the diagnostic with its existing
contentless fields, verifies the exact tombstone and checks Job removal; zero-row success
is rejected. recordImportAbort's full ten-identity/failed-paperDeleting/deleting-saga
admission remains byte-for-byte unchanged.

Authored owned-GRDB tests (not executed by this worker):
- testDeletionDiagnosticPreservesWholeSucceededFailedAndInterruptedJobRows: actual
  owned-file success, failed import and running interruption, all three fixed codes,
  complete Job/Paper preservation, persisted opaque history sentinel, live/reopened
  libraryRecords cause selection, same-saga retry clearing and unchanged late-abort fence.
- testActualAndReopenedLifecycleListSeparatesFailedImportAndDeletionCauses plus the
  extended testMissingPurgeBlocksDeletionAndKeepsTruthfulDebt: actual lifecycle list and
  reopen show the deletion cause without destroying failed/succeeded Job rows.
- testDeletionDiagnosticRejectsInvalidReasonSagaGenerationAndStateWithoutEffects:
  invalid reason, wrong/malformed/noncanonical/missing saga, wrong/unknown state and
  empty generation reject without row changes; malformed admission cannot mint a saga.
- testDeletionDiagnosticTriggerRefusalAndFullRowCorruptionRollBack: BEFORE RAISE(IGNORE)
  and AFTER diagnostic/title/generation/SHA or Job failure/state/progress/attempt/history/
  removal corruption roll back the complete SQL transaction.
- testDeletionRetryDiagnosticClearingIsCheckedAndAtomic and
  testDeletionAdmissionJobInterruptionRefusalRollsBackDiagnosticClearing: refused/corrupt
  diagnostic clearing and refused running-Job interruption roll back, then same-saga
  retry or running-only admission succeeds after removing the owned trigger.
- testDeletionTombstoneClearsDiagnosticAndJobWithCheckedRollback: refused Paper/Job
  effects and corrupt diagnostic/title roll back; successful tombstone erases content,
  clears the diagnostic and removes the Job; duplicate finalization is not success.

Only ProductDatabase.swift, LocalLibraryLifecycleTests.swift and this integration Spec
were edited by the worker. Source inspection is not runtime proof. All tests/builds/
gates/lint/format/commit/remote and physical Agent/profile/SDK/app/helper/renderer/trial
execution are deliberately skipped under the assigned boundary; parent owns verification,
independent review and commit. Existing actual Agent purge, known-closure and deletion
tests remain in place and were not run. Opaque-history preservation is not journal
validation or producer-owner cutover evidence. No same-Job Retry, journal bridge,
architecture/privacy change or Story certification is claimed.

### Parent actual deletion diagnostic verification and review

Three-source binary diff against e71cfe9 SHA256:
a2624026a45da763ebf189283990c5fcbd99b99c3a076c7a2e546c147366c837.
Focused85/0 artifact1176; initial Product370/1 artifact1179 is preserved: the existing
organization fixture passed fixtureFailure, correctly denied by the explicit fixed-code
contract. Parent changed that single caller argument to deletionIncomplete, without
weakening validation. Affected suites67/0 artifact1184 and final Product370/0 artifact1185.
Fresh unsigned native Release arm64/macOS15 BUILD SUCCEEDED artifact1182, namespace
product-native-compile-20261010-ai; no production source changed after compilation.
Review96 SOURCE-ONLY CLEAR / APPROVE for database/lifecycle tests/Spec. Parent's one-line
organization fixture caller correction is separately directly verified, not a broadened
review claim. Actual existing deletion data ownership/real GRDB rollback/reopened list is
proved; no actual Agent purge, app/helper/SDK/renderer/remote/trial or profile certification.
No policy/copier/late-abort guard relaxation; no Package/project or new database/owner.
Serialized history and opaque fixture bytes are not physical closure or Retry authority.
Full durable actor/producer receipt bridge and same-Job Retry UI remain unfinished.

### Next bridge slice: exact saga-bound deleting history transactions

Contract92 is already consumed: ordinary transaction primitives, diagnostic ownership
and actual HTTPS uncertain-close retention are delivered. Do not repeat that assessment.
Add separate internal static readImportRecoveryForDeletion(identity:saga:maximumBytes:in:)
and compareAndSwapImportRecoveryForDeletion(expected:replacement:saga:maximumBytes:in:)
on the sole existing database extension. Ordinary restore/CAS continue denying deletion.
Caller supplies the existing GRDB transaction and explicit positive serialized byte bound;
no queue, selector, physical effect, closure command or production cutover is introduced.

Require actual Paper status deleting, exact canonical non-NULL saga, full ten captured
UUIDs and generation/ownership, bounded canonical existing BLOB, genuine revoked import
history and matching retained execution state. Preserve succeeded/previously failed
executions; interrupted active execution requires failed/paperDeleting. Paper diagnostic
must not replace execution cause. NULL legacy remains ineligible. Strict immutable-prefix
CAS keeps current capture/facts and revocation, rejects Retry/new permits/history renewal,
checks exact old bytes/affected rows/bounded exact readback and unrelated whole-row facts.
Failure propagates for caller transaction rollback. No generic failed-row fallback and
no change to recordImportAbort's stricter late-producer admission.

Write only ProductDatabase+ImportRecovery.swift, ImportRecoveryPersistenceTests.swift
and this integration Spec. Actual owned-GRDB fixtures prove retained successful/failed/
paperDeleting histories, genuine cleanup observations, reopen, wrong/malformed saga,
full-lineage drift, NULL/non-BLOB/oversize/noncanonical/unrevoked/state mismatch rejection,
no-op/divergent/Retry denial, ignored/corrupt triggers and caller marker rollback. Fixture
closure events are synthetic attestations, not real physical ACK. Parent gates/reviews/
commits; worker skips tests/builds/formatters/commits/SDK/helper/renderer/remote/trials.
No new migration/membership, actor cutover, physical receipt authority or Retry UI claim.

### Saga-bound deleting history implementation (worker99, parent verification pending)

Traceability: baseline 90b7189; existing committed Spec aa27603 (no leading `c`).
Contract92 remains consumed; this is its requested separate metadata implementation,
not a repeat assessment or completed durable producer/lifetime bridge.
Only the three assigned integration files changed; no root documentation changed.

Authored internal static APIs on the sole ProductDatabase extension:
`readImportRecoveryForDeletion(_ identity: ImportIdentity, saga: UUID,
maximumBytes: Int, in db: Database) throws -> ImportRecoveryRecord` and
`compareAndSwapImportRecoveryForDeletion(expected: Data,
replacement: ImportRecoveryJournal, saga: UUID, maximumBytes: Int,
in db: Database) throws -> ImportRecoveryRecord`.
They use only the supplied database context, do not open a transaction or queue,
and propagate failure so the caller must roll back its complete transaction.
The positive bound is checked before SQL. Shared ordinary/deletion identity parsing
and the existing canonical codec retain the bounded BLOB-only CASE materialization
gate; ordinary reads/CAS still require NULL deletionID and non-deleting Paper status.

Deleting restore requires actual status `deleting`, exact canonical supplied saga text,
all ten canonical captured UUIDs (including actual owner/generation), and genuine
non-NULL revoked import replay. It checks the entire current captured lineage and
actual Job state/cause. Retained succeeded execution requires actual `succeeded` and
NULL failure. Retained failed execution requires actual `failed` with this closed
source-derived code mapping, not an arbitrary-reason or generic failed-row fallback:

| Actual importJob.failure | Required journal policy failure | Existing source |
| --- | --- | --- |
| importFailed | failed | LocalLibraryLifecycle local abort |
| publicationRejected | failed | LocalLibraryLifecycle post-rename abort |
| sourceChanged | failed | LocalLibraryLifecycle selected-source abort |
| urlImportFailed | failed | LocalLibraryLifecycle URL abort |
| cancelled | failed | Both lifecycle abort paths terminate with `.failed`, not `.cancelled` |
| interrupted | interrupted | ProductJobRecovery startup replay |
| paperDeleting | paperDeleting | beginDeletion active execution interruption / journal revoke |

Unknown codes, policy `.cancelled`/`.timeout` without a matching existing actual code,
pending/running/unknown actual states, unrevoked replay and mismatched state/cause are
ineligible. `paper.deletionFailure` is an independent diagnostic, never Job cause.
The fixed `deletionIncomplete` fixture diagnostic deliberately coexists with all
accepted retained Job causes to exercise this separation.

Deleting CAS decodes canonical bounded expected bytes and validates genuine revoked
previous/replacement snapshots, unchanged capture/facts/execution history and used
permit IDs, plus strict codec immutable-prefix extension (no zero-event/no-op,
truncation, divergent history, Retry/new grant/capture or revocation clearing).
Parent clarified no-op means identical/no-added-event history, as in `extends`;
valid added same-authority or repeated-revoke observations are not denied solely
because their final snapshot is unchanged.
Cleanup may update/release existing permits and reserve fresh cleanup operation IDs;
committed successful publication bytes are not treated as failed-stage cleanup.
UPDATE matches exact old BLOB, all ten lineage fields, actual Paper owner/generation,
exact saga and `deleting`. Affected count must be one. Typed bounded canonical
readback must equal replacement bytes. All actual Paper columns and all current
importJob columns other than recoveryJournal are compared exactly, including progress,
diagnostic, state/cause, deletionID, result-file pointers and immutable metadata.
The comparison's job query also CASE-gates the journal rather than using unbounded
SELECT-star materialization. Ignore/corruption/unrelated mutations throw; no marker,
automatic transaction or error swallowing is added. recordImportAbort is unchanged.

Five authored owned-GRDB test methods extend ImportRecoveryPersistenceTests:

- `testDeletingHistoryRetainsExactTerminalCauseResultAndCleanupAcrossReopen`:
  genuine journaled reservation/claim/writer, synthetic publication or termination,
  revoke persisted before marking actual saga in the same controlled transaction;
  all seven fixed failed codes plus succeeded result/pointer, failed/fresh successful
  cleanup operations, permit release, used IDs, namespace observation and reopened
  exact snapshot/bytes. Ordinary helpers deny deleting history before and after cleanup.
- `testDeletingReadRejectsWrongSagaAndEveryCapturedIdentityDrift`:
  wrong/malformed/lowercase/renamed saga, supplied full-ten identity drift, actual Job
  ID and owner drift, generation and remaining captured field drift.
- `testDeletingReadRejectsStatesCausesAndIneligiblePayloadWithoutFallback`:
  invalid Paper/Job states, wrong causes, NULL/unrevoked/corrupt/truncated/noncanonical/
  text/integer/oversized history, exact byte limit and one-byte-short denial. Stored
  invalid payloads are exercised against both deleting APIs.
- `testDeletingBoundsAreValidatedBeforeAnySQLAndCASRejectsNonExtensionsAndRetry`:
  renamed-away table proves nonpositive bounds precede SQL; canonical expected-data
  validation, replacement byte bound, no-op/truncation/divergence, facts/capture/Retry
  mismatch, wrong saga, stale expected data and reopened successful append.
- `testDeletingCASIgnoredCorruptAndEveryUnrelatedColumnTriggerRollsBackCallerAndReopens`:
  ignored/corrupt/oversized/text payload and independent column triggers; caller's
  initialized providerConfig generation/model marker changes before CAS, thrown error
  escapes adapterWrite, then reopen compares prior exact payload and entire Paper/Job/
  providerConfig rows. Each trigger operates only on its synthetic fixture database.

Worker evidence is source inspection and authored fixtures only; no tests, build,
gate, lint, formatter, commit, SDK/app/helper/renderer/network/remote/paid trial ran.
Parent must run the focused persistence suite, ordinary/startup regression coverage,
review exact three-file diff and own any authorized gate/review/evidence/commit.
Production callsites intentionally remain unchanged: these internal transaction
metadata helpers are not production actor integration, physical closure ACKs,
producer-owner event authority, same-Job Retry, lifetime cutover or UI proof.
Original FD/root/lease debt and actual HTTPS unknown-close permanent fixture debt
remain untouched and are not acknowledged by serialized history.

### Parent saga-bound metadata verification and independent review

Two-source binary diff against aa27603 SHA256:
a7a5f0b9ce6b927ef59c1833d7fe15a31568c164080862dfa22c046d43e6db06.
Initial focused47/1 artifact1213 preserved: replacement prefix validation leaked a codec
byte-limit error before normalized encoding. Parent moved wrapped replacement encoding
before prefix validation, preserving both quota denial and invalidHistory contract.
Final focused47/0 artifact1214 (28 persistence including5 new,19 startup), Product378/0
artifact1220, fresh unsigned native Release arm64/macOS15 BUILD SUCCEEDED artifact1221,
namespace product-native-compile-20261010-ak. Review100 SOURCE-ONLY CLEAR / APPROVE,
no actionable finding. Actual owned-GRDB saga/history/reopen/trigger rollback proof is
metadata only; fixture closures/results are synthetic attestations, not physical ACK.
Ordinary deletion denial and stricter late producer abort remain unchanged; terminal
history is preserved and final deletion still erases Job/journal under existing privacy
contract. No schema/Package/project/policy/lifecycle/copier/profile/selector changes.
No app/helper/SDK/renderer/live/paid/remote/protected trial execution or warning suppression.
Coordinated producer receipt/actor journaling and same-Job Retry remain unfinished.

## Next bounded slice: actual deletion-command history acknowledgment

Baseline e8bf535 preserves real local/HTTPS/validator physical debts; saga metadata
transactions5436b8f remain separate from actual command acknowledgment. Existing
ProductDatabase.beginDeletion changes Paper/saga and active Job rows but does not
append genuine journal revocation. Connect this actual deletion command to genuine
nonNULL history in its existing sole-GRDB transaction, not a second actor/store.

Before changing rows, restore every nonNULL import history using bounded canonical
existing ordinary or exact-existing-saga admission and full captured lineage. NULL
legacy history stays NULL and is not reconstructed. Malformed/type/oversize/stale
history fails the complete command transaction before visibility/saga changes.
After operational deleting/saga and only-running failed/paperDeleting updates,
append .revoke from the restored exact journal under the same writer transaction.
Require exact prior bytes, canonical saga, unchanged capture/facts/used IDs and
typed bounded readback. Revocation preserves already succeeded/failed executions
and original cause; never force every deleting Job to paperDeleting. Valid added
same-snapshot observations are permitted by extends; identical/no-added-event
payloads remain denied. Repeated deletion commands retain the same saga and may
append genuine repeated revocation observations, not Retry or new permits.

Whole-row readbacks permit only existing command changes plus recoveryJournal;
unexpected trigger changes, refused updates or malformed readbacks roll back the
entire transaction. Existing contentless tombstone/final Job erasure, diagnostics,
late producer-abort strict guard and NULL legacy handling remain unchanged.
This command's actual revocation is authority to deny admission, not physical
closure/purge/removal ACK. Actor installation, receipt retention/cleanup and
same-Job Retry remain separately unfinished; do not activate partial cutover.

Writable scope: Infrastructure/ProductDatabase.swift, its ImportRecovery extension,
Tests/Product/ImportRecoveryPersistenceTests.swift and this existing Spec. Parent
owns integration, all gates/review/evidence/commits. Verify real owned-GRDB running,
succeeded and each supported failed cause, repeated saga/reopen, NULL preservation,
canonical bound/full-lineage rejection and ignore/corruption/unrelated-column
trigger whole-command rollback. Run focused persistence/lifecycle/startup coverage
and all Product tests in per-test isolated processes, then fresh unsigned native
compilation; no app/helper/SDK/renderer/live/paid/protected trial or remote action.

### Authored command bridge (parent verification pending)

Authored against committed Spec 8a719c8 following verified implementation e8bf535.
The four-file slice now connects actual `beginDeletion` to genuine durable history
in its existing sole `queue.write`. `boundedDeletionJobs` first performs SQL CASE
type/size admission at the shipped 262144-byte metadata quota, then captures full
rows through the existing deterministic `deletionJobs`; oversized/nonBLOB payloads
are never materialized by the command's full-row query. Finalization and failure
bookkeeping retain their existing full-row capture and erasure contracts.
Every nonNULL history is restored before operational changes. NULL remains NULL.
`readImportRecoveryBeforeDeletion` obtains identity/facts from canonical captured
history, verifies all ten IDs against actual joined rows, and uses ordinary restore
for nondeleting commands. Its narrow existing-saga branch admits only actual
deleting/deletionFailed with canonical matching saga and already-revoked terminal
execution/cause. Public ordinary/deleting guards and fixed seven-cause mapping are
unchanged. Unsupported pending commands and mismatched operational states fail.

`revokeImportRecoveryForBeginDeletion` is a caller-Database-only transition hook:
it validates the exact admitted old BLOB after operational mutations without
pretending that old history was already revoked, records only policy `.revoke`,
requires a genuine immutable extension, and updates by exact bytes, ten-ID lineage
and deleting saga. Typed bounded readback must equal the canonical replacement
and preserve full Paper/Job rows apart from the acknowledged journal column.
The outer command allows journal differences only for returned exact acknowledgments;
all existing running-only failed/paperDeleting and whole-row assertions remain.
Succeeded/previously failed executions retain original state, result and cause;
repeated same-saga/deletionFailed commands append valid same-snapshot observations.
No Retry, permit/operation allocation, physical closure/cleanup/removal acknowledgment,
actor cutover, diagnostic change or new transaction/store is introduced.

Six new command tests cover running plus succeeded/seven fixed causes, retries and
reopen/prefix/exact bytes, NULL legacy preservation, ten captured identity drifts,
corrupt/nonBLOB/oversize/unrevoked prior saga/state/cause rejection, canonical pending
and append-quota rejection, and journal/operational trigger whole-command rollback.
Trigger cases retain complete before/after Paper/Job/provider rows across reopen;
the public command has no caller transaction hook, so no provider marker mutation
is fabricated. Existing manual-revoke metadata fixtures remain unchanged and
synthetic terminal observations never assert physical ACK. Final deletion still
erases importJob/full history and leaves only the existing contentless tombstone.

No test/build/lint/formatter/commit was run in this authoring lane. Parent owns
focused persistence/lifecycle/startup checks, isolated Product gates, fresh unsigned
native compilation and review. Producer/actor receipt ownership and same-Job Retry
remain unfinished; this bridge is actual durable admission revocation only.

### Parent actual-command verification and independent review

Initial affected88 run artifact1251 failed two test methods: the new fixture used
forbidden terminate(.paperDeleting), and the older diagnostic fixture treated an
opaque BLOB sentinel as eligible history. The former now obtains paperDeleting
through actual beginDeletion plus exact deleting restore. The latter now asserts
whole-command corruption denial and unchanged rows/opaque bytes, then restores
the originallyNULL owned legacy fixture and verifies diagnostic ownership/reopen.
No policy relaxation, decoder fallback, skipped test or invented history was added.
The directly affected LocalLibraryLifecycleTests.swift is a parent-owned fifth
source/spec path; its diagnostic assertions remain covered rather than removed.

Final affected88 passed artifact1253:34 persistence (six new methods),35 lifecycle,
19 startup. All390 Product tests passed artifact1258, with every test invoked by
SwiftPM --parallel --num-workers1 per-test process isolation; no skipped cases,
quota reset or manual-close logical ACK. Fresh unsigned Release arm64/macOS15
native-an BUILD SUCCEEDED artifact1262; app/helper binaries were not executed and
warnings were not suppressed. Review104 SOURCE-ONLY CLEAR / APPROVE, findings empty.
Four-source binary diff against committed Spec8a719c8 SHA256:
`9eeaa211e2506ea22bb19edce9b6059b5ac6679def64d0a25c9c6deb9ddeb793`.
Package/project, policy/journal codec, lifecycle actor/physical roots, diagnostics
schema, paired resource contracts and contentless finalization stay unchanged.
This proves actual durable admission revocation, not producer receipt/actor
cutover, physical closure/purge, same-Job Retry or Story/Epic acceptance.

## Next bounded slice: atomic ordinary import failure acknowledgment

After verified7edb828, reservation/publication/deletion primitives acknowledge
genuine history, but ordinary import failure still lacks an atomic history/row
transition for the future actual producer bridge. Add internal
`recordJournaledImportFailure(expected:replacement:failure:cleanupDebt:)` on the
sole ProductDatabase owner. Fixed ImportAbortFailure cases are cancelled,
sourceChanged, importFailed, urlImportFailed and publicationRejected; each maps
to existing policy .failed, including current cancelled SQL cause mapping.
Startup interruption and paperDeleting stay separate owners, not abort cases.

In one existing adapterWrite transaction, bound and canonically validate expected
and replacement before effects, require exact current nondeleting running capture
and genuine BLOB, strict immutable event prefix, unchanged captured facts/ten IDs,
unchanged usedPermitIDs and retained prior executions/current lineage. Replacement
must terminate the current execution as .failed(.failed); no Retry/new permits or
retrospective legacy admission. A false cleanupDebt input is inadmissible while
replacement still retains permits or namespace-removal debt. Existing Paper debt
must not be cleared. Failure/uncertainty remains deny authority, not physical ACK.

Reuse the existing exact running failure SQL hook (make its private visibility
internal solely for the extension), atomic journal CAS, exact typed bounded
readback and whole-row invariants. Only Paper status/reference/conservative debt,
Job state/fixed failure and recoveryJournal may change; scalar progress/folder/
immutable identities/configuration and unrelated columns remain untouched.
Ignore/corruption/column mutation triggers throw and roll back the whole writer
transaction. Stale expected, NULL, bound/capture/facts/state/permit drift all deny
without effects. Ordinary and deleting APIs remain distinct; deleting late abort
retains its stricter failed/paperDeleting contract and is not expanded here.

This is an independently verified long-term transaction boundary, not production
actor cutover or synthetic physical receipt authority. Actual owner observation,
cleanup acknowledgment and fresh same-Job Retry remain unfinished. Writable scope:
ProductDatabase.swift, its ImportRecovery extension, ImportRecoveryPersistenceTests
and this existing Spec. Parent owns all gates/review/evidence/commits. Test real
owned-GRDB five causes, unknown/retained and synthetic known-clean observations,
existing debt preservation/reopen, stale and all full-lineage/state/payload/quota
denials, and whole-row ignore/corrupt/marker rollback. All Product tests execute
in isolated per-test processes; no skip/reset/ACK, live/SDK/helper/renderer/trial,
user document/credential access, remote or release action is admitted.

### Authored ordinary-failure boundary after committed Spec ed673b5

The four permitted integration files now author the bounded ordinary failure
transaction. This is source-only implementation evidence; no tests, builds,
gates, formatter, review or commit were run by the executor. Parent verification
must retain every existing Product test and use isolated per-test SwiftPM
processes with `--parallel --num-workers 1`, without skip/reset/physical ACK.

Internal `ImportAbortFailure: String, Sendable` admits exactly cancelled,
sourceChanged, importFailed, urlImportFailed and publicationRejected. Its raw
values are the existing SQL causes; every admitted replacement must end as
policy `.failed(.failed)`, including cancelled. Interrupted and paperDeleting
remain excluded owners. `failRunningImport` changes visibility only: its exact
running guard and SQL body and every legacy caller remain unchanged.

`recordJournaledImportFailure(expected:replacement:failure:cleanupDebt:)` uses
one sole-owner adapterWrite transaction. Before SQL effects it validates the
positive existing 262144-byte budget, typed/canonical expected bytes, canonical
replacement, strict event prefix, full ten-ID capture/facts, unchanged prior
executions/current lineage/dispatch/result/usableResult and usedPermitIDs.
Current genuine non-NULL history must match the expected BLOB on a nondeleting
running row. Ordinary journal CAS runs before the reused running failure hook;
both are read back with exact fixed cause, typed history and whole-row checks.
Only Paper status/pdfReference/conservative cleanupDebt and Job state/failure/
recoveryJournal can change. Existing Paper debt is OR-preserved, incoming true
is conservative, and false rejects retained permits or namespace-removal debt.
Folder membership is compared within the same transaction. An exact four-write
SQLite total_changes delta (journal CAS, Paper failure, Job failure and the existing
mandatory revokeReaderPosition trigger's Paper UPDATE) additionally
checks the expected write count, but is not row-scope authority: compensating
RAISE(IGNORE) triggers can substitute a foreign write for the reader UPDATE.
Transaction-local row-scope observation described below rejects those substitutions
without materializing unrelated journal payloads.
Snapshot/debt bytes never close a writer, purge bytes or grant physical authority.

Authored owned-GRDB test names:
- `testOrdinaryJournaledFailureFiveFixedCausesRetainUnknownPermitAndReopenExactRows`
- `testOrdinaryJournaledFailureSyntheticCleanAllowsFalseButPreservesExistingDebt`
- `testOrdinaryJournaledFailureRejectsExpectedBytesPrefixCapturePolicyPermitRetryAndQuotaBeforeEffects`
- `testOrdinaryJournaledFailureRejectsLegacyNullStoredPayloadAndOperationalCaptureDrift`
- `testOrdinaryJournaledFailureTriggerMutationsRollBackActualWriterAndProviderMarker`
- `testOrdinaryJournaledFailureUnrelatedRowMutationWithoutMarkerIsRejected`
- `testOrdinaryJournaledFailureCompensatingReaderTriggerCannotSubstituteForeignWrites`
- `testOrdinaryJournaledFailureWithoutRowIDSchemaDeniesCompensatingAndUntriggeredWrites`
- `testOrdinaryJournaledFailureShadowTriggerDefinitionDeniedAndCanonicalSchemaAdmitted`

These fixtures reserve genuine new journals with fresh captures. Closed/unvalidated
writer and successful cleanup observations are explicitly SYNTHETIC policy data,
not physical receipts; unknown retained permits still require debt. Triggers
place providerConfig rollback markers inside the actual method transaction,
without nesting its queue writer. Existing tests remain unchanged and present.

Actual lifecycle producer/actor cutover, independently observed physical closure,
cleanup receipt reconciliation, namespace purge and fresh same-Job Retry remain
unfinished. Publication is not an abort; deleting late abort stays outside this
slice. No production activation, Story/Epic acceptance, physical cleanup, permanent
journal retention or SameJobRetry completion is claimed.

Parent focused94 run artifact1267 reported two authored test failures:
`testOrdinaryJournaledFailureFiveFixedCausesRetainUnknownPermitAndReopenExactRows`
and `testOrdinaryJournaledFailureSyntheticCleanAllowsFalseButPreservesExistingDebt`.
Both reported generic invalidHistory. Source diagnosis identified the original
three-write counter as incorrect: the shipped revokeReaderPosition trigger always
updates Paper reader fields to NULL/0 on this non-ready status transition, even
when already unchanged. The exact counter is corrected to four; all reader-field
whole-row invariants and rejection of additional trigger writes remain enforced.
The synthetic cleanup sequence, permit/debt constraints and existing SQL hook are
unchanged. No executor reproduction/gate was run; parent must verify both failures
and retained adversarial rollback coverage after this correction.

Review106 P1 identified an exact-count bypass: a BEFORE UPDATE OF readerSequence
trigger can write an unrelated Paper/providerConfig then RAISE(IGNORE), leaving
four writes and unchanged target rows. The bounded correction registers a public
GRDB TransactionObserver with `.nextTransaction` after exact canonical capture/
running-row validation and before effects. It admits actual UPDATE events only
on the captured main.paper/main.importJob SQLite rowids. Every observed insert,
delete, foreign row/table/database event or unspecified change flags denial.
The flag is checked before returning and again in databaseWillCommit; GRDB keeps
a strong reference until actual commit/rollback, including buffered savepoint
events. Existing four-write, whole-row/folder and exact readback checks remain.
main.schema_version and database_list are compared before/after effects.

Pinned public source inspected: GRDB/Core/TransactionObserver.swift defines
databaseEventObservationStrategy, event databaseName/tableName/rowID, commit veto
and `.nextTransaction` strong retention/release. Setting requiresDatabaseEventKind
false observes universal events and prevents truncate optimization on all tables;
registration also clears cached delete statements. No SQLite hook/authorizer is
replaced and the shipped reader trigger is not disabled.

The pinned Documentation.docc/Extension/TransactionObserver.md explicitly excludes
schema/internal-table events, WITHOUT ROWID writes and implicit REPLACE deletions.
WITHOUT ROWID user tables are now denied before effects by the schema admission
guard below, rather than admitted with an observation exclusion. No guarantee for
arbitrary invisible C/internal-schema effects or implicit REPLACE deletions is
claimed; schema checks are additional checks, not an observer expansion. The actual
bounded SQL uses GRDB UPDATEs on rowid tables and SQL triggers (which cannot issue
schema DDL). This correction covers their observable main-rowid write scope.

The new owned synthetic regression substitutes exactly one unrelated Paper update,
providerConfig update, Paper deletion/insertion or truncate-style libraryFolder
deletion for the ignored reader UPDATE. It adds no extra provider marker and
requires whole rollback/reopen of all fixture rows and exact journal bytes.
No executor tests/build/gates/formatter/commit were run; parent verifies the new
regression, all retained authored/legacy tests and observer commit behavior.

Review106 second P1 demonstrated the same substitution with an observer-invisible
WITHOUT ROWID UPDATE. Before registering observation or issuing any SQL effects,
the method now reads public `PRAGMA table_list` schema/name/type/wr metadata only.
Every row must provide typed text schema/name/type and INTEGER wr in {0,1}; missing
wr, empty results, unknown types or unlisted admitted databases deny. Any user table
with wr=1 in main, temp or attached databases denies the transaction. This is an
observer-coverage prerequisite, not a physical profile, new store or payload scan.
Canonical rowid schemas retain the same observer/four-write/whole-row/folder and
schema-version/database-list checks. No private hook fallback is introduced.

Canonical FTS5 generates WITHOUT ROWID shadow tables, so type=shadow is not blanket
schema denial. Instead every listed shadow table name (case-normalized across all
databases) enters a second `.nextTransaction` public TransactionObserver using
GRDB's default event-kind strategy. Pinned TransactionObserver.swift:1040-1080
invokes observes(eventsOfKind:) over compiled statement.authorizerEventKinds,
including trigger side effects before execution. Any potential shadow-table write
flags denial, checked before return and in databaseWillCommit. This conservatively
rejects even conditional compiled shadow writes; it does not depend on invisible
WR row callbacks. Primary universal exact-row observation remains unchanged.
Parent agreed to this bounded public-observer correction after source inspection.

Parent affected97 run artifact1281 failed only the attempted shadow-trigger fixture:
SQLite denied CREATE TRIGGER with SQLITE_ERROR and `may not write to shadow table
extractionFTS_config`, before the helper executed. The corrected
`testOrdinaryJournaledFailureShadowTriggerDefinitionDeniedAndCanonicalSchemaAdmitted`
asserts that typed actual definition denial, absence of the trigger and unchanged
shadow value/Paper/Job/providerConfig/history across reopen. It then requires an
ordinary journaled failure to succeed with canonical FTS5 shadows still admitted,
preserving shadow/configuration values across another reopen. The existing public
shadow observer remains defense, but this profile's trigger-definition denial is
not evidence that its observer caught a shadow write. No defensive/trusted-schema
or other profile restriction is disabled and no fallback is introduced. This does
not certify all SQLite profiles or extend coverage to arbitrary invisible
C/internal-schema effects or implicit REPLACE. No executor gates were run; parent
verifies the corrected regression and retained user-WR before-effects denial.

The owned synthetic regression
`testOrdinaryJournaledFailureWithoutRowIDSchemaDeniesCompensatingAndUntriggeredWrites`
checks both a preexisting untriggered WR table and its compensating reader trigger
(UPDATE WR then RAISE(IGNORE), with no extra provider marker). Both must deny before
effects and reopen with unchanged WR value, original Paper/Job/providerConfig rows
and exact history. No executor tests/build/gates/formatter/commit were run; parent
owns runtime verification and narrow review. Arbitrary invisible C/internal-schema
side effects remain outside the claimed public-observer coverage.

### Parent ordinary-failure verification and independent review

Nine new persistence methods (six initial plus three write-coverage regressions)
were executed, not skipped. Initial affected94 artifact1267 failed two methods
because the three-write count omitted the mandatory reader revoke UPDATE. After
the four-write correction affected94 passed1269, Product396 passed1272 and unsigned
native-ao succeeded1275. Review106 P1 compensated-rowid substitution then required
the retained exact-row observer; affected95 passed1278. Its second P1 invisible
user-WR substitution required enforced typed schema admission and shadow defense.
Affected97 artifact1281 failed the assumption that SQLite would create a shadow
trigger; the fixture instead now proves actual typed definition denial without
relaxing SQLite configuration. Artifact1282 preserved one exact-message assertion
failure; parent matched the observed quoted `"extractionFTS_config"` spelling.

Final affected97 all passed1283 (43 persistence,35 lifecycle,19 startup). Every399
Product case passed1285 in --parallel --num-workers1 per-test process isolation;
no skipped cases, pool reset or manual FD logical ACK. Fresh unsigned Release
arm64/macOS15 native-ap BUILD SUCCEEDED1286, warnings retained and no app/helper
binary execution. Final narrow Review106 SOURCE-ONLY CLEAR / APPROVE, findings
empty; both P1 substitutions resolved within public GRDB coverage and enforced
schema boundaries. Shadow-definition denial is not an observer callback proof.
Three-source binary diff against Speced673b5 SHA256:
`6fb3fd3b0d6a64195527d65551facd535ad9bef3c363abc9b2a805ab667f55cb`.
Package/project, reader trigger, policy/codec, lifecycle and physical owners remain
unchanged. This is real GRDB metadata failure acknowledgment; producer observations,
actual actor cutover/cleanup, same-Job Retry and Story/Epic acceptance remain open.

## Next bounded slice: deleting late-producer abort history acknowledgment

Verifieda760a9f supplies ordinary failure acknowledgment; the future actual owner
also needs a separate late-abort transaction after actual beginDeletion revocation.
Add internal `recordJournaledDeletingImportAbort(expected:replacement:saga:
cleanupDebt:)` on the existing sole GRDB owner. No generic failure fallback:
require actual Paper.deleting, exact canonical saga, full ten captured identities,
genuine bounded revoked history and actual Job.failed/paperDeleting. Succeeded
or previously failed deleting histories stay eligible only for existing metadata
helpers, not this specifically late-producer API. No new failure cause argument.

Validate exact canonical expected BLOB, strict immutable event extension, unchanged
capture/facts/executions/usedPermitIDs and revoked replacement before effects.
No Retry/new permit/result/config or new current execution. Owner observations
remain independent authority; encoding cannot infer closure. False cleanupDebt
requires no retained permits/removal debt; true is conservative. Existing Paper
debt is OR-preserved, never cleared. Preserve status/saga/generation/reference,
Job cause/state, counters/folder and every unrelated row/column.

In one adapterWrite, reuse separate deleting CAS plus exact-saga debt-only update
when needed, typed bounded readback and whole-row comparisons. Reuse existing
public transaction write-scope/schema/shadow guards from the ordinary failure
boundary rather than parallel hooks; capture only exact target rows. Preserve
the mandatory reader trigger and validate actual write count for this debt-only
operation without assuming a status-trigger write. Refusal, corruption, trigger
substitution or stale lineage propagates and rolls back the whole transaction.
NULL legacy is ineligible; no retrospective reconstruction, new store, physical
cleanup/purge ACK, actor activation or permanent tombstoned journal retention.

Writable scope: ImportRecovery extension, ImportRecoveryPersistenceTests and this
Spec. Parent owns all gates/review/evidence/commits. Test actual beginDeletion from
genuine running journal, synthetic unknown/known-clean observations, monotonic
debt/repeated valid prefix/reopen, strict denial of successful/previously failed
rows, wrong saga/full identity/status/cause/NULL/type/bounds/prefix/Retry and real
owned-GRDB ignore/corrupt/foreign-write whole rollback. All tests remain invoked
in per-test isolated processes; no quota reset/fake ACK, SDK/app/helper/renderer,
live/paid/protected trial/user document/credential/remote/release action admitted.

### Deleting late-producer abort implementation (source-only, parent verification pending)

Implemented internal sole-owner API
`ProductDatabase.recordJournaledDeletingImportAbort(expected: ImportRecoveryRecord,
replacement: ImportRecoveryJournal, saga: UUID, cleanupDebt: Bool) throws -> ImportRecoveryRecord`
in `PaperLensApp/Infrastructure/ProductDatabase+ImportRecovery.swift`. Actual
Paper.deleting / exact canonical saga, ten canonical captured UUIDs (including
generation and ownership), exact bounded canonical expected BLOB and genuine
revoked Job.failed/paperDeleting history are prerequisites. Earlier success or
original failure causes are still valid for existing deleting metadata helpers,
never for this API. No failure argument, generic-cause fallback, legacy backfill,
selector/store/transaction/cache/root or ordinary-abort caller changes.

The late acknowledgment is a strict immutable extension preserving capture/facts,
authority, complete executions, usableResult, usedPermitIDs, revoked status and
namespace state. Parent-directed narrow admission also preserves usedOperationIDs:
new cleanup/removal operation requests belong to the separate existing deleting
metadata CAS boundary, not this late-producer acknowledgment. Completion and release
of an already-recorded cleanup operation are policy-validated observations. Tests
first record the synthetic closure/request using deleting CAS, then acknowledge
completion/release here. This restriction avoids new codec/event accessors and
avoids separate JSON-tag parsing; exactly the original three paths remain writable.
Unknown retained permits require requested true debt; false requires no retained
permits, pending removal or removal debt. Existing Paper debt is always OR-preserved.
These typed observations remain METADATA, not physical closure or cleanup ACKs.

One existing adapterWrite performs deleting CAS followed only by an optional
exact-saga/full-identity debt-only 0->1 UPDATE. An unchanged debt avoids UPDATE.
Paper status/saga/generation/reference and all other fields, Job failed/paperDeleting
and all other fields except journal, counters and folder remain exact. Bounded
typed readback and full-row comparisons are required. Actual write count is one
CAS plus optionally one debt UPDATE (1/2), not ordinary failure's four writes:
the debt-only UPDATE does not fire the mandatory Reader status trigger. Count is
additional detection, never independent authority. Existing rowid/main exact-target
write-scope and public shadow-potential observers are both retained `.nextTransaction`,
validated before return and veto actual commit. Ordinary schema admission is narrowly
factored, not weakened: user WITHOUT ROWID tables deny before effects; canonical FTS
shadows are admitted while potential shadow writes remain vetoed. Schema/database-list
stability is checked. Ignore/corruption/foreign writes and write-restore substitutions
throw and roll back the actual writer, including trigger-issued provider markers.

Added methods in `Tests/Product/ImportRecoveryPersistenceTests.swift`:
- `testDeletingLateAbortUnknownPermitDebtAndRepeatedObservationsReopenExactHistory`
- `testDeletingLateAbortExistingCleanupCompletionAllowsFalseAndNeverClearsDebt`
- `testDeletingLateAbortRejectsEarlierSuccessAndFailureEvenWithValidRevokedMetadata`
- `testDeletingLateAbortRejectsExpectedEncodingCaptureDivergenceRetryNewOperationsAndQuota`
- `testDeletingLateAbortRejectsActualSagaAllTenIdentitiesStatesCausesAndPayloads`
- `testDeletingLateAbortTriggerIgnoreCorruptionForeignWritesAndRestoreRollBackActualWriter`
- `testDeletingLateAbortUserWithoutRowIDSchemaDeniedBeforeAnyEffects`
- `testDeletingLateAbortLegacyNullNeverReconstructsAndPositiveBoundsPrecedeSQL`

Fixtures use actual reserveJournaledImport -> actual beginDeletion -> readDeleting
baseline. Unknown/repeated/clean observations are explicitly synthetic metadata.
Tests cover true/false monotonic debt and no-unneeded-debt-write, prefix/reopen,
terminal history exclusion, canonical saga and all ten identities including rebound,
state/cause/type/NULL/oversize/noncanonical/noop/stale/divergence/facts and policy-denied
Retry/new grant/result/dispatch, unchanged positive shipped 262144-byte bound,
actual writer trigger marker/ignore/corrupt/debt/foreign row/folder/provider/counter
and write-restore rollback. Existing tests are retained, including finalization
contentless erasure (DELETE importJob), ordinary failure/schema/shadow coverage.

No tests/build/gates/lint/formatter/commit/remote actions run by this implementation
lane; parent owns every runtime verification, review, evidence and commit. No claim
of actual physical ACK, full actor cutover, unfinished physical cleanup completion,
Same-Job Retry, Story/Epic acceptance or end-to-end product completion. Actual
producer owners must independently admit observations and execute physical cleanup;
future actor receipt journaling/caller cutover remains a separate boundary.

Quota-fixture follow-up (source-only): parent affected105 run1290 timed out after
300 seconds with last progress15; this is incomplete, not verification. Parent
reports targeted pgrep found no remaining owned XCTest process. The new quota
method previously replayed/encoded every growing repeated-revoke prefix. It now
uses the existing bounded raw-fixture pattern: encode one typed revoke, derive
the positive canonical increment, calculate a finite repeat count (at most
262145), append that genuine event using sorted-key JSON, and decode/encode the
complete oversized history once with maximumInt. Exact canonical bytes and size
are asserted; the fixture exceeds 262144 by at most one event increment. No quota
weakening, skipped case, production codec change or timeout increase.

Source inspection of `testDeletingLateAbortRejectsEarlierSuccessAndFailureEvenWithValidRevokedMetadata`
and its fixture/readDeleting/casDeleting paths found sequential adapterRead and
adapterWrite calls, not nested adapter access. Thus progress15 is consistent with
the subsequent quadratic quota fixture, not evidence of a nested-access deadlock.
No follow-up gate/build/test/formatter/commit run in this lane; parent verification
remains pending and run1290 remains recorded as timed out.

### Parent strict late-abort verification and independent review

After bounded quota-fixture correction, all105 affected cases passed1291:
51 persistence (eight new methods),35 lifecycle and19 startup. Every407 Product
case passed1300 using --parallel --num-workers1 per-test process isolation; no
skipped cases, quota reset or manual FD logical ACK. Fresh unsigned Release
arm64/macOS15 native-aq BUILD SUCCEEDED1302, warnings retained, no app/helper
binary execution. Review108 SOURCE-ONLY CLEAR / APPROVE, no actionable findings.
The timed-out1290 receipt and its owned fixture are preserved; timeout is not a
pass and no protected trial was repeated or expanded. Two-source binary diff
against Spec0605dc0 SHA256:
`524308ffcfd3663d3f9ff241f2a71f858f0a6211a2325bb55c1253177a222b3c`.
Main legacy late-abort guard/finalization, Reader trigger, Package/project,
policy/codec/lifecycle/physical roots and paired resource contracts stay unchanged.
Actual producer observation, journaled actor caller cutover/cleanup, same-Job Retry
and canonical Story/Epic acceptance remain unfinished; metadata cannot ACK them.

## Next actual owner slice: explicit local copier completion

After verified7fe4daa, LocalLibraryLifecycle still infers physical close from
`error != producerClosureUnknown` and emits validated writer closure before checking
the confirmed expectedSHA256. Replace that inference with a private nonserialized,
identity-correlated completion issued only by the actual copying operation:
never-started before acquisition, closed-unvalidated with original work error,
closed-validated with actual sealed stage/SHA/positive copied bytes, or unknown.
The copying operation returns an explicit outcome on every path rather than a
digest-or-throw contract. Closed outcomes require both actual endpoints known
closed or never acquired, original scope/lease release and producer quiescence;
unknown retains original roots/FDs/quota/scope/stage and outranks work failure.
Do not add ARC/probe/close retry/manual ACK or infer closure from serialized bytes.

Validate the confirmed expectedSHA256 before issuing the validated completion.
The actual actor consumes this completion for its existing policy/cleanup path;
pre-producer command failure is distinguishable from a started operation without
a completion, which must fail closed. Later publication errors cannot overwrite
known actual copier completion or erase genuine unknown debt. Preserve original
work errors even when their enum label happens to be producerClosureUnknown; the
label alone is not a physical close attestation. No guessed successful defaults.

For owned-input proof only, add immutable read-only completion observations to
the explicit existing ActualCopyEffects fixture instrumentation; production and
its sole owned-effects test constructor bind explicitly, no default fake-closed
flag or compatibility overload. Observation callbacks grant no authority and
cannot replace the private completion. Tests verify once-close/census/pool/scope,
work-error label ambiguity with known endpoints, hash mismatch never validated,
success actual SHA/bytes/identity and unchanged unknown-root preservation.
Writable scope: LocalLibraryLifecycle.swift, LocalLibraryLifecycleTests.swift and
this existing Spec. Parent owns gates/review/evidence/commits; all Product cases
run per-test isolated without skip/reset/manual ACK. URL writer/adapter, GRDB,
journal/policy/schema/membership/contracts remain unchanged. No full journaled
actor cutover, same-Job Retry, SDK/live/helper/renderer/trial/user-doc/credential,
remote/release or Story acceptance is admitted by this bounded physical slice.

### Explicit actual copier completion — source implementation, verification pending

This bounded three-file change implements the above owner slice after Spec1e94cc4;
it does not extend the prior407/native-aq receipts to the changed source. Parent
owns all builds, tests, review and commits. No test/build/gate/lint/formatter,
commit, remote, workflow, live/SDK/helper/renderer or protected trial ran in this
implementation lane.

`copyValidatedPDF(source:stage:identity:database:cancellation:effects:expectedSHA256:)`
now returns nonthrowing private `ActualCopyCompletion`, with the full ten-field
ImportIdentity and private nonserialized Outcome:
`neverStarted(any Error)`, `closedUnvalidated(any Error)`,
`closedValidated(ActualClosedImportStage)`, or `unknown(ActualCopyOwner)`.
The private stage contains the actual file URL, SHA256 and positive Int64 bytes.
Only the actual copier's local completion factory constructs these completions;
no public constructor, encoded receipt, success default or observer authority is
introduced. Before acquisition, cancellation/path/provider/pool failures return
neverStarted. Once rooted, body errors preserve their original Error independently
of its enum label. Original output-then-input checked close runs once per acquired
endpoint. Any uncertain close retains the original owner and permanent debt with
FDs, lease, scope and stage, outranking body failure. Known endpoints release the
actual scope and lease outside arbitration before reporting. Confirmed SHA is
checked inside the copier before closedValidated; mismatch is closedUnvalidated
with sourceChanged. Post-close cancellation is unvalidated with cancelled.

The actor records its producer invocation gate, awaits the nonthrowing detached
producer through its cancellation handler, and correlates all identity fields
before any completion-driven policy transition. Only closedValidated authorizes
the existing validated writer closure and publication of that same actual stage.
Catch cleanup uses the correlated completion, or the fact that no producer was
invoked; a started operation without matching completion remains unknown. Later
policy/publication errors cannot replace physical proof. Producer drains finish
only after the awaited copier has returned. URL sticky uncertainty, original
physical copy guards/progress/close ordering, GRDB and journal activation remain
unchanged.

Mandatory `ActualCopyEffects.completed` is bound explicitly by production and the
existing sole OwnedCopyEffects constructor. It receives immutable read-only
ActualCopyCompletionObservation(identity/status/error/optional SHA256/bytes), once
per actual completion after release or retained-debt settlement. Fixture-only
descriptor probes and pre-close fstat record timing, sealing and byte size; they
do not authorize any runtime closure, retry or logical ACK. No global observation
store or permanent known-completion registry is added.

Authored tests (not run here): new
`testActualBodyClosureUnknownLabelDoesNotOverrideKnownPhysicalClosure` injects the
unchanged producerClosureUnknown error before output open, asserting original
error observation, once-closed real input, released pool/scope, no namespace or
FD debt, failed actual Paper/Job and clean reopen. New
`testActualConfirmedHashMismatchClosesButNeverValidates` asserts real sealed-copy
size, both actual closes before the unvalidated/sourceChanged observation, no
Ready/hash/reference/debt, same failed identity/Job and clean reopen. Strengthened
`testActualCopyCheckedEndpointCensusAndScopePoolRelease` checks one correlated
validated completion, exact actual SHA/bytes, close-before-callback, immutable
independent file and actual GRDB reopen. Existing full/partial unknown FD cases
now assert exactly one unknown observation after facade loss, unchanged retained
scope/pool/namespace and original permanent obligations; no additional unknown
fixture is created. Malformed path and capacity tests assert neverStarted;
existing output-open/cancel/once-close/delete coverage remains.

Parent verification remains required with --parallel --num-workers1 and no skip,
reset or manual ACK. This is physical local copier completion only, not whole
actor journaling, same-Job Retry, Story acceptance or a product/profile claim.

### Parent actual copier completion verification

Affected121 all passed1310 (37 lifecycle including two new methods,51 persistence,
19 folder,14 URL writer); every409 Product case passed1316 in per-test isolated
--parallel --num-workers1 processes. No skipped tests, quota reset or manual FD
logical ACK; original unknown fixtures remain invoked with no added debt fixture.
Fresh unsigned Release arm64/macOS15 native-ar BUILD SUCCEEDED1317, warnings
retained and app/helper binaries not executed. Review110 SOURCE-ONLY CLEAR /
APPROVE, no findings, for actual physical completion prerequisite only.
Two-source binary diff against Spec1e94cc4 SHA256:
`4cf7d54eac337ae0d49c7bb9f103a5fa5c60c63149f6ec58f4d9ddd8d7e8d0a5`.
GRDB/journal/policy/URL writer/adapter/schema/membership/paired contracts remain
unchanged. Actual completion is not serialized read/cleanup/publication authority;
whole journaled actor cutover and same-Job Retry/Story acceptance remain unfinished.

## Next actual cleanup slice: checked namespace absence

Verified96906de supplies correlated physical copier completion. The actual shared
removeNamespace helper still equates FileManager.fileExists=false with absence,
which conflates ENOENT with inaccessible/malformed paths and can manufacture
successful cleanup/deletion. Replace the boolean probe with checked Darwin.lstat
before and after actual removal. Validate file URL/absolute fully decoded path/no
NUL/nonNULL representation; capture errno immediately. Only exact ENOENT is absence.
EACCES/EPERM/ENOTDIR and other errors deny with cleanupFailed; do not repair runtime
permissions, follow an unexpected symlink or erase a foreign non-directory entry.
Existing directory removal remains real owned FileManager removal; afterwards
require checked ENOENT, never suppress a removal error or use ARC/descriptor probes
as cleanup ACK. Preserve original producer/reader/Agent drain and policy admission.

This is pathname absence evidence for the existing private namespace, not same-UID
race/ABA/isolation or Agent-purge proof. Do not add a guessed profile, new owner/store,
clock/pool/protocol or fake-success default. Tests use actual owned temporary PDFs
and namespaces: normal removal/contentless finalization, already-absent idempotence,
inaccessible ancestor (positive lstat EACCES/EPERM before command), unexpected
namespace symlink preserving target bytes, and non-directory obstruction. A denied
command must retain deleting failure/cleanup obligation and actual bytes across
reopen, never finalize a tombstone. Restoring permissions only for the owned fixture
in teardown is not runtime permission repair or closure ACK. Skip no cases/reset.
Writable scope: LocalLibraryLifecycle.swift, LocalLibraryLifecycleTests.swift and
this existing Spec. Parent all gates/review/evidence/commits; all Product cases
remain isolated per test. No URL/DB/journal/policy/schema/membership/contract change,
full actor cutover/Retry/Story acceptance, live/SDK/helper/renderer/paid/protected
trial/user document/credential/remote/release execution is admitted.

### Checked namespace absence implementation (parent verification pending)

The shared production removeNamespace now calls checkedNamespace before removal
and after a successful real FileManager.removeItem. The checked helper validates
a file URL, its fully decoded absolute path without NUL, and a nonnil C filesystem
representation; Darwin.lstat is immediately followed by errno capture. Only
result -1 with ENOENT yields absence. EACCES, EPERM, ENOTDIR and every other failed
probe throw LocalLibraryError.cleanupFailed. Directory spelling's trailing
separators are removed for the probe so lstat cannot follow the final namespace
symlink merely because the URL carries isDirectory=true. Present entries must be
actual directories owned by getuid() with exact private mode 0700, matching the
existing namespace creation mode; unexpected links/files/modes/owners are denied
before erasure. Actual removal errors propagate without suppression. No boolean
fileExists result supplies either cleanup acknowledgment.

Four added owned-fixture cases:
- testInaccessibleNamespaceAncestorCannotProveAbsenceOrFinalizeDeletion
- testSymlinkNamespaceDeniesDeletionAndPreservesOwnedTargetAcrossReopen
- testRegularFileNamespaceDeniesDeletionAndPreservesObstructionAcrossReopen
- testAlreadyAbsentNamespaceFinalizesDeletionOnlyAfterActualENOENT

Each imports a real private synthetic PDF and uses the existing explicit fake
owned Agent fixture, not a certified real Agent purge. Denials assert typed
cleanupFailed, deletionFailed/deletionIncomplete, retained cleanup debt and no
tombstone. All original importJob columns and immutable paper facts remain equal;
only the existing deletion transitions (including clearing pdfReference to make
the paper unopenable) are excluded from the before/after comparison. Rows and
physical bytes/obstructions remain checked after reopening. The non-directory
fixture additionally observes actual child lstat ENOTDIR; the symlink fixture
checks the link itself and the relocated owned PDF target separately. Exact
ENOENT after actual fixture removal admits contentless tombstone finalization and
idempotent deletion across reopen. Existing normal deletion coverage is unchanged.

The chmod-000 case changes only this fixture's owned papers directory, not the
database root, so product.db can record failure. Before delete it requires actual
lstat EACCES/EPERM. A runner that bypasses ancestor search permissions fails that
owned-fixture prerequisite; there is no root fallback or skip. Its scoped fixture
teardown restores the captured original mode even on error, before retained bytes
and reopened rows are inspected. This is not production permission repair.

Implementation is source-only here: no tests, builds, gates, lint, formatter,
commits, workflows, network or binaries were run for this slice. Parent must run
every Product case with --parallel --num-workers1, without skips, reset or manual
ACK, then independent review/native/evidence/commit. Verified96906de actual copier
completion, physical drains, policy admission and permanent unknown/once-close
semantics are unchanged; no new FD/lease/pool debt fixture was added. The proof is
absence of one private pathname only, not same-UID race/ABA protection,
inode-global closure, Agent purge, whole journaling, same-Job Retry or Story
acceptance. Writable changes remain exactly the helper source, its lifecycle
tests and this existing Spec.

### Parent checked namespace verification

All82 affected cases passed1319 (41 lifecycle with four new methods,14 URLwriter,
19 folder,8 read-lease). Every413 Product case passed1323 in per-test isolated
--parallel --num-workers1 processes, no skipped test/quota reset/manual logical
ACK. Actual EACCES/EPERM, symlink/non-directory preservation, checked ENOENT and
durable denial/finalization across reopen were exercised on owned fixtures.
Fresh unsigned Release arm64/macOS15 native-as BUILD SUCCEEDED1324; warnings
retained, app/helper binaries not executed. Review112 SOURCE-ONLY CLEAR / APPROVE,
no findings. Two-source binary diff against Spece651acb SHA256:
`c1a6f4984fae7caf4cf338569693b0e8e98c6a030601790a376449c1e1f6a915`.
URL/DB/journal/policy/schema/membership/paired contracts and actual copier
completion stay unchanged. This proves only checked private-path cleanup; actor
journal/Retry, same-UID isolation/ABA, production Agent purge and Story acceptance
remain unfinished and unclaimed.

## Coordinated local/URL owner-to-journal cutover

After verifiedc3b1abc, consume the existing contract92 (not a renewed audit) using
the implemented sole-GRDB reservation/append/publication/failure/deletion primitives,
actual local copier completion96906de, checked namespace absencec3b1abc, and actual
HTTPS/validation lifetime roots90b7189/e8bf535. Implement local and URL cutover
together: no optional journal, missing-history memory-success fallback, separate
policy machine or partial production activation. Same-Job Retry remains separate.
The current fixed ordinary failure mapping in a760a9f (.failed for cancelled too)
overrides the older advisory contract92 mapping; strict deleting late abort remains
failed/paperDeleting and usedOperationIDs-preserving7fe4daa. Contentless tombstone
and final importJob/history deletion remain the privacy contract.

Replace mutable snapshots/synchronous apply with acknowledged ImportRecoveryRecord
captures and snapshot derivation. Per-Paper FIFO transition admission spans detached
database work through committed record installation, never producer/network/copy
or drain waits. Immediate cancellation/read revocation does not wait for that gate;
subsequent transitions queue. SQL/FS remain offactor and MainActor reader callbacks
remain outside all database/registry arbitration. Never install an older callback
over a newer acknowledged record or use serialized history as read authority.

Reservation captures explicit SHA/folder facts and commits reserveJournaledImport
before source/scope/namespace/network effects. Actual producer rooting/start gate
and durable writer-open acknowledgment precede effects. Local actual completion
and URL actual file-close plus final network-drain plus validation-close receipt
are independently retained in their existing physical roots until exact durable
acknowledgment. Unknown original FD/scope/lease/stage obligations remain permanent.
Do not infer either URL closure from reason enums or task terminal status; existing
sticky publication uncertainty remains irreversible. Receipt callbacks/UUIDs and
memory stages are fencing data, not manufactured authorization. No second pool,
budget/selector/database or permanent registry for acknowledged known receipts.

Publication records real closed-validated observation, acquires publication and
records rename admission before physical move. Reuse publishJournaledImport for
actual move plus success suffix/SQL/readback in one writer transaction. Parent
removes obsolete reserveImport and updates owned legacy fixtures to explicit
NULL-history inserts through existing adapterWrite/insertImport; no compatibility
alias. Actual publication receipts must distinguish move/commit outcome: SQL rollback
cannot undo move. Retain bytes and actual receipt on failed acknowledgment; verify
exact committed ready/current-history state before cleanup. Late cancellation never
rewrites committed success; independently admitted Delete still fences/drains.

Abort consumes actual correlated producer completion. Ordinary running failure uses
recordJournaledImportFailure; deleting late abort uses its exact saga and strict
paperDeleting-only primitive, never rewrites retained success/original failure.
Persist fresh cleanup request before actual removal; persist matching completion
and release only afterwards. New cleanup operations enter existing separate deleting
CAS before the strict late-abort completion boundary. Unknown prohibits cleanup,
release and removal. Failures to persist are surfaced and retain actual receipt/
obligation; no try?-discard of operational journal writes or fake restored ACK.

Deletion returns acknowledged durable capture or explicitly legacy NULL history
without reconstruction. Current/previous genuine capture/saga is restored, not
re-created from row values. Persist cleanup/removal admissions before effects and
actual completion afterwards. Add exact finalization transaction that validates
and appends successful namespaceRemovalFinished, bounded readback, then performs
existing terminal cascade/tombstone/importJob erasure atomically. Do not permanently
retain full journal or turn earlier terminal execution into paperDeleting. Legacy
deletion remains explicitly non-retryable as Import, with actual existing drains
and no fabricated history. Agent:nil still denies successful deletion truthfully.

Before every new physical admission, pre-encode correlated success/abort/deletion
terminal branches and preserve terminal headroom under the existing262144 serialized
metadata quota. Exhaustion denies new work but cannot erase outstanding physical
obligations or receipts. No new allocator/RSS/enforcement profile or history pruning.
Existing public signatures and caller-confirmed input stay intact. No production
SDK/live/paid/helper/renderer/trial execution, old credentials/CODEX_HOME/user PDF,
remote/release/migration permission relaxation or Story acceptance is included.

Implementation lane owns exactly five source files: LocalLibraryLifecycle.swift,
LibraryURLImportWriter.swift, HTTPSPDFImportAdapter.swift, ProductDatabase.swift and
ProductDatabase+ImportRecovery.swift. Parent owns this Spec, membership if needed,
all directly affected tests/legacy fixture updates, gates/review/evidence/commits.
No new source file or abstraction outside these existing owners. Keep working
imports end to end; deliver coherent local+URL+failure+deletion cutover, not stubs.
Parent verifies actual owned local and URLProtocol flows, every existing Product
case in per-test isolated processes, durable reopen/startup/legacy ineligibility,
cancel/delete both race orders, failed close/rename/CAS/finalization receipts,
immutable prefixes/fresh identity denial, false cleanup/absence and no resurrection.
Unsigned native compile is separate from app/helper/runtime/Story certification.

### Coordinated cutover corrective integration receipt

Parent correction also updates the existing ProductJobRecovery reconciliation seam;
it does not add an owner, database, migration, policy or source file. When current
bytes are missing/nonregular/symlinked, a genuine succeeded importJob and its full
history remain byte-exact. Existing Paper availability becomes importFailed with
NULL reference and debt1, retaining generation/SHA; this exact validated state
lists missingPDF and admits genuine-history deletion, not Import Retry/publication.
The existing startup check does not perform a regular-replacement SHA rescan.

Known physical closure releases original concurrency capacity independently of
receipt custody: HTTPS requires actual file-close plus final network drain, and
validation requires actual checked read-FD close. Unknown original obligations do
not release. Every deleting revoke protects terminal headroom transactionally,
and the acknowledged capture is preflighted before Agent purge. Preview encoding
is not physical authority; committed publication permits are not failed-stage
cleanup, and irreversible unknown closure is not promoted by preview.

Parent verified418 Product cases, every case in an isolated process, zero failures
(artifact://1360), and fresh unsigned native-at BUILD SUCCEEDED (artifact://1369).
Preserved failed attempts and scoped source hash are in local-verification.json.
Review113's three findings have implemented/tested corrections; final independent
correction reviews115/116 are SOURCE-ONLY CLEAR / APPROVE, no findings. Same-Job
Retry, production Agent purge, runtime/profile
calibration and Story/Epic acceptance remain incomplete. No application/helper
binaries were executed; the owned XCTest scenarios above were executed.

## Fresh confirmed same-Job local Retry

After45b1129, extend the existing local confirmation route, not fresh-Paper import
masquerading as Retry. Explicit failed-Paper selection captures the exact genuine
failed Job/history; selecting a new PDF reuses actual selected-source hashing and
the existing confirmation sheet. Cancel reserves no new execution. Continue
consumes one fresh pending intent, rechecks actual SHA and chosen folder, then
asks the sole lifecycle to retry that exact captured Job. Consumed/stale intents
cannot replay. No automatic retry, saved input reconstruction or URL replay.

Eligibility requires exact Paper generation and one genuine canonical bounded
import history, current failed execution/SQL cause correspondence, nonrevoked
history, no permits/removal debt/pending removal, cleanupDebt0 and nondeleting
Paper with NULL reference/deletionID. NULL legacy history, current succeeded
unavailable bytes, unknown retained closure/debt, stale capture and deleting state
deny. Observe actual owned namespace absence before admission; observation is not
permission to clean a collision or acknowledge unknown obligations.

Core bounded interface in existing owners:
- ProductDatabase.captureRetryableImport(paperID:generation:) returns the exact
  ImportRecoveryRecord; it performs no source/namespace/reservation effects.
- ProductDatabase.reserveJournaledImportRetry(expected:identity:confirmedInput:currentEpoch:)
  constructs retryCapture/claim/acquireWriter internally, never accepts arbitrary
  replacement history. Preserve Paper/generation/Job and the entire old prefix,
  executions/captures/facts/used IDs. Mint fresh attempt/fence/correlation/input/
  writer/publication UUIDs in Main; use its actual current lifecycle epoch (not a
  fabricated epoch renewal) and newly confirmed SHA/folder.
  Record the actual current Main epoch observation in the same atomic suffix
  before retryCapture when needed; retain captured old epochs/executions and the
  existing epoch-mismatch guard. An arbitrary UUID is not observed-epoch authority.
  Require the new capture epoch to equal the separately supplied actual Main epoch;
  reject mismatch before mutation rather than treating capture epoch as observation.
- The one defended transaction replaces the same importJob execution columns,
  journal, failed state/cause and progress with the exact new running capture;
  resets Paper availability to importing without clearing unrelated facts, and
  validates schema, scoped writes, exact counters/readback and rollback. Ordinary
  CAS still rejects changed capture; no codec/tag parser, backfill or new store.
- LocalLibraryLifecycle.retryImportPDF(expected:from:expectedSHA256:destinationFolderID:)
  installs the committed record under the existing per-Paper FIFO, acknowledges
  writer-open before actual copier effects, and shares actual completion,
  publication/abort/deletion/unknown-root behavior with normal import. No FIFO
  gate spans copying/drain; failed reservation has no physical effects. Preflight
  terminal headroom before producer admission under the unchanged metadata quota.

Sequence core storage/lifecycle implementation (two existing files) before actual
confirmation/caller integration (FolderImportService, ProductWorkspaceView and
LibraryBrowserView), including directly affected ImportConfirmationView wording
that distinguishes same-Job Retry from an independent new Paper. Parent owns
tests, membership, independent data-integrity
review, unsigned compile, evidence and commits. Verify same Paper/Job with fresh
execution IDs across reopen, immutable previous failure/facts, fresh-folder/SHA
publication, Cancel/replay/stale/delete/unknown/legacy/succeeded denials, SQL
trigger rollback and zero effects before denied admission. Run every Product
case in isolated processes. UI is source/owned-model verified unless separately
authorized visible accessibility evidence exists; no app/helper/live trial or
profile/Story acceptance is granted by this slice.

### Same-Job Retry implementation receipt

The exact six existing source owners and two parent test files implement the
contract above. Main uses six fresh IDs plus its real current epoch; the same
Paper/generation/Job and complete prior failed history survive successful Retry.
Service purpose is explicit newPaper versus retry(captured genuine record), never
derived from display UUID or missing history. Actual Library picker and confirmation
are mounted in compiled product source. Counter3 accounts for the Job/Paper updates
and existing revokeReaderPosition Paper update; row/shadow/schema/readback defenses
remain required and do not certify arbitrary invisible SQLite effects.

Review119 is SOURCE-ONLY CLEAR. Review120 found two concrete caller cancellation
gaps: post-service stale confirmation installation and Cancel/Continue scheduling.
Parent implemented token/task freshness and returned-intent cleanup plus synchronous
connected confirmation-action consumption. The pre-install owned-fixture callback
is observation/veto only, not authority. Six caller regressions pass1405; full433
isolated Product cases pass1409, no skips/reset/fake ACK. Fresh unsigned native-av
BUILD SUCCEEDED1410; no application/helper binaries executed. Initial passing429/
430 suites, native-au, review120 and final source hash are preserved in evidence.
Final caller correction review120 is SOURCE-ONLY CLEAR / APPROVE, both P2 findings
resolved and no residual findings. Visible accessibility/runtime,
production Agent purge, calibration/profile and Story/Epic acceptance remain false.

### Pre-admission owned-PDF integrity observation

Extend existing startup reconciliation to sequential SHA observation of canonical
app-owned PDFs before `LocalLibraryLifecycle.open` exposes its owners. Reuse the
existing `FolderImportService.hashSelectedSource(_:close:beforeOpen:)`, made
internal, and its original `SelectedSourceReadOwner`, import lease/budget,
incremental hash, checked close and rooted unknown-closure obligations. Production
uses actual `FileHandle.close()` and no observation callback. Do not create a
second pool, owner, profile, quota, store, import Job or physical publication.

Capture each ready Paper's canonical UUID, generation, lowercase 64-hex SHA and
reference on the sole GRDB queue. Keep deleting-to-deletionFailed reconciliation
and the existing missing/nonregular/symlink branch. Observe bytes outside database
transactions, one file at a time, using the existing import PDF-size, read-buffer,
body-byte and elapsed-time limits. The metadata journal quota is not physical
admission. Do not claim an aggregate startup/RSS bound or same-UID hostile-mutation
isolation; this is an observation before Main producer admission, not a file pin
or an everlasting attestation of file contents.

Consume SHA only after the existing owner reports successful checked FD closure.
A matching digest writes nothing. A successfully observed mismatch uses the
existing unavailable transition, defended by exact pre-observation Paper
UUID/generation/SHA/reference/ready/nondeleting validation and UPDATE predicates.
Missing/type/symlink downgrades use the same captured predicates. Stale captures
throw without recapturing or applying their evidence to a different generation.
Retain genuine succeeded Job/history byte-exact and keep generation/SHA; downgrade
only Paper availability to importFailed, NULL reference and cleanupDebt1. Preserve
the separate legacy-NULL-history handling without backfill or Retry authority.

Any hash failure, cancellation, exhausted budget/capacity or unknown closure stops
reconciliation and lifecycle exposure. Do not classify uncertainty as missing,
continue with another file, retry the read, release unknown obligations or invent
cleanup/history evidence. An existing nonempty `unknownSelectedSourceReads()` set
also denies a new scan before integrity effects; it is never cleared as admission.

Implementation scope is exactly FolderImportService.swift, ProductJobRecovery.swift
and ProductDatabase+ImportRecovery.swift. LocalLibraryLifecycle.open already owns
the required pre-exposure placement and remains unchanged. This amendment is
committed before source mutation under the existing Story-range execution scope.
Tests, native execution, independent review and acceptance remain deferred by the
current implementation-first instruction; no user documents, SDK/provider/renderer
trial, new permission, remote or distribution action is authorized here.

### Owned startup integrity regression

Three new ProductJobRecoveryTests use actual owned local imports and checked-close
startup hashing. Matching bytes preserve all Paper/ImportJob fields, full succeeded
journal and document bytes. A changed regular nonsymlink owned document downgrades
only availability/reference/debt while retaining original generation/SHA and exact
succeeded history; a second startup does not replay it. Old captured generation,
SHA or reference cannot mutate a changed row: recoveryConflict preserves both rows
and jobs. Six focused startup/folder cases passed, then full isolated Product475
passed artifact1668. No user PDF, provider/SDK/renderer request or unknown-close
injection; no aggregate/RSS, hostile mutation or actual cleanup/purge proof.

### Review171 required startup cancellation propagation

Source BLOCK/P1 identifies unstructured detached startup work not receiving caller
cancellation; awaiting alone can still expose a producer-capable lifecycle after
Cancel. Check the caller before starting, retain the existing detached worker and
forward cancellation with withTaskCancellationHandler calling worker.cancel().
Keep awaiting its completion. Check worker cancellation before/after atomic recovery,
at reconciliation entry, between files and after checked-close observation before
consumption/update, plus final completion. Check caller again before return. Signal
handlers must not close FD, stop scope, release leases, erase roots or fabricate ACK;
the original checked-close owner alone determines known/unknown physical closure.
Scope only LocalLibraryLifecycle.swift/ProductJobRecovery.swift and owned cancellation
regressions; no additional owner/pool/profile/quota/store or alternate recovery path.
This bounded amendment precedes source mutation and does not renew protected trials.

Correction verification: pre-cancelled actual owned startup denies before exposure
and preserves exact published Paper/succeeded journal; a real GRDB reconciliation
SELECT barrier cancels the caller while two owned files contain known mismatching
bytes, then verifies worker cancellation prevents both availability downgrades and
returns no lifecycle. Bounded barrier timeouts fail, never skip. Initial test compile
failure1675 (semaphore wait unavailable in async context) was corrected in the test
helper only; both cases then passed. Review171 follow-up SOURCE CLEAR resolves P1.
Current full isolated Product477 passed artifact1676; separate fresh unsigned arm64
four-target native build1677 SUCCEEDED, no binaries launched or protected trials.
Mid-read/actual FD-close cancellation and unknown-close startup injection are not
exercised; no immediate cancellation/atomic-recovery rollback, aggregate/RSS, hostile
mutation, authenticated provider, purge, OS×CPU or canonical acceptance is inferred.

### Current isolated Product XCTest verification driver

`scripts/product/verify-isolated-tests.py` accepts an existing caller-built
`ProductTests.xctest`, optional `--package-path` caller package directory
(default current directory), required `--report`, optional exact class/case
`--filter`, and finite positive per-case `--timeout` seconds (default120). Installed
`xcrun xctest --help` documents only `-XCTest`, not native JSON listing;
`swift test list --help` also has no JSON-format option. Discovery uses supported
`swift test list --skip-build --disable-automatic-resolution` in that explicit
package directory, with a120-second subprocess timeout and separate stdout/stderr.
Every nonempty stdout line must be a native Module.Class/testCase selector;
well-formed other modules are validated but not executed. Malformed/injected or
duplicate selectors, empty ProductTests output, listing failure/timeout deny all
case execution. The caller must build matching package/bundle artifacts first;
the driver neither builds nor infers cases from source. No JSON-input alias remains.

Each selected case runs sequentially in a fresh process with argv
`xcrun xctest -XCTest ProductTests.Class/testCase /path/ProductTests.xctest`.
Exit0 alone is insufficient: exactly one matching start/pass and positive
exactly-one XCTest summary with zero failures/skips are required. Crash/nonzero,
skip, zero/multiple execution, missing evidence and timeout fail; owned children
are killed/reaped on timeout/interruption. Progress is emitted per case and at
bounded ten-second wait intervals, failures retained, JSON includes every case's
output/result and listing stdout/stderr/errors; exit0 means all selected cases passed,
exit1 case failure, exit2 input/report error. Exact filtering deliberately covers
only that subset. Package/bundle build correspondence, foreign output spoofing, descendant-process
cleanup and aggregate memory/disk limits are not attested. Report output can
contain test diagnostics and must remain in caller-owned evidence storage.

Usage: `python3 scripts/product/verify-isolated-tests.py /path/ProductTests.xctest
--package-path /path/package --report /path/report.json --timeout 120`.
No builds/resolution/network/app/SDK/renderer actions, runtime quota/root reset,
skip or logical closure ACK are performed by this driver. Mocked fixture tests in
`Tests/Topology/test_isolated_product_tests.py` cover execution/evidence failures,
timeouts/reaping, discovery, selector injection and reports; all test executions,
builds, gates and formatters are explicitly deferred to the parent. Help-only CLI
inspection is not verification, and no Story/Epic/runtime acceptance is promoted.

Parent verification on 2026-10-14: the revised driver's 15 offline fixture tests
PASS, including nonzero/crash/skip/zero/multiple evidence, selector denial,
timeout/reap, supported discovery and report failures. Its actual native full run
discovered and executed 481 Product cases, each in a separate owned process:
481 PASS, zero failures/errors, no skipped-case promotion. Evidence report:
`.build/isolated-product-8C627C92-348F-473A-A735-466D0EA28510.json`.
The prior shared-process failure and five stale workspace-test failures remain
recorded; production ownership/quota/admission was not weakened. These current
private-fixture tests do not prove genuine auth, actual Agent purge, rendered
accessibility, OS×CPU or P1/P2/P3/P6/Story/Epic completion. No configured project
formatter was found; focused Python tests, actual XCTest execution and diff checks
provide this slice's verification, not a substituted product acceptance gate.
