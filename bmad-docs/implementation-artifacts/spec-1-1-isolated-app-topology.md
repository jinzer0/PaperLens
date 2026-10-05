---
title: 'Story 1.1 — 두 CPU에서 격리된 앱 실행 구조 입증'
type: feature
created: 2026-10-05
status: draft
review_loop_iteration: 0
story: '1.1'
issue: 'https://github.com/jinzer0/PaperLens/issues/2'
branch: issue/2-isolated-app-topology
risk: HIGH
implementation_approval: pending
architecture_baseline: 1195c92227cc628e325f5ff24d70cc93639bf7a9
context:
  - '{project-root}/docs/ai-governance.md'
  - '{project-root}/bmad-docs/planning-artifacts/architecture/architecture-PaperLens-2026-08-28/ARCHITECTURE-SPINE.md'
  - '{project-root}/bmad-docs/planning-artifacts/architecture/architecture-PaperLens-2026-08-28/SOLUTION-DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** P-1의 실행·격리 topology는 아직 실증되지 않았다. 제품 Provider/PDFium 구현 전에 arm64와 실제 Intel 환경에서 동일한 경계가 유지되는지 확인해야 한다.

**Approach:** Story 1.1에 한정된 실제 패키징 prototype으로 Main App, no-network PDFium XPC, 별도 sandbox identity의 Provider Agent를 실행하고 서명·공증·접근 거부 증거를 남긴다. 제품 기능을 대신하는 mock이나 완성된 앱으로 제공하지 않는다.

## Boundaries & Constraints

**Always:** AD-2/4/7/13을 유지한다. 모든 executable은 App Sandbox와 hardened runtime을 적용하고 두 CPU 산출물은 같은 source·후보 dependencies·entitlements·검증 기준을 사용한다. Agent와 Main은 container/app-group을 공유하지 않는다. Main의 broad Agent filesystem 접근과 XPC의 network·DB·Secrets·Caches 접근은 금지한다. XPC에는 시험용 PDF의 read-only 권한만 전달한다. Agent 자식 Python/SDK/CLI도 실제 패키징 대상이며 host-installed runtime으로 대체하지 않는다.

**Ask First:** 이 파일의 커밋 SHA에 대한 IMPLEMENTATION 승인 전 source를 작성하지 않는다. 별도 지시 전 push·PR·Actions 실행·공증 제출·artifact 업로드를 하지 않는다. sandbox 예외·shared container·다른 Provider mode·stack 변경이 필요하면 중단하고 architecture/product 영향에 맞춰 재승인한다. 환경이 없다는 이유로 요구를 낮추지 않는다.

**Never:** 제품 로그인/AI 요청, PDF 추출, Library/DB, Paper 삭제 saga를 구현하지 않는다. Story 1.2/1.3의 marker purge 또는 P-2의 최종 locks/전체 OS matrix를 완료로 계산하지 않는다. 실제 사용자의 문서·인증정보에 접근하거나 권한을 바꾸지 않는다. 이 Story 완료는 P-1/P-2 통과나 공개 배포 승인이 아니다.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| 실행 | CPU별 서명된 bundle | 실제 Main/XPC/Agent와 nested runtime의 identity·architecture·sandbox 경계 확인 | 누락/실행 실패는 failed |
| XPC 접근 | read-only 시험 PDF, 보호된 Main/Agent canary, 접근 가능한 통제 network endpoint | 허용 PDF read 성공; write·보호 데이터 read/write·network 연결 거부 | canary 부재나 endpoint 장애는 통과 아닌 inconclusive |
| Agent 접근 | 자기 private zone, Main canary, 외부 시험 파일 | 자기 zone 사용 가능; Main container/group·임의 파일 접근 거부 | 상속된 Main identity/shared group은 failed |
| Main 접근 | Agent가 자체 생성한 private canary | 일반 경로로 broad Agent-zone read/write 거부 | Main에 임시 예외를 주어 검사를 우회하지 않음 |
| 패키징 | 동일 source의 arm64/x86_64 산출물 | nested inventory·signature·notary·staple·Gatekeeper 결과를 각 hash에 연결 | unsigned/rejected/미실행은 blocked 또는 failed |
| 환경 부족 | Intel·toolchain·signing/notary 권한 부족 | 부족한 항목과 재검증 조건 기록 | cross-build/Rosetta/개발 Mac 단독 성공으로 대체 금지 |

</frozen-after-approval>

## Code Map

현재 제품 source/build target은 없다. 다음은 승인 후 만들 최소 경계이며, 기존 구현이 있다는 뜻이 아니다.

- `PaperLens.xcodeproj/project.pbxproj` — Main/XPC/Agent targets, 두 CPU 별도 빌드, macOS 15 deployment target과 embedding/signing 구성.
- `PaperLensApp/App/`, `PDFiumXPC/`, `ProviderAgent/` — Main launch coordinator, no-network worker, 별도 identity의 packaged Agent. 각 target의 Info.plist/entitlements도 같은 경계에 둔다.
- `Contracts/ProviderRPC/` — native/Agent 유일 wire 계약. 별도 시험용 private RPC를 만들지 않는다.
- `Tests/Topology/` — 소유자가 분명한 synthetic canary와 실제 process 경계 검사. 제품 데이터를 사용하지 않는다.
- `scripts/topology/` — 후보 dependency inventory, build/sign/notary 및 증거 수집. 원격 실행은 별도 지시 전 비활성이다.
- `bmad-docs/implementation-artifacts/evidence/1-1/` — 향후 redacted 결과·manifest. binary·secret·raw process output을 저장하지 않는다.

## Tasks & Acceptance

**Execution:**

- [ ] Preflight — Xcode 27.0/Swift 6.4/SDK 27.0 및 SDK/CLI-bin 0.160.0의 architecture 승인은 기록됐다. Team `397452Z366`의 유일한 local Developer ID Application identity를 후보로 선택했다. key 접근/서명, notary credential reference, Intel 실행 경로는 미검증이다. Intel·notary 실제 성공은 해당 검증 단계와 Story 완료 조건이지 prototype 작성 전에 실증을 끝내야 한다는 뜻이 아니다.
- [ ] Launch/topology — 아래 embedded XPC 후보와 entitlement map을 사용해 독립 identity와 private zone을 검증한다. Main sandbox를 상속한 일반 child를 별도 Agent로 오인하지 않는다. 이 revision의 후보 입력·fixture 계약을 근거로 새 SHA 승인을 받은 뒤 prototype을 구현한다. 문서 근거는 실제 격리 성공의 증거가 아니다.
- [ ] 실제 구성요소 — PDFium은 승인 commit `ad5bc13610718aefe737bd9b2f1b258d08e39428`의 complete static library를 PDFiumXPC에 링크·초기화하고 Agent는 packaged official Python SDK/runtime/CLI 실행을 확인한다. PDF 추출·인증 요청 없이 실제 loader/process topology를 검증한다. 후보 버전/hash는 재현용으로 기록하되 P-2 최종 lock으로 표기하지 않는다.
- [ ] 최소 wire — 아래 `topology-v1` 제안의 fields/numeric limits를 `Contracts/ProviderRPC`에서 단일 정의하고 native/Agent 양쪽이 같은 fixtures로 검증한다. 제품 operation별 P-3/Story 1.9 계약 완료로 승격하지 않는다.
- [ ] Negative-access 검증 — 표의 모든 성공/거부 경로를 실제 signed process에서 수행한다. canary 소유 process가 자체 생성·검증·정리하며 테스트를 위해 Main에 Agent zone 접근 권한을 부여하지 않는다. 거부 원인을 sandbox 경계와 연결하고 단순 ENOENT/network 장애를 성공으로 세지 않는다. symlink 경유 접근도 포함한다.
- [ ] 패키징 검증 — nested code를 inside-out 서명하고 개별 identity·entitlement·runtime flag 및 전체 bundle을 검사한다. runtime entitlement 예외가 필요하면 임의 허용하지 말고 재승인한다. 명시적 원격 실행 지시 후에만 notarization/stapling을 수행하고 각 CPU의 clean-machine Gatekeeper launch를 확인한다.
- [ ] 결과 — source commit, CPU/OS build, toolchain, artifact/nested hashes, 계약/entitlement revision, scenario별 pass/failed/blocked/inconclusive, 자동/manual/remote 분류와 한계를 기록한다. raw stdout/stderr, 환경 덤프, 개인 경로·secret은 제외한다. 제품 상태나 gate 통과로 표시하지 않는다.

