# Story 1.21 Build Spec — Parsing failure and explicit Retry

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
