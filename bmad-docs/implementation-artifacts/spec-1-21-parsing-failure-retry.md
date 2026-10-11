# Story 1.21 Build Spec — Parsing failure and explicit Retry

## Current-source Retry presentation and accessibility

Scope: ParsingStatusView.swift only. The existing explicit Retry button remains
owned by the same coordinator/context and disabled admission; its label will distinguish
an in-flight retry request from an idle explicit action. This is request activity, not
parser progress, accepted dispatch or completion. Expose that distinction and the
explicit-action purpose to accessibility, mark the status/AI headings as headers, and
present a retry-action failure as a warning rather than undifferentiated body text.
Keep native Button keyboard/focus behavior; do not steal focus during persisted polling
or add global shortcuts, automatic Retry, dispatch authority or a new status owner.
Availability, safe failure mapping and floating notice remain unchanged. No tests,
builds, formatters, gates or runtime execution in this slice. Parent source review and
permitted checks remain required; actual keyboard/VoiceOver, request-state rendering,
immediate notification, real restart and calibrated parser/Retry remain unproved.
Canonical acceptance is unchanged.

## Right-panel recovery and explicit AI availability

Baseline4ff6a2fa80737798092849eadfda350d17510ab6 mounts ParsingStatusView in a
horizontal header above Reader, not the canonical right panel, and does not explain
Translation/Paper Chat/Brief generation availability. Exact source scope:
Features/Reader/ParsingStatusView.swift, Features/Reader/NativeReaderView.swift,
Features/Library/ProductWorkspaceView.swift. Workspace passes its existing actual
ParsingStatusView value as a required NativeReaderView initializer argument; Reader
mounts it at the top of its existing right metadata pane. Preserve whole mount identity,
actual StateObject/session/document/annotation and metadata bindings, read callbacks,
polling request/Paper/cancellation fences, notification and disabled Retry admission.
No duplicate status mount, fourth pane, extra owner/schema/store/timer/producer or
calibration. Pane contains meaningful status when metadata is absent, not blank space.
Explain AI preparation using only accepted persisted usableRevision: initial nil/read
unavailable is unknown, known missing revision is unavailable, retained revision is
usable despite latest failure. Independently name all three unimplemented features;
no enabled action, generated success, Provider request, partial-row readiness or raw
diagnostic/count/time/history. Existing actual storage projection and safe mapping stay
unchanged. Only minimum existing persisted notice/reopen/retained-revision and actual
Reader search scenarios; new tests/review/full/native/formatter/rendered gates remain
deferred per implementation-first. Scope does not certify immediate/visible notice,
focus/VoiceOver, real process restart, calibrated parsing/Retry or Story/Epic acceptance.

### Right-panel source delivery receipt

Spec8e4de0e00506cb3605766d671b699b220388b9c3 preceded three-source edits.
The sole NativeReaderView callsite passes the original ParsingStatusView/database/
Paper ID/metadata reconciliation callback; it mounts once in the right metadata pane,
retaining reader.mountIdentity (Paper/generation/actual session) and actual presentation.
Availability copy distinguishes nil/read-unavailable, missing usable revision and
accepted retained revision, independently stating all three AI features unimplemented.
No enabled generation action, fake producer/coordinator/Job or provider dispatch.
Existing notice and refresh/Retry guards, persistence, metadata and annotation actions
stay unchanged. The prior no-blank-metadata-panel layout now contains actual recovery
status even without metadata; no fourth pane or duplicate polling was introduced.
Parent existing persisted notice/retry/reopen/retained-revision fixture and actual
windowless Reader search/latest/no-results cases both pass exit0; SwiftPM compiled
changed sources in4.27 seconds. Only a notice-layout comment changed afterward;
executable source did not. Final three-source binary diff SHA256 against Spec:
`e24bf23c179db866f45d13aea03143d70a42b77aa81951bd93f34444f2e33019`.
Fixtures do not exercise new availability Text branches, actual panel layout/notice
position/focus/VoiceOver, immediate delivery, process restart or genuine parser/Retry.
New tests/review/full/native/formatter/protected trials remain deferred; Story/Epic false.

## Authority and admission

Issue#23 / issue/23-story-1-21, basef14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own committed Spec before source; no repeated unchanged-scope SHA approval (parent reconciled proposal's generic per-SHA wording). No actual gates/live/paid/credential/remote/distribution permission inferred.

