---
title: 'Epic 1 — Story 1.1~1.27 전체 계획·구현·검증'
status: in-progress
issue: 'https://github.com/jinzer0/PaperLens/issues/3'
branch: planning/epic-1-execution
product_baseline: 5eac3bb9424ad893eca7d63bc319b71f580838ed
architecture_baseline: 1195c92227cc628e325f5ff24d70cc93639bf7a9
approval: explicit-human-story-range-execution
---

# 전체 실행 계약

사용자 명시적 지시: **Story 1.1~1.27 전체 계획·구현·검증을 워크플로대로 진행**. 승인 provenance는 Epic #3이다. 현재 열린 Story1.1의 진단만으로 전체 목표를 축소하지 않는다. 각 in-scope 단계마다 승인을 다시 요청하지 않는다.

Canonical Story 정의는 `bmad-docs/planning-artifacts/epics.md`의 Epic1이다. 현재 정의와 sprint registry에는 **1.1~1.26만 존재**하며 1.27은 정의 공백이다. 미존재 Story의 요구/AC를 만들어내거나 전체 완료로 계산하지 않는다. 기존 Product/Architecture 승인과 Story 분해의 AC를 baseline으로 삼는다. Draft/pending frontmatter보다 실제 human 승인 기록을 우선한다.

## BMAD 실행 순서

1. Story의 AC/선행 계약/검증 경계를 확인하고 governing Issue·task branch·Build Spec을 연결한다.
2. Spec을 commit하고 Epic의 전체 SCOPE+IMPLEMENTATION 승인 provenance를 Story Issue에 기록한다.
3. 명세에 정의한 최소 end-to-end 단위를 구현한다. 다른 Story의 변경은 별도 work unit으로 분리한다.
4. 부모만 focused/union tests·formatter(프로젝트에 설정된 경우)·build/scenario 검증을 실행한다. 하위 에이전트는 bounded source/spec/static review만 수행한다.
5. 독립 리뷰·부모 회귀 후 로컬 구현/증거 commit을 만든다. 실패/미관측/외부 차단을 숨기지 않는다.
6. 다음 dependency-ready Story를 진행한다. 테스트 PASS와 제품/architecture gate PASS를 구분한다. 필수 pre-split gate가 미통과면 downstream 제품 구현 분기는 하지 않되, 해당 gate의 검증용 harness/계약 결정을 계속 진행한다.

## 전체 Story 작업 목록

