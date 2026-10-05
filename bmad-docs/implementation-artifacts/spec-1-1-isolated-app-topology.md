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

- [ ] Preflight — Swift 6.3.3을 제공하는 Xcode/toolchain의 실제 가용성, Developer ID Team/identities, notary credential reference, Intel 실행 경로를 확인한다. 현재 관측은 Xcode 27.0 (27A266a), SDK 27.0, Swift 6.4, arm64이므로 승인 stack 충족 증거가 아니다. 설치/선택 변경은 이 작성 단계에서 하지 않았다. 필요한 환경을 확보하지 못하면 source 구현에 앞서 blocked로 기록한다.
- [ ] Launch/topology — 아래 embedded XPC 후보와 entitlement map을 사용해 독립 identity와 private zone을 검증한다. Main sandbox를 상속한 일반 child를 별도 Agent로 오인하지 않는다. 후보 runtime/dependency closure와 fixture 계약을 먼저 닫고 새 SHA 승인을 받은 뒤 prototype을 구현한다. 문서 근거는 실제 격리 성공의 증거가 아니다.
- [ ] 실제 구성요소 — PDFium은 승인 commit `ad5bc13610718aefe737bd9b2f1b258d08e39428`을 패키징/로드하고 Agent는 packaged official Python SDK/runtime/CLI 실행을 확인한다. PDF 추출·인증 요청 없이 실제 loader/process topology를 검증한다. 후보 버전/hash는 재현용으로 기록하되 P-2 최종 lock으로 표기하지 않는다.
- [ ] 최소 wire — 아래 `topology-v1` 제안의 fields/numeric limits를 `Contracts/ProviderRPC`에서 단일 정의하고 native/Agent 양쪽이 같은 fixtures로 검증한다. 제품 operation별 P-3/Story 1.9 계약 완료로 승격하지 않는다.
- [ ] Negative-access 검증 — 표의 모든 성공/거부 경로를 실제 signed process에서 수행한다. canary 소유 process가 자체 생성·검증·정리하며 테스트를 위해 Main에 Agent zone 접근 권한을 부여하지 않는다. 거부 원인을 sandbox 경계와 연결하고 단순 ENOENT/network 장애를 성공으로 세지 않는다. symlink 경유 접근도 포함한다.
- [ ] 패키징 검증 — nested code를 inside-out 서명하고 개별 identity·entitlement·runtime flag 및 전체 bundle을 검사한다. runtime entitlement 예외가 필요하면 임의 허용하지 말고 재승인한다. 명시적 원격 실행 지시 후에만 notarization/stapling을 수행하고 각 CPU의 clean-machine Gatekeeper launch를 확인한다.
- [ ] 결과 — source commit, CPU/OS build, toolchain, artifact/nested hashes, 계약/entitlement revision, scenario별 pass/failed/blocked/inconclusive, 자동/manual/remote 분류와 한계를 기록한다. raw stdout/stderr, 환경 덤프, 개인 경로·secret은 제외한다. 제품 상태나 gate 통과로 표시하지 않는다.

**Acceptance Criteria:**

1. 별도 IMPLEMENTATION 승인과 환경이 확보된 뒤 arm64/x86_64 각각의 Main·XPC·Agent 실행, nested inventory·서명·entitlements·공증·Gatekeeper 증거가 기록된다. Provider 연결/PDF 추출/공개 배포 완료로 표시하지 않는다.
2. XPC와 Agent의 금지 network/file/container/app-group 접근 및 Main의 broad Agent-zone 접근 거부가 두 실제 CPU 환경에서 검증된다.
3. 자격 증명·실행 환경·필수 증거가 없거나 negative-access 검사가 실패하면 실패/미검증과 재검증 조건을 명시한다. Story를 done 또는 P-1을 통과로 표시하지 않는다.

## Design Notes

