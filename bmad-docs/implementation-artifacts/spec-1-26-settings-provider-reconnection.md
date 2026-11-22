# Story 1.26 Build Spec — Settings Provider reconnection

## Settings 키보드 초점과 재연결 흐름 — 2026-11-22

macOS 26.7.1 arm64의 Developer ID 서명 앱에서 Settings를 닫으면 초점이 태그 필터로
이동하는 결함을 재현했다. 수정한 앱에서는 닫기 또는 Escape 후 Settings 버튼으로
초점이 돌아왔고, 스페이스 키로 다시 열 수 있었다.

전용 합성 저장소와 로컬 응답으로 연결 거절 및 취소를 검증했다. 거절 후 재시도 안내가
유지됐고, 취소 후 키 입력란으로 초점이 돌아왔다. 늦은 응답을 받은 뒤 임시 키가 정리됐으며
기존 선택과 연결 버전은 앱을 재실행한 뒤에도 일치했다. 관련 XCTest 116개가 통과했다.
로컬 실행 기록은 `.build/epic1-settings-actual-flow/settings-verified-ui.log`에 있다.
실제 Provider 인증, VoiceOver 사용 및 macOS 15 검증은 남아 있다.

## API 키 연결 확인 취소 — 2026-11-22

Settings와 최초 연결 화면의 취소 버튼을 화면에 표시된 API 키 확인 시도에 연결했다.
이전 버튼의 동작이 뒤늦게 들어와도 새 확인을 취소하거나 이미 표시된 성공·실패 상태를
바꾸지 않는다. 취소 상태는 한 번만 발행해 상태를 구독하는 코드가 즉시 새 확인을
시작하더라도 이전 취소 상태가 새 진행 상태를 덮지 않는다.

합성 응답을 보류해 두 경합을 재현했고, 수정 뒤 세 회귀 사례를 포함한 관련 XCTest
67개가 통과했다. arm64 Release 빌드와 Developer ID 서명을 확인했다. 실제 인증 요청과
macOS 15에서의 실행 및 Settings 접근성 검증은 남아 있다.

## Existing Settings opener return (baseline 0ee17ee)

Review194 resolves one finite source input, not an observed native failure:
the Workspace Settings Button survives over Library but has no native FocusState
or retained opener receipt. Existing source returns only folder/PDF opener focus.
Implement this UI-only continuation after this contract is committed, in
ProductWorkspaceView.swift; this Spec and paired Spec1.17 are the affected records.
No authentication/service/model/selector/resource changes or new controller.

Reuse the existing folder toolbar receipt as one typed toolbar presentation
(folders/settings), retaining its fresh identity and original root mount. Both
real Buttons require clear native slot/toolbar receipt/owner sheet, no Reader,
preparation/opening/cleanup before capture and existing sheet assignment. Rejected
assignment consumes only its matching receipt. Attach native Settings FocusState
to the actual existing Button, not a replacement control.

Latch the toolbar receipt identity into the existing immutable native slot only
when its kind and mount match the actual owner sheet. Unrelated presentation
consumes toolbar eligibility rather than retargeting it. Actual native appearance
records the matching receipt; unmount/Reader entry invalidates it. Actual onDismiss
calls existing owner cleanup before focus guards, then consumes the exact matching
toolbar receipt once. Return to that receipt's real Button only after actual
appearance/dismissal, live original mount, no Reader/new sheet/native slot and
clear preparation/opening/cleanup fences. Stale callbacks cannot consume a newer
receipt. Folder return semantics and direct-PDF Cancel-only reconciliation remain
unchanged. UI identities grant no provider, cancellation or physical-ACK authority.

Tests/test fixes, type/build/native runtime and keyboard/VoiceOver verification
remain deferred under the current instruction. Parent owns permitted source checks
and independent review; no Story/Epic acceptance or authenticated reconnect claim.

### Source implementation notes (contract 465b289)

The existing Settings and folder Buttons now have their own native FocusState
bindings and share one typed ToolbarPresentation in the existing Workspace root.
Accepted actions capture a fresh receipt/original mount before owner assignment;
rejection clears only that receipt. The immutable NativeSlot latches the matching
kind/mount receipt ID. Common actual native appearance records that exact receipt;
unrelated sheets, Reader entry and unmount deny toolbar return. Native dismissal
invokes existing owner cleanup first, consumes only the slot-linked receipt once,
then returns to its actual Button only with appearance/live-mount/clear-owner fences.
Stale callbacks cannot consume a newer receipt. Direct-PDF Cancel-only reconciliation
and all Workspace model/provider/resource authority remain unchanged.