Architect53 inspected exactly ROOTepics985–1017, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift; canonical root-only not copied. Planning ONLY/not implementation-ready; actual1.20 required, real Library/Reader/persistence/connections absent, product BLOCKED, StoryDone=false. P1/P2/P3/P6 unproved, blankCapture FAIL. Initial1.13 pure20PASS independently BLOCKED48; repair49 not accepted at proposal. Local14dd7b3/c93e873 nonproduct.

## Truthful failure and recovery

Accepted CURRENT parser failure immediately yields in-app floating notification and right-panel latest SAFE reason plus Retry Parsing. No raw worker diagnostics or waiting for AI. Retain PDF navigation/search/selection and Reader position/context during failure/Retry, no blocking replacement screen.

No usable extraction→explain Translation/Paper Chat/Brief generation unavailable; independently distinguish unimplemented controls, never pretend executable/completed. Failed replacement preserves actually usable old active revision; availability derives real usable revision/implementation, not partial rows or blanket-failure.

Explicit Retry revalidates active Paper/generation/immutablePDF/input/parser prerequisites through single1.13 policy, fresh attempt/fence/correlation/epoch reservation BEFORE mutation. One accepted pending/running execution; rapid/concurrent clicks no duplicate dispatch, rejected/deleting/stale action zero newJob/effects. Never automatic replay or old fence renewal.

Success ONLY complete validated extraction+FTS atomically published with current Job/usable pointer (1.20), then extraction-ready. No fake Translation progress/result/success (Epic2). Repeated failure updates latest reason/explicitRetry; old usable pointer/history immutable. Duplicate/stale/reverse completion cannot change pointer/notice/current UI.

Expose NO attempt count/time/duration/history in panel/notification/tooltip/VoiceOver; internal lineage remains internal. Restart real durable failure/reason/actions, running→failed/interrupted/no resume, old usable retained; storage/reconcile failure never restored success. Delete immediately blocks Retry/re-entry/newJob/claim/dispatch/publication even after restart; no filesystem/cache/late callback resurrection.

## Owners and conditional source/test phase

Application/persistence own Job/visibility, no-network PDFium owns typed extraction, PDFKit ephemeral reading. UI derives accepted state, no second persisted failure/recovery mirror/adapter Retry/winner. ProviderRequest operations unchanged, parser-ready not generatedAIresult. UNKNOWN actual APIs/state projections/safe reason mapping/notification details/persistence/Reader/accessibility files; bind accepted owners in same Spec before source, no guessedschema/helper/CI/fallback/fakeparser/newoperation.

Conditional≤5exactmutablefiles per named phase: existing Application projection/recovery; sole persistence; Reader/statusUI; paired command/storage tests; actual nativeUI/relaunch/integration tests. Ownership slots not scaffold paths. Resolve required callsites/wiring within amended bounded phases, no omitted test to fit cap. Policy defect repaired in1.13 not local workaround.

Reuse permits/synchronous cleanup outside short arbitration; immutable fresh per-cleanup/removal operation+ownedscope completion, failures retain debt. Actual producer closure/physical/drain/product store proof needed; policy/mock/synthetic/localGRDB cannot complete.

## Required evidence and native UI

Actual parser failure→immediate notice/reason/Retry while navigate/search/select; PDF unchanged/inactive revision not active. No extraction/unimplementedAI zero fakeJob/providerdispatch. ExplicitRetry actualsuccess freshlineage/one dispatch/atomiccompleteFTS; repeatedfailure truthfulreason/no counttime/history/old usable.

Vary every attempt/fence/input/Paper/config/epoch guard, stale/reverse/duplicate results leavecurrentnotice unchanged and cleanup obeys capturedop. Real exit/relaunch failures/running/storagefail restore correct actions without replay. Delete beforeRetry/duringparse/publish/restart blockswork and lateUI/resurrection.

Native Canvas semantics/Korean state+nextaction/non-color progress/error/delete cues, actual-background contrast/text scaling/window resize/keyboardVoiceOver label-role-state. Notification/Retry discoverable, same guardedcommand/no bypass, focus preserved/dialog-drawer opener return/accessible RetryCancelDelete. Validate all existingPaper data failure/restart/delete races here, no deferredpolish.