- 이 Spec은 **draft, 실행 차단 상태**다. 아래는 공식 문서를 바탕으로 구체화한 후보이며 승인되거나 실증된 설계가 아니다. dependency closure·시험 fixture·실행 환경의 차단 조건이 남아 있으므로 아직 IMPLEMENTATION 승인을 요청하지 않는다. 현재 사용자 지시는 작성 계속이며 이전의 일반 IMPLEMENTATION 발언을 미래 SHA에 소급 적용하지 않는다.
- Intel은 적합한 GitHub Actions runner를 우선 조사하되 실제 runner 가용성·Xcode·signing 권한·GUI/Gatekeeper 증거를 확인해야 한다. 충족하지 못하면 별도 Intel Mac/self-hosted 환경이 필요하다. 현재 원격 실행/권한/Intel 환경은 확인되지 않았다.
- PRODUCT baseline: `5eac3bb9424ad893eca7d63bc319b71f580838ed`. ARCHITECTURE baseline: `cdabe4419606ab0c1efebcfeb79bded0fe344512`. 관련 AD-2/4/7/13, AR-002~005/020, FR-002/005/035 선행 검증, R-005/007을 추적한다.
- Story 원본: `bmad-docs/planning-artifacts/epics.md` §1.1. 작성 시 파일 SHA-256: `0dbed1d4dac4435b8ce29a3fd8bfe273f730f99e8c5f4a98a2e76a33bee75434`. 기존 untracked planning/governance 파일은 이 작업의 커밋에 임의 포함하지 않는다. 위 AC·범위는 원본의 Story 1.1 경계를 이 커밋에 보존한다.

### Launch 후보와 identity

2026-10-05 조사 결론: **Provider Agent 자체를 embedded XPC service로 시작하고 그 안에서만 Python/CLI를 자식으로 실행하는 후보**를 사용한다. Apple은 `NSTask`/`posix_spawn`으로 각 부분에 독립 sandbox를 부여할 수 없고 XPC service는 자체 sandbox를 갖는다고 설명한다 [A1]. 따라서 Main → `Process(Python)`은 제외한다. Login Item·LaunchAgent 등록, privileged helper, global Mach service, app group은 이 후보에 필요하지 않다.

| 역할 | bundle/code identity 후보 | app 내부 위치 | 실행/수명 |
| --- | --- | --- | --- |
| Main | `io.github.jinzer0.PaperLens` | `PaperLens.app/Contents/MacOS/PaperLens` | 사용자가 GUI로 실행 |
| PDF worker | `io.github.jinzer0.PaperLens.PDFiumXPC` | `Contents/XPCServices/PDFiumXPC.xpc` | Main의 `NSXPCConnection(serviceName:)`, service listener |
| Agent | `io.github.jinzer0.PaperLens.ProviderAgent` | `Contents/XPCServices/ProviderAgent.xpc` | 위와 같은 on-demand launchd 경로; Main의 직접 spawn 금지 |
| Python/CLI | Agent 하위의 고정 code-signing identifiers | Agent bundle의 `Contents/MacOS/`, libraries는 `Contents/Frameworks/`, pure Python/data는 `Contents/Resources/` | Agent → packaged Python → packaged CLI; host PATH 탐색 금지 |

각 XPC Info.plist는 자신의 `CFBundleIdentifier`/`CFBundleExecutable`, `CFBundlePackageType=XPC!`, `XPCService.ServiceType=Application`을 사용한다. 모든 executable의 deployment target은 macOS 15, build configuration은 Release, hardened runtime은 활성이다. 서로 다른 bundle ID나 `$HOME` 문자열만으로 독립 container를 입증했다고 보지 않는다. 실제 container URL·code identity·canary 접근 결과를 함께 확인한다. 기본 sandbox의 시스템 파일 읽기 허용까지 “모든 filesystem 접근 금지”라고 표현하지 않는다.

**핵심 미입증 사항:** Apple의 “각 XPC service는 자체 sandbox를 가진다”는 설명은 Main↔Agent의 양방향 container 접근 거부를 보장하는 문구가 아니다. 실제 거부가 성립하지 않으면 이 후보를 폐기/재설계하고 재승인한다. “우리 코드가 그 경로를 읽지 않는다”는 정책으로 OS 격리를 대체하지 않는다.

