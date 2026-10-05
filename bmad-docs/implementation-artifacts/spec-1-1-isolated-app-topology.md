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
- [ ] Launch/topology — macOS의 지원된 launch 경로로 Agent의 독립 identity와 private zone을 실제로 입증한다. Main sandbox를 상속한 일반 child를 별도 Agent로 오인하지 않는다. 먼저 exact launch wiring·bundle identities·최소 entitlement map·후보 runtime hashes를 이 Spec에 고정하고 새 SHA 승인을 받은 뒤 prototype을 구현한다. 현재 문서는 이 선택이 검증됐다고 주장하지 않는다.
- [ ] 실제 구성요소 — PDFium은 승인 commit `ad5bc13610718aefe737bd9b2f1b258d08e39428`을 패키징/로드하고 Agent는 packaged official Python SDK/runtime/CLI 실행을 확인한다. PDF 추출·인증 요청 없이 실제 loader/process topology를 검증한다. 후보 버전/hash는 재현용으로 기록하되 P-2 최종 lock으로 표기하지 않는다.
- [ ] 최소 wire — AD-2의 32-bit big-endian length/UTF-8 JSON, startup version handshake, correlation, one terminal response, typed failure, cancellation/timeout, allowlist, bounded stream, protocol-only stdout를 보존한다. topology 검증에 필요한 exact method fields/numeric limits는 위 launch 계약 고정 때 같은 Spec에 포함한다. 제품 operation별 P-3/Story 1.9 계약 완료로 승격하지 않는다.
- [ ] Negative-access 검증 — 표의 모든 성공/거부 경로를 실제 signed process에서 수행한다. canary 소유 process가 자체 생성·검증·정리하며 테스트를 위해 Main에 Agent zone 접근 권한을 부여하지 않는다. 거부 원인을 sandbox 경계와 연결하고 단순 ENOENT/network 장애를 성공으로 세지 않는다. symlink 경유 접근도 포함한다.
- [ ] 패키징 검증 — nested code를 inside-out 서명하고 개별 identity·entitlement·runtime flag 및 전체 bundle을 검사한다. runtime entitlement 예외가 필요하면 임의 허용하지 말고 재승인한다. 명시적 원격 실행 지시 후에만 notarization/stapling을 수행하고 각 CPU의 clean-machine Gatekeeper launch를 확인한다.
- [ ] 결과 — source commit, CPU/OS build, toolchain, artifact/nested hashes, 계약/entitlement revision, scenario별 pass/failed/blocked/inconclusive, 자동/manual/remote 분류와 한계를 기록한다. raw stdout/stderr, 환경 덤프, 개인 경로·secret은 제외한다. 제품 상태나 gate 통과로 표시하지 않는다.

**Acceptance Criteria:**

1. 별도 IMPLEMENTATION 승인과 환경이 확보된 뒤 arm64/x86_64 각각의 Main·XPC·Agent 실행, nested inventory·서명·entitlements·공증·Gatekeeper 증거가 기록된다. Provider 연결/PDF 추출/공개 배포 완료로 표시하지 않는다.
2. XPC와 Agent의 금지 network/file/container/app-group 접근 및 Main의 broad Agent-zone 접근 거부가 두 실제 CPU 환경에서 검증된다.
3. 자격 증명·실행 환경·필수 증거가 없거나 negative-access 검사가 실패하면 실패/미검증과 재검증 조건을 명시한다. Story를 done 또는 P-1을 통과로 표시하지 않는다.

## Design Notes

- 이 Spec은 **draft, 실행 차단 상태**다. P-1이 풀어야 할 exact launch/entitlement 선택을 조사 없이 확정하지 않았다. 해당 계약과 시험용 wire를 구체화한 revision만 구현 승인 대상으로 제시한다. 현재 사용자 지시는 작성 허용이며 이전의 일반 IMPLEMENTATION 발언을 미래 SHA에 소급 적용하지 않는다.
- Intel은 적합한 GitHub Actions runner를 우선 조사하되 실제 runner 가용성·Xcode·signing 권한·GUI/Gatekeeper 증거를 확인해야 한다. 충족하지 못하면 별도 Intel Mac/self-hosted 환경이 필요하다. 현재 원격 실행/권한/Intel 환경은 확인되지 않았다.
- PRODUCT baseline: `5eac3bb9424ad893eca7d63bc319b71f580838ed`. ARCHITECTURE baseline: `cdabe4419606ab0c1efebcfeb79bded0fe344512`. 관련 AD-2/4/7/13, AR-002~005/020, FR-002/005/035 선행 검증, R-005/007을 추적한다.
- Story 원본: `bmad-docs/planning-artifacts/epics.md` §1.1. 작성 시 파일 SHA-256: `0dbed1d4dac4435b8ce29a3fd8bfe273f730f99e8c5f4a98a2e76a33bee75434`. 기존 untracked planning/governance 파일은 이 작업의 커밋에 임의 포함하지 않는다. 위 AC·범위는 원본의 Story 1.1 경계를 이 커밋에 보존한다.

## Verification

**작성 단계:** frontmatter·필수 섹션·Issue/branch 대응·Story AC 보존·공백 검사 및 커밋 파일 목록 확인. 제품 테스트·prototype·signing·notarization·CI를 실행하지 않는다.

**구현 이후:** `xcodebuild`로 각 CPU bundle을 빌드하고 `codesign --verify --strict --verbose=2 <bundle>` 및 각 nested code의 entitlement/runtime 검사를 수행한다. 명시적 공증 제출 지시 이후 `xcrun stapler validate <bundle>`과 `spctl --assess --type execute --verbose=2 <bundle>`을 실행한다. 정확한 artifact 경로와 자동 test 명령은 launch 계약 revision에서 고정한다. CLI 검사는 실제 CPU의 clean-machine GUI launch·process별 negative-access 증거를 대체하지 않는다.

## Spec Change Log

- 2026-10-05: 최초 작성. 실행 topology·entitlement/wire 미확정과 Swift 6.4 대 승인 6.3.3 불일치를 발견했다. 계획을 draft로 유지하고 계약 구체화·환경 확보 이전의 구현 승인을 차단했다. Story 1.1의 두 CPU 실제 검증 및 P-1 부분 증거 경계는 유지한다.