Architect53 COMMENT/WATCH/read-only five-source only; no writes/tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done needs actual1.20+accepted1.13/gates, real durable parser/ReaderUI/restart evidence, parent verification/independentreview. Planning passes none.

## Human-requested independent source slice (2026-10-10)

The current human instruction supersedes the historical source-absence assessment for this
slice only. Exact ownership: ParsingRecoveryCoordinator.swift, ParsingStatusView.swift,
ParsingRecoveryCoordinatorTests.swift and this Spec. No execution gates or commits in this
session; parent commits the reconciled Spec/source and verifies the integrated union.

Coordinator uses the existing ProductDatabase GRDB queue and extraction tables, without
schema changes. A captured failed-attempt context contains complete old lineage, the usable
revision and current provider configuration. Retry checks all three atomically against the
ready/nondeleting Paper before replacing the failed attempt; immutable invocation rows remain.
Missing producer/geometry validator rejects before reservation. Main supplies its existing
epoch, never a coordinator-generated process epoch. JobRecoveryPolicy admits/claims/dispatches
fresh parser lineage; existing ExtractionRevisionService batch validation and database
publication/failure methods retain sole extraction result ownership. No second store or
unchecked geometry producer is introduced. Safe failure text never interpolates diagnostics.

Parent must bind the actual producer and geometry validator, supply the Main epoch, recover
interrupted extractions once before exposing commands, bind the guarded Retry context and
immediate floating notice to Reader, and include the new source in explicit build source lists.
Storage fixtures and injected failing producers are tests of coordination, not parser proof.
Actual producer/native Reader/relaunch evidence remains unproved; no StoryDone claim.

## Parent scoped-producer caller integration (2026-10-10)

The committed Story1.20 correction Spec (`fb3fa60`, original `9948634`) requires an
original-budget consumer scope rather than returning unowned arrays. After its existing
atomic failed-context/lineage admission, Retry calls the sole service's `consumeReserved`
path. Canonical validation and actual GRDB publication run under that captured scope;
both success and unwind retain pin/resource ownership through consumer disposal. The
coordinator no longer duplicates array-returning producer, validation or failure paths.
Cleanup failure after committed publication remains ownership debt, not a false failed Job.
Missing producer/geometry still rejects before reservation; one supplied process epoch,
old usable revision and current full-context arbitration remain unchanged.

Parent Product union: 220 tests/zero failures (`artifact://894`); full unsigned native
Release arm64/macOS15 build succeeded (`artifact://891`, fresh native-g). Synthetic
failing-producer/storage tests and compilation do not establish actual Retry/native
notification/relaunch/AD8/P1/P2/P3 or Story completion. Production owner bindings and
protected runtime evidence remain separate from this source caller adaptation.

## Reader notice mounting — bounded local source slice

Current ProductWorkspaceView mounts NativeReaderView but not the existing persisted
ParsingStatusView. Mount that existing notice next to the original Reader using the
workspace's same ProductDatabase and the admitted Paper generation as SwiftUI identity.
No new database, job, lease or provider owner is admitted. Preserve Reader annotations,
metadata, search, selection, position and synchronous close behavior. Status reads use
the existing durable extraction adapter; failure is not rewritten to success.

Required calibrated geometry and producer activation remain unavailable. Do not create
a successful placeholder coordinator or dispatch parsing/Retry. With no genuine bound
coordinator, retain the existing disabled Retry and explicit unavailable-service notice.
This is source-level mounting of real persisted status, not full Retry or Story acceptance.
Same-paper generation replacement must discard the old notice's state; existing mounted
polling cancellation and identifier checks remain intact. No UI renderer/app/helper trial
or privacy/approval limit is relaxed.

Exact source scope: ProductWorkspaceView.swift; reuse ParsingStatusView unchanged.
Parent verifies actual recovery/state regression suite and fresh unsigned native compile,
then narrow independent source review and local evidence commit. UI visibility,
VoiceOver/focus/accessibility and runtime notification/relaunch remain unverified because
protected product/renderer execution has not been renewed; compilation is not a visible
witness. This does not authorize geometry defaults, automatic replay or remote effects.

## Reader notice mounting — parent source verification