Main↔Agent transport는 `Contracts/ProviderRPC`에 선언한 **단일 `sendFrame(Data)` 호출과 `receiveFrame(Data)` callback**으로 고정한 후보다. 각 Data는 아래 prefix를 포함한 완전한 frame 하나이며 XPC는 운반만 한다. Agent 내부 Python stdin/stdout도 같은 frame을 사용하고 native bootstrap은 별도 operation/schema를 만들지 않는다. SDK↔CLI의 공식 app-server JSON-RPC는 Agent 내부 adapter detail이며 Main에 노출하거나 ProviderRPC를 대체하지 않는다. SDK import/CLI initialize까지만 검증하고 login/thread/turn을 보내지 않는다.

launchd가 시작한 XPC service의 stdout을 Main의 child pipe처럼 읽지 않는다. bootstrap stdout은 사용하지 않고 Agent가 생성한 Python bridge의 stdout만 전용 pipe로 연결한다. SDK/CLI stdout은 해당 내부 adapter가 소비하며 ProviderRPC pipe에 그대로 연결하지 않는다.

Main의 outbound connection과 service가 수락한 inbound connection 모두 `setCodeSigningRequirement`를 **resume 전에 한 번** 설정한다. 요구조건은 Apple signing anchor, 같은 승인 Team ID, 상대의 정확한 code identifier, Developer ID Application certificate 조건을 포함한다. Team ID 값은 실제 서명 manifest에서 선택하며 임의 값으로 대체하지 않는다. PID만 조회해 신원을 확인하지 않는다. `NSXPCListener.service()`에 `setConnectionCodeSigningRequirement`를 호출하지 않는다: 로컬 SDK 헤더는 해당 listener API를 anonymous/Mach-service listener로 제한한다 [A3]. 같은 Team의 다른 bundle, 잘못된 signer, unsigned peer는 거절 시험 대상이다.

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

`caseID`는 `ownZoneReadWrite`, `mainCanaryRead`, `mainCanaryWrite`, `externalCanaryRead`, `externalCanaryWrite`, `mainCanarySymlinkRead`, `externalCanarySymlinkRead`, `inboundListen`의 닫힌 목록이다. `reason`은 `none`, `permissionDenied`, `missingFixture`, `controlFailed`, `unexpectedErrno`뿐이다. `permissionDenied`만으로 sandbox 귀속을 확정하지 않고 아래 별도 증거를 요구한다. arbitrary path/URL/command/JSON passthrough는 금지한다. 시험 fixture의 위치/소유권 매핑은 승인 전 추가로 고정해야 한다.

동시에 outstanding request 최대 4개(일반 3개 + cancel 전용 1개), 각 방향 queued frame 최대 4개/262160 bytes, 연결당 request 총수 최대 256개 후 정상 종료한다. 넘친 신규 유효 request는 `busy`, framing/중복 ID/해석 불가능한 envelope/queue overflow는 fail-closed 연결 종료다. 이 revision의 chunk/event/stream 수는 **0**이며 streaming operation을 허용하지 않는다. child stdout은 frame 전용, stderr는 읽어 버리며 저장하지 않는다.

각 id의 완료 전이는 serial executor 한 곳에서 경쟁을 판정한다. cancel이 먼저 이기면 target은 `cancelled` terminal 한 번, 늦은 result는 폐기한다. 이미 완료/없는 target의 cancel은 `accepted:false`. deadline도 같은 fence를 사용한다. crash/EOF/invalid frame에서는 상대가 terminal을 보냈다고 꾸미지 않고 caller가 미완료 id를 각각 local `unavailable`로 한 번 종결한다. XPC 자동 재시작 후에는 새 handshake가 필요하며 이전 operation을 replay하지 않는다.

### Dependency 조사 — 채택/다운로드/실행과 구분

승인 stack의 Codex **compatibility target은 `0.150.1`**이다. 이를 현재 latest로 조용히 바꾸지 않는다. 공식 문서에서 Python SDK `openai-codex`와 Python 3.10+ 요구, packaged CLI 의존을 확인했다 [D1]. PyPI의 `openai-codex/0.150.1/json`은 조회 시 HTTP 404였다. 이것만으로 공식 Python SDK가 없다고 결론 내리지 않는다.

