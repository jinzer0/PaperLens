# Story 1.18 Build Spec — URL Import and shared Library entry

## Current source phase (2026-10-09 explicit human order)

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