**Acceptance Criteria:**

1. 별도 IMPLEMENTATION 승인과 환경이 확보된 뒤 arm64/x86_64 각각의 Main·XPC·Agent 실행, nested inventory·서명·entitlements·공증·Gatekeeper 증거가 기록된다. Provider 연결/PDF 추출/공개 배포 완료로 표시하지 않는다.
2. XPC와 Agent의 금지 network/file/container/app-group 접근 및 Main의 broad Agent-zone 접근 거부가 두 실제 CPU 환경에서 검증된다.
3. 자격 증명·실행 환경·필수 증거가 없거나 negative-access 검사가 실패하면 실패/미검증과 재검증 조건을 명시한다. Story를 done 또는 P-1을 통과로 표시하지 않는다.

## Design Notes

- 이 Spec은 **기술 명세 구체화 완료, IMPLEMENTATION 승인 대기 draft**다. 사용자가 `APPROVED: ARCHITECTURE @ 1195c92227cc628e325f5ff24d70cc93639bf7a9`를 명시했고 [Issue #2 승인 기록](https://github.com/jinzer0/PaperLens/issues/2#issuecomment-5987295896)에 보존했다. 승인된 파일의 작성 당시 draft/pending 표기는 승인 기록을 무효화하지 않으며, 표기만 바꾸려고 승인된 artifact를 재커밋하지 않는다. “나머지 특별히 검토할 게 없으면 잠정 승인”은 조건부 의사로 보존한다. 이번 조사로 후보 입력 계약은 닫았지만 새 runtime/빌드 입력을 담은 이 Spec commit SHA에 대한 확정 구현 승인으로 소급하지 않는다. artifact 취득·build·격리 성공은 승인 후 검증 대상이다.
- Intel은 적합한 GitHub Actions runner를 우선 조사하되 실제 runner 가용성·Xcode·signing 권한·GUI/Gatekeeper 증거를 확인해야 한다. 충족하지 못하면 별도 Intel Mac/self-hosted 환경이 필요하다. 현재 원격 실행/권한/Intel 환경은 확인되지 않았다.
- PRODUCT baseline: `5eac3bb9424ad893eca7d63bc319b71f580838ed`. ARCHITECTURE baseline: `1195c92227cc628e325f5ff24d70cc93639bf7a9` (이전 `cdabe4419606ab0c1efebcfeb79bded0fe344512` 대체). 관련 AD-2/4/7/13, AR-002~005/020, FR-002/005/035 선행 검증, R-005/007을 추적한다.
- Story 원본: `bmad-docs/planning-artifacts/epics.md` §1.1. 작성 시 파일 SHA-256: `0dbed1d4dac4435b8ce29a3fd8bfe273f730f99e8c5f4a98a2e76a33bee75434`. 기존 untracked planning/governance 파일은 이 작업의 커밋에 임의 포함하지 않는다. 위 AC·범위는 원본의 Story 1.1 경계를 이 커밋에 보존한다.
- 승인 후 `epics.md` AR-002 한 줄만 새 stack/SHA로 동기화했다. 현재 파일 SHA-256은 `bc776329ab7d74016634ebefad7a5fc70c4761b1da848f55806ba18f52ba46a6`이며 AR-002를 원래 한 줄로 되돌린 메모리 사본의 hash가 위 최초 hash와 일치함을 검사했다. 다른 사용자 내용과 Story AC·sprint 상태는 그대로다. 기존 untracked 파일 전체는 이번 커밋에 포함하지 않는다.

### Launch 후보와 identity

2026-10-05 조사 결론: **Provider Agent 자체를 embedded XPC service로 시작하고 그 안에서만 Python/CLI를 자식으로 실행하는 후보**를 사용한다. Apple은 `NSTask`/`posix_spawn`으로 각 부분에 독립 sandbox를 부여할 수 없고 XPC service는 자체 sandbox를 갖는다고 설명한다 [A1]. 따라서 Main → `Process(Python)`은 제외한다. Login Item·LaunchAgent 등록, privileged helper, global Mach service, app group은 이 후보에 필요하지 않다.

| 역할 | bundle/code identity 후보 | app 내부 위치 | 실행/수명 |
| --- | --- | --- | --- |
| Main | `io.github.jinzer0.PaperLens` | `PaperLens.app/Contents/MacOS/PaperLens` | 사용자가 GUI로 실행 |
| PDF worker | `io.github.jinzer0.PaperLens.PDFiumXPC` | `Contents/XPCServices/PDFiumXPC.xpc` | Main의 `NSXPCConnection(serviceName:)`, service listener |
| Agent | `io.github.jinzer0.PaperLens.ProviderAgent` | `Contents/XPCServices/ProviderAgent.xpc` | 위와 같은 on-demand launchd 경로; Main의 직접 spawn 금지 |
| Python/CLI | `io.github.jinzer0.PaperLens.ProviderAgent.Python` / `io.github.jinzer0.PaperLens.ProviderAgent.Codex` | Agent bundle의 `Contents/MacOS/`, libraries는 `Contents/Frameworks/`, pure Python/data는 `Contents/Resources/` | Agent → packaged Python → packaged CLI; host PATH 탐색 금지 |

각 XPC Info.plist는 자신의 `CFBundleIdentifier`/`CFBundleExecutable`, `CFBundlePackageType=XPC!`, `XPCService.ServiceType=Application`을 사용한다. 모든 executable의 deployment target은 macOS 15, build configuration은 Release, hardened runtime은 활성이다. 서로 다른 bundle ID나 `$HOME` 문자열만으로 독립 container를 입증했다고 보지 않는다. 실제 container URL·code identity·canary 접근 결과를 함께 확인한다. 기본 sandbox의 시스템 파일 읽기 허용까지 “모든 filesystem 접근 금지”라고 표현하지 않는다.

**핵심 미입증 사항:** Apple의 “각 XPC service는 자체 sandbox를 가진다”는 설명은 Main↔Agent의 양방향 container 접근 거부를 보장하는 문구가 아니다. 실제 거부가 성립하지 않으면 이 후보를 폐기/재설계하고 재승인한다. “우리 코드가 그 경로를 읽지 않는다”는 정책으로 OS 격리를 대체하지 않는다.

Main↔Agent transport는 `Contracts/ProviderRPC`에 선언한 **단일 `sendFrame(Data)` 호출과 `receiveFrame(Data)` callback**으로 고정한 후보다. 각 Data는 아래 prefix를 포함한 완전한 frame 하나이며 XPC는 운반만 한다. Agent 내부 Python stdin/stdout도 같은 frame을 사용하고 native bootstrap은 별도 operation/schema를 만들지 않는다. SDK↔CLI의 공식 app-server JSON-RPC는 Agent 내부 adapter detail이며 Main에 노출하거나 ProviderRPC를 대체하지 않는다. SDK import/CLI initialize까지만 검증하고 login/thread/turn을 보내지 않는다.

launchd가 시작한 XPC service의 stdout을 Main의 child pipe처럼 읽지 않는다. bootstrap stdout은 사용하지 않고 Agent가 생성한 Python bridge의 stdout만 전용 pipe로 연결한다. SDK/CLI stdout은 해당 내부 adapter가 소비하며 ProviderRPC pipe에 그대로 연결하지 않는다.

Main의 outbound connection과 service가 수락한 inbound connection 모두 `setCodeSigningRequirement`를 **resume 전에 한 번** 설정한다. 요구조건은 Apple signing anchor, Team `397452Z366`, 상대의 정확한 code identifier, Developer ID Application certificate 조건을 포함한다. 해당 Team은 local identity의 공개 정보만 읽어 선택했으며 실제 서명 manifest가 일치해야 한다. PID만 조회해 신원을 확인하지 않는다. `NSXPCListener.service()`에 `setConnectionCodeSigningRequirement`를 호출하지 않는다: 로컬 SDK 헤더는 해당 listener API를 anonymous/Mach-service listener로 제한한다 [A3]. 같은 Team의 다른 bundle, 잘못된 signer, unsigned peer는 거절 시험 대상이다.

PDF 입력은 Main이 연 synthetic PDF의 `O_RDONLY` descriptor를 XPC로 전달한다. worker가 임의 path를 받아 열거나 security-scoped bookmark를 보존하지 않는다. read 성공과 descriptor write 실패를 검사하되 **read-only fd의 EBADF만으로 sandbox write 거부를 입증하지 않는다**. 별도 경로 reopen/write 거부와 owner positive control을 함께 검사한다.

### 최소 entitlement 후보

아래 표의 entitlement 외 권한은 추가하지 않는다. signing metadata와 executable entitlement, dylib signature를 구분해 inventory에 기록한다.

| 대상 | `true`인 sandbox entitlements | 이유 / 제외 |
| --- | --- | --- |
| Main | `com.apple.security.app-sandbox`, `com.apple.security.network.client` | 외부 통제 endpoint positive control; synthetic PDF에 user-selected 권한 불필요 |
| PDFium XPC | `com.apple.security.app-sandbox` | network client/server, inherit, file exceptions 없음 |
| Provider Agent XPC | `com.apple.security.app-sandbox`, `com.apple.security.network.client` | 자체 sandbox의 outbound network; inherit 없음 |
| Python 및 CLI child executable | `com.apple.security.app-sandbox`, `com.apple.security.inherit` | **Agent** sandbox 상속; Apple helper 지침의 두 entitlement만 사용 [A2] |
| PDFium/Python extension/dylib | executable 권한을 부여하지 않고 nested code로 서명 | 로드한 process의 sandbox 경계; dylib를 별도 sandbox process로 세지 않음 |

모든 executable에 runtime signing flag를 적용한다. `get-task-allow`, app groups, keychain groups, temporary exceptions, absolute-path exceptions, `disable-library-validation`, JIT/unsigned executable memory 예외는 없다. Python child는 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`로 불필요한 개발 권한 주입을 막는다 [A2]. packaged extension/library를 동일 Team으로 inside-out 서명한 상태에서 로드하지 못하면 실패로 기록하고 예외를 자동 추가하지 않는다.

`network.client`는 목적지별 allowlist가 아니다. Agent의 “허용되지 않은 network” 검사는 inbound server 권한 부재와 승인된 통제 endpoint 사용 정책을 구분한다. 이 entitlement만으로 “OpenAI 외 모든 host는 OS가 차단한다”고 주장하지 않는다. Provider 목적지 제한이 OS 수준 요구로 해석된다면 이 후보로 충족했다고 처리하지 말고 AD-2 해석/architecture 재승인 경계로 올린다.

Agent는 자기가 해석한 private container 안에만 cwd/HOME/TMPDIR/CODEX_HOME을 설정한다. child env는 `HOME`, `TMPDIR`, `CODEX_HOME`, `PATH`(bundle 내부 실행 경로만), `LANG=C`, `LC_ALL=C`만 새로 구성하며 부모 environment를 복사하지 않는다. Python은 isolated mode와 bytecode write 비활성으로 packaged entry point를 실행한다. proxy/API-key/DYLD/PYTHON 환경값과 secret argv를 전달하지 않는다. SDK가 이 allowlist를 보존하는지는 pinned source/child-launch 검토와 이후 실행으로 확인해야 하며 현재 확인 완료가 아니다.

### 최소 ProviderRPC 제안 — `topology-v1`

이 절은 승인 전 계약 제안이다. 실제 schema/code는 만들지 않았다. 제품 auth/generation/Paper purge method는 여기에 추가하지 않는다.

- Frame: unsigned 32-bit big-endian **JSON byte 수**, 이어서 UTF-8 JSON object. body `1..65536` bytes, frame 최대 `65540` bytes. prefix 초과를 allocation 전에 거절한다. JSON depth 최대 8, object key 최대 16, array 최대 32 items, string 최대 256 UTF-8 bytes. 중복 key·invalid UTF-8·NaN·unknown field를 거절한다.
- Request: 정확히 `{kind:"request", id:UUID, method:enum, timeoutMs:integer, params:object}`. UUID는 lowercase canonical UUID v4 문자열이고 연결 간에도 재사용하지 않는다. `timeoutMs`는 `1..10000`, 수신 시점부터 monotonic deadline으로 측정한다.
- Terminal: 성공은 정확히 `{kind:"result", id, result:object}`, 실패는 `{kind:"error", id, code:enum}`. error code는 `versionMismatch`, `handshakeRequired`, `unknownMethod`, `invalidParams`, `busy`, `cancelled`, `timeout`, `unavailable`, `internal`뿐이다. path/exception/SDK text/message 필드는 없다.
- 첫 request는 `hello`, 연결 후 5000 ms 안에 완료해야 한다. version은 major `1`, minor `0`, capabilities는 정확히 `["topology-v1"]`; major 불일치는 `versionMismatch` 후 연결 종료, minor는 양쪽 최소값을 선택하고 이 revision에서 0만 지원한다. handshake 전 probe를 수행하지 않는다.

| Method | 정확한 params | 성공 result |
| --- | --- | --- |
| `hello` | `{major:integer, minor:integer, capabilities:[string]}` | `{major:1, minor:0, capabilities:["topology-v1"]}` |
| `topology.runtime` | `{}` | `{sdkImported:bool, cliInitialized:bool, architecture:"arm64" 또는 "x86_64"}` |
| `topology.prepare` | `{runID:UUID}` | `{prepared:bool}` — Agent 자기 zone의 synthetic canary만 생성 |
| `topology.probe` | `{runID:UUID, caseID:enum}` | `{outcome:"allowed" 또는 "denied" 또는 "inconclusive", reason:enum}` |
| `topology.cleanup` | `{runID:UUID}` | `{absent:bool}` — 자기 소유 시험 canary만 정리; 제품 purge 아님 |
| `topology.wait` | `{durationMs:integer}` (`1..5000`) | `{elapsed:bool}` — cancellation/deadline 경쟁 검증용, I/O 없음 |
| `cancel` | `{targetID:UUID}` | `{accepted:bool}` |

`caseID`는 `ownZoneReadWrite`, `mainCanaryRead`, `mainCanaryWrite`, `externalCanaryRead`, `externalCanaryWrite`, `mainCanarySymlinkRead`, `externalCanarySymlinkRead`, `foreignGroupCanaryRead`, `foreignGroupCanaryWrite`, `foreignGroupCanarySymlinkRead`, `inboundListen`의 닫힌 목록이다. `reason`은 `none`, `permissionDenied`, `missingFixture`, `controlFailed`, `unexpectedErrno`뿐이다. `permissionDenied`만으로 sandbox 귀속을 확정하지 않고 아래 별도 증거를 요구한다. arbitrary path/URL/command/JSON passthrough는 금지한다. fixture 위치는 아래 고정 map만 사용한다.

동시에 outstanding request 최대 4개(일반 3개 + cancel 전용 1개), 각 방향 queued frame 최대 4개/262160 bytes, 연결당 request 총수 최대 256개 후 정상 종료한다. 넘친 신규 유효 request는 `busy`, framing/중복 ID/해석 불가능한 envelope/queue overflow는 fail-closed 연결 종료다. 이 revision의 chunk/event/stream 수는 **0**이며 streaming operation을 허용하지 않는다. child stdout은 frame 전용, stderr는 읽어 버리며 저장하지 않는다.

각 id의 완료 전이는 serial executor 한 곳에서 경쟁을 판정한다. cancel이 먼저 이기면 target은 `cancelled` terminal 한 번, 늦은 result는 폐기한다. 이미 완료/없는 target의 cancel은 `accepted:false`. deadline도 같은 fence를 사용한다. crash/EOF/invalid frame에서는 상대가 terminal을 보냈다고 꾸미지 않고 caller가 미완료 id를 각각 local `unavailable`로 한 번 종결한다. XPC 자동 재시작 후에는 새 handshake가 필요하며 이전 operation을 replay하지 않는다.

### Dependency 조사 — 채택/다운로드/실행과 구분

승인된 compatibility target은 **official Python SDK/CLI-bin `0.160.0` 일치 조합**이다. 공식 SDK는 Python 3.10+, `pydantic>=2.12`, `packaging>=26.2`, `openai-codex-cli-bin==0.160.0`을 요구한다 [D1/D2]. 아래 특정 version/hash만 Story 1.1 후보로 사용하고 latest resolution은 금지한다. 최종 P-2 lock이나 두 CPU 실행 성공을 뜻하지 않는다.

| 확인 대상 | upstream이 게시한 SHA-256 / 식별자 | 판정 |
| --- | --- | --- |
| `openai_codex-0.160.0-py3-none-any.whl` | `61d2d855ca2ebedfd51280fbeb60ff31fc47ccbd55ebce186505e3f3da096921` | SDK wheel metadata [D2]; binary 실행 없음 |
| `openai_codex_cli_bin-0.160.0-py3-none-macosx_11_0_arm64.whl` | `c9b472e8928d8f94f65e43ba4928e3ecac071ccf8680bbb8281334e32cec409b` | arm64 runtime metadata [D3] |
| `openai_codex_cli_bin-0.160.0-py3-none-macosx_10_9_x86_64.whl` | `06571f34b99feee1f1116577f66b82b1b6d582993e07d2099e20e346c73de374` | Intel runtime metadata [D3] |
| `openai_codex-0.160.0.tar.gz` | `31c94d69a81794aaadfaad371c5f95480a28cd7703d9fc7ca3c574286cacaff3` | source archive를 `/tmp`로 다운로드해 로컬 SHA-256 일치 확인, 읽기 전용 검토 [D4] |
| PDFium | commit `ad5bc13610718aefe737bd9b2f1b258d08e39428` | 승인 pin 유지; 아래 source-build 경로, 정확한 prebuilt 대체 없음 |

기존 SDK 0.147.0/실행 CLI 0.150.1 조합은 SDK의 CLI-bin 0.147.0 의존성까지 포장해야 하므로 승인된 0.160.0 조합에서는 제외한다. old runtime·fallback·metadata 삭제·`--no-deps` 우회는 추가하지 않는다. SDK 0.160.0의 `resolve_codex_bin()`에서도 명시 경로가 있으면 탐색 없이 선택하고 없는 경로는 실패하는 것을 source archive에서 확인했다. 실제 실행은 포함된 CLI-bin 0.160.0 distribution의 검증된 bundle 내부 executable 경로로 고정한다.

source archive의 `src/openai_codex/client.py`/`api.py`/`__init__.py`를 읽었으며 SDK를 설치·import·실행하지 않았다. GitHub `python-v0.160.0` tag 조회는 HTTP 404였으므로 존재하지 않는 commit pin을 발명하지 않고 위 archive hash를 source provenance로 사용한다.

SDK 0.160.0의 `start()`는 `os.environ.copy()` 뒤 `config.env`를 합친다. `CodexConfig.env`만으로 allowlist를 강제할 수 없으므로 Agent가 **Python 프로세스 시작 전에** 새 환경을 구성한다. 명시 packaged `codex_bin`과 private `cwd`를 사용하고 `launch_args_override`는 사용하지 않는다. no-auth smoke는 SDK import → 공식 `openai_codex.client.CodexClient`의 start/initialize/initialized → close 및 실제 child 종료 확인까지만 수행한다. default approval handler는 command/file-change를 accept하므로 사용하지 않고 주입 handler로 모든 approval을 거절하며 예상 밖 server request는 실패로 종결한다. close는 별도 shutdown RPC가 아니라 stdin close/terminate/wait/kill 경로다. SDK의 blocking waiter에는 Agent supervisor의 기존 10000 ms 상한을 적용한다. login/account/models/thread/turn을 호출하지 않는다. no-auth가 network-free 또는 filesystem-free라는 뜻은 아니다.

위 wheel hash는 **upstream metadata 값**이며 로컬 binary 검증·실행 증거가 아니다. source archive만 다운로드·hash 검증·열람했다. SDK 내부 stderr tail을 예외 문자열에 포함하는 구현도 확인했으므로 raw SDK exception을 wire/diagnostics로 전달하지 않는다. CPython/전이 wheel 및 PDFium의 후보 source/build-tool 입력은 아래에 고정했다. 전체 P-2 배포 lock 감사와 실제 다운로드 bytes 검증은 완료됐다는 뜻이 아니다.

#### CPython 및 전이 wheel 후보

CPython은 Astral `python-build-standalone` release `20261003`의 **3.13.16, 일반 GIL-enabled `install_only_stripped`**를 사용한다 [D5]. 이는 공식 OpenAI SDK와 구분되는 제3자 CPython 재배포다. release API의 정식 immutable release와 두 architecture asset을 확인했으며 다운로드·실행·재서명 검증은 아직 아니다.

| 정확한 배포 파일 | upstream SHA-256 |
| --- | --- |
| `cpython-3.13.16+20261003-aarch64-apple-darwin-install_only_stripped.tar.gz` | `9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147` |
| `cpython-3.13.16+20261003-x86_64-apple-darwin-install_only_stripped.tar.gz` | `b4dad38ba6a344555ccb71a1b08caad0a6c0dda88c5803658bc95bd7f04e9f5c` |
| `annotated_types-0.8.0-py3-none-any.whl` | `f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0` |
| `packaging-26.3-py3-none-any.whl` | `d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c` |
| `pydantic-2.13.5-py3-none-any.whl` | `346a034f080da3755d8e9cb5e00e8b07de1d39e4f6e2c87d8ab7cafa0b269a73` |
| `pydantic_core-2.46.5-cp313-cp313-macosx_11_0_arm64.whl` | `f332f0e72a5a0400141f830744e141bf9f97917878dbe968669e8a7fefea78ff` |
| `pydantic_core-2.46.5-cp313-cp313-macosx_10_12_x86_64.whl` | `b7ca9034437b6022f941f4857459562ee00a560b97e7cce8a0ec5a74fc6766e0` |
| `typing_extensions-4.16.0-py3-none-any.whl` | `481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8` |
| `typing_inspection-0.4.4-py3-none-any.whl` | `65b8397ba37ccbce054456aaccddfc91e6e3083c92824df348d96ca832f3f147` |

`uv 0.12.23`에서 `openai-codex==0.160.0`, Python 3.13, `--only-binary :all:`을 지정한 macOS `aarch64-apple-darwin`/`x86_64-apple-darwin` resolution은 동일한 **8개 version 집합**을 반환했다. 실제 명령은 `uv pip compile - --python-version 3.13 --python-platform <target> --only-binary :all: --no-header --no-annotate --output-file <temporary-path>`이며 입력은 위 SDK exact pin이다. 결과는 SDK/CLI-bin 두 개와 표의 여섯 Python package다. extras·source wheel build·host site-packages를 사용하지 않는다. 이후 resolution은 이 pin 집합과 위 architecture별 hash를 모두 강제한다.

이 8개 pin을 입력으로 `--python-version 3.13.16 --offline --only-binary :all:`을 지정한 양쪽 재-resolution도 같은 결과였다. 단 uv는 local 3.13.16이 없어서 dependency build용 interpreter로 3.13.12를 사용한다는 경고를 냈다. 경고를 숨기지 않으며 wheel-only resolution 중 source dependency build는 수행하지 않았다. 이 검사는 metadata 만족성일 뿐 CPython 3.13.16 설치·SDK 실행 호환성 증거가 아니다.

Runtime archive는 Python executable 하나가 아니라 배포 tree와 동봉 native libraries/license를 포함한다. relocation 뒤 `otool` load-command 및 nested-code inventory로 app 밖 Homebrew/build-machine 경로 의존을 거절한다. `_sysconfigdata`/Makefile의 build-time 경로는 runtime이 relocatable임을 자동 보장하지 않으며 runtime 안에서 extension을 빌드하지 않는다. native extension은 위 cp313 wheel만 사용한다. bundle 경로 재배치·서명·sandbox inheritance·실행 증거는 승인 후 prototype 검증 대상이다.

#### PDFium exact-pin source-build 입력 계약

조사한 bblanchon/pdfium-binaries `chromium/8035` release는 승인 commit을 changelog에 포함하지만 upstream branch tip은 `6f2272e1f3aaa141305475b83ef4eac2c1f527b8`이다. 이를 승인 commit의 binary라고 사용하지 않는다 [D7]. 실제 정확한 commit용 macOS 두 CPU prebuilt/hash 조합은 확인하지 못했다.

승인 commit의 `BUILD.gn`은 `pdf_is_complete_lib`일 때 `static_component_type="static_library"`, `complete_static_lib=true`를 설정한다 [D8]. 따라서 추가 provider dylib patch 대신 **upstream complete static library를 PDFiumXPC에 링크하는 후보**를 사용한다. GN에는 `is_component_build=false`, `pdf_is_complete_lib=true`, `pdf_enable_v8=false`, `pdf_enable_xfa=false`, `target_os="mac"`, CPU별 `target_cpu="arm64"`/`"x64"`를 명시하고 macOS deployment target 15를 검증한다. `FPDF_InitLibrary()`/`FPDF_DestroyLibrary()`만 호출하며 extraction/document open은 하지 않는다. static archive에 별도 sandbox identity를 부여하지 않고 최종 XPC executable에 적용한다.

확인한 source pins:

| 입력 | 관측된 identity |
| --- | --- |
| PDFium tree Git object | `7a17f761fbcaca163cef3575ed98a0a2058dbb3d` |
| DEPS Git blob | `169680f06af94277eba6ec9e9597635b40092daf` |
| build revision | `299066ef2d5d1396f97e582627880cebe33f497a` |
| buildtools revision | `9e7655f4ee433ef4c6efcffd57e379db8f8c0432` |
| depot_tools revision | `732902ab86f8bd629bee00af102d5aa2d9336166` |
| Clang management source revision | `e4816757c45a072f08279139108a0a937bbeb239` |
| GN CIPD version | `git_revision:1c79e13d17a1760d6c6401c90061411842bd4881` |
| Ninja CIPD version | `version:3@1.12.1.chromium.4` |

위 표는 Git/CIPD 식별자이며 binary SHA-256이 아니다. macOS DEPS graph는 이 exact DEPS blob을 authority로 사용하고 revision/tag를 latest로 갱신하지 않는다. `checkout_configuration="minimal"`, `checkout_rust=false`를 사용하되 DEPS의 무조건부 Rust toolchain GCS 항목까지 사라진다고 주장하지 않는다. 남는 GCS object도 해당 DEPS의 generation/hash를 그대로 강제한다. depot_tools는 위 commit으로 고정하고 자동 update를 비활성화한다.

PDFium용 Clang package version은 pinned `tools/clang/scripts/update.py` 및 DEPS가 일치하는 `llvmorg-23-init-19482-g53d18800-2`다 [D9]. 다음 GCS object는 `https://commondatastorage.googleapis.com/chromium-browser-clang/` 아래의 경로다. generation 및 SHA-256을 모두 검사한다.

| host CPU / object | generation | SHA-256 |
| --- | --- | --- |
| arm64 / `Mac_arm64/clang-llvmorg-23-init-19482-g53d18800-2.tar.xz` | `1785366640567652` | `a9c5ab02bfdc07a6ad6c6711d884dccab1fdf52e05e71aa9328039cddaff3664` |
| x64 / `Mac/clang-llvmorg-23-init-19482-g53d18800-2.tar.xz` | `1785366628543558` | `51350c8f6da5c92ab19b0b17a3cbc7762b960b29fd68530e9feb52eb5079ae19` |
| arm64 / `Mac_arm64/llvmobjdump-llvmorg-23-init-19482-g53d18800-2.tar.xz` | `1785366640876543` | `39fad69229bd7f8b440809f74a711175f5f0ed3cc92c4d6f3652c0ca57e39c2e` |
| x64 / `Mac/llvmobjdump-llvmorg-23-init-19482-g53d18800-2.tar.xz` | `1785366628828288` | `ab7600041b0db44338b42c55b7ed1224edc10c96283d71e53a373820be9e62f9` |

GN/Ninja는 DEPS의 tag뿐 아니라 확인한 CIPD immutable instance를 고정한다 [D10]. 아래 SHA-256은 package archive hash이지 executable 자체 hash가 아니다.

| CIPD package | instance ID | SHA-256 |
| --- | --- | --- |
| `gn/gn/mac-arm64` | `pSLAXpGkmW3xgEhISBOgpR68Z3Z6HVOnu_rF7Ju0t50C` | `a522c05e91a4996df18048484813a0a51ebc67767a1d53a7bbfac5ec9bb4b79d` |
| `gn/gn/mac-amd64` | `rIjtpVIc0WCOx1IcxodnmiQXXcL7qCaWHsHydJpqGdgC` | `ac88eda5521cd1608ec7521cc687679a24175dc2fba826961ec1f2749a6a19d8` |
| `infra/3pp/tools/ninja/mac-arm64` | `xem0_6s7Lt77xBhJ_IHxFsjQR7JYkGvswGG-nsrwSv0C` | `c5e9b4ffab3b2edefbc41849fc81f116c8d047b258906becc061be9ecaf04afd` |
| `infra/3pp/tools/ninja/mac-amd64` | `mGbmncDR78ysAZaXITtasuAzLcxiloLxNzPgeS6pURkC` | `9866e69dc0d1efccac019697213b5ab2e0332dcc629682f13733e0792ea95119` |

초기 build host는 현재 arm64 Mac이다. 이 host의 arm64 도구로 arm64/x64 target을 각각 만들되 cross-build를 실제 Intel 실행 증거로 세지 않는다. Intel host에서 재빌드할 때만 x64 tool package를 사용한다.

공통 GN args는 위 static/V8/XFA flags에 더해 `is_debug=false`, `pdf_is_standalone=false`, `pdf_use_skia=false`, `pdf_use_agg=true`, `pdf_enable_fontations=false`, `pdf_enable_rust_bmp=false`, `pdf_enable_rust_jpeg=false`, `pdf_enable_rust_png=false`, `enable_rust=false`, `use_custom_libcxx=false`다 [D11]. AGG/Skia 모두 false로 만들지 않는다. tests/sample binary를 빌드하지 않는 선택이며 upstream PDFium library를 Init/Destroy 전용 stub으로 줄이는 것이 아니다.

`mac_sdk_path`는 승인 Xcode 27.0의 실제 SDK 27.0 경로, `mac_deployment_target="15.0"`, `mac_min_system_version="15.0"`으로 고정한다. Xcode XPC와 system libc++ linkage를 사용한다. `use_custom_libcxx=false`는 pinned build source가 제공하지만 장래 제거를 경고하는 옵션이므로 향후 PDFium pin 변경 시 다시 검토한다. 현재 pin을 자동 upgrade하지 않는다. GN이 산출한 `pdfium` static output을 확인해 `.build/topology/<cpu>/deps/libpdfium.a`로 수집하며 provider patch는 적용하지 않는다.

이 Git/DEPS blob + GCS generation/hash + CIPD instance/hash + GN args가 후보 입력 계약이다. 실제 다운로드 후 불일치, undeclared input, compile/link/InitLibrary 실패는 즉시 차단하고 원인을 기록한다. 입력 교체나 PDFium pin/권한 변경이 필요하면 재승인한다. 아직 없는 자체 build 출력 hash나 두 CPU 성공은 구현 승인 전 선행 조건으로 요구하지 않는다.

### Synthetic fixture 및 증거 계약

이 절은 실행 결과가 아닌 시험 설계다. 별도 시험계정의 home `H=/Users/paperlens-topology`를 두 CPU에서 동일하게 사용한다. 현재 사용자 계정에 이 fixture를 만들지 않는다. `r`은 검증된 runID, `M0=H/Library/Containers/io.github.jinzer0.PaperLens/Data`, `A0=H/Library/Containers/io.github.jinzer0.PaperLens.ProviderAgent/Data`다. 소유 process가 실제 container URL과 고정 map의 일치를 확인하며 불일치 시 다른 경로로 대체하지 않는다.

| Alias | 고정 경로 | 생성·검증·정리 owner |
| --- | --- | --- |
| M | `M0/Library/Application Support/PaperLensTopology/r/db.canary` | Main |
| A | `A0/Library/Application Support/PaperLensTopology/r/secret.canary` | Agent |
| C | `A0/Library/Caches/PaperLensTopology/r/cache.canary` | Agent |
| E | `H/Library/Application Support/PaperLensTopologyFixtureHost/r/external.canary` | 제품 밖의 같은 UID 비-sandbox 시험 harness |
| G | `G0/PaperLensTopology/r/group.canary` | 제품 밖의 signed sandbox fixture-group-owner |
| PDF | `M0/Library/Application Support/PaperLensTopology/r/input.pdf` | Main |

`G0`는 선택한 Team의 fixture 전용 group `397452Z366.io.github.jinzer0.PaperLens.TopologyFixture`를 가진 owner가 OS로부터 얻고 검증한 실제 group URL이다. 두 CPU의 signed fixture-map은 같은 값을 사용한다. 임의 폴더를 만들어 group이라고 부르지 않는다. Main/Agent/PDFium에는 이 group entitlement를 주지 않는다. 시험용 owner 두 개는 `Tests/Topology/` 경계 안에서만 만들고 배포 앱에 포함하지 않는다. group provisioning이 준비되지 않으면 해당 검사는 blocked다.

Agent는 signed map과 runID만으로 M/E/G 경로를 계산한다. 보호 canary fd/bookmark/security-scoped URL은 전달하지 않는다. Main/Agent의 synthetic marker는 공개된 고정 bytes이며 실제 DB/Secrets/Cache 기능이 아니다. 새 fixture만 exclusive 생성하며 기존 파일이나 symlink를 덮어쓰지 않는다. directory `0700`, file `0600`, 같은 UID 및 추가 ACL 없음의 positive control을 기록한다.

| Actor | 대상 | 연산 및 기대 |
| --- | --- | --- |
| 각 owner | 자기 M/A/C/E/G | 시험 전후 기존 파일 read/write 성공, marker 훼손 확인 |
| Agent | M/E/G 각각 | read, 기존 파일 1-byte write, 자기 zone의 고정-target symlink를 통한 read 모두 sandbox 거부 |
| Main | A/C 각각 | 위 세 연산 모두 sandbox 거부 |
| PDFium XPC | M/A/C/E/G 각각 | 위 세 연산 모두 sandbox 거부 |
| PDFium XPC | PDF | 전달된 fd read 성공·write 거부; 고정 원래 경로의 reopen-write는 별도로 sandbox 거부 |

금지 write 검사는 create/truncate하지 않는다. owner는 예상치 못한 write를 확인하기 전에 marker를 복원하지 않는다. Agent `ownZoneReadWrite`는 A/C를 함께 확인한다. 동일 UID 비-sandbox control도 고정 synthetic 경로만 사용한다. 보호 container에 대한 control이 TCC로 막히면 FDA를 부여해 우회하지 않고 inconclusive다.

Network 통제 endpoint는 시험 harness의 `127.0.0.1:18765`이며 고정 synthetic nonce만 송수신한다. Main/Agent 연결 성공을 전후 확인하고 PDFium의 connect 거부를 검사한다. Agent의 inbound listen 검사는 `127.0.0.1:18766`에서 수행하고 비-sandbox harness로 전후 정상 bind/listen control을 둔다. 각 network 작업 timeout은 2000 ms다. 이미 사용 중인 port의 process를 중단하지 않으며 EADDRINUSE/ECONNREFUSED/timeout은 sandbox PASS가 아니다. loopback 거부가 실제로 성립하지 않으면 성공으로 꾸미지 않는다.

Manifest 필드는 `schemaRevision, sourceCommit, artifactHash, fixtureMapHash, entitlementHash, OSBuild, actualCPU, codeIdentityRefs`로 고정한다. Case 필드는 `runID, caseID, fixtureID, actorInstanceRef, operation, ownerPre, ownerPost, sameUIDControl, expectedRootMatched, posixACLControl, syscallResult, errno, sandboxDenialRef, promptObserved, verdict`다. `verdict`는 pass/failed/blocked/inconclusive다. denied syscall과 정상 control, 해당 actor/operation/fixture로 귀속되는 OS App Sandbox denial 관측이 모두 있어야 거부 PASS다. raw OS 로그는 저장하지 않으며 denial reference는 safe-code projection만 가리킨다. 개인 절대경로·username·marker 내용·환경·credential은 저장하지 않고 M/A/C/E/G/PDF alias를 사용한다.

### 승인된 toolchain 설치와 실제 실패 기록

- 사용자 선택: **“6.3.3 추가 설치·환경 검증 승인”**. 공식 문서의 `installer -target CurrentUserHomeDirectory -pkg …` 방식으로 사용자 Toolchains에 추가 설치했다. 전역 Xcode 선택과 shell 설정은 바꾸지 않았다.
- 설치 파일: `swift-6.3.3-RELEASE-osx.pkg`, 로컬 계산 SHA-256 `ee82e57774d6650f94aa06302435d6f44a055b9411698db8ecb85d9a3bcc91d0`. `pkgutil --check-signature`에서 `Developer ID Installer: Swift Open Source (V9AUD2URP3)`와 Apple notary trusted를 확인한 뒤 설치했다. 이는 **Swift 배포자 패키지** 검증이지 PaperLens 서명·공증이 아니다.
- 설치 결과 success; toolchain ID는 `org.swift.633202606251a`. `xcrun --toolchain org.swift.633202606251a swift --version` 및 직접 binary 실행은 **Swift 6.3.3**을 보고했다. 초기 absolute-path `--toolchain` 호출은 default 6.4로 해석됐으므로 확인된 identifier만 사용한다.
- `/tmp`의 제품과 무관한 최소 Foundation/UUID smoke를 `-sdk <Xcode 27 macOS SDK> -target arm64-apple-macosx15.0`으로 컴파일했다. 결과 **failed**: `unknown argument: '-target-arch-variant'`, 이어서 `cannot find 'UUID' in scope`. `TOOLCHAINS=org.swift.633202606251a`와 직접 swiftc를 지정한 재검사도 동일 실패였다. 실행 binary는 얻지 못했다.
- 동일 입력/SDK/target의 default Swift 6.4 control은 compile·실행 성공, 예상 UUID `00000000-0000-0000-0000-000000000001`을 출력했다. 실행 뒤에도 default compiler는 6.4, `xcode-select -p`는 기존 `/Applications/Xcode.app/Contents/Developer`였다. 이 control 성공은 stack 변경 승인이나 PaperLens 테스트 통과가 아니다.
- 따라서 “Swift 6.3.3 설치됨”과 “앱 build 가능”은 다르다. 6.3.3/SDK27 조합은 blocked다. Apple 표는 Xcode 26.6을 Swift 6.3 계열/macOS SDK 26.5로 분류한다 [E3]. 당시 호환 Xcode 확보와 Swift6.4 변경안을 비교했으며, 이후 사용자는 후자를 선택하고 architecture1195c922를 승인했다. 현재 구현 기준은 승인된 Xcode27/Swift6.4다. 설치된 6.3.3은 사용하지 않으며 사용자 toolchain을 임의 제거하지 않는다.

### 환경 및 승인 전 차단 목록

| 항목 | 이번에 확인한 사실 | 해제 조건 |
| --- | --- | --- |
| Swift | Xcode27.0/Swift6.4/SDK27.0 architecture 승인 기록 완료, local Foundation control 성공 | 두 CPU 앱 build·실행 검증은 별도 |
| Developer ID | valid Developer ID Application identity **1개**, 공개 Team `397452Z366` 선택. 이름·fingerprint·private key 미출력 | key 접근/서명 가능성 확인; identity 존재를 서명 성공으로 간주하지 않음 |
| Notary | credential 내용/저장소 미조회, 제출 없음 | 사용 credential reference 및 공증 제출 명시적 지시 |
| Intel | GitHub 문서에 `macos-15-intel`/`macos-26-intel` 존재 [E2]; 저장소 self-hosted runner API 결과 0개 | 실제 Intel 실행 경로/원격 실행 지시 확보. hosted label 존재는 job 실행/GUI Gatekeeper 증거 아님 |
| Dependency | CPython3.13.16 두 CPU, SDK/CLI-bin0.160.0 및 전이 wheels, PDFium exact source/DEPS·Clang/GN/Ninja immutable 입력 및 GN recipe 고정 | 승인 후 실제 취득 hash/build/link/runtime 검증; 전체 P-2 lock·nested output inventory는 아직 미완료 |
| Fixture/증거 | 고정 map·owner·case matrix·통제 endpoint·safe evidence fields 명세화 | 별도 시험계정/group의 실제 준비 및 각 CPU 실행 시 denial 귀속 검증; 아직 미실행 |
| Approval | architecture 명시 승인 완료, IMPLEMENTATION은 조건부 잠정 의사만 있음 | 이 확정 후보 입력을 담은 새 Spec commit SHA에 대한 명시적 IMPLEMENTATION 승인 |

시험 harness는 sandbox 거부와 Unix mode/ACL/TCC 거부를 구분해야 한다. owner가 시험 전후 canary 존재와 정상 read/write를 확인하고 같은 user의 통제 실행에서 비교한다. app-group entitlement가 없다는 정적 증거와 실제 다른 group canary 접근 거부 증거를 구분한다. group canary가 없으면 그 동적 검사는 `blocked`이며 새 shared group 권한을 제품에 부여해 통과시키지 않는다. 보호 데이터를 검사하기 위해 실제 사용자 container를 탐색하지 않는다.

Apple은 macOS 14+에서 다른 앱 container 접근 시 사용자 승인 요청이 발생할 수 있다고 설명한다 [A4]. 시험은 추가 접근 승인/FDA가 없는 clean-machine 상태를 기록하고 수행한다. prompt를 승인해 격리를 우회하지 않으며, prompt·사용자 거부·sandbox 자동 거부를 서로 다른 관측으로 남긴다. 사용자 거부만 관측한 경우 sandbox 격리 PASS가 아니라 `inconclusive`로 기록한다. 기존 사용자 환경의 TCC/권한을 초기화하거나 변경하지 않는다.

### 조사 근거

- [A1] Apple, [Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html): XPC sandbox/launchd/on-demand lifecycle 및 `Contents/XPCServices`.
- [A2] Apple, [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app): helper의 app-sandbox+inherit, runtime flag, base entitlement 주입 금지.
- [A3] local Xcode 27 SDK `Foundation.framework/Headers/NSXPCConnection.h`, connection signing requirement 및 listener restriction 주석. API 가용성 macOS 13+; 승인 toolchain의 SDK에서도 재확인 대상.
- [A4] Apple, [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox): container/code-signature 연결, 사용자 승인 및 POSIX/ACL 등 다른 거부 원인.
- [D1] OpenAI, [Codex SDK](https://developers.openai.com/codex/sdk/) (조회 시 `learn.chatgpt.com/docs/codex-sdk`로 연결).
- [D2] [PyPI openai-codex 0.160.0 metadata](https://pypi.org/pypi/openai-codex/0.160.0/json).
- [D3] [PyPI CLI-bin 0.160.0 metadata](https://pypi.org/pypi/openai-codex-cli-bin/0.160.0/json).
- [D4] [SDK 0.160.0 source archive](https://files.pythonhosted.org/packages/c8/75/9f0934ce92e8428b926ac9a555bb0f7b2728b054a59003edd039adc494dd/openai_codex-0.160.0.tar.gz); hash와 읽은 member는 위 표/본문 참조.
- [D5] Astral [python-build-standalone 20261003](https://github.com/astral-sh/python-build-standalone/releases/tag/20261003), asset API [arm64](https://api.github.com/repos/astral-sh/python-build-standalone/releases/assets/607987313)/[x86_64](https://api.github.com/repos/astral-sh/python-build-standalone/releases/assets/607987946), [relocation caveats](https://gregoryszorc.com/docs/python-build-standalone/main/quirks.html#references-to-build-time-paths).
- [D6] version-specific PyPI JSON metadata: [annotated-types](https://pypi.org/pypi/annotated-types/0.8.0/json), [packaging](https://pypi.org/pypi/packaging/26.3/json), [pydantic](https://pypi.org/pypi/pydantic/2.13.5/json), [pydantic-core](https://pypi.org/pypi/pydantic-core/2.46.5/json), [typing-extensions](https://pypi.org/pypi/typing-extensions/4.16.0/json), [typing-inspection](https://pypi.org/pypi/typing-inspection/0.4.4/json).
- [D7] [bblanchon chromium/8035](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/8035), [실제 branch tip](https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/8035?format=JSON).
- [D8] exact PDFium commit의 [BUILD.gn](https://pdfium.googlesource.com/pdfium/+/ad5bc13610718aefe737bd9b2f1b258d08e39428/BUILD.gn?format=HTML), [DEPS](https://pdfium.googlesource.com/pdfium/+/ad5bc13610718aefe737bd9b2f1b258d08e39428/DEPS?format=HTML), [public API](https://pdfium.googlesource.com/pdfium/+/ad5bc13610718aefe737bd9b2f1b258d08e39428/public/fpdfview.h?format=HTML).
- [D9] pinned Clang [scripts/update.py](https://chromium.googlesource.com/chromium/src/tools/clang/+/e4816757c45a072f08279139108a0a937bbeb239/scripts/update.py?format=HTML) 및 [D8] DEPS의 object/generation/hash.
- [D10] CIPD metadata base `https://chrome-infra-packages.appspot.com/p/`: GN `gn/gn/mac-arm64/+/git_revision:1c79e13d17a1760d6c6401c90061411842bd4881` 및 `mac-amd64` counterpart; Ninja `infra/3pp/tools/ninja/mac-arm64/+/version:3@1.12.1.chromium.4` 및 `mac-amd64` counterpart. 위 instance IDs를 최종 선택에 사용한다.
- [D11] pinned [pdfium.gni](https://pdfium.googlesource.com/pdfium/+/ad5bc13610718aefe737bd9b2f1b258d08e39428/pdfium.gni?format=HTML), build `299066ef2d5d1396f97e582627880cebe33f497a`의 [rust.gni](https://chromium.googlesource.com/chromium/src/build/+/299066ef2d5d1396f97e582627880cebe33f497a/config/rust.gni?format=HTML), [c++.gni](https://chromium.googlesource.com/chromium/src/build/+/299066ef2d5d1396f97e582627880cebe33f497a/config/c++/c++.gni?format=HTML), [mac_sdk.gni](https://chromium.googlesource.com/chromium/src/build/+/299066ef2d5d1396f97e582627880cebe33f497a/config/mac/mac_sdk.gni?format=HTML).
- [E1] Swift.org [macOS 설치/Previous Releases](https://www.swift.org/install/macos/), [Swift 6.3.3 macOS pkg](https://download.swift.org/swift-6.3.3-release/xcode/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-osx.pkg).
- [E2] GitHub [hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
- [E3] Apple [Xcode SDK and system requirements](https://developer.apple.com/xcode/system-requirements/), Swift.org [user-domain package installer](https://www.swift.org/install/macos/package_installer/).

## Verification

**작성 단계:** frontmatter·필수 섹션·Issue/branch 대응·Story AC 보존·공백 검사 및 커밋 파일 목록 확인. 제품 테스트·prototype·signing·notarization·CI를 실행하지 않는다.

**승인 후 생성할 실행 entry points:** 다음은 아직 존재하거나 실행된 script가 아니라 구현 계약이다. `<cpu>`는 `arm64`/`x86_64`, app 경로는 `.build/topology/<cpu>/PaperLens.app`, safe evidence는 `bmad-docs/implementation-artifacts/evidence/1-1/<cpu>/`로 고정한다.

- `scripts/topology/build.sh --arch <cpu>` — 고정 입력 취득/hash 검증 → PDFium static build → Xcode `PaperLensTopology` scheme Release build → inside-out signing·inventory. source commit과 승인 compiler/SDK/Team이 다르면 중단한다. 후보 artifact의 다운로드/hash 검사와 local signing은 구현 승인 범위에 포함되며 원격 CI/notary 제출은 포함되지 않는다.
- `xcodebuild -project PaperLens.xcodeproj -scheme PaperLensTopology -configuration Release -destination 'platform=macOS,arch=arm64' test` — ProviderRPC frame 분할/합침, zero/oversize prefix, invalid UTF-8/중복 key, version mismatch, unknown method, capacity+1, cancel/result/deadline 경쟁, EOF/restart/중복 terminal 및 synthetic fixture validation을 검사한다. Intel host에서는 `arch=x86_64`로 실행한다. unit 성공을 signed process 격리 증거로 세지 않는다.
- `scripts/topology/verify.sh --arch <cpu> --bundle .build/topology/<cpu>/PaperLens.app` — 실제 host CPU/Rosetta 여부·clean fixture profile을 확인하고 모든 positive/negative case와 safe evidence를 수집한다. 다른 CPU이면 그 실행 증거를 blocked로 기록하며 자동 Rosetta 대체를 하지 않는다. fixture/group/signing 준비 실패도 blocked다.
- 각 bundle에 `codesign --verify --strict --verbose=2` 및 nested entitlement/runtime 검사를 수행한다. **별도 공증 제출 지시 이후에만** `xcrun stapler validate`와 `spctl --assess --type execute --verbose=2` 및 clean-machine GUI launch를 검증한다. CLI 검사만으로 GUI/실제 process 경계 증거를 대신하지 않는다.

**완료 기준의 단계 구분:** 명세 입력 고정 → 이 Spec SHA의 IMPLEMENTATION 승인 → 취득/컴파일/unit → signed arm64 실행 → 실제 Intel 실행 → 별도 지시된 notarization/Gatekeeper 검증 순으로 증거를 쌓는다. 뒤 단계가 막혀도 앞의 성공을 기록할 수 있지만 Story done/P-1 PASS로 승격하지 않는다. 새로운 계약·권한·dependency pin 변경은 원래 Ask First 경계를 따른다.

## Spec Change Log

- 2026-10-05: 최초 작성. 실행 topology·entitlement/wire 미확정과 Swift 6.4 대 승인 6.3.3 불일치를 발견했다. 계획을 draft로 유지하고 계약 구체화·환경 확보 이전의 구현 승인을 차단했다. Story 1.1의 두 CPU 실제 검증 및 P-1 부분 증거 경계는 유지한다.
- 2026-10-05: 2차 조사 revision. embedded XPC Agent·child inheritance·서명 peer 검증·최소 entitlement 및 topology-only RPC 제안을 추가했다. 공식 Python SDK/CLI 후보 hash, Swift 6.3.3 배포 경로, local Developer ID identity 개수와 Intel runner 문서 가용성을 확인했다. SDK/CLI pair·runtime closure·fixture 계약·환경은 여전히 차단 상태다. source 구현·설치·서명·공증·CI·push는 하지 않았다.
- 2026-10-05: 3차 revision. 사용자 승인으로 공식 Swift 6.3.3을 추가 설치했으나 SDK 27 Foundation compile 실패를 실제 확인했다. SDK explicit binary override·environment merge·종료 경로를 immutable source로 확인하고 고정 synthetic fixture/control/evidence 계약을 보완했다. stack 선택과 dependency closure는 아직 미확정이며 제품 source·서명·공증·CI·push는 수행하지 않았다.
- 2026-10-05: 4차 revision. 사용자 선택에 따라 Swift6.4/Xcode27 및 official Python SDK·CLI-bin0.160.0 변경안을 Spine/companion과 함께 작성했다. SDK0.160.0 source archive의 로컬 hash와 launch/env/approval/close 동작을 재확인했다. 새 architecture 승인과 Story 구현 승인은 아직 없다.
- 2026-10-05: 5차 revision. architecture1195c922의 명시적 승인을 Issue에 기록하고 baseline·epics AR-002를 동기화했다. CPython 및 8개 Python package의 두 CPU 후보/hash, signing Team을 고정했다. 정확히 일치하지 않는 PDFium prebuilt를 배제하고 upstream static-library 및 Clang/GN/Ninja immutable 입력을 확정했다. 기술 명세를 구현 승인 대상으로 준비했으며 조건부 잠정 승인을 새 SHA의 확정 IMPLEMENTATION 승인으로 확대하지 않았다.