| Story | Canonical 책임 | 실행 및 검증 deliverable |
| --- | --- | --- |
| 1.1 | 두 CPU 격리 실행 topology | 기존 Spec/Issue#2와 signed/static/live 증거 유지. OS collector/denial 귀속·TCC·두 CPU·공증/Gatekeeper 미입증은 blocked |
| 1.2 | Provider 종료·재시작 정리 | Issue#4. Paper UUID/generation/correlation attempt ownership, terminal/cancel/startup purge 및 safe Agent acknowledgement. 실제 packaged SDK 사건 증거는 synthetic 테스트와 별도 |
| 1.3 | 앱 교체·Paper 삭제 정리 | 1.2 ownership 기반 replacement/startup/paper purge, 늦은 writer 부활 방지·idempotency. P1 항목별 검증 |
| 1.4 | P2 lock·OS 매트릭스 | 정확 toolchain/runtime/SDK/CLI/PDFium/hash provenance와 최소/현재 OS×CPU 실행 matrix. candidate를 final lock으로 오인하지 않음 |
| 1.5 | packaged DB/FTS5 | 1.4 lock의 GRDB open/ordered migration/FTS create-query-delete 및 실패 재오픈. host-only DB test는 packaged matrix 증거 아님 |
| 1.6 | packaged Agent matrix | 1.2~1.5 기반 success/failure/restart/replacement/delete 사건의 OS×CPU evidence 및 P2 판정 |
| 1.7 | 공통 요청 허용·자원 한도 | ProviderRequest 단일 versioned allowlist/item-byte-token-message-stream/import-parser numeric ceilings와 Application 공통 budget policy |
| 1.8 | PDF readiness 측정 계약 | 단일 자동 navigation 또는 zoom probe, main-thread visible completion, ImportAcceptedAt/FirstInteractivePageAt·네 입력·두 CPU·초과 disposition |
| 1.9 | Main/Agent 제품 RPC | P1/P2/P3 실제 gate 이후 단일 framing/handshake/method/correlation/terminal/cancel/purge/error/bounds 계약 양쪽 검증 |
| 1.10 | OpenAI API key 연결 | 실제 최소 인증 요청·typed response·staged slot/SQLite selector CAS·기존 active 보존. secret/유료 real request 검증은 필요한 human 입력 없이 실행하지 않음 |
| 1.11 | Codex ChatGPT 로그인 | packaged official SDK browser login·stage/usable request/config generation·정리와 safe auth 상태 |
| 1.12 | device-code 연결 | 동일 Provider 계약의 device-code 로그인·취소/기한/실패/old active 보존 |
| 1.13 | Job 실패·재실행·Retry | 제품 Import 이전 공통 class recovery, startup interrupted, attempt fence·dispatch·explicit Retry·writer/publication permit 계약 |
| 1.14 | 연결 후 local PDF Library | Provider gate·Job 정책 기반 import/독립 PDF ownership·삭제 경합. fake 연결 성공으로 gate 우회하지 않음 |
| 1.15 | Reader 읽기·이어 읽기 | 실제 PDFKit navigation/zoom/search/selection/read position·readiness instrumentation·복구 |
| 1.16 | Highlight/Note | 안정 geometry/persistence/annotation·현재 데이터 삭제·재실행·accessibility |
| 1.17 | folder/duplicate import | content hash와 Paper UUID 분리, duplicate 결정·별도 copy·folder·permit·실패 복구 |
| 1.18 | 세 URL import | HTTPS/arXiv abstract/PDF/general URL·redirect/credential/type/resource validation·취소·readiness 네 입력 통합 |
| 1.19 | sentence/geometry/Anchor | canonical extraction revision·PDF coordinates·shared tolerance/round trip·PDFKit transform·immutable sentence identity |
| 1.20 | parse/search revision 공개 | no-network PDFium XPC typed batch·inactive build·FTS·atomic active revision/fence·old refs 보존 |
| 1.21 | parse 실패/복구 | PDF 읽기 보존·typed failure·사용자 Retry·stale result/삭제 경합 방지 |
| 1.22 | metadata/outline | 실제 Paper metadata와 PDF outline/Reader navigation·실패/부재 처리·접근성 |
| 1.23 | 근거 한 줄 요약 | 공통 allowlisted summary operation·fenced Provider result·정확 provenance·실패 시 기존 결과 보존 |
| 1.24 | Library 보기/정렬/재방문 | card/list/sort·실제 저장 기록·DeleteAlert·namespace/Agent purge·작업 경합 |
| 1.25 | tag/read/favorite/search | transactional 분류·필터/search·FTS·삭제/재실행·UI 접근성 |
| 1.26 | Settings Provider 재연결 | active/staged 슬롯·config generation CAS·기존 정상 연결 보존·실제 reconnect 결과·안전한 UI |
| 1.27 | 정의 없음 | epics/sprint/기존 Issue에서 식별되지 않음. 승인된 정의를 받기 전 구현/완료 판정 금지 |

## 선행 경계 및 순서

- 검증 substrate: 1.1 → 1.2 → 1.3, 이후 1.4 → 1.5/1.6; P1/P2 증거를 CPU/OS/사건별로 검증한다.
- 공통 계약: 1.7 및 1.8의 required source/limit/readiness 결정을 제품 분기 전에 고정한다. 1.9는 P1/P2/P3 actual pass를 소비한다.
- 제품 Provider: 1.9 이후 1.10~1.12, 공통 Job1.13 이후 local import1.14. 실제 credentials/device/browser input·billable request를 synthetic success로 대체하지 않는다.
- Reader/import: 1.14 → 1.15/1.16/1.17 → 1.18. 화면 별 native semantic styling/한국어 copy/resize/focus/keyboard/VoiceOver와 해당 데이터의 복구·삭제 경합을 같이 검증한다.
- extraction: 1.19 계약 후 1.20 → 1.21. metadata/outline1.22, summary1.23, Library1.24~1.25, Settings1.26은 각 canonical AC/공통 gate를 소비한다.
- 구현 가능 여부는 synthetic prototype와 downstream 제품 분기를 분리해 판단한다. 외부 환경이 없다는 이유로 전체 작업을 한 log control에 고정하지 않지만, architecture의 필수 gate를 승인만으로 PASS 처리하지도 않는다.

## 검증 matrix와 완료 증거