The existing status view is now mounted beside NativeReaderView from the exact same
workspace GRDB reference (fileprivate, not a public replacement owner). The whole
container identity includes both Paper ID and generation, fencing both status state
and Reader presentation while preserving all original session/service/close callbacks.
No coordinator was fabricated: absent calibrated activation keeps Retry disabled with
the existing explicit disconnected-service message. Polling reads actual persisted
state; it does not create a job, lease, provider request or successful parse.

Seven existing guarded recovery regressions passed (artifact953); unchanged prior full
261-test union from fc9f804/artifact945 is reused rather than claimed rerun. Fresh native
unsigned Release arm64/macOS15 compiled in native-q (artifact954). Independent review66
returned SOURCE-ONLY CLEAR / APPROVE. Exact workspace-source binary delta against
preimplementation8eaca03: 653a333fcedb3726f833545a33129a78cde99f16ef006e160f2055e61fc4b178.
No UI/app/helper binary or protected renderer trial ran; visible layout, immediate notice,
keyboard/VoiceOver/focus and real Retry/relaunch remain unverified. Neither compilation
nor source review establishes Story acceptance, and durable Epic/Story status stays false.

## Current accepted-failure floating presentation — bounded source correction

Architect124 found the mounted status header has no distinct floating failure notice.
Add a nonmodal, pointer-pass-through overlay below that existing header, using only
its accepted persisted failed status and the existing safe Korean mapping. A small
production-used stateless projection returns no notice for nil/running/success/
unavailable or a failed status read. Retained usable revisions do not hide a current
failure; subsequent failures replace the message without history/count/time/diagnostics.
No coordinator, dispatch, timer, persisted mirror, inferred attempt or resource owner.
Preserve refresh request/Paper/cancellation fences and native Reader/session identity.
Exact writable sources: Features/Reader/ParsingStatusView.swift and existing
Tests/Product/ParsingRecoveryCoordinatorTests.swift; parent owns this Spec and evidence.
Test actual GRDB failure/running/repeated failure/reopen/deletion projections, usable
revision retention, read-unavailable suppression and unsafe diagnostic rejection.
Focused/union tests, unsigned compile and independent source review are required.
Polling remains unchanged: this does not prove immediate producer delivery, rendered
visibility, VoiceOver/focus, process relaunch, genuine parsing/Retry or Story acceptance.

### Parent floating-presentation source receipt

After committed745e395, the two named Swift files implement the stateless safe-failure
projection and floating nonmodal overlay, without changing accepted-read fences, Reader
mount, coordinator, storage or dispatch. Actual GRDB controlled failure/retry/reopen and
deletion projections preserve the old usable revision; adversarial diagnostic/nonfailed
inputs cannot display an old failure as current. Focused23/zero1434, full isolated441/
zero1438 and fresh unsigned native-ay1439 pass. Independent125 SOURCE-ONLY CLEAR /
APPROVE, no actionable delta findings. Two-source binary diff SHA256 versus745e395:
`d4c8860b1d23c009e976c0d0a022851c17ee0c91d59e84d93f9d038687a642fa`.
Rendered visibility/pointer behavior, VoiceOver/focus, immediate producer delivery,
process relaunch and genuine calibrated parser/Retry remain unverified. No protected
binary/renderer/SDK/provider/remote operation ran; canonical0/26 and Story/Epic false.

## Commit-driven parsing presentation source phase

Current source inspection confirms that mounted status refresh waits on a one-second
polling loop. This leaves the canonical immediate failure-presentation requirement
without producer-driven delivery. Replace polling with the pinned GRDB7.11.1 public
ValueObservation async sequence on the existing sole ProductDatabase queue; do not
add a global notification bus, timer, database, persistent mirror or producer owner.
Exact source scope: Infrastructure/ProductDatabase.swift,
Infrastructure/ProductDatabase+Extraction.swift and Features/Reader/ParsingStatusView.swift.

Factor the existing extractionStatus SQL/readback into one shared transaction-local
fetch helper without changing its semantics. ProductDatabase.extractionStatuses(paperID:)
returns AsyncValueObservation<ExtractionStatus> from tracking that helper on its own
queue, with bufferingNewest(1). This is latest presentation-state coalescing, not a
physical resource limit, publication authority or cleanup ACK. Use the maintained
GRDB iterator cancellation rather than a new observer/continuation owner. No nested
queue reads, filesystem/PDF/transport effects or callbacks inside SQL transactions.