| 확인 대상 | upstream이 게시한 SHA-256 / 식별자 | 판정 |
| --- | --- | --- |
| `openai_codex-0.147.0-py3-none-any.whl` | `ab2e0b3a41dba5a62be8561397cf3e7913afb53b5372ad881002a6f0b77e6a0a` | Python SDK 후보; metadata는 CLI-bin `==0.147.0` 의존 [D2] |
| `rust-v0.150.1`의 `codex-aarch64-apple-darwin.tar.gz` | `f66f1c45f1eda49d6a8aef86faee24121b0c8913cd9023f23ee44262606fc7b6` | 승인 compatibility target의 CLI 후보 [D3] |
| 같은 release의 `codex-x86_64-apple-darwin.tar.gz` | `d00bdeb113c2cb42b43fbe4916b681ab1405772ac38fc8ac7fa9cc0934d1d0aa` | Intel CLI 후보 [D3] |
| PDFium | commit `ad5bc13610718aefe737bd9b2f1b258d08e39428` | 승인 pin 유지; source/dependency/binary inventory 미수집 |

`rust-v0.150.1/sdk/python/pyproject.toml`도 CLI-bin `0.147.0`을 의존한다 [D4]. 따라서 SDK와 CLI가 같은 버전 번호라고 가정한 lock은 금지한다. SDK의 명시적 packaged `codex_bin` 설정으로 0.150.1을 선택할 수 있는지, 요구 runtime/package의 중복 포함 및 실제 protocol 호환성을 확인한 뒤 후보 pair를 확정해야 한다. 최신 SDK 0.160.0/CLI-bin 0.160.0 metadata도 확인했지만 대체 채택하지 않았다.

위 hash는 **upstream metadata 값**이며 로컬 binary를 다운로드·계산·실행한 증거가 아니다. CPython 배포형태/버전/source hash, Pydantic 및 native extension 등 전이 dependencies, PDFium build inputs, 전체 nested executable inventory는 아직 미확정이다. 이 closure를 채우기 전에는 구현 승인 가능한 lock이라고 표현하지 않는다.

### 환경 및 승인 전 차단 목록

| 항목 | 이번에 확인한 사실 | 해제 조건 |
| --- | --- | --- |
| Swift | local Xcode 27.0/SDK 27.0/Swift 6.4; 일반 Xcode 및 시스템/사용자 Toolchains 위치에 추가 toolchain 없음. Swift.org는 6.3.3 macOS pkg를 제공 [E1] | 설치/선택 변경 별도 허용 후 실제 6.3.3 compiler와 Xcode/SDK 조합 검증; 현재 컴파일 미수행 |
| Developer ID | `security find-identity -v -p codesigning` 결과 valid Developer ID Application identity **1개**. 이름·fingerprint·private key 미출력 | 사용 Team/identity 선택과 key 접근/서명 가능성 확인; identity 존재를 서명 성공으로 간주하지 않음 |
| Notary | credential 내용/저장소 미조회, 제출 없음 | 사용 credential reference 및 공증 제출 명시적 지시 |
| Intel | GitHub 문서에 `macos-15-intel`/`macos-26-intel` 존재 [E2]; 저장소 self-hosted runner API 결과 0개 | 실제 Intel 실행 경로/원격 실행 지시 확보. hosted label 존재는 job 실행/GUI Gatekeeper 증거 아님 |
| Dependency | 위 SDK/CLI pair·CPython·전이 hash closure 미확정 | 승인 compatibility target 유지한 실제 package map과 immutable hashes 고정 |
| Fixture/증거 | synthetic owner-positive-control 원칙만 확정 | protected container·외부 파일·app-group별 **실재** fixture, 통제 endpoint, sandbox denial 귀속 방법과 safe evidence schema 고정 |
| Approval | IMPLEMENTATION 승인 없음 | 위 명세 차단 항목 해소 후 새 Spec commit SHA에 대한 명시적 승인 |

시험 harness는 sandbox 거부와 Unix mode/ACL/TCC 거부를 구분해야 한다. owner가 시험 전후 canary 존재와 정상 read/write를 확인하고 같은 user의 통제 실행에서 비교한다. app-group entitlement가 없다는 정적 증거와 실제 다른 group canary 접근 거부 증거를 구분한다. group canary가 없으면 그 동적 검사는 `blocked`이며 새 shared group 권한을 제품에 부여해 통과시키지 않는다. 보호 데이터를 검사하기 위해 실제 사용자 container를 탐색하지 않는다.