This is authored source, not observed native focus or reconnection proof. Tests,
test fixes, type/build checks, gates, formatters and native/keyboard/VoiceOver trials
were not run. Parent Workspace syntax parsing and git diff --check pass;
independent196 is SOURCE CLEAR for this three-file delta. No StoryDone/Epic promotion
or physical cleanup ACK is claimed.

## Authority and admission

Issue#28 / `issue/28-story-1-26`; base `f14f15f3f1c1fed02657ebf0c7ecdcb23721bfa8`. PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`; ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own committed Spec before source; no repeated unchanged-scope SHA approval (parent reconciled generic proposal wording), no actual gates/credentials/live/paid/remote/distribution permission.

Architect58 exactly ROOTepics1148–1190 and own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json, PaperLensApp.swift. Root-only not copied. Latest explicit human source-order instruction admits actual local Settings implementation against completed auth23; product proof remains incomplete/StoryDone=false. P1/P2/P3/P6 unproved, blankCapture FAIL, Main topology not Settings.

## Settings and current candidate activation

Display current Provider/status, native key reentry, official ChatGPT browser/device-code and connection test. Candidate progress NOT active status. Never reveal stored key; native/Agent owners retain secret entry/auth, Settings gets safe projection only. Application alone owns config/availability/selector/winner, sole SQLite/migration authority.

Fresh staged slot/version preserves last-good while testing. Verify controlled roots0700/files0600/backup exclusion and SDK descendants after writes/auth/startup; unsafe blocks test/promotion, owned removal only/no repair/fallback. Agent zone not Main mount/read and Agent never native key/SQLite/PDF access.

Smallest ACTUAL authenticated v1 generation via candidate adapter, existing closed connectionTest/fixedProbe/shared budgets/matching exact PAPERLENS_OK result. Identity/model/SDK init/login/fixture echo never proof. Final outer usable mapping/public SDK effects/private paths/storage/crash/API UNKNOWN, not invented.

Capture candidate/version/expected active selector+config generation/attempt/correlation/epoch/current intent; final safe storage/current cancel checks. Only current typed usable success serialized atomic CAS publishes new active slot/config generation. Competing/stale winner cannot promote. Split store/selector failure follows sole committed active selection, never filename-derived alternate selector. Old slot retained until every old lease closes; old calls may finish, no new old-generation work or old-generation publication.

## Failure and recovery

Failure/cancel/timeout/late/duplicate preserves last-good and its availability; redacted reason/explicit Retry. Missing/unsafe selected config means unavailable, no erased history/fabricated success. Edit/path-switch/restart invalidate candidate; Retry fresh intent/identities/current prerequisites, never revival.

Paper publication uses accepted1.13 running/current attempt/fence/input/config/Paper/epoch/permit guards after typed result. Old usable provenance retained. ConnectionTest explicitly non-Paper. No FS/DB/transport/callback/drain under short state arbitration; cleanup fresh operation/immutable target/completion, failure retains debt/not false absent.

Startup validates selected complete slot and removes only owned abandoned/retired stages through owners, actual no-live-lease proof; attempt-linked Agent content cleanup. Running Jobs interrupted/no fence renewal. Settings changes/restart NEVER covertly redispatch failed/ambiguous external work. Current Paper writers/publishers revoke/drain/scoped synchronous cleanup, no resurrection.

## Conditional phase and proof

### Actual local source phase — 2026-10-09

Exactly four mutable files: this Spec; `PaperLensApp/Application/ProviderSettingsService.swift`; `PaperLensApp/Features/Settings/ProviderSettingsView.swift`; `Tests/Product/ProviderSettingsTests.swift`. Implement service forwarding and native SwiftUI settings against the completed auth23 `@MainActor NativeAPIKeyConnection` contract: phase/activeSelection/eligibleForEntry/connect/cancel/restore/invalidateCandidate, acquireLease/mayPublish/releaseAfterTermination. The same connection instance owns staged slots, cleanup debt, generation arbitration and the sole `APIKeySelectorPersistence.currentSelection/compareAndSwap`; Settings never adds selector storage, credentials to projected state, or Paper redispatch. Parent seeds completed auth/core sources and binds durable selector/composition after handoff.

File-level plan: amend this phase before source; service projects current versus candidate state without cached winner and forwards generation leases; native Settings renders safe Korean state/actions with transient SecureField entry; paired pure service tests use real temporary private slots and injected deterministic transport with suspended completions. No real credentials, network/paid calls, tests/gates/builds/formatters/commits/remotes or workflow invocation in this lane. Source inspection only; test execution and native accessibility/runtime evidence remain parent verification, never PASS.