각 Story는 Spec/Issue/branch/구현 commit, automated focused+union tests, 독립 리뷰, 실제 scenario 증거, limitations를 보유해야 한다. 실제 사용자가 제공하지 않은 auth/문서로 검증하지 않는다. macOS15/현재 OS×arm64/x86_64 packaged execution, signed sandbox negative-access attribution, TCC/coverage/clock, 실제 인증 요청은 해당 실제 환경/권한/입력의 증거가 없으면 blocked다. Intel 동적 실행은 현 요청에서 자동 복구되지 않았고 면제는 PASS가 아니다.

로컬 구현 테스트와 physical CPU·packaged execution·public distribution 완료를 혼동하지 않는다. push/PR/remote CI/notary/stapler/spctl/upload/배포/merge는 별도 human 지시 대상이다. 사용자의 `.gitignore` 및 unrelated untracked와 기존 report/fixture/receipt/package namespace를 보존한다. raw request/response/log/path/secret는 safe diagnostics에 남기지 않는다.

## 현재 상태

- 전체 human SCOPE+IMPLEMENTATION 및 workflow 기록: Epic#3.
- Story1.1: 구현/진단 evidence 존재, 전체 AC와 P1 blocked; 과거 소진된 batch 재실행 없음.
- Exactly26 canonical Story Issues와 별도 local task branches가 존재한다. Issue 생성은 Story 완료가 아니다.
- Story1.2: Issue#4, Spec551dab9 / concrete synthetic cleanup68b8f41. Python315 + native15 tests, independent static CLEAR. 실제 packaged SDK/dualCPU lifecycle 및 P1/P2/P3 완료 아님.
- Story1.3: Issue#6 own-branch amended Spec9c90218 / post-flock owner·current namespace binding precursor82f558c. Owned task worktree topology318 PASS, independent static CLEAR. Retained session coordinator·registered producer drain·paperPurge RPC와 실제 SDK/P1 증거는 아직 미구현/미입증이며 permanent deletion 주장 없음.
- Story1.4: Issue#7 Spec243a0ec / candidate source2da39b9. Closed offline validator와 nonpromoting four-cell matrix 구현. Story1.5 consumer integrationeff8349에서 single16-fact export policy와 actual source digest 갱신, focused21 + topology355 PASS/static CLEAR. MinimumOSbuild 및 실제 packaged matrix 미입증.
- Story1.5: Issue#8 initial Specd7c43ba / offline phase validator·evidenceeff8349. Architecture-aligned Spec amendment7b48957 / correctionaa18bfa separates two CPU artifacts from four independent executions. DB20 + topology356 PASS; static review26 CLEAR with isolated per-CPU regression gap subsequently covered. Pinned GRDB source materialization와 arm64 library compilation PASS(경고4개)는 source-only 증거이며 실제 DB/FTS/migration/reopen·loaded image·main-app integration·packaged P2 증거 아님.
- Story1.6: Issue#9 own-branch Specf3c3500 committed before offline twenty-row validator implementation. Repaired upstream DB pairingaa18bfa integrated at0d3cb71. Agent event implementation/review/verification pending; no SDK/native matrix/P2 completion claim.
- Story1.7: Issue#5, Specaf2d9d1 / Python SliceA762b385 / native 및 fixed-authority security boundary7a06389. Python34 + native31/RPC15 + concurrent offline topology355 PASS, independent static CLEAR. Fixed-v1 definition/resource rewrites·Unicode closed-key aliases·typed source-kind downgrade 수정. Actual Provider certification/authentication/import/parser enforcement·측정된 allocation/runtime 한도 및 Story 완료 미입증.
- Story1.8: Issue#10 own-branch Spec99b5409 precedes current uncommitted implementation. Pure state13 + request31/RPC15 PASS(artifact37996ee6-2bb8-42c4-b8d1-3347956c4183), zero warnings. Actual public offscreen PDFKit trialea270b54-0010-437b-a552-b9656d026e0e remains FAILED with blankCapture after public layout/display setup corrections; no raster proof or full-suite PASS. Raster and visible-interactive completion remain separate; independent source review pending and visible witness/source×CPU×OS/P6/Story completion unproven.
- 나머지 canonical Stories: Issue/branch 존재, 구현·검증 완료 아님. 각 dependency-ready work unit으로 진행하며 mandatory architecture gates를 synthetic precursor로 대체하지 않는다.
- Story1.27: requirements gap. 이 공백은 나머지 정의된 Story의 계획/검증용 선행 작업을 막지 않는다.