The existing Paper-scoped SwiftUI task consumes observations and invokes its current
guarded refresh/recovery-context/reconciliation path. Remove the one-second sleep;
keep Retry admission and its dispatch unchanged. Observation errors clear stale status
and recovery context and reconcile unavailable using fresh existing request and task
cancellation fences. A terminal observation error also records that mounted tracking
ended. Explicit Refresh and post-Retry readback rearm one ended iterator for the same
mount; ordinary observation-triggered reads never restart tracking. Use a view-local
restart token with Paper ID in the task key, capture that actual key in the body, and
fence initial/terminal state and rearming against it. A replacement task must not erase
successful same-Paper presentation merely to restart observation. No automatic restart
loop, replay, timer or polling fallback. A removed Reader receives no late effects;
the existing Paper/generation/session mount and actual metadata pins remain intact.
No extraction reservation, retry lineage, provider/config generation, accepted
revision, schema or calibrated parser contract changes.

Commit this contract before source because the change crosses the shared read-query
and presentation boundary. Implementation-first/test deferral still applies: no new
tests, runtime/native/SDK/helper/renderer or protected trials in the source lane.
Parent owns source checks and independent review; real commit-driven delivery,
rollback/no-change/read-error/replacement/cancellation behavior and native immediate
notice remain verification obligations, not source-only Story acceptance.

### Commit-driven source implementation notes

Contract0d822c9 precedes the three-source implementation. The synchronous status
adapter and sole-queue GRDB observation now share fetchExtractionStatus(paperID:in:),
with the original joins, ready-state mapping, missing-revision mapping and UUID
readback unchanged. Observation uses bufferingNewest(1); its payload only invalidates
presentation and invokes the existing guarded refresh, recovery-context read and
metadata reconciliation callback. The Paper-scoped task no longer sleeps or polls.
Initial consumption and every observation reject cancelled tasks; each observation
also rejects a changed Paper before refreshing. Stream errors first reject cancelled
or stale-Paper tasks, then allocate a fresh reconciliation request, clear status and
recovery context, mark unavailable and reconcile that outcome without exposing raw
diagnostics. No stream error is converted into a polling fallback. GRDB's maintained
iterator owns observation cancellation. Review186 found the initial implementation
leaves tracking terminated after an error even if explicit readback later succeeds;
that combined presentation replacement is BLOCK until the recovery contract above
is implemented. The shared SQL/sole-queue boundary is source-clear. Existing workspace
generation/session mount and actual metadata callback remain unchanged.

No tests, builds, compiler commands, gates, formatter or runtime trials ran in this
source lane. Parent checks and independent source review remain pending, including
commit/rollback/no-change/error, superseding request and removed-task behavior;
immediate native presentation and canonical Story/Epic acceptance remain unproved.

### Terminal observation recovery source notes

Correction contract2f66ea6 precedes this view-only fix. The actual Paper/restart-UUID
task key is captured lexically in body, before attaching the task. Entry, yielded
invalidations, readback publication, errors and terminal tracking changes reject
stale keys and cancellation. Tracking termination is recorded before unavailable
reconciliation awaits; normal active sequence completion also records termination.
Initial or different-Paper entry clears presentation; same-Paper rearming preserves
status, recovery context and reconciliation, including successful explicit readback.

Explicit Refresh and post-Retry readback share recoverTracking. It first executes the
existing guarded readback, then synchronously checks its captured key and ended
tracking, invalidates the old reconciliation request, and advances one UUID.
Concurrent recoveries with the old key cannot advance it twice. Ordinary observation
invalidations only refresh; errors never automatically restart. Iterator cancellation
remains GRDB-owned. Retry dispatch/admission stays unchanged; the existing same-Paper
retrying cleanup survives observer-key advancement, while Retry errors/readback use
the key fence. No new SQL/database boundary, timer, supervisor or publication ACK.

Parent syntax parsing of the three changed Swift files and git diff --check pass.
Independent186 re-review is SOURCE CLEAR and resolves its retained terminal-recovery
BLOCK finding. This is source inspection, not behavioral/runtime proof. Deferred
obligations include terminal error then explicit recovery and later commit delivery,
overlapping recoveries/Retry, delayed old-task entry, cancellation during readback or
metadata callback, and native immediate notice. No acceptance or runtime proof claimed.