Actual completion gaps: official ChatGPT browser/device-code auth23 counterpart is not supplied; no unsupported login button or fabricated success is shipped. Native settings is callable, but genuine Codex reconnection, startup abandoned-slot proof, all Paper-job publication integration, model enforcement certification, signed/runtime/accessibility evidence remain incomplete. `eligibleForEntry` is not P3 certification. Existing API-key lease release failures propagate, including cleanup debt; no swallow/fallback. No changes to auth23 or core DB.

The four exact paths above replace the previous unknown-path planning condition. No second secret/selector owner, helperCI/Keychain/generic OAuth/consent-disclosure/future AI screens. Story1.27 remains UNDEFINED.

Actual native/browser/device tests with/without last-good, malformed/wrong probe/identity-only/cancel/timeout/explicit Retry. Deterministic overlapping candidate/reverse auth/edit/CAS/duplicate/store failure→one current winner. Real permissions/backup SDK mutation/removal failures/no raw secrets in diagnostics; old held lease/promotion/deferred retirement/stale cleanup. Real restart selected/missing/incomplete/abandoned/ambiguous/interrupted, no auto-send. Config/delete races across all currently owned Paper data.

Native Canvas semantic/Korean state+action/non-color cues, actual contrast/text scaling/resize/keyboardVoiceOver label-role-state. Dialog/drawer focus return/accessibility RetryCancelDelete, no deferred polish.

Architect58's historical read-only phase is superseded only for the four local source paths by the explicit human instruction. No tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits are run in this lane. Done still requires real prerequisite owners/authenticated generation/durable CAS/private lifecycle/native UI and parent verification/independent review; source delivery is not StoryDone.

## Bounded synchronous native key edit boundary

Assessment133 inspected exactly this Spec, ProviderSettingsView.swift,
ProviderSettingsService.swift and ProviderSettingsTests.swift at source55dd7c7.
SecureField currently writes transient key before a separate onChange invalidates
the actual shared candidate. MainActor serializes calls but does not guarantee that
deferred change observation precedes a candidate completion. Fix the caller to enforce
the already-required edit invalidation synchronously, not a new authorization policy.
Exact source scope: ProviderSettingsView.swift and existing ProviderSettingsTests.swift;
NativeAPIKeyConnection/ProviderSettingsService/selector/storage remain unchanged.
Internal production-used providerSettingsKeyBinding accepts the existing Binding<String>
and same service; for changed value call candidateEdited before forwarding the transient
entry write. Same-value assignment does not invalidate. Replace SecureField binding and
remove deferred onChange; no controller, secret mirror, selector or extra intent state.
Parent uses existing real Native owner/owned private slots/test selector/held synthetic
correlated transport. Test actual helper setter ordering, old successful completion after
edit denied without CAS, last-good/held lease retained, no automatic probe, unchanged
terminal cancellation and cleanupBlocked/debt during edits. No real key/authentication,
network/request or permission repair. Parent focused/full isolated tests, unsigned native
compile, independent delta review and local evidence commit remain admitted. This
corrective caller fence preserves approved semantics and strengthens early denial; it
does not relax profile/storage/security policy or authorize live/paid/SDK trials.
Controlled Binding/source tests are not observed SwiftUI interleaving, visible secure
entry/keyboard/VoiceOver/focus/authenticated generation/P3/P6 or Story acceptance.
Full Epic objective remains active0/26; no remote or protected gate promotion.

### Native key binding local receipt

Preimplementation `864866bac5825b4a16da05e9f86b254ddd9d6674`; executor134 implemented
the production Binding and removed deferred onChange in the exact view file. Parent
tested the actual helper against the existing shared Native owner/owned private slots/
test selector/held synthetic transport. Underlying unchanged-value setter sees probing;
changed-value setter sees already invalidated owner before entry write. Late synthetic
success with/without last-good performs no CAS or automatic new probe; old held lease
and selection retained where applicable. Actual helper edits preserve terminal cancel
and cleanupBlocked/debt without permission repair or swallowed release errors.
Focused18/zero `artifact://1474`; isolated Product451/zero `artifact://1478`;
fresh unsigned native-bd BUILD SUCCEEDED `artifact://1479`; independent135 SOURCE-ONLY
CLEAR / APPROVE explicitly supersedes133 HIGH/P1 BLOCK / REQUEST CHANGES for this delta,
retaining the original source-level finding, not rewriting it as visible UI proof.
Two-source diff SHA256:
`e03b373c4e2798e83ef1825e9ddfadd362ea281b74f25e6343cbc2e252b6bb68`.
Slot-count waits are cleanup observations, not independent transport termination/drain
ACK; pre-completion slot retention not separately confirmed. Controlled Binding and
synthetic response tests do not prove SwiftUI interleaving, authentication, SDK/P3/P6,
VoiceOver/focus or Story. No protected/live/remote execution;0/26/Story/Epic false.