Apple은 macOS 14+에서 다른 앱 container 접근 시 사용자 승인 요청이 발생할 수 있다고 설명한다 [A4]. 시험은 추가 접근 승인/FDA가 없는 clean-machine 상태를 기록하고 수행한다. prompt를 승인해 격리를 우회하지 않으며, prompt·사용자 거부·sandbox 자동 거부를 서로 다른 관측으로 남긴다. 사용자 거부만 관측한 경우 sandbox 격리 PASS가 아니라 `inconclusive`로 기록한다. 기존 사용자 환경의 TCC/권한을 초기화하거나 변경하지 않는다.

### 조사 근거

- [A1] Apple, [Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html): XPC sandbox/launchd/on-demand lifecycle 및 `Contents/XPCServices`.
- [A2] Apple, [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app): helper의 app-sandbox+inherit, runtime flag, base entitlement 주입 금지.
- [A3] local Xcode 27 SDK `Foundation.framework/Headers/NSXPCConnection.h`, connection signing requirement 및 listener restriction 주석. API 가용성 macOS 13+; 승인 toolchain의 SDK에서도 재확인 대상.
- [A4] Apple, [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox): container/code-signature 연결, 사용자 승인 및 POSIX/ACL 등 다른 거부 원인.
- [D1] OpenAI, [Codex SDK](https://developers.openai.com/codex/sdk/) (조회 시 `learn.chatgpt.com/docs/codex-sdk`로 연결).
- [D2] [PyPI openai-codex 0.147.0 metadata](https://pypi.org/pypi/openai-codex/0.147.0/json).
- [D3] [OpenAI Codex rust-v0.150.1 release API](https://api.github.com/repos/openai/codex/releases/tags/rust-v0.150.1); 위 정확한 asset 이름의 `digest`.
- [D4] [해당 release의 Python pyproject](https://raw.githubusercontent.com/openai/codex/rust-v0.150.1/sdk/python/pyproject.toml).
- [E1] Swift.org [macOS 설치/Previous Releases](https://www.swift.org/install/macos/), [Swift 6.3.3 macOS pkg](https://download.swift.org/swift-6.3.3-release/xcode/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-osx.pkg).
- [E2] GitHub [hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Verification

**작성 단계:** frontmatter·필수 섹션·Issue/branch 대응·Story AC 보존·공백 검사 및 커밋 파일 목록 확인. 제품 테스트·prototype·signing·notarization·CI를 실행하지 않는다.

**구현 이후:** `xcodebuild`로 각 CPU bundle을 빌드하고 `codesign --verify --strict --verbose=2 <bundle>` 및 각 nested code의 entitlement/runtime 검사를 수행한다. 명시적 공증 제출 지시 이후 `xcrun stapler validate <bundle>`과 `spctl --assess --type execute --verbose=2 <bundle>`을 실행한다. 정확한 artifact 경로와 자동 test 명령은 launch 계약 revision에서 고정한다. CLI 검사는 실제 CPU의 clean-machine GUI launch·process별 negative-access 증거를 대체하지 않는다.

## Spec Change Log

- 2026-10-05: 최초 작성. 실행 topology·entitlement/wire 미확정과 Swift 6.4 대 승인 6.3.3 불일치를 발견했다. 계획을 draft로 유지하고 계약 구체화·환경 확보 이전의 구현 승인을 차단했다. Story 1.1의 두 CPU 실제 검증 및 P-1 부분 증거 경계는 유지한다.
- 2026-10-05: 2차 조사 revision. embedded XPC Agent·child inheritance·서명 peer 검증·최소 entitlement 및 topology-only RPC 제안을 추가했다. 공식 Python SDK/CLI 후보 hash, Swift 6.3.3 배포 경로, local Developer ID identity 개수와 Intel runner 문서 가용성을 확인했다. SDK/CLI pair·runtime closure·fixture 계약·환경은 여전히 차단 상태다. source 구현·설치·서명·공증·CI·push는 하지 않았다.
