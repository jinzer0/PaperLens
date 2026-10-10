# Story 1.14 Build Spec — Actual Library, local PDF import and deletion

## Authority and admission

Issue#16 / `issue/16-story-1-14`, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Commit own Spec before source; unchanged-scope local work requires no repeated SHA approval. Material scope changes still require governance. Authority does not pass gates or permit credentials/paid/live/remote/distribution.

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

## Conditional ≤5-file phase

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
