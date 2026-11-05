---
stepsCompleted:
  - step-01-validate-prerequisites
  - step-02-design-epics
  - step-03-create-stories
  - step-04-final-validation
currentStep: step-04-final-validation
status: completed
inputDocuments:
  - bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/prd.md
  - bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/addendum.md
  - bmad-docs/planning-artifacts/architecture/architecture-PaperLens-2026-08-28/ARCHITECTURE-SPINE.md
  - bmad-docs/planning-artifacts/architecture/architecture-PaperLens-2026-08-28/SOLUTION-DESIGN.md
  - bmad-docs/planning-artifacts/ux-designs/ux-PaperLens-2026-08-29/DESIGN.md
  - bmad-docs/planning-artifacts/ux-designs/ux-PaperLens-2026-08-29/EXPERIENCE.md
productBaseline: 5eac3bb9424ad893eca7d63bc319b71f580838ed
architectureBaseline: cdabe4419606ab0c1efebcfeb79bded0fe344512
uxRevision: 5eac3bb9424ad893eca7d63bc319b71f580838ed
inputSelectionConfirmed: true
requirementsConfirmed: true
epicsConfirmed: true
---

# PaperLens - Epic Breakdown

## Overview

승인된 제품·아키텍처와 완성된 UX를 구현 가능한 Epic·Story로 분해한 문서다. 사용자가 요구사항 추출, 다섯 Epic, 53개 Story와 Party 수정·최종 명확화를 승인했고 최종 검증 통과 후 `[C] Complete Workflow`를 선택하여 **Epic·Story 분해 workflow를 완료**했다. 이 확인은 Build Spec의 IMPLEMENTATION 승인이나 기술 게이트 통과가 아니다.

### 권위와 추적 원칙

- 제품 기준: `APPROVED: PRODUCT @ 5eac3bb9424ad893eca7d63bc319b71f580838ed`, [GitHub 승인 기록](https://github.com/jinzer0/PaperLens/issues/1#issuecomment-5863429635). FR-037~039와 SM-007을 포함한다. 원문 draft/pending 및 이전 SHA 표기는 승인 전 이력이며 이후 명시적 승인 기록과 함께 해석한다. 이를 고치기 위한 원문 재작성은 하지 않는다.
- 아키텍처 기준: `APPROVED: ARCHITECTURE @ cdabe4419606ab0c1efebcfeb79bded0fe344512`, [GitHub 승인 기록](https://github.com/jinzer0/PaperLens/issues/1#issuecomment-5490375836). AD-1~14를 유지한다. 테마 소유권은 PRD 부록 §11.1의 기존 AD-1/6/11 경계에 따른다.
- UX: 위 UX revision의 DESIGN/EXPERIENCE를 하나의 계약으로 사용한다. 연결된 11개 mockup은 정적 시각 참조이며 native 동작·접근성 검증 증거가 아니다. 충돌 시 문서 계약이 우선한다.
- 제품 FR/NFR 번호는 원문 그대로 보존한다. 아래 요약은 원문의 모든 `Consequences (testable)`를 대체하지 않는다. Story 작성 때 해당 ID의 본문·하위 조건 전체를 인수 조건으로 추적한다.
- 과거 Brief·검토 초안은 요구사항 기준에서 제외한다. UX 열린 구현 세부사항을 새 제품 요구사항이나 완료된 결정으로 승격하지 않는다.
- P-1~P-6은 **미통과**다. 각각 독립 검증 작업 및 해당 downstream 의존성으로 분해하며 모든 Story에 일괄 선행 조건으로 걸지 않는다. 프로토타입 소스 변경 역시 별도 Build Spec과 IMPLEMENTATION 승인이 필요하며 계획 작성은 게이트 통과 증거가 아니다.
- 비사소한 구현은 Story : GitHub Issue : task branch : PR = 1:1:1:1이다. Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인 전 제품 소스를 만들지 않는다. Push/PR은 별도 지시, merge는 현재 PR HEAD의 MERGE 승인이 필요하다.

## Requirements Inventory

### Functional Requirements

출처: PRD §7, 각 ID의 모든 하위 검증 조건 포함.

- FR-001: 첫 실행에서 지원 Provider 설정과 연결 테스트 성공 전 전체 앱 진입을 막고, 실패 이유·Retry 및 성공 후 진입을 제공한다.
- FR-002: OpenAI API key와 공식 Codex SDK ChatGPT 로그인/device-code를 지원하고 각 연결 결과를 표시한다. generic Codex OAuth는 금지한다.
- FR-003: Onboarding/Settings에서 Provider 선택과 현재 상태를 보여준다. 별도 전송 고지·필수 동의·consent gate는 추가하지 않는다.
- FR-004: Settings에서 연결 정보 갱신·재로그인·재테스트를 제공한다. 실패 시 기능 가용성은 마지막 성공 연결 기준으로 표시한다.
- FR-005: arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF 네 경로를 지원한다. abstract는 PDF로 해석하고 로컬은 URL 없이 처리한다.
- FR-006: Import 전에 Folder/default를 확인하고 제목·URL·식별자에 따른 중복 가능성을 경고한다. 중단/계속 선택을 제공한다.
- FR-007: PDF 준비와 후속 AI Job 상태를 분리한다. PDF 준비 후 Reader를 열 수 있고 실패·재실행 후 상태에 Open Reader/Retry를 제공한다.
- FR-008: 한 Reader의 Paper 맥락에서 PDF, Translation, Paper Chat, Brief Drawer, Highlight/Note를 제공한다. Drawer는 페이지를 유지하고 기록은 Library에 남는다.
- FR-009: PDF 페이지 이동, 확대/축소, 검색·일치 없음, 선택 가능한 텍스트의 드래그 선택을 제공한다.
- FR-010: Paper별 마지막 읽은 위치를 화면 재진입·앱 재실행 후 복원하고 삭제 후에는 복원하지 않는다.
- FR-011: 파싱 실패에도 원본 PDF를 유지하고 Translation/Chat/Brief를 이유와 함께 비활성화하며 Retry Parsing을 제공한다.
- FR-012: 원문/번역 문장을 1:1로 대조하고 양쪽 hover에서 대응 문장을 함께 강조한다.
- FR-013: Translation 대상 언어의 기본값은 한국어이며 설정 변경을 새 Job과 명시적 재생성에 적용한다.
- FR-014: Translation 진행률·오류·재시도를 제공하고 완료 결과는 재방문 시 재생성 없이 캐시로 표시한다.
- FR-015: 정렬 실패·보정 상태를 일반 성공과 구분하고 완전 정확도를 주장하지 않는다.
- FR-016: Paper Chat은 항상 단일 Paper 전체 검색 근거 기반이다. 모드 토글·현재 페이지/선택 문장 전달 없이 동작하고 Paper 밖 지시에도 범위를 유지한다.
- FR-017: Chat의 논문 주장에 Evidence Anchor 또는 근거 부족 상태를 표시한다. hover 원문 미리보기와 click PDF 페이지·문장 강조 이동을 제공한다.
- FR-018: Paper별 복수 Chat Session을 자동 저장하고 목록 선택·앱 재실행 후 대화를 복원한다.
- FR-019: Session 생성·이름 변경·삭제를 제공하고 첫 질문에서 제목을 자동 생성한다. 수정·삭제는 재진입 후에도 유지한다.
- FR-020: Paper 추가 시 구조화된 Markdown Brief Job을 생성하고 완료·실패·Retry 및 독립 Brief 화면을 제공한다.
- FR-021: 기본 Brief는 문제, 기존 방법 한계, 제안 방법, 논문 명시 한계, AI 분석 한계, 추가 최적화 가능성, 방법의 장점과 한계를 포함한다. 논문/AI 한계를 구분하고 누락을 빈 성공처럼 보이지 않게 한다.
- FR-022: 기본/사용자 Template으로 Brief 생성·재생성을 제공하고 Template 버전·입력을 Paper-bound snapshot으로 캡처한다. 교체를 명확히 하며 실패 시 기존 Brief를 유지한다.
- FR-023: 독립 사용자 Template의 Markdown 항목 추가·수정·삭제 및 프롬프트 편집·저장을 제공한다. Paper 삭제 후에도 Template과 이후 생성 선택지를 보존한다.
- FR-024: Brief의 논문 주장에 Evidence Anchor를 연결하고 hover 원문 미리보기·click Reader 페이지/강조 이동을 제공한다.
- FR-025: Brief Drawer에서 Markdown/Anchor를 확인하고 열기·닫기 전후 PDF 읽기 위치를 유지한다.
- FR-026: Library에 Folder 생성·Paper 배치/이동, 최근 읽은 Paper, 카드/목록과 Reader 진입을 제공한다.
- FR-027: 카드/목록에 제목·발행연도·한 줄 요약을 표시하고 hover/detail에서 abstract 일부·주제 태그를 제공한다.
- FR-028: 태그 추가·수정·삭제, 제목/태그/읽기 상태/Favorite 검색·필터 및 읽기 상태/Favorite 보존을 제공한다.
- FR-029: Highlight, Note, Brief, Reading Status, 마지막 위치를 Paper의 Library 기록에 연결하고 재실행 후 유지한다.
- FR-030: Paper 삭제 완료 후 검색·최근·폴더·Reader에서 PDF와 Translation, Brief, snapshot, Session, Highlight, Note, 읽기 이력/위치에 재진입할 수 없고 재실행 후 복원되지 않는다. 독립 Template은 보존한다.
- FR-031: 삭제 실패는 미완료와 재시도로 표시한다. 진행 중 Job이 삭제한 Paper를 되살리거나 부분 삭제를 성공으로 표시하지 못한다.
- FR-032: Import, parsing, Translation, Chat 준비, Brief의 pending/running/succeeded/failed와 기능 가용성을 구분한다. 30초 이상 AI Job도 PDF 접근을 막지 않는다.
- FR-033: Job 실패 기능·이유·가능한 Retry를 표시하고 PDF/기존 Brief 등 사용 가능한 결과는 유지한다.
- FR-034: 앱 재실행 후 완료/실패/재시도 필요 상태와 결과를 복구하고 Reader 열기·재시도·사용 불가 중 다음 행동을 제공한다.
- FR-035: macOS 15+ 공개 오픈소스 arm64/x86_64 별도 산출물, 실행·Provider 설정 방법, 최종 라이선스를 제공한다.
- FR-036: 추천·지식 그래프·로컬 모델·cloud sync 등 후속 후보를 v1 출시 약속으로 표현하지 않는다.
- FR-037: 새 설치 기본 Native Canvas와 Settings의 Native Canvas/Scholarly Press/Focused Instrument 선택을 앱 화면 전체에 일관되게 적용한다.
- FR-038: 테마·명암 설정을 로컬에 보존하고 전환 시 Paper/페이지/Session/Note/Brief/원본 PDF를 유지한다. 설정 또는 OS 명암 변경은 AI/Import/parsing Job 생성·재시도를 유발하지 않는다. Paper 삭제 후에도 설정은 남는다.
- FR-039: 세 테마 모두 matte Light/Dark와 동일한 기능·상태 의미를 제공한다. System 기본 및 독립 System/Light/Dark 정책을 저장한다. System만 OS 변경을 따르며 명시 Light/Dark는 유지한다. 재실행은 정책을 복원하고 테마/명암은 서로 바꾸지 않는다. 여섯 렌더링 조합에서 강조·Anchor·오류/복구·삭제 실패 계약을 유지한다.

### NonFunctional Requirements

출처: PRD §9. 가정은 게이트의 측정·결정으로 구체화하되 여기서 임의 확정하지 않는다.

- NFR-001: arXiv 제출 수락부터 첫 PDF 표시 및 navigation/zoom 응답까지 30초 soft target을 측정·보고한다.
- NFR-002: A-002의 일반 네트워크·정상 URL·과도하게 크지 않은 텍스트 PDF 조건을 P-6/QA에서 측정 가능한 fixture/profile로 확정한다.
- NFR-003: 로컬/일반 PDF URL도 AI보다 PDF 접근이 우선이며 source별 세부 시간 기준을 Architecture/QA에서 확정한다.
- NFR-004: 첫 가치 도달 전 이탈 위험을 줄이도록 원본 PDF 접근을 우선한다.
- NFR-005: AI 답변·Brief·Translation·Anchor의 완전 정확도를 주장하지 않는다.
- NFR-006: AI 논문 주장은 Evidence Anchor에 연결하거나 근거 부족을 명시한다.
- NFR-007: macOS Local App Data를 사용하며 cloud backup/sync/recovery를 제품 기능으로 제공하지 않는다.
- NFR-008: Paper와 소유 파생 데이터 전체 삭제를 완료 동작으로 보장하고 독립 Template은 보존한다.
- NFR-009: Provider 비밀정보에 OS keychain을 사용하지 않는다. A-003을 AD-4의 명시적 내부 threat boundary와 함께 적용한다.
- NFR-010: 외부 Provider 사용에 따른 논문·개인 데이터 외부 전송을 제품 전제로 유지한다.

### Additional Requirements

출처: Architecture Spine AD-1~14, P-1~6, SOLUTION-DESIGN §4~11, PRD §10~14 및 부록. AR 번호는 이 분해 문서의 추적 식별자이며 새 아키텍처 결정이 아니다.

- AR-001 (AD-1): SwiftUI native modular monolith의 Features → Application → Domain 및 port/adapter 경계를 유지한다. Application만 durable state/side-effect winner를 소유하고 Composition Root만 concrete adapter를 조립한다. Feature/PDFKit page/zoom/selection만 ephemeral이다. Worker/adapter는 typed output만 반환한다.
- AR-002 (Structural Seed/Stack): Main App, PDFiumXPC, ProviderAgent, ProviderRPC/ProviderRequest/EvidenceAnchor/PersistenceMigrations 경계를 따른다. 승인 문서에 외부 starter template 지정은 없다. APPROVED: ARCHITECTURE @ 1195c92227cc628e325f5ff24d70cc93639bf7a9에 따라 Swift 6.4, Xcode 27.0 (27A266a)/SDK 27.0, GRDB 7.11.1, PDFium commit ad5bc13610718aefe737bd9b2f1b258d08e39428, macOS 15+, system SQLite/FTS5를 추적한다. 공식 Python Codex SDK/CLI-bin 0.160.0 일치 조합을 기준으로 하되 CPython/전이 의존성 및 P-2 최종 lock·두 CPU 증거 완료를 주장하지 않는다.
- AR-003 (AD-2): 별도 sandbox identity의 hardened Provider Agent가 packaged official Python Codex SDK를 사용한다. app container/group 공유와 native의 broad Agent filesystem 접근을 금지한다. installed CLI/Python 의존, chatgptAuthTokens, direct app-server injection, generic OAuth를 금지한다.
- AR-004 (AD-2/SD §5.1): sole ProviderRPC의 big-endian 32-bit length+UTF-8 JSON, startup major/minor handshake, major mismatch fail-closed, correlation, exactly-one terminal response, typed error, cancellation/timeout, method allowlist, bounded stream을 따른다. stdout은 protocol-only, environment는 allowlist, argv secret은 금지다. 정확 method fields는 구현 분기 전 shared Build Spec에 고정한다.
- AR-005 (AD-2/11): Agent는 auth/config/package metadata만 durable 보존한다. Paper request/response/EvidenceBundle/result/content는 durable 보존하지 않고 SDK 임시 상태는 Paper UUID/generation/correlation attempt-scoped다. terminal/cancel/startup purge와 Paper 삭제 purge acknowledgment/verification을 RPC로 제공하고 native가 Agent 영역을 직접 정리하지 않는다.
- AR-006 (AD-3): Application이 active revision에 pin된 versioned operation과 ordered immutable EvidenceBundle(Anchor, full quote, selection metadata, order, insufficiency)을 만든다. Adapter add/drop/reorder/rerank/truncate/insufficiency 승격을 금지한다. Provider 한도 오류는 typed error이고 공통 budget으로 재구성하는 주체는 Application뿐이다.
- AR-007 (AD-3/P-3): operation별 source/field allowlist만 허용한다. raw PDF/path/DB·FTS rows/URL credentials/workspace/Reader page·selection·highlight/임의 Note·Template/무제한 history는 금지하고 명시적으로 선택한 bounded prior turns만 허용한다. ranking/prompt/budget은 shared Build Spec에서 분기 전에 고정한다.
- AR-008 (AD-4): Keychain·별도 at-rest 암호화 없이 API key는 native adapter만 읽는 private backup-excluded plaintext slot에 둔다. Agent 비밀정보는 Agent zone 소유다. root/descendant directory 0700, file 0600과 매 write/auth 후 backup exclusion/권한을 검증하고 실패 시 test/promotion 거부·stage 삭제·startup 정리를 수행한다. 비밀정보를 SQLite/일반 config/log에 넣지 않는다.
- AR-009 (AD-5): 실제 최소 authenticated v1 generation의 typed usable response만 연결 성공이다. identity/list-only는 불충분하다. immutable never-reused slot/version/config generation과 SQLite sole active selector를 사용한다. serialized CAS promotion, commit/in-flight retirement까지 last-good 보존, selected complete slot만 startup 보존, old-generation 결과 publish 금지, ambiguous attempt 자동 retry 금지를 지킨다.
- AR-010 (AD-6): persistence adapter의 단일 long-lived GRDB.DatabaseQueue만 SQLite/FTS5를 연다. Application Support의 durable data/PDF와 Caches의 재생성 artifact를 분리한다. 한 ordered append-only migration registry와 transactional startup forward migration을 사용하며 실패는 fail-closed다. durable data를 cache/filesystem에서 재구성하지 않는다.
- AR-011 (AD-6/10/11): 모든 Paper filesystem producer는 첫 접근 전 UUID/generation writer permit을 받고 close/취소 bytes cleanup까지 유지한다. revoke 후 typed cancelled/stale만 반환하고 bytes 제거 전 release하지 않는다. final rename 직전 별도의 publication permit을 얻어 guarded DB commit 또는 동기 rollback cleanup까지 유지한다. 실패한 guard는 같은 operation에서 final artifact를 제거한다. SQLite가 visibility authority이고 startup referenced-missing은 typed failure, unreferenced stage/final은 scavenge한다.
- AR-012 (AD-7): Paper UUID는 lifecycle, SHA-256은 immutable content/duplicate identity다. 중복 계속은 새 UUID와 단독 소유 PDF copy를 만들며 blob sharing/refcount는 없다. URL HTTPS-only, 매 redirect 재검증, embedded credentials 및 type/magic/resource 위반 거부, ATS cleartext exception 금지다. local security scope는 copy 동안만 유지하고 bookmark를 저장하지 않는다.
- AR-013 (AD-7): PDFKit은 UI process의 render/search/selection을 담당한다. no-network sandbox PDFium XPC는 read-only imported PDF와 resource ceilings로 canonical sentence/geometry batch만 반환하고 DB/Secrets/Caches/임의 파일을 열지 않는다. Application이 inactive immutable sentence/geometry/revision FTS를 완성한 뒤 단일 transaction으로 active revision을 게시한다. Retrieval은 revision을 pin하고 참조 중 old revision을 보존한다.
- AR-014 (AD-8): Anchor identity는 Paper UUID/PDF SHA-256/extraction revision/zero-based page/sentence ID다. full sentence quote와 unrotated CropBox PDF points, lower-left origin, +x/+y, TL/TR/BR/BL quad 및 rotation을 따른다. PDFium normalize/PDFKit display transform을 분리하고 PDF component 분기 전 shared tolerance를 고정한다. anchored/insufficientEvidence/locationUnclear/navigationFailed/staleRevision을 구분하며 추정 위치를 성공으로 위장하지 않는다.
- AR-015 (AD-9): canonical sentence map 기반 페이지 독립 Translation task를 page order로 enqueue하고 bounded parallelism으로 처리한다. navigation은 queue를 재정렬하지 않는다. 완료 page 즉시 표시, 미완료 PDF+loading/error, Paper/generation/extraction/input/provider-result version 캐시와 정렬 실패/보정 구분을 유지한다.
- AR-016 (AD-10): logical Job은 stable, Retry attempt/fence는 immutable never-reused다. transactional pending→running claim과 외부 호출 전 durable dispatch intent/correlation을 기록한다. publication CAS는 running/current attempt/fence/input/provider generation/active Paper generation을 검사하고 result/success/current-usable pointer를 원자 commit한다. stale/failure는 prior usable을 바꾸지 않는다.
- AR-017 (AD-10): startup의 모든 이전 running attempt는 단일 reconciliation transaction에서 failed/interrupted로 전환하고 기존 fence resume/renew를 금지한다. 정상 claim은 pending만 가능하다. Job 구현 분기 전 Application-owned Job-class recovery policy를 고정한다. ambiguous external dispatch는 명시적 Retry만 새 attempt/fence를 만든다.
- AR-018 (AD-11): 삭제 시작 transaction에서 active predicate·generation·lease·새 writer/publication permit을 revoke 후 cancellation을 전달한다. 새 filesystem access/Provider dispatch/final rename을 막고 기존 writers/publishers를 drain한 다음 namespace 제거·absence check를 한다. pending/running은 non-retryable failed/paperDeleting, 늦은 결과는 publish/diagnostic 금지다. Agent purge 확인과 PDF/cache absence 이후 terminal DB cascade·minimal contentless durable tombstone을 남긴다. 실패는 같은 saga로 재개하고 old identity를 부활시키지 않으며 Template은 남긴다.
- AR-019 (AD-12): ImportAcceptedAt은 source/folder/duplicate/local-scope 결정 후 Job 생성 transaction에서, resolve/download/copy 전에 기록한다. FirstInteractivePageAt은 first-page presentation 직후 자동 시작한 P-6 단일 probe의 main-thread visible update 완료 신호다. manual input/think time/control enable/document open은 대체 신호가 아니며 AI 시간은 제외한다. 30초는 arXiv soft target이고 material/repeated 초과에는 disposition이 필요하다.
- AR-020 (AD-13): direct Developer ID arm64/x86_64 별도 self-contained 산출물, manual app replacement만 지원한다. App Store/updater/telemetry backend는 없다. 모든 nested executable은 sandbox/hardened runtime이며 inventory, inside-out signing, sealed bundle, notary log, staple/validate, clean-machine Gatekeeper를 각각 검증한다. 두 CPU는 동일 source/lock/contracts/migrations/extraction/entitlements/smoke와 expected results를 사용한다. credentials는 release environment만 소유한다.
- AR-021 (AD-14): Template save는 immutable version/current pointer를 만든다. Brief command는 선택 버전·sections/prompts/inputs의 value-copy snapshot, ordered regeneration version, Job을 원자 생성한다. payload는 snapshot만 읽고 result는 snapshot identity/hash·extraction·provider·Paper generation을 기록한다. current fenced regeneration 성공만 current Brief를 교체하며 failed/out-of-order는 prior Brief를 유지한다. 참조 중 Template version은 임의 정리하지 않는다.
- AR-022 (AD-4/11/consistency): diagnostics는 safe code/allowlisted fields만 저장하고 secret/raw URL/argv/environment/request·response/document·personal content/raw streams를 금지한다. 동일-user malware, PDFKit compromise, backup/snapshot, 이미 전송된 요청의 한계는 내부 review에 남기며 별도 user-facing accepted-limit disclosure/consent surface를 추가하지 않는다. privacy/security/containment/삭제에 대한 거짓 보장도 금지한다.
- AR-023 (consistency): canonical Domain 명칭, immutable ID/version, UTC RFC3339 persisted time, closed typed state/error/reason enum을 따른다. interrupted/paperDeleting은 failed의 reason이지 새 state가 아니다. framework/SDK type은 Domain/wire에 노출하지 않는다.
- AR-024 (PRD §4/10/14): macOS desktop만 범위다. cloud 계정/storage/sync/recovery, mobile/web, 협업/Zotero, OCR, local model, Provider-free mode, 추천/지식 그래프, 일반 AI Chat, 완전한 표·그림·수식 분석, 이해도 평가·퀴즈를 추가하지 않는다. 사용자 테마 editor/download/marketplace도 범위 밖이다. EasyPaper는 UX 영감만 사용하고 코드는 재사용하지 않는다.
- AR-025 (FR-035/AD-13): AGPL-3.0-only와 dependency compatibility, corresponding source/notices, macOS/Provider 실행 안내를 공개 산출물에서 확인한다. 한 개발자의 agentic coding 맥락에서도 출시 필수 기능을 조용히 축소하지 않는다.
- AR-026 (부록 §11.1): theme/appearance는 Application use case와 기존 persistence가 소유하는 Paper-independent cross-feature 상태다. 별도 feature durable store/직접 SQLite를 만들지 않는다. 저장 연산·migration 필요성·native appearance 관찰·저장 실패 처리는 Build Spec에서 정한다.

#### Blocking Gates — 통과로 간주하지 않음

| ID | 독립 검증/결정 작업의 산출물 | 소유자와 차단 경계 |
|---|---|---|
| P-1 | 두 CPU의 signed/notarized Main App + no-network PDFium XPC + 별도 Agent prototype, sandbox/entitlement negative tests, container/group 비공유, nested inventory, Gatekeeper 및 성공/실패/restart/replacement/Paper 삭제 후 Agent marker absence/purge 증거 | Architecture/Security/Release; Provider Agent·PDFium XPC·packaging Build Specs 차단 |
| P-2 | 정확 Xcode/SDK/Python SDK·runtime·CLI/PDFium deps와 hashes, 최소 macOS 15 및 현재 지원 OS build × 두 CPU matrix. 매 점에서 packaged DB open/migration, FTS5 create/query/delete, Agent marker absence/purge 증거 | Release; helper·CI·persistence·public packaging 분기 전 차단 |
| P-3 | versioned operation field/source allowlists와 numeric item/byte/token/message/stream/import/parser ceilings | Application/Provider/Import/PDF; Chat·Translation·Brief·Provider·Import·PDFium Build Specs 차단 |
| P-4 | local diagnostics 위치·보관·사용자 export·redaction·deletion 정책. telemetry 없음 | Application/Release; public release plan 차단 |
| P-5 | downgrade/rollback 지원 경계, incompatible schema/corruption fail-closed 결정·검증 | Persistence/Release; schema-bearing public release 차단 |
| P-6 | 모든 source·CPU 공통 navigation 또는 zoom 중 정확히 하나의 readiness probe/completion signal, fixture/profile, general/local 기준, material/repeated 초과 disposition | QA/Architecture; Import/Reader timing Build Specs 분기와 release readiness evidence 차단 |

P-1/P-2 실패 시 ChatGPT 경로를 제거해 우회하지 않는다. 제품 수정·새 PRODUCT 승인이 필요하다. 정확 schema/SQL, method payload, scheduling/backoff/lease/worker 수, ranking/segmentation/geometry algorithm, prompt/limits는 지정 shared Build Spec과 해당 게이트의 미결정 사항이다.

#### Release Acceptance 및 counter-metrics

- SM-001: 실제 Provider 설정→arXiv Import→interactive PDF와 30초 측정 증거→Translation/Chat/Brief 분리 상태의 end-to-end 흐름. material/repeated 초과는 release review/disposition 필요.
- SM-002: 양방향 Translation hover 및 Chat/Brief Anchor hover/click이 PDF 페이지·visible highlight로 돌아가는 native 검증.
- SM-003: 파싱 실패 PDF 유지, AI 비활성 이유, Retry, 재실행 복구 시나리오.
- SM-004: Library 최근/폴더/태그/필터/상태/Favorite/Highlight/Note/마지막 위치 재방문.
- SM-005: 모든 Paper 소유 데이터 삭제, 재실행·검색·Reader 비복원, independent Template 보존 및 실패/경합 검증.
- SM-006: 두 CPU 공개 macOS 15+ 산출물에서 실행/Provider 설정/라이선스 확인.
- SM-007: Native Canvas/System 기본, 세 테마×두 명암, 독립 정책 저장·OS 반영/명시 override, 재실행·Paper 삭제 후 보존, Reader/Library/Brief/Settings 가독성·상호작용·오류/복구, 원본 PDF/맥락/데이터 보존과 새 Job 부재. 하나라도 실패 시 테마 gate 미통과.
- CM-001: 속도 향상으로 Anchor 실패·wrong clickback·근거 부족 누락을 정당화하지 않는다.
- CM-002: 기능 수 완료율은 SM-001~005 end-to-end 실패를 가리지 못한다. 30초 초과만으로 자동 실패는 아니나 미해결 material/repeated disposition은 release-ready를 막는다.
- CM-003: AI 유창성으로 근거 없는 논문 주장을 정당화하지 않는다.

#### 위험 추적

R-001 parsing 품질, R-002 문장 정렬/Anchor 품질, R-003 필수 onboarding, R-004 외부 전송 기대, R-005 no-keychain, R-006 macOS/no-sync 경계, R-007 전체 출시 범위/1인 유지, R-008 Reader 속도, R-009 여섯 테마 조합을 해당 Story의 위험·실패 검증으로 연결한다. A-001은 AD-8/shared tolerance, A-002는 P-6, A-003은 AD-4의 통제·증거로 추적하며 가정 자체를 검증 성공으로 표시하지 않는다.

### UX Design Requirements

출처: DESIGN의 tokens/Components 및 EXPERIENCE의 Component/State Patterns, Interaction Primitives, Accessibility Floor, UJ-1~4. UX-DR1~29는 양 문서에 대응하는 **29개 component 각각**이며 이후 항목은 교차 계약이다.

- UX-DR1 — ProviderOnboarding: full-window에서 두 Provider 경로를 동등하게 표시한다. cold/selection/input/testing/succeeded/failed를 구분하고 실패 시 form·안전 입력 보존, redacted reason/Retry/Change Provider Path를 제공한다. 실제 요청 성공 후에도 explicit Continue 전에는 Library로 자동 이동하지 않는다.
- UX-DR2 — ProviderSettings: native Settings에서 현재 Provider/상태, 재입력·재로그인·테스트를 묶는다. 실패를 성공으로 승격하지 않고 last-good 기준 가용성과 redacted reason/Retry를 표시한다.
- UX-DR3 — TranslationLanguageControl: native 언어 선택과 한국어 기본값을 제공하고 새/명시 재생성 Job에만 반영한다. 기존 번역을 몰래 교체하지 않으며 선택·저장 실패를 텍스트로 표현한다.
- UX-DR4 — ImportDropTarget: Library는 평상시 content를 유지하고 지원 file/URL drag-over 중 전체 surface를 tint+label target으로 바꾼다. URL paste/local file 선택도 명시적으로 남긴다.
- UX-DR5 — ImportConfirmationSheet: 네 source branch, recognized Paper, Folder/default, duplicate를 compact sheet로 확인한다. Cancel/Continue 전 Job을 만들지 않고 Continue 후 Library에 남는다. PDF-ready는 Open Reader, 실패·재실행은 reason/Retry를 제공한다.
- UX-DR6 — JobStatusStrip: Import/parsing/Translation/Chat 준비/Brief의 네 Job 상태와 개별 가용성·복구를 텍스트/진행/Retry로 분리한다. 실패를 색만으로 표시하거나 30초를 UI timer 약속으로 표시하지 않는다.
- UX-DR7 — LibraryPaperCard: 기본 card에 title/year/one-line summary/reading state/favorite/more-actions를 제공하고 저장된 읽기 위치로 연다. duplicate/deleting을 성공처럼 보이지 않게 한다.
- UX-DR8 — LibraryPaperRow: card와 동일 식별 정보·상태·검색 결과를 list로 제공하고 card/list 선택을 재실행 후 유지한다. hover/detail의 abstract/topic tags와 non-openable 삭제 미완료/Retry Deletion을 제공한다.
- UX-DR9 — LibraryOrganizationControls: native folder 생성·Paper 배치/이동, tag 추가·수정·삭제, Reading Status/Favorite 변경을 label/현재 값으로 표시하고 재진입 후 보존한다. card/list와 독립이다.
- UX-DR10 — LibrarySearchFilters: top toolbar 검색과 left sidebar tag/Reading Status/Favorite 필터를 두 presentation에 공통 적용한다. cold-loading/populated/empty/no-match를 구분하고 empty에 Import 진입을 제공한다. 기본 recently read와 name/recently added/recently read/publication year 정렬을 제공한다.
- UX-DR11 — ReaderShell: 한 Paper의 PDF/Translation/Chat/Brief/Highlight/Note를 묶고 AI pending과 무관하게 PDF를 연다. Translation tab은 equal split이며 PDF navigation만 Translation page를 제어한다. last-read를 재진입/재실행 후 복원한다.
- UX-DR12 — ReaderOutline: metadata/Contents/active section/last position을 제공하고 section 선택이 PDF와 Translation page를 맞춘다. parsing recovery action은 이 sidebar에 두지 않는다.
- UX-DR13 — ReaderToolbar: 이전/다음·page count·페이지 이동, zoom, PDF search/no-match를 제공한다. native convention과 충돌하는 단축키를 만들지 않고 미결정 global shortcut을 시안으로 확정하지 않는다.
- UX-DR14 — PdfPanel: Original PDF scroll/search/select/zoom을 AI 상태와 독립적으로 제공한다. feature-local state와 Application durable 저장을 분리하고 실제 PDF content/font/file을 테마로 변경하지 않는다.
- UX-DR15 — TranslationPanel: 현재 PDF page 결과를 자연스러운 문단으로 표시하고 pending/running/succeeded/failed/alignment-uncertain/cached를 구분한다. 실패 page에 reason/inline Retry, 완료 page 즉시 표시, 미완료 동안 PDF 유지, 내부 scroll로 PDF navigation 변경 금지를 따른다.
- UX-DR16 — SentenceMatch: 양쪽 hover 및 keyboard focus에서 동일 sentence identity의 원문/번역 pair를 match/outline으로 강조한다. 문장 순서·citation range·페이지를 임의 변경하지 않는다.
- UX-DR17 — PaperChatPanel: empty composer에서 첫 질문 submit 때 Session을 만든다. paper-wide evidence만 사용하고 current page/selection/highlight 전송과 Chat mode toggle은 없다. loading/answer/근거 부족 및 Anchor 실패 상태를 구분한다.
- UX-DR18 — EvidenceAnchor: Chat/Brief 주장 옆 inline marker를 제공한다. hover/focus full source sentence preview, click PDF page/visible highlight, anchored/insufficientEvidence/locationUnclear/navigationFailed/staleRevision을 구분한다. 시각 truncation은 명시적 확장으로 전체 의미를 보존한다.
- UX-DR19 — BriefTrigger: Reader edge trigger로 Drawer를 열고 닫을 때 페이지를 보존한다. Markdown/Anchor를 제공하고 generation failure가 prior usable Brief를 숨기거나 교체하지 못한다.
- UX-DR20 — BriefView: 독립 화면과 Drawer에서 FR-021의 일곱 섹션을 모두 제공한다. 논문 명시/AI 분석 한계를 분리하고 missing-content, auto-pending/ready/regenerating/failed-with-prior/empty를 구분한다.
- UX-DR21 — SelectionActionBar: PDF 텍스트 선택 뒤 Highlight/Add Note/Copy만 제공하고 Chat context 전송 action은 없다. Add Note는 PDF 위치와 선택 원문을 유지한다.
- UX-DR22 — NotesDrawer: Add Note로 right drawer를 열어 선택 원문을 보존하고 저장 Note를 Paper Library에 남긴다. 닫으면 Reader context로 돌아오며 개인 Note를 anchored claim처럼 표시하지 않는다.
- UX-DR23 — TemplateSelector: default/user Template과 Template 관리 action을 제공한다. Settings editor 저장 후 originating Brief로 복귀하고 선택 상태를 유지하되 선택/저장만으로 재생성하지 않는다.
- UX-DR24 — TemplateEditor: Settings dedicated editor에서 Markdown section 추가·수정·삭제와 prompt 저장을 제공한다. immutable version 및 Paper 삭제 후 보존을 따른다. validation 상세는 Build Spec에서 결정한다.
- UX-DR25 — ChatSessionMenu: title dropdown의 세션 선택은 in-place 복원, 별도 새 대화는 첫 질문 전 durable session 없는 empty composer다. 자동 저장/재실행 복원·첫 질문 자동 제목을 지원한다. entry/current more-actions는 동일 rename/delete를 호출하고 rename dialog에 현재 제목을 채운다. current 삭제 후 최근 active remaining session, 마지막 삭제 후 replacement 없는 empty composer로 돌아간다.
- UX-DR26 — DeleteAlert: macOS Paper alert/Session warning에서 대상 이름, 제품 삭제 범위, irreversible action, Cancel/destructive Delete를 구분한다. 취소는 원래 상태를 유지한다. Paper 삭제 실패 card/row는 non-openable 삭제 미완료와 같은 saga의 Retry Deletion만 제공하고 별도 deletion work area나 AI Retry를 만들지 않는다. accepted-limit disclosure를 추가하지 않는다.
- UX-DR27 — ThemePicker: Settings에서 세 테마와 현재 선택을 label+accent-soft로 표시한다. 기본 Native Canvas, 앱 전체 일관 적용·재실행 보존, appearance 독립, 읽기 맥락/Job 불변을 따른다.
- UX-DR28 — AppearancePicker: ThemePicker와 별도 native System/Light/Dark 선택을 제공한다. System 기본·현재 OS 추종, 명시 override 유지, 재실행 정책 복원, Paper 삭제 후 설정 유지, 전환 시 새 AI 요청/Retry 없음과 원본 PDF 불변을 따른다.
- UX-DR29 — StatusBar: 현재 페이지, PDF navigation→Translation 관계, match 상태를 텍스트로 제공한다. 시안 Match 03이나 sample progress를 항상 성공/실제 진행률로 고정하지 않는다.
- UX-DR30 — Design tokens: DESIGN의 세 테마×Light/Dark semantic color roles, typography/Korean fallback, spacing/radius를 같은 역할로 적용한다. Native는 따뜻한 matte, Scholarly는 serif/firm rule/제한 mono, Focused는 차가운 tonal/compact metadata를 유지한다. 네 번째 혼합 테마/glossy 장식을 추가하지 않는다. artifact 배경·HTML paper 모형·CSS literal을 native runtime 계약으로 오인하지 않는다.
- UX-DR31 — 대비와 상태: normal text ≥4.5:1, large text/meaningful non-text/focus ≥3:1을 실제 배경과 여섯 조합에서 검증한다. selected/progress/success/error/deletion-incomplete는 label/outline 등 색 외 신호를 가진다. 기존 네 palette pair 계산은 전체 native 감사 성공이 아니다.
- UX-DR32 — 타이포그래피/resize: native semantic text scaling과 macOS 접근성 설정, 한국어 strict/keep-all 문단 흐름을 존중한다. 창 축소·확대에서도 PDF/페이지/Translation 상태/Chat·Brief/포커스가 소실되거나 텍스트가 잘리지 않아야 한다. HTML 1440×900/1240 breakpoint/30px control을 native minimum으로 강제하지 않는다.
- UX-DR33 — Keyboard/VoiceOver: 모든 button/tab/row/menu/drawer/dialog/선택에 name/role/state/next action을 제공한다. Titlebar→Outline→Toolbar→PDF→Translation/Chat→Brief/Status 순서, Tab/Shift-Tab, 최상위 Escape 닫기, drawer/dialog focus 진입·opener 복귀, keyboard/VoiceOver preview·clickback·Retry/Cancel/Delete를 검증한다. Job status/alert 중복 안내를 피하고 PDF 원문/Translation 언어 metadata를 제공한다.
- UX-DR34 — Parsing recovery: 즉시 in-app floating notification과 right panel의 latest reason/Retry Parsing을 제공한다. PDF는 유지하고 AI만 비활성화한다. attempt count/time/history는 노출하지 않는다. 성공하면 Translation tab/current-page progress로 전환하며 반복 실패·재실행 후에도 latest reason/explicit Retry를 유지한다.
- UX-DR35 — 비동기·복구: PDF 접근을 진행률로 막지 않고 ambiguous external work를 자동 재시도하지 않는다. relaunch 후 persisted failed/retry-needed/completed와 prior usable 결과, 각 다음 action을 복원한다. deleting/deleted Paper의 새 AI Job/재진입은 금지한다.
- UX-DR36 — Voice/tone: 짧고 차분한 한국어 상태+다음 행동, Reader 고정 용어를 일관 적용한다. 정확도/privacy/forensic deletion 보장, 일반 Chat/근거 mode toggle, 홍보/추천 문구와 별도 accepted-limit 고지·consent를 추가하지 않는다.
- UX-DR37 — UJ 검증: UJ-1 네 Import→PDF/번역→whole-paper Chat/Anchor→Brief/Note/재방문, UJ-2 Provider/파싱 실패 및 복구, UJ-3 정리/재방문/완전 삭제, UJ-4 Template 관리·명시 재생성/복수 Session의 성공·취소·실패·재실행 경로를 native 시나리오로 추적한다. 정적 HTML 검사를 대체 증거로 사용하지 않는다.
- UX-DR38 — 후속 세부 결정: native 최소 창/adaptive rule, Chat tab 열 비율, pointer target 수치, Reduce Motion, Template validation, global shortcuts, modal 중첩, 설정 저장 실패 처리는 해당 Build Spec에서 명시한다. 임의 확정 또는 제품 범위 확대를 하지 않으며 현재 요구사항 추출의 사용자 blocker로 만들지 않는다.

### FR Coverage Map

각 FR의 **v1 전체 범위 최종 통합 책임 Epic**을 하나로 지정한다. 이는 해당 FR을 처음 구현하는 시점이나 앞 Epic의 통과를 늦추는 표시가 아니다. 각 Epic은 그때 존재하는 모든 Paper 소유 데이터·Job에 대해 삭제·실패·재실행·재시도 경로를 해당 Epic의 완료 조건으로 검증한다. 후속 Epic은 신규 데이터/Job을 동일한 경계에 추가하고 전체 범위를 재검증한다.

| FR | 완료 책임 | 범위 / 선행 기여 |
|---|---|---|
| FR-001 | Epic 1 | 필수 Provider onboarding과 앱 진입 |
| FR-002 | Epic 1 | API key 및 공식 SDK ChatGPT/device-code 두 경로 |
| FR-003 | Epic 1 | Onboarding/Settings Provider 선택·상태 |
| FR-004 | Epic 1 | 연결 갱신·재테스트·last-good 보존 |
| FR-005 | Epic 1 | 네 Import 입력 |
| FR-006 | Epic 1 | Folder/default·중복 확인 |
| FR-007 | Epic 3 | Epic 1 PDF-first Import, Epic 2 Translation/Chat, Epic 3 Brief까지 상태 분리 완결 |
| FR-008 | Epic 3 | Epic 1 PDF/Highlight/Note, Epic 2 Translation/Chat, Epic 3 Brief Drawer의 Reader 통합 완결 |
| FR-009 | Epic 1 | PDF 탐색·zoom·검색·선택 |
| FR-010 | Epic 1 | 읽기 위치 저장·재진입·삭제 |
| FR-011 | Epic 3 | Epic 1 parsing/PDF 복구, Epic 2~3의 모든 AI 비활성·재개 연동 완결 |
| FR-012 | Epic 2 | 문장 정렬·양방향 강조 |
| FR-013 | Epic 2 | 언어 설정과 새 Job 적용 |
| FR-014 | Epic 2 | Translation 진행·오류·Retry·캐시 |
| FR-015 | Epic 2 | 정렬 불확실성 |
| FR-016 | Epic 2 | whole-paper 단일 Chat |
| FR-017 | Epic 2 | Chat Anchor·근거 부족 |
| FR-018 | Epic 2 | Session 자동 저장·복원 |
| FR-019 | Epic 2 | Session 생성·제목·이름 변경·삭제 |
| FR-020 | Epic 3 | Paper 추가 시 자동 Brief와 기존 Paper 연동 검증 |
| FR-021 | Epic 3 | 기본 Brief 일곱 항목 |
| FR-022 | Epic 3 | Template 선택·snapshot·재생성 |
| FR-023 | Epic 3 | 독립 사용자 Template 편집·보존 |
| FR-024 | Epic 3 | Brief Anchor |
| FR-025 | Epic 3 | 페이지를 유지하는 Drawer |
| FR-026 | Epic 1 | Folder·최근·card/list |
| FR-027 | Epic 1 | title/year/summary/abstract/topic tags 식별 정보 |
| FR-028 | Epic 1 | 태그·검색/필터·Reading Status·Favorite |
| FR-029 | Epic 3 | Epic 1 Highlight/Note/상태/위치, Epic 3 Brief 기록까지 완결 |
| FR-030 | Epic 3 | 매 Epic의 해당 데이터 삭제는 그 Epic에서 통과; Epic 3이 snapshot/Brief까지 전체 cascade와 Template 보존 최종 통합 |
| FR-031 | Epic 3 | 매 Epic에서 해당 Job과 삭제 경합/미완료·동일 saga 재시도 통과; Epic 3 전체 Job 통합 |
| FR-032 | Epic 3 | 매 Epic에서 새 Job의 durable 상태와 PDF 가용성 통과; Epic 3 모든 Job 유형 통합 |
| FR-033 | Epic 3 | 매 Epic에서 실패 이유/명시 Retry/그때 존재하는 prior usable 결과 보존 통과; Epic 3 전체 결과 통합 |
| FR-034 | Epic 3 | 매 Epic에서 새 Job의 restart reconciliation/다음 행동 통과; Epic 3 모든 Job 유형 통합 |
| FR-035 | Epic 5 | 두 CPU 공개 실행·설정·라이선스 |
| FR-036 | Epic 5 | 각 기능의 copy 제약 상시 적용, 공개 문구 최종 확인 |
| FR-037 | Epic 4 | 세 테마 선택·전 화면 적용 |
| FR-038 | Epic 4 | 설정 보존·맥락/데이터/Job 불변 |
| FR-039 | Epic 4 | 독립 appearance·여섯 렌더링 조합 |

## Epic List

**Epic 구조 승인됨 — Story 작성 중.** 기술 계층별 DB/API/UI Epic 대신 사용자가 실제로 끝낼 수 있는 작업으로 묶는다. 제품·UX·아키텍처 방향은 확정되어 있으므로 동일 Reader/Library/Job 경계를 불필요하게 세분화하지 않는다. 다만 Provider/PDF 기반, 근거 기반 AI, immutable Brief/Template, 전역 시각 설정, 공개 배포는 서로 다른 위험·검증 경계를 가진다.

Epic 완료는 해당 사용자 결과가 동작한다는 뜻이지 public v1 release-ready라는 뜻이 아니다. 모든 v1 기능은 여전히 출시 필수다. 초기 Epic은 미래 기능의 stub/가짜 성공/빈 구현에 의존하지 않고 현재 제공하는 기능을 실제로 완결한다. FR 전체 완료는 위 책임 Epic에서 판단한다.

### Epic 1: Provider를 연결하고 논문을 읽고 정리해 다시 찾기

사용자는 실제 Provider 연결을 완료하고 네 입력으로 Paper를 가져와 PDF를 읽으며, Highlight/Note와 읽기 위치를 남기고 Library에서 정리·재방문·삭제할 수 있다.

**FRs covered (완료 책임):** FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, FR-009, FR-010, FR-026, FR-027, FR-028.

- **사용자 결과:** Onboarding→Import→PDF→개인 기록→Library 재방문/삭제의 실제 로컬 읽기 루프. 두 Provider 경로 모두 실제 연결 성공·실패·교체를 검증한다. Provider 없는 제한 모드는 아니다.
- **함께 구현할 교차 범위:** FR-007/008/011/029~034 중 현재 Paper/PDF/parsing/Highlight/Note/Library 데이터에 적용되는 부분. 단일 persistence·fenced Job·writer/publication permit·삭제 saga·Agent purge·restart recovery는 첫 durable 기능부터 작동한다. parsing canonical revision과 Evidence geometry 계약을 여기서 제공하여 Epic 2가 새 파서/저장 경로를 만들지 않게 한다.
- **Epic 1 완료 조건:** 실제 Import/parsing·Provider 관련 Job은 실패 이유와 명시 Retry, 재실행 후 interrupted/failed 상태와 기존 usable 결과를 복원한다. 삭제 확인 후 해당 Paper의 PDF·추출/FTS·Highlight·Note·상태·읽기 위치·현재 생성된 파생 데이터와 Agent의 Paper-linked 임시 상태가 보이지 않아야 한다. 진행/실패 중 row는 열리지 않고 `삭제 미완료`/동일 saga의 Retry Deletion을 제공한다. 재실행·동시 write/publication·늦은 Provider 결과 후에도 부활하지 않고, 아직 없는 Translation/Chat/Brief를 성공처럼 표시하지 않는다.
- **식별 정보 책임:** FR-027 한 줄 요약은 미래 Brief 결과를 기다리지 않는다. metadata/summary 생성·저장과 loading/failure 상태를 이 Epic 범위에서 설계하고 필요한 Provider operation은 P-3 공통 계약에 포함한다. 생성 방식·fallback을 이 문서에서 임의 확정하지 않는다.
- **선행 Epic:** 없음. P-1/P-2/P-3 및 timing 부분의 P-6는 아래 표의 해당 작업 경계에서 별도로 충족해야 한다.
- **구현 경계:** greenfield native 앱과 필요한 최소 schema부터 사용자 흐름 순서로 확장한다. 모든 미래 테이블을 미리 만드는 database Epic은 두지 않는다. 기본 Native Canvas/System과 semantic token 사용·접근성은 초기 화면부터 적용하되 세 테마 기능의 완료 책임은 Epic 4다.
- **비목표:** Translation/Chat/Brief를 완성했다고 표시하지 않는다. 이들의 fake 성공 상태나 후속 Epic 구현을 Epic 1 완료 조건으로 요구하지 않는다.
- **주요 위험:** R-001/003~008, 실제 packaged Provider/PDFium 실행, Import validation, 삭제·publication 경합. 단순 UI 목업으로 완료할 수 없다.

### Epic 2: 번역을 대조하고 논문 전체 근거로 질문하기

사용자는 원문과 문장별 번역을 대조하고, Paper 전체 근거로 질문하며, 답변의 원문 문장으로 돌아가고 저장된 대화를 다시 열 수 있다.

**FRs covered (완료 책임):** FR-012, FR-013, FR-014, FR-015, FR-016, FR-017, FR-018, FR-019.

- **사용자 결과:** PDF와 equal-split Translation, 페이지별 진행/캐시/Retry, 양방향 hover/focus, 근거 부족을 구분하는 Chat와 다중 Session.
- **선행 Epic:** Epic 1의 Provider, canonical extraction, persistence/Job, Reader, Library 및 삭제 경계. Brief/Template이나 추가 테마가 없어도 번역·질문·재방문은 완결된다.
- **교차 범위:** FR-007/008/011/029~034를 Translation/Chat/Session에 확장한다. parsing 실패 AI 비활성 및 성공 후 Translation 전환, Session 자동 저장·restart, Provider 교체·삭제 중 결과 차단을 포함한다. 삭제 지원을 Epic 3로 미루지 않는다.
- **Epic 2 완료 조건:** Translation page/cache·Chat 결과/Session과 그 Job의 진행·실패·Retry·restart 복원을 실제로 검증한다. Paper 삭제는 Epic 1의 saga를 통해 새 데이터와 Agent purge를 함께 제거하며, 취소·실패·늦은 답변/번역 publish·재실행 경합에도 재진입/부활이 없고 Template/Brief의 미래 구현을 기다리지 않는다. Chat Session 자체의 rename/delete 취소·확정·복원도 독립 검증한다.
- **구현 경계:** Application-owned 공통 EvidenceBundle/Anchor와 두 Provider의 동일 의미를 사용한다. Translation과 Chat이 공유하는 sentence identity, Reader right-panel, Job·evidence 정책을 한 Epic으로 묶어 중복 구현을 피한다.
- **비목표:** Reader page/selection 주입, 일반 Chat 모드, 무제한 history, 추정 Anchor 성공, 완전 정확도 보장.
- **주요 위험:** R-001/002/009, version·정렬 불일치, stale revision, 근거 없는 주장, ambiguous external Retry. P-3 수치/allowlist 및 shared geometry tolerance를 각 구현 분기 전에 고정한다.

### Epic 3: 근거 있는 Brief와 재사용 Template으로 연구 기록 남기기

사용자는 자동 생성된 Markdown Brief를 Reader Drawer와 독립 화면에서 읽고, 자신의 Template을 편집해 명시적으로 재생성하며, 실패해도 기존 결과를 보존할 수 있다.

**FRs covered (완료 책임):** FR-007, FR-008, FR-011, FR-020, FR-021, FR-022, FR-023, FR-024, FR-025, FR-029, FR-030, FR-031, FR-032, FR-033, FR-034.

- **사용자 결과:** 기본 일곱 섹션과 근거 확인, 독립 reusable Template, originating Brief 복귀, snapshot 기반 재생성, 전체 연구 기록의 재방문·삭제.
- **선행 Epic:** Epic 1의 저장/Reader/Library/삭제와 Epic 2의 공통 evidence/clickback·AI 처리 계약. Theme switching/public packaging은 선행 조건이 아니다.
- **교차 범위 완료:** 기존 FR-007/008/011/029~034에 Brief/snapshot을 연결해 모든 v1 데이터·Job 유형을 대상으로 상태 분리, parsing 복구, Library 기록, 삭제·restart 시나리오를 완결한다. 새 Paper 추가에서 자동 Brief가 시작되는 통합 동작도 여기서 검증한다. 이는 Epic 1/2의 삭제·복구 통과를 연기하는 것이 아니라 신규 Brief/snapshot과 전체 유형의 통합 회귀다.
- **Epic 3 완료 조건:** 자동/명시 재생성 Brief·snapshot Job의 실패, 이전 usable Brief 보존, interrupted 재실행, 역순 완료·삭제 경합을 검증한다. Paper 삭제 후 PDF/추출/번역/Session/Brief/snapshot/기록 모두 비가시적이고 독립 Template/version은 재실행 후에도 남는다. Agent purge 실패는 삭제 미완료이며 동일 saga 재시도로만 완료한다.
- **구현 경계:** immutable Template version과 Paper-owned snapshot, current fenced regeneration만 승리하는 pointer, 실패/out-of-order 완료 시 prior Brief 유지, Paper 삭제 후 Template 보존을 한 사용자 기능 안에서 구현한다.
- **비목표:** Template 선택/저장만으로 자동 재생성, live Template로 이전 provenance 변경, Note를 evidence로 위장, 과거 Paper의 일괄 자동 재생성이라는 새 기능 추가.
- **주요 위험:** R-001/002/007, snapshot/provenance race, 생성 결과 역순 완료, 삭제 cascade의 Template 침범. P-3 Brief operation 계약을 준수한다.

### Epic 4: 읽기 맥락을 유지하며 테마와 명암 선택하기

사용자는 세 테마와 System/Light/Dark를 독립적으로 선택하고 앱을 다시 열어도 유지하며, 어떤 조합에서도 동일한 읽기·근거·오류 복구 동작을 사용할 수 있다.

**FRs covered (완료 책임):** FR-037, FR-038, FR-039.

- **사용자 결과:** Native Canvas 기본, Scholarly Press/Focused Instrument 선택, System 기본 및 OS 반영/명시 override, 전 화면 일관성.
- **선행 Epic:** Epic 1~3의 실제 화면/데이터/Job이 있어야 전환 불변성과 여섯 조합의 전체 동작 검증을 완료할 수 있다. 초기 semantic tokens/native 기본 스타일 도입까지 이 Epic 완료 뒤로 미루지 않는다.
- **구현 경계:** 기존 Application/persistence의 Paper-independent 설정을 사용한다. theme 변경은 appearance를, appearance 변경은 theme을 덮어쓰지 않는다. Paper 삭제 후 설정 유지와 native text scaling/VoiceOver/대비를 검증한다.
- **비목표:** 원본 PDF restyle, AI 새 요청/Retry, 기능별 새 durable owner, theme editor/marketplace.
- **주요 위험:** R-009, OS appearance 관찰과 저장 실패, 화면별 대비/상태 의미 불일치. HTML 검사가 아니라 실제 화면/전환 증거가 필요하다.

### Epic 5: 두 Mac 아키텍처에서 설치하고 전체 연구 흐름 사용하기

사용자는 macOS 15+ arm64 또는 x86_64 공개 산출물을 설치·실행하고 Provider를 연결해 전체 v1 흐름을 사용할 수 있으며 수동 앱 교체 후에도 지원되는 데이터 경계를 따른다.

**FRs covered (완료 책임):** FR-035, FR-036.

- **사용자 결과:** self-contained Developer ID 배포, 실행/Provider 안내, AGPL-3.0-only 및 source/notices, 검증된 전체 연구 루프.
- **선행 Epic:** Epic 1~4. P-1/P-2의 초기 signed prototype/lock 증거를 재사용하되 실제 최종 산출물에서 재검증한다. signing·CI 설계를 처음 시작하는 기술 계층 Epic이 아니다.
- **구현 경계:** 동일 source/locks/contracts/migrations/entitlements/smoke 기준의 두 artifacts, nested inventory/sign/notary/staple/Gatekeeper, 지원 OS matrix, local diagnostics 정책, schema upgrade/downgrade/corruption 경계, UJ-1~4 및 SM-001~007/CM-001~003 검증.
- **게이트:** public release plan 전 P-4, schema-bearing public release 전 P-5, timing/release readiness 전 P-6. P-1/P-2/P-3도 적용 범위의 통과 증거가 있어야 하며 Epic 5에서 처음 처리하도록 늦추지 않는다.
- **비목표:** App Store, updater, telemetry, cloud 복구, 후속 기능의 v1 약속. 계획 승인이 실제 Push/PR/공개 배포 실행 승인은 아니다.
- **주요 위험:** R-006~009, 두 CPU/OS의 runtime 차이, nested code와 SDK purge, migration 실패, material/repeated timing 초과의 미해결 disposition.

### 의존성 및 조기 게이트 배치

기본 사용자 가치 순서는 **Epic 1 → Epic 2 → Epic 3 → Epic 4 → Epic 5**다. 각 Epic은 앞선 실제 기능을 재사용하고 뒤 Epic의 구현을 요구하지 않는다. P 작업은 제품 Epic 대신 별도 기술 계층 Epic으로 만들지 않고, 후속 Story 분해에서 독립 검증 work unit과 소비 Story의 명시적 의존성으로 연결한다. 이 표는 검증 작업의 배치이지 prototype 수행/게이트 통과 기록이 아니다.

| Gate | 최초 소비 지점 | 후속 적용 및 분해 원칙 |
|---|---|---|
| P-1 | Epic 1의 제품 Provider Agent/PDFium 및 packaging Build Spec 전 | 별도 승인된 **게이트 검증용** 최소 signed/notarized topology prototype으로 두 CPU의 Main App + no-network XPC + 분리 Agent, negative-access, nested inventory, Gatekeeper와 성공/실패/restart/replacement/Paper 삭제 후 marker purge를 실증한다. 이 증거를 제품 Agent/PDFium 구현 완료로 계산하지 않는다. |
| P-2 | Epic 1의 제품 helper/CI/persistence 분기 전 | 별도 승인된 게이트 검증 범위에서 정확 SDK/runtime/CLI/PDFium/Xcode·SDK locks와 최소 macOS 15·현재 지원 OS × 두 CPU matrix를 만들고 **packaged** DB open/forward migration·FTS5 create/query/delete와 Agent marker purge를 각 지점에서 실증한다. 빈 mock DB/가상 Agent의 통과로 치환하지 않는다. |
| P-3 | Epic 1 Provider/Import/PDFium Build Spec 전 | 최초 공통 allowlists/ceilings에 Epic 2 Chat/Translation과 Epic 3 Brief operation까지 포함한다. 기능 구현은 나중이어도 계약을 adapter별로 따로 정하지 않는다. |
| P-4 | public release plan 수립 전 | Epic 5 본문은 사용자 결과 후보이며 실제 release plan은 P-4 미결정 상태에서 확정하지 않는다. 모든 초기 기능에도 기존 safe diagnostic 제약은 즉시 적용한다. |
| P-5 | schema-bearing public release 전 | 초기부터 ordered transactional migration을 유지하되 rollback/corruption 지원 정책·증거를 공개 전 확정한다. 전체 Epic 1을 일괄 차단하는 새 조건으로 과장하지 않는다. |
| P-6 | Epic 1 Import/Reader timing Build Spec 분기 전 | 하나의 probe/completion과 fixture/profile/초과 disposition 결정. Epic 5는 실제 end-to-end timing/release evidence를 확인한다. |

**P-1/P-2 순환 의존성 차단:** 게이트 검증 work unit은 목적을 실제 실행·isolation·runtime matrix 입증으로 제한하고, 그 목적에 필요한 최소 Main App/helper/Agent/DB migration/FTS wiring과 signed package만 허용한다. Story별 governing Issue·task branch·Build Spec과 해당 커밋 SHA의 별도 IMPLEMENTATION 승인을 받아야 한다. 검증용 wiring이 실제 코드를 포함해도 제품 기능의 Build Spec, 본격 구현, Provider 연결 성공/삭제/배포 완료를 선승인하거나 게이트 통과로 자동 판정하지 않는다. P-1과 P-2는 증거를 공유할 수 있으나 각 행의 모든 criteria를 독립적으로 통과 판정한다. 증거가 없으면 downstream Build Spec은 계속 차단된다. Prototype 구현에서 제품 scope/architecture가 실질적으로 바뀌면 문서 개정·재승인 전 멈춘다. 각 Epic의 제품 Story는 위 완료 조건에 따라 그 시점의 데이터를 실제로 지우고 복구해야 한다.

**Epic 1 P-1/P-2의 승인된 Intel 실행 경로:** Story 1.1~1.6부터 arm64는 현재 Mac에서, x86_64 빌드·패키징 및 실행 가능한 자동 검증은 GitHub Actions의 적합한 Intel macOS runner에서 수행한다. 각 Build Spec에서 실제 runner 가용성, 고정 Xcode/SDK·runtime·locks, signing/notary secrets와 명시적 원격 실행 지시를 확인한다. hosted runner가 조건을 충족하지 못하면 Intel self-hosted runner 또는 별도 Intel Mac을 사용하며 환경이 없으면 downstream 제품 Build Spec을 계속 차단한다. 실제 Intel 실행·negative access·Agent marker purge·packaged DB/FTS·최소 macOS 15 및 현재 지원 OS matrix·clean-machine Gatekeeper 중 CI로 입증할 수 없는 조건은 별도 Intel 환경에서 검증한다. 빌드 성공·Apple Silicon cross-build·부분 matrix로 전체 게이트를 통과시키지 않는다. Epic 5 최종 후보에도 동일 실행 경계를 적용하며 현재 계획 단계에서 workflow 생성·push·원격 실행은 하지 않는다.

### 교차 요구사항 책임

| 요구사항 | Epic 적용/완료 책임 |
|---|---|
| NFR-001~004 / AR-019 | Epic 1 PDF-first와 P-6 timing, Epic 5 공개 산출물의 측정·disposition |
| NFR-005~006 / AR-006~007/013~015 | Epic 2 번역/Chat evidence, Epic 3 Brief evidence, Epic 5 end-to-end 확인 |
| NFR-007~008 / AR-010~012/016~018/021 | Epic 1부터 데이터·복구·삭제, Epic 2~3 신규 데이터별 연동, Epic 5 release 회귀 |
| NFR-009~010 / AR-003~005/008~009/022 | Epic 1 Provider·secret·purge, Epic 2~3 모든 외부 operation에 같은 통제, Epic 5 packaged 증거 |
| AR-001~002/023~024 | Epic 1의 구조·최소 runtime부터 모든 Epic의 소유권·명칭·범위 제약 |
| AR-014 | Epic 1 canonical coordinate/identity·shared tolerance, Epic 2 Anchor preview/clickback, Epic 3 Brief 재사용 |
| AR-020/025 | Epic 1 P-1/P-2로 조기 실증, Epic 5 최종 설치·배포·license 완료 |
| AR-026 | Epic 4 기존 Application/persistence에 설정 통합 |
| UX-DR1~2/4~14/21~22/26/29/34 | Epic 1 관련 surface를 완결, AI 관련 확장은 Epic 2~3; Session DeleteAlert는 Epic 2 |
| UX-DR3/15~18/25 | Epic 2 Translation/Chat/Session/evidence; Brief Anchor는 Epic 3 |
| UX-DR19~20/23~24 | Epic 3 Brief/Template |
| UX-DR27~28/30 | Epic 1 Native 기본·semantic token, Epic 4 전체 테마/명암 |
| UX-DR31~33/35~36/38 | 각 Epic의 화면/기능에서 접근성·복구·copy·세부 결정을 함께 완료하며 Epic 5로 미루지 않음 |
| UX-DR37 / SM-001~007 / CM-001~003 | 각 관련 Epic에서 시나리오 누적, Epic 5에서 실제 두 산출물의 전체 출시 판정 |

### 파일 중복 및 Story 분해 가드레일

- 아직 제품 소스 파일이 없으므로 특정 파일 변경 횟수는 추정하지 않는다. 공유 경계는 Architecture의 Application, persistence, Reader, Provider contracts다.
- Import 상태·파일 접근·삭제를 별도 Epic으로 나누지 않고 Epic 1의 Paper lifecycle 안에 둔다. Translation/Chat은 shared extraction/evidence/right-panel을 Epic 2에서 함께 다룬다. Brief/Template은 snapshot과 immutable provenance를 Epic 3 안에서 함께 다룬다.
- 공통 경계 재사용은 허용하되 기능마다 새 Job runner/store/Anchor를 만들지 않는다. schema는 해당 기능 Story에서 필요한 만큼 추가한다.
- Story는 한 개발 에이전트가 다룰 수 있는 크기로 나누고 같은 Epic 안에서도 이미 완료된 Story에만 의존한다. 각 Story에 scope/non-goals, Given/When/Then, source IDs, gate/dependency, 위험·검증, 별도 구현 승인 경계를 기록한다.
- 승인된 Story는 아래 Epic별 Story 섹션에 순서대로 추가한다. 초안은 사용자 확인 전 추가하지 않는다.

## Epic 1: Provider를 연결하고 논문을 읽고 정리해 다시 찾기

사용자는 실제 Provider 연결을 완료하고 네 입력으로 Paper를 가져와 PDF를 읽으며, Highlight/Note와 읽기 위치를 남기고 Library에서 정리·재방문·삭제할 수 있다. 다음 검증용 Story는 제품 기능 완료와 구분한다.

### Story 1.1: 두 CPU에서 격리된 앱 실행 구조 입증

As a macOS 논문 독자,
I want 두 CPU용 설치 산출물에서 Main App·PDFium XPC·Provider Agent의 격리 구조가 실제로 실행되는 근거를 확인하고,
So that 이후 Provider 연결과 PDF 처리를 검증된 실행 경계 위에서 사용할 수 있다.

**Acceptance Criteria:**

**Given** 이 Story의 governing Issue·task branch·Build Spec이 준비되고 해당 Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인을 받았으며 두 CPU 검증 환경이 있을 때,
**When** 각각 최소 Main App, no-network PDFium XPC, 별도 identity의 Provider Agent를 패키징·서명·공증하여 실행하면,
**Then** 두 산출물에서 예상된 경계로 세 프로세스가 실행되고 nested-code inventory·서명·entitlement·공증·Gatekeeper 실행 결과가 기록된다.
**And** 이 결과를 제품 Provider 연결·PDF 추출·공개 배포 완료로 표시하지 않는다.

**Given** 두 CPU에서 XPC와 Agent가 실행 중일 때,
**When** 허용되지 않은 네트워크·파일·container/app-group 접근 및 native app에서 Agent zone으로의 광범위한 파일 접근을 시도하면,
**Then** 접근 거부와 실제 entitlement/identity 경계가 각 산출물에서 검증되고 실패 지점이 기록된다.

**Given** 서명·공증 자격 증명이나 두 CPU 환경 등 필수 증거가 부족하거나 어떤 negative-access 검사가 실패했을 때,
**When** 이 Story의 결과를 기록하면,
**Then** 성공으로 추정하지 않고 미검증/실패 항목과 재검증 필요 조건을 명시하며 P-1을 통과로 표시하지 않는다.

**범위:** P-1의 최소 실행 topology, 두 CPU signing/notarization 및 sandbox/entitlement negative access와 nested-code/Gatekeeper 증거. 검증용 prototype은 별도 승인된 Build Spec에만 따른다.

**비목표/후속 의존성:** 실제 Provider 제품 연결, PDF 추출, Paper 삭제 완료가 아니다. Agent marker-content의 성공·실패·재시작·교체·Paper 삭제 후 purge 검증과 P-2 dependency lock/OS matrix는 아직 미검증이다. Story 1.1만으로 P-1 또는 P-2 게이트를 통과시키지 않는다.

**추적/위험:** AD-2/4/7/13, P-1의 topology·isolation 일부, AR-002~005/020, FR-002/005/035의 선행 검증; R-005/007. Story 구현 승인, gate 판정, public release 승인은 별개다.

### Story 1.2: Provider Agent 작업 종료·재시작 정리 검증

As a macOS 논문 독자,
I want Provider 작업이 끝나거나 앱을 다시 실행해도 Agent 영역에 Paper 내용이 남지 않는다는 검증 근거를 확인하고,
So that 이후 근거 기반 기능을 Agent의 승인된 저장 경계 안에서 사용할 수 있다.

**Acceptance Criteria:**

**Given** Story 1.1의 패키징·격리 구조와 별도 승인된 이 Story의 governing Issue·task branch·Build Spec, 해당 커밋 SHA의 명시적 IMPLEMENTATION 승인 및 패키징된 공식 Codex SDK Agent와 Paper UUID·generation·correlation으로 식별된 시험 작업이 있을 때,
**When** 실제 Provider 요청이 성공하거나 실패하면,
**Then** 양쪽 경로에서 Paper-linked 임시 내용이 terminal 후 정리되고 Agent에는 허용된 auth/config/package metadata만 남았음이 marker 검사로 확인된다.
**And** 시험 요청의 내용이나 비밀정보가 durable Agent zone·진단에 남지 않는다.

**Given** 시험 작업이 취소되거나 Agent가 종료 시 정리를 끝내지 못했을 때,
**When** Agent를 재시작하면,
**Then** 남은 attempt-scoped 내용을 멱등적으로 정리하고 그 결과를 Agent 경계를 통해 확인한다.
**And** native app은 Agent 파일 영역을 직접 열어 정리하지 않는다.

**Given** 정리 실패나 어느 경로의 증거 누락이 있을 때,
**When** 검증 결과를 기록하면,
**Then** 실패·미확인 상태와 재검증 조건을 그대로 남기고 P-1 통과를 주장하지 않는다.
**And** marker 원문·문서 내용·요청/응답·비밀정보가 진단에 기록되지 않음을 확인한다.

**범위:** P-1 검증용 packaged Agent의 성공·실패·취소·재시작 후 Paper-linked marker absence/purge 및 안전한 정리 경계. Story 1.1만을 선행 Story로 소비하고 제품 Provider 작업의 완료를 주장하지 않는다.

**비목표/후속 의존성:** 앱 교체와 Paper 삭제 시 Agent purge 검증, 제품 Provider 연결 및 삭제 saga, P-2 정확 dependency lock/OS matrix와 P-3 제품 operation 계약은 별개다. Story 1.2만으로 P-1/P-2/P-3를 통과시키지 않는다.

**추적/위험:** AD-2/4/11, P-1의 Agent marker lifecycle 일부, AR-003~005/022, FR-002/030/031의 선행 검증; R-005/007. 별도 Build Spec의 구현 승인은 제품 기능 승인이나 gate 합격으로 전용하지 않는다.

### Story 1.3: 앱 교체·Paper 삭제 시 Agent 정리 검증

As a macOS 논문 독자,
I want 앱을 교체하거나 Paper를 삭제할 때 Agent에 남은 해당 Paper의 임시 내용이 정리됐다는 근거를 확인하고,
So that 오래된 작업이 삭제한 Paper의 상태를 다시 드러내지 않는다.

**Acceptance Criteria:**

**Given** Story 1.1의 두 CPU 실행 구조, Story 1.2의 attempt 식별·정리 경계, 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인과 두 CPU의 패키징된 Agent에 식별 가능한 Paper-linked 시험 marker가 있을 때,
**When** 앱을 교체하고 Agent를 실행하면,
**Then** startup 정리 후 해당 marker의 부재를 검사하고 CPU별 결과를 기록한다.

**Given** Paper UUID·generation·correlation에 연결된 실행 중이거나 남아 있는 시험 작업이 있을 때,
**When** 검증용 Paper 삭제 명령으로 취소와 Agent purge를 요청하면,
**Then** Agent 경계를 통해 purge 확인·검증을 받고 해당 Paper-linked marker의 부재를 확인한다.
**And** 늦게 끝난 작업이 이를 다시 남기거나 성공으로 보고되지 않는다.

**Given** purge가 실패하거나 확인되지 않았을 때,
**When** 같은 요청을 재시도하면,
**Then** 멱등적으로 정리되거나 실패 상태가 유지되며 확인 전에는 삭제 완료 또는 P-1 통과로 기록하지 않는다.

**Given** Story 1.1~1.3의 증거가 모였을 때,
**When** P-1 기준을 판정하면,
**Then** 두 CPU 각각의 topology·negative access·서명/공증/Gatekeeper 및 Provider 성공·실패·재시작·교체·Paper 삭제 후 marker 검사를 항목별로 대조한다.
**And** 하나라도 증거가 누락되거나 실패하면 P-1은 미통과로 남는다.

**범위:** P-1 검증용 앱 교체와 Paper 삭제 신호 후 Agent marker purge 및 Story 1.1~1.3의 두 CPU 증거 대조. 해당 prototype은 별도 승인된 Build Spec 범위를 넘지 않는다.

**비목표/후속 의존성:** 검증용 Paper 삭제 신호는 제품의 전체 삭제 saga·DB cascade·Reader UI 완료가 아니다. P-2의 exact locks·OS matrix는 별도 검증이며 이 Story의 통과로 추론하지 않는다.

**추적/위험:** AD-2/11/13, P-1의 교체·삭제 marker lifecycle 및 종합 판정, AR-003~005/018/020, FR-030/031/035의 선행 검증; R-005/007. 평가 항목별 증거만 gate 판정의 근거가 된다.

### Story 1.4: P-2 의존성 잠금과 실행 OS 매트릭스 확정

As a macOS 논문 독자,
I want 지원하는 CPU·OS별 산출물이 어떤 도구와 의존성으로 만들어졌는지 확인하고,
So that 실행 환경 차이 때문에 논문 데이터나 Provider 동작이 달라지는 위험을 검증할 수 있다.

**Acceptance Criteria:**

**Given** Story 1.1~1.3의 검증용 실행 구조, 이 Story의 별도 governing Issue·task branch·Build Spec과 해당 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인 및 공식 의존성 후보가 있을 때,
**When** 두 CPU 검증용 산출물의 빌드 입력을 확정하면,
**Then** 정확한 Xcode/SDK, Python SDK·runtime·CLI, PDFium 및 하위 의존성의 버전·출처·hash와 두 산출물의 공통 lock을 기록한다.
**And** Codex compatibility target만을 확정된 SDK/CLI 조합으로 표시하지 않는다.

**Given** macOS 15 최소 지원 빌드와 현재 지원 빌드가 있을 때,
**When** 검증 매트릭스를 확정하면,
**Then** 각 OS 빌드 × arm64/x86_64의 실행 지점과 SQLite/FTS5 provenance, 실행·증거 수집 방법을 명시한다.
**And** 검증하지 못한 지점을 성공으로 표시하지 않는다.

**Given** version/hash 충돌이나 지원 지점의 실행 불가가 발견될 때,
**When** 결과를 기록하면,
**Then** 원인과 재검증 조건을 남기고 P-2와 downstream 제품 helper·CI·persistence·packaging Build Spec을 계속 차단한다.

**범위:** P-2 검증용 exact dependency/toolchain lock, provenance와 최소 macOS 15 및 현재 지원 OS × 두 CPU의 실행 매트릭스 확정. Story 1.1~1.3만 선행하고 두 산출물의 동일 기준을 요구한다.

**비목표/후속 의존성:** DB migration·FTS5·packaged Agent purge의 매트릭스별 실행 검증은 후속 Story다. 이 Story의 잠금/문서화만으로 P-2를 통과시키거나 제품 Provider/Import를 구현한 것으로 간주하지 않는다.

**추적/위험:** AD-2/6/13, P-2의 exact lock·runtime matrix 정의, AR-002/010/020/025, FR-035의 선행 검증; R-005/006/007. 서명·공증 자격 증명을 bundle/진단에 포함하지 않는다.

### Story 1.5: 패키징된 DB·FTS5 매트릭스 검증

As a macOS 논문 독자,
I want 지원 OS와 두 CPU의 실제 앱 산출물에서 로컬 데이터베이스와 논문 검색 기반이 동작하는 근거를 확인하고,
So that 이후 Library·근거 검색이 특정 실행 환경에서만 작동하는 일을 피할 수 있다.

**Acceptance Criteria:**

**Given** Story 1.4의 lock·OS×CPU 매트릭스, 별도 governing Issue·task branch·Build Spec과 해당 커밋 SHA의 명시적 IMPLEMENTATION 승인, 각 지점의 패키징된 검증용 앱이 있을 때,
**When** 앱의 GRDB 경계로 로컬 DB를 처음 열고 최소 ordered migration을 적용하면,
**Then** 각 지점의 DB 열기·schema version·migration 결과와 Xcode/SDK·system SQLite 출처를 기록한다.
**And** mock DB나 개발 호스트 단독 실행으로 대신하지 않는다.

**Given** migration이 적용된 패키징 앱이 있을 때,
**When** FTS5 table을 만들고 시험 문장을 넣어 검색한 뒤 삭제하면,
**Then** 각 OS×CPU 지점에서 create/query/delete 결과와 FTS5 capability를 확인한다.

**Given** migration 실패 또는 FTS5 미지원·실패가 있을 때,
**When** 다시 앱을 열면,
**Then** 불완전한 migration을 성공으로 기록하거나 cache에서 durable 데이터를 재구성하지 않고 fail-closed 결과를 남긴다.
**And** 해당 지점과 P-2를 통과로 표시하지 않는다.

**범위:** P-2 검증용 실제 패키징 앱의 GRDB DB open/최소 ordered migration과 FTS5 create/query/delete의 OS×CPU별 실행 증거. 제품 persistence 단위 분기 전에 필요한 검증 범위에 국한한다.

**비목표/후속 의존성:** 전체 제품 schema·Library 기능 구현과 P-5의 downgrade/corruption 지원 정책 결정은 별개다. 매트릭스의 packaged Agent marker purge는 후속 Story에서 검증하며 이 Story만으로 P-2는 통과하지 않는다.

**추적/위험:** AD-6/13, P-2의 DB·FTS5 matrix 부분, AR-010/020, FR-026/035의 선행 검증; R-006/007. 실제 앱에서의 증거는 후속 제품 구현·공개 산출물의 검증을 대신하지 않는다.

### Story 1.6: 패키징된 Agent 정리를 OS×CPU 매트릭스에서 검증

As a macOS 논문 독자,
I want Provider Agent의 Paper 임시 내용 정리가 지원하는 모든 OS·CPU 조합에서 동일하게 작동한다는 근거를 확인하고,
So that 특정 실행 환경에서만 Paper-linked 내용이 남는 위험을 판별할 수 있다.

**Acceptance Criteria:**

**Given** Story 1.2~1.3의 marker 검사, Story 1.4의 lock·매트릭스, Story 1.5의 패키징 앱 검증 경계와 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인이 있을 때,
**When** 확정된 lock으로 만든 각 OS×CPU 지점의 패키징 앱에서 Provider 요청 성공·실패·재시작·앱 교체·Paper 삭제 신호에 기존 marker 검사를 각각 실행하면,
**Then** 각 지점·사건별로 Agent 영역의 Paper-linked 내용 부재와 purge 확인 결과를 기록한다.
**And** 개발 호스트의 결과를 다른 지점의 증거로 복사하지 않는다.

**Given** 한 지점에서 purge 실패·marker 잔존·서명된 Agent 실행 실패가 발생했을 때,
**When** 매트릭스를 판정하면,
**Then** 그 지점을 실패/미검증으로 남기고 P-2를 통과시키지 않는다.

**Given** Story 1.4~1.6의 증거가 모두 있을 때,
**When** P-2를 판정하면,
**Then** 정확한 도구·의존성/hash, 전체 OS×CPU 지점의 패키징 DB open/migration, FTS5 create/query/delete, Agent의 다섯 정리 사건을 대조한다.
**And** 하나라도 빠지거나 lock이 달라지면 helper·CI·persistence·public packaging의 제품 Build Spec 차단을 유지한다.

**범위:** P-2의 확정 lock을 사용한 packaged Agent marker purge의 OS×CPU별 실행 증거 및 P-2 항목별 판정. Story 1.4/1.5와 기존 1.2/1.3 검증 fixture를 재사용하며 매트릭스 증거를 독립적으로 기록한다.

**비목표/후속 의존성:** 제품 Provider 연결·실제 Paper 삭제 완료·공개 출시 판정은 별개다. 게이트 검증용 삭제 신호를 사용자 삭제 기능으로 표시하지 않는다. P-1과 P-2는 서로 다른 기준으로 각각 판정하며 한 gate의 판정이 다른 gate를 대신하지 않는다.

**추적/위험:** AD-2/6/13, P-2 전체 판정, AR-003~005/010/020, FR-002/030/035의 선행 검증; R-005/006/007. 미확인 매트릭스 지점은 통과로 해석하지 않는다.

### Story 1.7: 공통 요청 허용 범위와 자원 한도 확정

As a 논문 독자,
I want 가져오기와 AI 요청이 허용된 입력·근거만 사용하고 크기 한도를 일관되게 지키며,
So that Provider나 입력 경로에 따라 다른 데이터가 전송되거나 과도한 작업이 실행되지 않는다.

**Acceptance Criteria:**

**Given** Story 1.1~1.6의 검증 경계, 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인 및 Import·PDF 파싱·Provider 연결 테스트·Translation·Paper Chat·Brief의 입력/출력 경계가 있을 때,
**When** P-3 계약을 확정하면,
**Then** operation별 버전·허용 field/source와 numeric item·byte·token·message·stream·Import·parser ceiling을 Application·Provider·Import/PDF가 공유하는 하나의 계약에 명시한다.
**And** Library 한 줄 요약에 별도 AI operation이 필요하다고 결정되면 구현 분기 전에 그 operation도 포함한다.

**Given** 허용 범위 밖의 raw PDF/path/DB·FTS row/URL credential/Reader page·selection·highlight/임의 Note·Template/무제한 history나 한도 초과 입력이 있을 때,
**When** 계약 검증 사례에 적용하면,
**Then** 전송·실행 전에 거부하거나 typed contract error로 반환한다.
**And** Provider adapter가 EvidenceBundle을 임의로 자르거나 재정렬해 성공으로 처리하지 않는다.

**Given** 한 Provider 또는 Import/PDF 구현에 다른 한도가 필요할 때,
**When** 계약을 검토하면,
**Then** adapter-local 예외 대신 Application 소유의 공통 budget/재구성 규칙을 정하고 적용할 소비 Story를 명시한다.
**And** 수치·허용 범위가 미결정이면 P-3을 통과시키지 않는다.

**범위:** P-3의 versioned operation field/source allowlists, numeric item/byte/token/message/stream/import/parser ceilings 및 공통 budget policy를 제품 Provider/Import/PDFium과 후속 Chat·Translation·Brief 구현 분기 전에 고정한다.

**비목표/후속 의존성:** Chat·Translation·Brief·Import 제품 구현은 별개다. 이 계약만으로 P-1/P-2 검증이나 해당 제품 기능의 별도 IMPLEMENTATION 승인을 대신하지 않는다.

**추적/위험:** AD-2/3/7, P-3, AR-004/006/007/012/013, FR-005/012/016/020/027의 선행 계약; R-001/002/005/007. 두 Provider에서 공통 근거·한도 의미를 유지한다.

### Story 1.8: PDF가 실제로 응답하는 시점의 측정 계약 확정

As a 논문 독자,
I want “PDF를 빨리 열 수 있다”는 판단이 단순히 창이 열린 시점이 아니라 실제 페이지 탐색·확대 응답에 근거하고,
So that 첫 페이지의 사용 가능 시간을 같은 조건으로 비교할 수 있다.

**Acceptance Criteria:**

**Given** Story 1.1의 두 CPU 실행 구조, 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인, PDFKit 검증용 Reader와 arXiv abstract URL·arXiv PDF URL·일반 PDF URL·로컬 PDF 시험 입력이 있을 때,
**When** 첫 페이지 표시 직후 자동 readiness 검사를 시작하면,
**Then** navigation 또는 zoom 중 정확히 하나를 모든 입력·두 CPU에 공통인 probe로 정하고 사용자 입력 없이 main thread에서 예상된 PDF 화면 갱신이 끝나는 완료 신호를 정의·검증한다.
**And** document open·control enable·첫 수동 조작을 완료 신호로 대체하지 않는다.

**Given** source·OS·CPU별 시험 환경이 있을 때,
**When** 측정 기준을 기록하면,
**Then** `ImportAcceptedAt`과 `FirstInteractivePageAt`의 경계, 일반 네트워크·접근 가능한 URL·텍스트 PDF fixture/profile, 일반 URL·로컬 PDF 기준, 반복/중대한 30초 초과의 review·disposition 방법을 고정한다.
**And** 사용자 생각 시간과 AI Job 시간은 측정 구간에서 제외한다.

**Given** 두 CPU나 입력 경로에서 probe의 의미가 달라지거나 완료 신호가 관찰되지 않을 때,
**When** P-6을 판정하면,
**Then** 차이와 미검증 지점을 기록하고 Import/Reader timing Build Spec과 release readiness의 차단을 유지한다.
**And** 30초 arXiv soft target의 단일 초과를 자동 출시 실패로 바꾸지 않는다.

**범위:** P-6 검증용 PDFKit readiness probe/completion signal과 named events, 네 입력 경로·두 CPU의 동일 의미, fixture/profile 및 초과 disposition의 확정. 제품 Import/Reader의 timing Build Spec 분기 전에 수행한다.

**비목표/후속 의존성:** 네 입력 경로의 제품 Import 구현, 실제 공개 산출물의 속도 목표 달성 주장이나 정적 시안 진행률을 증거로 사용하지 않는다. 검증 불충분이면 P-6은 미통과다.

**추적/위험:** AD-12, P-6, NFR-001~004, AR-019, FR-007/032, SM-001의 선행 검증; R-008. 사용자 think time·수동 조작을 측정치에 넣지 않는다.

### Story 1.9: Main App과 Provider Agent의 공통 통신 계약 확정

As a 논문 독자,
I want ChatGPT 연결·요청·취소가 앱과 Agent 사이에서 같은 의미로 처리되고,
So that 응답이 끊기거나 오래된 요청이 돌아와도 다른 작업의 성공으로 오인되지 않는다.

**Acceptance Criteria:**

**Given** P-1·P-2·P-3의 해당 증거/결정이 실제로 통과하고 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인을 받은 뒤 하나의 `Contracts/ProviderRPC`가 있을 때,
**When** Main App과 Agent가 연결하면,
**Then** 32-bit big-endian 길이 + UTF-8 JSON frame과 시작 시 major/minor handshake를 사용한다.
**And** major 불일치는 요청 전에 닫힌 실패로 처리하며 허용되지 않은 method·field·크기는 typed error를 반환한다.

**Given** 인증 또는 Paper-linked 작업이 시작됐을 때,
**When** 성공·실패·취소·timeout·프로세스 종료가 발생하면,
**Then** 재사용하지 않는 correlation ID에 정확히 하나의 terminal response를 연결한다.
**And** 취소와 Agent 정리 요청·확인은 같은 통신 경계를 따르며 오래된 응답을 새 작업의 성공으로 게시하지 않는다.

**Given** 잘못된 frame, 초과 message/stream, 예상 밖 stdout/stderr 또는 SDK 오류가 발생했을 때,
**When** 양쪽 계약 검증 사례를 실행하면,
**Then** protocol-only stdout과 allowlisted 환경·안전한 진단 정보만 허용하고 raw secret/요청/응답/문서 내용을 기록하지 않는다.

**범위:** 두 구현이 갈라지기 전 `Contracts/ProviderRPC`에서 정확한 method fields·numeric bounds·취소/정리 응답을 단일 계약과 양쪽 검증 사례로 고정한다. Story 1.1~1.7의 검증 경계를 소비한다.

**비목표/후속 의존성:** 실제 Onboarding UI, Provider 연결 성공 판정·slot 승격, Paper Chat 구현은 별개다. 통신 검사만으로 그 기능 완료나 P-1~P-3 통과를 주장하지 않는다.

**추적/위험:** AD-2/3/5, P-1~P-3의 소비 경계, AR-003~007/009, FR-001/002의 선행 계약; R-003/005. Agent가 filesystem이나 DB durable state owner가 되지 않는다.

### Story 1.10: OpenAI API key를 실제 요청으로 연결하기

As a 첫 실행 사용자,
I want OpenAI API key의 연결 성공 여부를 실제 AI 요청으로 확인하고 실패하면 기존에 작동하던 연결을 잃지 않으며,
So that 잘못된 연결이 성공으로 표시되거나 사용 가능한 연결을 교체하지 않는다.

**Acceptance Criteria:**

**Given** P-1·P-2·P-3의 실제 통과, Story 1.9의 공통 계약, 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인과 새 설치의 API key 입력이 있을 때,
**When** 연결 테스트를 실행하면,
**Then** staged key로 최소 실제 인증 v1 generation 요청을 보내 typed usable 응답이 온 경우에만 성공을 표시한다.
**And** identity/model 목록 조회만으로 성공 처리하지 않으며 실패 시 full-window 입력 화면에 머물러 redacted 이유·Retry를 보이고 앱 진입을 허용하지 않는다.

**Given** 이미 성공한 연결이 있고 사용자가 key를 교체할 때,
**When** 새 key의 테스트가 실패하거나 promotion 중 충돌하면,
**Then** 기존 active slot과 기능 가용성을 유지한다.
**And** 성공한 새 slot만 serialized CAS로 SQLite active selector/config generation에 게시하고 이전 slot은 commit과 진행 중 작업 종료 전 삭제하지 않는다.

**Given** key 저장·갱신 또는 앱 재실행이 발생할 때,
**When** private slot을 확인하면,
**Then** Keychain·별도 at-rest 암호화 없이 backup-excluded private 영역의 directory `0700`/file `0600`과 하위 항목 권한을 검증한다.
**And** 검증 실패는 연결 테스트·승격을 막고 stage를 제거하며 key를 SQLite·일반 설정·진단에 기록하지 않고 startup의 버려진 stage를 정리한다.

**범위:** native OpenAI API-key 경로의 private slot·실제 연결 테스트·last-good 승격·실패 복구 및 그 경로의 첫 실행 성공/실패 화면. Product의 Provider 선택 결과가 SQLite의 sole active selector와 일치해야 한다.

**비목표/후속 의존성:** 공식 Codex SDK ChatGPT/device-code 경로, 두 경로의 최종 동등 선택 UI와 Library 진입은 후속 Story다. 이 Story만으로 FR-001~004 전체 완료를 주장하지 않고 아직 없는 기능으로 우회하는 제한 모드도 만들지 않는다. 내부 accepted limit을 사용자-facing 고지·consent로 추가하지 않는다.

**추적/위험:** AD-1/4/5, P-1~P-3의 실제 통과 경계, AR-008/009/022, FR-001~004, NFR-009/010, UX-DR1/2 일부; R-003~005. 새 연결의 실패는 마지막 정상 연결을 손상하지 않는다.

### Story 1.11: 공식 Codex SDK의 ChatGPT 로그인 연결

As a 첫 실행 사용자,
I want API key 대신 공식 Codex SDK의 ChatGPT 로그인으로 Provider를 연결하고,
So that 연결 실패 시에도 이전에 작동하던 연결을 잃지 않는다.

**Acceptance Criteria:**

**Given** P-1~P-3의 실제 통과, Story 1.9의 ProviderRPC, Story 1.10의 active selector·승격 규칙과 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인이 있고 패키징된 공식 Python Codex SDK Agent의 ChatGPT 로그인 경로를 선택했을 때,
**When** 로그인을 완료하고 연결 테스트를 실행하면,
**Then** 최소 실제 인증 v1 generation 요청의 typed usable 응답이 온 경우에만 성공으로 표시한다.
**And** generic Codex OAuth·internal-only `chatgptAuthTokens`·설치된 시스템 Python/CLI 의존은 사용하지 않는다.

**Given** 로그인 취소·실패 또는 테스트 실패가 발생했을 때,
**When** 화면과 active 연결을 확인하면,
**Then** redacted 이유·Retry/경로 변경을 제공하고 실패한 staged slot을 승격하지 않는다.
**And** 마지막 성공 연결과 진행 중 작업의 config generation을 보존한다.

**Given** SDK가 Agent의 auth/config 데이터를 저장하거나 작업을 종료할 때,
**When** private zone을 검사하면,
**Then** Agent만 자기 zone을 소유하고 하위 항목까지 권한 `0700`/`0600`·backup exclusion을 확인한다.
**And** Paper-linked 임시 내용은 terminal/startup에 정리하고 purge 결과를 RPC로 전달하며 native app의 광범위한 Agent 파일 접근·raw 진단·콘텐츠 durable 보존은 없다.

**범위:** 공식 SDK ChatGPT 로그인 경로와 실제 연결 판정, private Agent zone 및 staged slot 승격·last-good 보존. Story 1.9의 단일 RPC 경계와 P-1/P-2 증거에 따른 패키징을 재사용한다.

**비목표/후속 의존성:** device-code 흐름과 두 Provider 경로의 최종 Onboarding/Settings 통합은 후속 Story다. 이 Story만으로 FR-002 전체 완료를 주장하거나 사용자-facing accepted-limit 고지·consent를 추가하지 않는다.

**추적/위험:** AD-2/4/5, AR-003~005/008/009/022, FR-001~004, NFR-009/010, UX-DR1/2 일부; R-003~005. 실패한 인증은 기존 연결을 교체하지 않는다.

### Story 1.12: ChatGPT device-code 연결 제공

As a 첫 실행 사용자,
I want 브라우저 로그인 대신 공식 Codex SDK의 device-code 흐름으로 ChatGPT 연결을 완료하고,
So that 코드 만료나 취소 후에도 안전하게 다시 시도할 수 있다.

**Acceptance Criteria:**

**Given** P-1~P-3의 실제 통과, Story 1.9의 RPC, Story 1.11의 공식 SDK Agent·slot 생명주기, 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인이 있고 사용자가 device-code 경로를 선택했을 때,
**When** SDK가 인증 코드와 확인 절차를 반환하면,
**Then** 앱은 해당 절차·대기 상태·취소 동작을 표시한다.
**And** 인증 완료 뒤 최소 실제 v1 generation 요청의 typed usable 응답이 온 경우에만 연결을 성공 처리한다.

**Given** 코드 만료·거절·네트워크 실패·사용자 취소가 발생했을 때,
**When** 대기 흐름이 종료되면,
**Then** 안전한 사유와 명시적 Retry/경로 변경을 보여준다.
**And** 실패한 staged slot은 승격하지 않고 마지막 성공 연결을 유지하며 중복·늦은 응답을 새 시도의 성공으로 간주하지 않는다.

**Given** Agent가 device-code 인증 상태를 기록할 때,
**When** 완료·취소·앱 재실행을 검사하면,
**Then** Story 1.11과 같은 Agent private-zone 권한·backup exclusion·startup stage 정리·진단 제한을 적용한다.
**And** generic OAuth·`chatgptAuthTokens`·외부 설치 Python/CLI로 우회하지 않는다.

**범위:** 공식 SDK device-code 대체 인증 경로, 대기/취소/만료/재시도 및 실제 연결 테스트. 기존 Agent RPC와 last-good 승격을 재사용한다.

**비목표/후속 의존성:** 두 Provider의 동등한 Onboarding 선택, Settings 재연결, 성공 후 명시적 Continue→Library는 실제 Library 진입이 가능한 후속 Story에서 완결한다. 이 Story에서 미구현 화면으로 이동시키지 않는다.

**추적/위험:** AD-2/4/5, AR-003~005/008/009, FR-001~004, UX-DR1 일부; R-003/005. 지원하지 않는 generic auth fallback을 추가하지 않는다.

### Story 1.13: Job 종류별 실패·재실행·Retry 계약 확정

As a 논문 독자,
I want 작업이 끊겨도 완료 결과를 잃지 않고 어떤 작업을 다시 실행해야 하는지 알 수 있으며,
So that 중단 후에도 안전하게 연구 흐름을 이어갈 수 있다.

**Acceptance Criteria:**

**Given** Import·parsing·Translation·Chat 준비/요청·Brief 및 한 줄 요약의 작업 종류가 정의됐을 때,
**When** 공통 복구 계약을 작성하면,
**Then** 각 종류의 입력 버전·dispatch 여부·완료 결과·중단 판정·Retry 조건·기존 결과 보존을 하나의 Application-owned 정책으로 고정한다.

**Given** 이전 프로세스의 `running` attempt가 저장돼 있을 때,
**When** 앱을 재실행하면,
**Then** `failed/interrupted`로 조정하고 이전 attempt/fence를 재개하거나 갱신하지 않는다.
**And** 정상 claim은 `pending`만 대상으로 한다.

**Given** 실패하거나 외부 전송 결과가 불명확한 작업이 있을 때,
**When** 사용자가 Retry하면,
**Then** 새 attempt/fence를 생성한다.
**And** 불명확한 외부 요청은 자동 재전송하지 않고 기존 usable 결과는 유지한다.

**Given** 삭제·입력 변경·Provider 변경 또는 늦은 결과가 경합할 때,
**When** 결과 publication을 시도하면,
**Then** 현재 attempt·fence·입력 버전·Provider config generation·Paper generation을 검증하며 stale 결과는 공개하지 않는다.

**범위:** Story 1.1~1.12의 prototype·Provider 계약과 실제 연결 경로를 기반으로 첫 제품 Import Job Build Spec 분기 전에 공통 정책을 고정한다. 현재 존재하는 Provider 작업과 계약 수준의 중단·Retry·stale publication·삭제 신호 검증 사례로 정책을 입증하며 미래 Paper 저장·Reader·annotation·Folder 구현을 선행으로 요구하지 않는다. filesystem writer/publication permit과 동기 정리 규칙을 포함한다. 후속 제품 데이터 Story는 이 정책을 적용하고 해당 실제 데이터의 실패·복구·삭제 경합을 각각 검증한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** 미래 AI 기능 구현·전체 schema 선생성은 하지 않는다. 미래 Job 종류의 계약을 고정하되 현재 기능의 완료가 미래 구현에 의존하지 않는다.

**추적/위험:** AD-6/10/11, FR-032~034, UX-DR6/35. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.14: 연결 후 Library에서 로컬 PDF 추가·삭제

As a 첫 실행 사용자,
I want Provider 연결을 확인한 뒤 Library에 들어가 로컬 PDF를 추가하고,
So that 잘못 추가한 Paper를 안전하게 삭제할 수 있다.

**Acceptance Criteria:**

**Given** P-1~P-3의 실제 통과, Story 1.13의 공통 Job-class 복구 정책, Story 1.10~1.12의 두 Provider 연결 경로, 이 Story의 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인과 새 설치 상태가 있을 때,
**When** 어느 한 경로의 실제 연결 테스트가 성공하면,
**Then** full-window Onboarding은 두 경로를 동등하게 제공하고 명시적 Continue로 실제 빈 Library에 진입시킨다.
**And** 실패 시 Library 진입을 허용하지 않는다.

**Given** 빈 Library에서 로컬 PDF를 선택했을 때,
**When** 저장을 확정하면,
**Then** Application이 Paper UUID/generation과 최소 Import Job을 생성하고 첫 파일 접근 전에 writer permit을 받아 보안 범위가 유효한 동안 Paper 전용 immutable PDF copy를 staging·검증·게시한다.
**And** 완료 후 보안 범위를 해제하고 bookmark를 저장하지 않으며 Library에는 실제 추가 결과와 진행/실패 상태가 보인다.

**Given** 사용자가 추가된 Paper를 삭제하거나 Import 중 삭제할 때,
**When** 삭제가 시작되면,
**Then** 새 write/publication을 차단하고 기존 작업의 정리·Agent purge·파일 부재를 확인한 뒤에만 성공으로 표시한다.
**And** 실패 중인 Paper는 열 수 없는 `삭제 미완료` 상태와 같은 saga의 `Retry Deletion`을 제공하며 재실행하거나 늦은 Import 결과가 와도 Paper가 되살아나지 않는다.

**Given** 앱이 Import 성공·실패 또는 삭제 실패 중 종료됐을 때,
**When** 다시 실행하면,
**Then** 완료/실패·재시도 필요 상태와 가능한 다음 행동을 복원하고 이전 실행의 `running` attempt를 그대로 재개하지 않는다.

**범위:** 두 Provider 경로에서 실제 빈 Library로 들어가는 첫 진입, 로컬 PDF 한 경로의 Paper lifecycle·삭제·복구. 실제 Reader가 생기기 전에는 작동하지 않는 `Open Reader`를 노출하지 않는다. 첫 실제 Paper 저장 경계의 큰 작업 단위라는 검토 의견을 제시했으며 사용자가 이 범위 그대로 승인했다. Party 검토의 승인된 순서 변경으로 번호만 이전 1.13에서 현재 1.14로 이동했다.

**비목표/후속 의존성:** URL 세 경로, Folder·중복 확인, PDF Reader, AI 파싱/Translation/Chat/Brief는 후속 Story다. 이를 구현된 것처럼 표시하지 않으며 Paper 소유 데이터가 늘 때마다 해당 Story에서 삭제·복구를 다시 검증한다.

**추적/위험:** AD-1/5/6/7/10/11, AR-009~012/016~018, FR-001~003/005/007/030~034의 현재 기능 범위, UX-DR1/4~8/26/35; R-003/005/007. Story 범위 승인은 별도 Build Spec의 IMPLEMENTATION 승인이나 P-1~P-3의 실제 통과를 대신하지 않는다.

### Story 1.15: 추가한 PDF를 Reader에서 읽고 이어 읽기

As a 논문 독자,
I want Library의 PDF를 열어 탐색·확대·검색·선택하고,
So that 다시 방문하면 마지막 읽은 위치에서 이어 읽을 수 있다.

**Acceptance Criteria:**

**Given** Story 1.14의 실제 Paper 저장·삭제 경계, 별도 governing Issue·task branch·Build Spec 커밋 SHA에 대한 명시적 IMPLEMENTATION 승인과 PDF 저장이 완료된 Paper가 있을 때,
**When** `Open Reader`를 선택하면,
**Then** 원본 PDF의 페이지 이동·확대/축소·검색·텍스트 선택이 동작한다.
**And** 검색 결과 없음도 명시한다.

**Given** 사용자가 읽기 위치를 바꿨을 때,
**When** Library로 돌아갔다 재진입하거나 앱을 재실행하면,
**Then** Paper별 마지막 읽은 위치가 복원된다.

**Given** Reader에서 열었던 Paper가 삭제 중이거나 삭제됐을 때,
**When** 재진입·위치 복원을 시도하면,
**Then** 접근과 복원을 차단하고 삭제한 Paper를 되살리지 않는다.

**Given** Story 1.8의 P-6 측정 계약이 실제로 통과했을 때,
**When** 첫 PDF 페이지를 표시하면,
**Then** 확정된 자동 readiness probe와 완료 신호로 측정한다.
**And** 원본 PDF 내용·글꼴·파일을 앱 스타일로 변경하지 않는다.

**범위:** 실제 저장된 PDF의 native PDFKit Reader, Open Reader 진입, 페이지 탐색·zoom·검색/결과 없음·텍스트 선택, Application use case를 통한 Paper별 durable last-read 저장·복원과 삭제 시 접근 차단. Timing 구현의 Build Spec은 P-6 실제 통과 뒤에만 확정한다.

**비목표/후속 의존성:** 파싱·Translation·Paper Chat·Brief·Highlight/Note 생성은 후속 Story다. 미구현 기능을 성공 상태로 표시하지 않는다. Reader 자체는 해당 미래 기능에 의존하지 않는다.

**추적/위험:** AD-1/6/7/11/12, AR-010/013/019, FR-007/009/010 및 FR-008의 PDF 범위, NFR-001~004, UX-DR11/13/14/32/33의 해당 Reader 범위; R-008. Story 승인과 별도 Build Spec 구현 승인·P-6 판정은 구분한다.

### Story 1.16: PDF에 Highlight·Note 남기고 다시 확인하기

As a 논문 독자,
I want PDF의 중요한 부분을 표시하고 개인 메모를 남기며,
So that 재방문할 때 원문 위치와 함께 확인할 수 있다.

**Acceptance Criteria:**

**Given** Story 1.15의 Reader, Story 1.14의 저장·삭제 경계, 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인과 선택 가능한 PDF 텍스트가 있을 때,
**When** 텍스트를 선택하면,
**Then** `Highlight`·`Add Note`·`Copy`를 제공한다.
**And** Paper Chat으로 선택 내용을 전달하는 action은 없다.

**Given** 선택 원문과 현재 PDF 위치가 있을 때,
**When** `Add Note`로 Drawer를 열어 저장하면,
**Then** 선택 원문·읽기 맥락을 유지하고 Note를 해당 Paper의 Library 기록에 남긴다.
**And** Drawer를 닫으면 같은 Reader 위치로 돌아온다.

**Given** Highlight·Note가 저장됐을 때,
**When** Paper에 재진입하거나 앱을 재실행하면,
**Then** 기록과 연결된 PDF 위치를 확인할 수 있다.
**And** 저장 실패는 성공으로 표시하지 않는다.

**Given** Highlight·Note가 있는 Paper를 삭제할 때,
**When** 삭제가 완료되면,
**Then** 두 기록도 함께 제거되고 재실행·늦은 저장 결과로 복원되지 않는다.
**And** 개인 Note를 AI Evidence Anchor처럼 표시하지 않는다.

**범위:** PDF selection의 Highlight/Add Note/Copy, Reader context를 보존하는 NotesDrawer와 Paper-bound 기록 저장·재방문·삭제 연동. 키보드·VoiceOver로 선택 action과 Drawer 저장·닫기를 사용할 수 있어야 한다. Durable 저장과 삭제는 기존 Application use case 및 persistence 경계를 따른다.

**비목표/후속 의존성:** Note의 Chat context 전송, 새로운 노트 분류·검색 기능은 추가하지 않는다. AI 파싱·Translation·Chat·Brief의 미래 구현 없이 현재 annotation 흐름을 완결한다.

**추적/위험:** AD-1/6/11, AR-010/011/018, FR-008/029~031의 Highlight·Note 범위, UX-DR21/22/33, NFR-007/008; R-007. 저장 실패·삭제 경합·재실행에도 삭제한 기록을 부활시키지 않는다.

### Story 1.17: Library 폴더와 중복 확인 후 가져오기

As a 논문 독자,
I want 저장할 폴더와 중복 가능성을 확인한 뒤 가져오기를 확정하고,
So that 기존 Paper를 잘못 덮어쓰지 않을 수 있다.

**Acceptance Criteria:**

**Given** Story 1.14의 로컬 Import·Library와 Story 1.15의 Reader, 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인과 Library에서 폴더를 만들거나 Paper를 이동할 때,
**When** 변경을 저장하면,
**Then** 폴더와 Paper 배치가 재진입·재실행 후 유지된다.

**Given** 로컬 PDF 입력이 인식됐을 때,
**When** 확인 sheet를 열면,
**Then** 인식된 Paper·저장 폴더/default·중복 상태를 보여준다.
**And** 확정 전에는 Import Job을 만들지 않고 Cancel은 추가를 취소한다.

**Given** 제목·URL·식별자 또는 PDF content hash로 중복 가능성이 발견됐을 때,
**When** 사용자가 계속 가져오기를 선택하면,
**Then** 새 Paper UUID와 별도 소유 PDF copy를 만든다.
**And** 기존 Paper를 덮어쓰거나 물리 파일을 공유하지 않는다.

**Given** 동일 내용으로 별도 가져온 Paper 두 개가 있을 때,
**When** 하나를 삭제하면,
**Then** 다른 Paper의 PDF·기록은 유지된다.
**And** Import 실패·삭제 경합·재실행도 기존 복구 규칙을 따른다.

**범위:** 폴더 생성·배치·이동과 현재 로컬 Import의 확인 sheet·중복 경고. 확정 후 Library에 남고 PDF 준비 후 Open Reader를 제공하며 자동 이동하지 않는다. 현재 인식 가능한 입력으로 중복 가능성을 판단하고, 아직 추출되지 않은 metadata를 인식된 값처럼 표시하지 않는다.

**비목표/후속 의존성:** URL 세 경로와 Library 태그·검색·필터는 후속 Story다. 현재 로컬 Import 흐름은 미래 URL·파싱 구현 없이 완결한다.

**추적/위험:** FR-006/007 및 Library 폴더 조직 범위, UX-DR5, AD-1/6/11; R-007. Paper별 독립 파일 소유권과 기존 삭제·복구 경계를 유지하며 중복 경고를 자동 덮어쓰기나 물리 파일 공유로 해석하지 않는다. 문서 승인은 IMPLEMENTATION 승인이나 기술 게이트 통과가 아니다.

### Story 1.18: 세 URL 경로로 PDF 가져오기

As a 논문 독자,
I want arXiv와 일반 PDF 링크를 로컬 파일과 같은 흐름으로 추가하고,
So that 네 입력 경로 모두에서 Library에 논문을 모아 읽을 수 있다.

**Acceptance Criteria:**

**Given** arXiv abstract URL·arXiv PDF URL·일반 PDF URL을 입력할 때,
**When** 입력을 인식하면,
**Then** 올바른 경로로 분류하고 abstract URL은 PDF 가져오기로 해석한다.
**And** 확인 sheet에서 저장 폴더·중복 가능성을 보여주며 확정 전 Job을 만들지 않는다.

**Given** Library에 지원 파일이나 URL을 drag하거나 URL paste/local file 선택을 사용할 때,
**When** 지원 입력이 drag-over되면,
**Then** Library content를 유지하면서 전체 surface에 tint와 label을 표시한다.
**And** Cancel은 추가를 취소하고 Continue 후 Library에 남는다.

**Given** URL 다운로드를 실행할 때,
**When** 응답·redirect·본문을 처리하면,
**Then** HTTPS만 허용하고 매 redirect를 재검증한다.
**And** embedded credentials·비PDF 응답·자원 한도 초과를 거부하며 PDF type/magic 검증 전 durable publication이나 parser dispatch를 하지 않는다.

**Given** 다운로드 성공·실패·취소·삭제 경합·재실행이 발생할 때,
**When** 상태를 표시하거나 복구하면,
**Then** 성공 시 Open Reader, 실패 시 안전한 이유·Retry를 제공한다.
**And** 독립 PDF 소유권·writer/publication permit·정리 규칙을 유지하고 raw URL을 diagnostics에 남기지 않는다.

**Given** 고정된 P-6 fixture/profile로 각 입력 경로를 실행할 때,
**When** 실제 Reader readiness를 측정하면,
**Then** 승인된 두 timing event와 공통 probe를 사용한다.
**And** arXiv 30초는 soft target으로 보고하며 AI 완료를 PDF 진입 조건으로 삼지 않는다.

**범위:** Story 1.13·1.17을 선행으로 세 URL 경로와 네 입력의 공통 confirmation·Library progress를 완결한다. 제품 Import에 해당하는 P-3 및 timing 분기 전 P-6의 실제 통과, 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** 임의 웹페이지 수집·HTTP 예외·자동 Reader 이동은 없다. 후속 AI 기능 없이 PDF 읽기가 동작한다.

**추적/위험:** FR-005~007, NFR-001~004, UX-DR4~6, AD-5/11/12. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.19: 공통 문장·좌표와 Anchor 변환 계약 입증

As a 논문 독자,
I want 번역과 근거 이동이 동일한 원문 문장·위치를 가리키는 기반을 확인하고,
So that 이후 근거 확인에서 서로 다른 위치를 성공으로 오인하지 않을 수 있다.

**Acceptance Criteria:**

**Given** PDF content hash와 extraction revision이 있을 때,
**When** 문장·Anchor 계약을 정의하면,
**Then** Paper UUID·SHA-256·revision·zero-based page·sentence ID로 identity를 고정한다.

**Given** CropBox와 page rotation이 다른 fixture가 있을 때,
**When** PDFium 좌표를 canonical geometry로 정규화하면,
**Then** unrotated CropBox·PDF points·lower-left origin·축 방향·quad 순서를 계약대로 보존하고 rotation은 별도 metadata로 둔다.

**Given** canonical geometry를 PDFKit 표시 좌표로 변환할 때,
**When** 확대·회전·페이지 이동 및 round-trip을 검증하면,
**Then** shared contract에 명시한 수치 tolerance를 만족하고 잘못된 위치를 성공으로 표시하지 않는다.

**Given** 문장 위치가 없거나 revision이 맞지 않을 때,
**When** 위치 해석을 요청하면,
**Then** typed 실패로 구분한다.
**And** 전체 원문 문장의 의미 범위를 화면 truncation 때문에 바꾸지 않는다.

**범위:** Story 1.15·1.13 및 P-1/P-2/P-3의 해당 실제 통과를 선행으로 PDF 컴포넌트 분기 전 shared tolerance 확정과 실제 PDFium↔PDFKit 변환 증거를 만든다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** Chat/Brief Anchor UI·Translation 구현은 하지 않는다. 검증은 미래 AI 기능 없이 완결한다.

**추적/위험:** AD-7/8, AR-014, A-001, R-001/002. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.20: PDF 파싱과 검색용 revision을 안전하게 공개하기

As a 논문 독자,
I want PDF를 읽는 동안 AI가 사용할 일관된 원문 기반을 준비하고,
So that 불완전한 추출이나 서로 다른 revision을 근거로 사용하지 않을 수 있다.

**Acceptance Criteria:**

**Given** Paper 소유 immutable PDF가 준비됐을 때,
**When** 파싱을 실행하면,
**Then** no-network PDFium XPC가 read-only 입력으로 bounded typed sentence/geometry batch를 반환한다.
**And** worker는 DB·FTS·cache에 직접 쓰지 않는다.

**Given** 유효한 batch가 반환됐을 때,
**When** Application이 저장하면,
**Then** 문장·geometry·FTS를 inactive revision으로 완성한 뒤 하나의 transaction으로 active revision을 공개한다.
**And** 부분 revision은 검색에 노출하지 않는다.

**Given** 기존 active revision이 있는 Paper를 다시 파싱할 때,
**When** 새 revision이 실패하거나 늦게 완료되면,
**Then** 기존 usable revision을 유지한다.
**And** 검색은 하나의 active revision에 pin하고 참조 중인 옛 revision은 제거하지 않는다.

**Given** parsing 중 중단·삭제·FTS 저장 실패가 발생할 때,
**When** 복구·정리를 수행하면,
**Then** 불완전 추출을 성공으로 표시하지 않고 삭제한 문장·geometry·FTS 결과가 재실행이나 늦은 결과로 부활하지 않는다.

**범위:** Story 1.19를 선행으로 실제 파싱·inactive build·atomic publication·revision-pinned 검색을 완결한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** Chat 답변·번역·Brief 생성은 없다. 미래 생성 기능 없이 추출·검색·실패 검증이 동작한다.

**추적/위험:** FR-011의 파싱 기반, AD-6/7/8/11, AR-013~014, R-001. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.21: 파싱 실패를 이해하고 다시 시도하기

As a 논문 독자,
I want 파싱 실패에도 PDF를 읽으며 필요한 복구 행동을 선택하고,
So that AI 준비 실패가 원본 읽기를 막지 않도록 할 수 있다.

**Acceptance Criteria:**

**Given** 파싱 실패가 발생했을 때,
**When** Reader에 상태를 반영하면,
**Then** 즉시 in-app floating notification과 right panel의 latest reason·Retry Parsing을 제공한다.
**And** PDF 탐색·검색·선택은 유지한다.

**Given** usable extraction이 없을 때,
**When** AI 가용성을 표시하면,
**Then** Translation·Paper Chat·Brief 생성이 불가능한 이유를 명시한다.
**And** 미구현 기능을 실행 가능하거나 완료 상태로 표시하지 않는다.

**Given** 사용자가 Retry Parsing을 선택했을 때,
**When** 새 attempt가 성공하거나 반복 실패하면,
**Then** 성공은 실제 extraction 준비 상태로, 실패는 latest reason·explicit Retry로 표시한다.
**And** attempt count/time/history는 노출하지 않는다.

**Given** 실패 상태에서 앱을 종료하거나 Paper를 삭제할 때,
**When** 재실행하면,
**Then** 실패·다음 행동을 복원하되 삭제한 Paper에는 Retry·재진입·새 Job을 허용하지 않는다.

**범위:** Story 1.20을 선행으로 실패·반복 Retry·재실행의 실제 복구 UI를 완결한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** Translation tab의 실제 결과·progress 전환은 Epic 2 통합 책임이다. 현재 파싱 성공을 번역 성공으로 위장하지 않는다.

**추적/위험:** FR-011/032~034, UX-DR34/35, SM-003. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.22: Paper metadata와 Reader 목차 확인하기

As a 논문 독자,
I want 논문을 식별하고 목차로 읽을 위치를 찾으며,
So that 같은 Paper의 읽기 맥락 안에서 필요한 원문으로 이동할 수 있다.

**Acceptance Criteria:**

**Given** source 또는 추출에서 metadata를 얻을 수 있을 때,
**When** Paper 정보를 표시하면,
**Then** 실제 제목·발행연도·abstract·topic 정보를 사용하고 누락 값은 미확인으로 구분한다.
**And** 임의 연도·abstract·태그를 만들지 않는다.

**Given** 유효한 Contents 위치가 있을 때,
**When** ReaderOutline에서 section을 선택하면,
**Then** 해당 PDF 위치로 이동하고 active section·last position을 반영한다.
**And** 잘못된 위치는 이동 성공으로 표시하지 않는다.

**Given** metadata나 Contents가 없거나 파싱이 실패했을 때,
**When** Reader를 열면,
**Then** 가능한 정보와 PDF 읽기를 유지한다.
**And** parsing recovery action은 Outline에 두지 않는다.

**Given** 저장·재진입·재실행·Paper 삭제가 발생할 때,
**When** 정보를 복원하면,
**Then** 현재 Paper 기록만 표시하고 삭제한 metadata·읽기 맥락은 복원하지 않는다.

**범위:** Story 1.20~1.21을 선행으로 실제 metadata·Contents와 ReaderOutline을 연결한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** 미래 Translation과의 페이지 동기화는 Epic 2에서 확장한다.

**추적/위험:** FR-027/029, UX-DR12, AD-1/6/8. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.23: 근거 기반 한 줄 요약으로 Paper 식별하기

As a 논문 독자,
I want 제목만으로 구분하기 어려운 논문을 한 줄 요약으로 확인하고,
So that Library에서 필요한 논문을 빠르게 식별할 수 있다.

**Acceptance Criteria:**

**Given** 사용할 수 있는 extraction과 Provider가 있을 때,
**When** 한 줄 요약을 생성하면,
**Then** Application-owned bounded source/request 계약을 사용하고 Reader page·selection·Note 등 금지 입력을 전달하지 않는다.

**Given** typed usable 요약 결과가 반환됐을 때,
**When** publication 검증을 통과하면,
**Then** 해당 Paper·입력 revision에 연결해 저장하고 Library 재진입·재실행 때 재생성 없이 표시한다.
**And** 논문 주장에 대한 요약 출력은 기존 공통 근거 계약에 따라 같은 Paper·입력 revision의 Evidence Anchor와 연결하거나 근거 부족 상태를 명시한다. Paper·입력 revision 연결만으로 주장 근거가 검증됐다고 간주하지 않으며 이 경계는 저장·Library 표시·재실행 후 복원에도 유지한다.

**Given** 근거 부족·Provider 실패·중단이 발생할 때,
**When** 상태를 표시하면,
**Then** 요약 준비/불가/실패를 실제 상태로 구분하고 빈 결과를 성공으로 표시하지 않는다.
**And** PDF 읽기를 막지 않으며 가능한 실패에 explicit Retry를 제공한다.

**Given** Paper 삭제 또는 stale 결과가 경합할 때,
**When** 응답이 도착하면,
**Then** 요약을 공개하지 않고 Paper-bound 결과·Agent 임시 상태를 기존 삭제 규칙으로 정리한다.

**범위:** Story 1.13·1.20·1.22, 실제 Provider 연결 및 해당 P-3 operation 계약을 선행으로 한 줄 요약의 생성·저장·캐시·실패·삭제를 완결한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** Brief를 가짜로 대신 표시하거나 새로운 연구 주장·추천을 생성하지 않는다.

**추적/위험:** FR-027, AD-3/10/11, NFR-005/006/010, UX-DR7/8/35. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.24: Library 카드·목록·정렬과 기록 재방문

As a 논문 독자,
I want 저장한 논문과 읽기 기록을 원하는 형태로 다시 찾고,
So that Library에서 이전 연구 맥락으로 돌아갈 수 있다.

**Acceptance Criteria:**

**Given** Library에 Paper가 있을 때,
**When** card 또는 list로 표시하면,
**Then** 제목·발행연도·한 줄 요약·읽기 상태·Favorite·more-actions와 실제 누락/Job 상태를 구분한다.
**And** hover/detail에서 abstract 일부·topic tags를 확인할 수 있다.

**Given** presentation 또는 정렬을 변경할 때,
**When** Library를 다시 열면,
**Then** card/list 선택을 재실행 후 복원하고 기본 recently read 및 name/recently added/recently read/publication year 정렬을 제공한다.

**Given** 읽을 수 있는 Paper를 선택할 때,
**When** Reader를 열거나 세부 기록을 확인하면,
**Then** 저장된 마지막 위치와 Highlight·Note를 확인한다.
**And** 아직 없는 Brief를 완료 기록으로 표시하지 않는다.

**Given** Paper 삭제를 선택할 때,
**When** native alert에서 Cancel 또는 Delete를 실행하면,
**Then** 대상 이름·실제 삭제 범위·irreversible action을 구분한다.
**And** Cancel은 상태를 유지하고 실패 card/row는 non-openable 삭제 미완료·같은 saga의 Retry Deletion을 제공한다.

**범위:** Story 1.16~1.17·1.22~1.23을 선행으로 두 presentation과 정렬·기록 재방문·삭제 확인을 완결한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** Brief 기록 연결은 Epic 3에서 확장한다. Reading Status/Favorite 편집과 검색·필터는 Story 1.25에서 추가하며 현재는 실제 저장 값만 표시한다.

**추적/위험:** FR-026/027/029~031, UX-DR7/8/10/26, SM-004/005. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.25: 태그·읽기 상태·Favorite와 검색·필터

As a 논문 독자,
I want Library를 자신의 연구 분류로 정리하고 필요한 Paper만 찾으며,
So that 축적한 논문을 다시 사용할 수 있다.

**Acceptance Criteria:**

**Given** Paper 조직 값을 변경할 때,
**When** 태그 추가·수정·삭제 또는 Reading Status/Favorite를 저장하면,
**Then** label과 현재 값을 표시하고 재진입·재실행 후 유지한다.
**And** 저장 실패를 성공으로 표시하지 않는다.

**Given** toolbar 검색과 sidebar 필터를 사용할 때,
**When** 제목·태그·Reading Status·Favorite 조건을 조합하면,
**Then** card/list에 동일한 결과를 적용하고 presentation 전환으로 조건을 잃지 않는다.

**Given** Library를 불러오거나 결과가 없을 때,
**When** 상태를 표시하면,
**Then** cold-loading·populated·empty Library·no-match를 구분한다.
**And** empty에는 Import 진입을 제공하고 no-match는 저장 데이터가 없다는 뜻으로 표시하지 않는다.

**Given** 폴더 이동·조직 변경·Paper 삭제가 검색과 경합할 때,
**When** 결과를 갱신하거나 재실행하면,
**Then** 현재 저장된 값만 반영하고 삭제한 Paper는 검색·최근 읽은 항목·폴더에 다시 나타나지 않는다.

**범위:** Story 1.24를 선행으로 Library 조직 편집·검색·필터·상태 구분을 완결한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** 새로운 연구 추천·지식 그래프·분류 체계는 추가하지 않는다. 미래 AI 기능 없이 현재 Library 검색·조직이 동작한다.

**추적/위험:** FR-026/028~031, UX-DR9/10, SM-004/005. 문서 승인은 기술 게이트 통과가 아니다.

### Story 1.26: Settings에서 Provider를 재연결하고 상태 확인하기

As a 논문 독자,
I want 연결을 변경하거나 복구해도 마지막 정상 연결을 불필요하게 잃지 않으며,
So that Provider 문제를 이해하고 안전하게 연구 흐름으로 돌아갈 수 있다.

**Acceptance Criteria:**

**Given** Settings를 열었을 때,
**When** Provider 설정을 확인하면,
**Then** 현재 Provider·연결 상태·API key 재입력·공식 ChatGPT 재로그인/device-code·연결 테스트를 제공한다.

**Given** 새 연결 정보를 시험할 때,
**When** 최소 실제 authenticated generation을 실행하면,
**Then** typed usable 응답만 성공으로 인정하고 stage/CAS promotion 규칙으로 활성화한다.
**And** identity/model list만으로 성공을 표시하지 않는다.

**Given** 테스트 실패·취소·늦은 응답이 발생할 때,
**When** 연결 상태를 표시하면,
**Then** last-good 연결을 보존하고 그 기준으로 기능 가용성을 표시한다.
**And** redacted reason·Retry를 제공하고 stale candidate는 승격하지 않는다.

**Given** 연결 변경과 진행 중 Paper 작업이 경합할 때,
**When** 결과를 공개하거나 앱을 재실행하면,
**Then** config generation과 기존 Job 정책을 적용한다.
**And** 설정 변경만으로 실패한 외부 작업을 몰래 재전송하지 않는다.

**범위:** Story 1.10~1.14를 선행으로 기존 native/Agent secret 소유권·permissions·backup exclusion·정리 규칙을 재사용한다. 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다.

**비목표/후속 의존성:** Keychain·generic OAuth·새 consent/disclosure surface는 없다.

**추적/위험:** FR-003/004, UX-DR2, AD-2/3/4/10, NFR-009/010. 문서 승인은 기술 게이트 통과가 아니다.

### Epic 1 공통 완료 검증 조건

Story 1.13 및 1.18~1.26의 해당 UI에는 다음 조건을 각각 포함하며 별도 마지막 polish Story로 미루지 않는다.

- Native Canvas 기본 semantic 스타일, 한국어 상태와 다음 행동, 색 외 오류·진행·삭제 신호.
- 실제 배경에서 대비, native text scaling·창 resize, 키보드·VoiceOver label/role/state 검증.
- dialog/drawer 진입·닫기·opener focus 복귀, Retry/Cancel/Delete의 접근성.
- 각 시점에 존재하는 모든 Paper 데이터의 실패·재실행·삭제 경합·부활 방지 검증.
- Epic 1은 PDF 읽기·Library 정리까지 완결하지만 v1 출시 완료는 아니다.
- Translation·Chat·Brief의 미래 확장은 Epic 2~3에서 실제 구현하며 현재는 동작하지 않는 성공 화면을 만들지 않는다.

### Epic 1 분해 검토 결과

사용자가 현재 번호 기준 Story 1.13 및 1.18~1.26과 공통 완료 검증 조건을 일괄 승인했다. Story 1.1~1.26은 분해 문서의 범위·인수 조건 승인 상태이며 구현 완료·IMPLEMENTATION 승인·P-1~P-6 통과를 의미하지 않는다. 이후 사용자의 명시적 진행 지시에 따라 Epic 2 일괄 분해·검토로 진행했다. Party 검토에서 승인된 순서 변경으로 아래 참조는 현재 번호를 사용한다.

| Epic 1 완료 책임 FR | 승인된 Story |
| --- | --- |
| FR-001 | 1.10~1.12, 1.14 |
| FR-002 | 1.10~1.12, 1.26 |
| FR-003 | 1.14, 1.26 |
| FR-004 | 1.26 |
| FR-005 | 1.14, 1.18 |
| FR-006 | 1.17, 1.18 |
| FR-009 | 1.15 |
| FR-010 | 1.15 |
| FR-026 | 1.17, 1.24~1.25 |
| FR-027 | 1.22~1.24 |
| FR-028 | 1.25 |

**교차 범위:** FR-007/008은 1.14~1.16·1.18의 PDF-first/Reader/annotation 기여, FR-011은 1.19~1.21의 extraction·복구, FR-029는 1.15~1.16·1.24~1.25의 현재 기록, FR-030~034는 1.14·1.13 및 각 후속 데이터 Story의 삭제·Job 검증으로 추적한다. Translation/Chat/Brief 추가 후 전체 통합 완료 책임은 기존 FR Coverage Map대로 Epic 2~3에 남는다.

**UX 및 비기능 범위:** Provider는 1.10~1.12·1.14·1.26, Import/Job은 1.14·1.13·1.17~1.18·1.20~1.21, Library는 1.17·1.22~1.25, Reader/Outline/PDF/Notes는 1.15~1.16·1.19·1.22, Paper DeleteAlert는 1.24에서 다룬다. UX-DR29의 현재 PDF page/status는 Reader 범위이며 Translation 관계·match 상태는 Epic 2에서 확장한다. Native 기본 semantic token과 접근성·한국어 copy·resize·focus·복구는 각 화면 및 공통 완료 조건에 적용한다. NFR-001~004는 1.8·1.15·1.18, NFR-007~008은 Paper 저장·삭제 Story, NFR-009~010은 Provider 연결·요약 Story에서 적용한다. 전체 테마/appearance·AI 정확도/Anchor·공개 배포 검증은 해당 후속 Epic의 책임으로 유지한다.

**선행 계약 경계:** Job-class 정책은 1.13에서 첫 제품 Import Job Story 1.14보다 먼저 확정하고 1.14~1.17의 Build Spec은 그 공통 recovery 정책을 적용한다. shared geometry tolerance는 1.19에서 확정한다. 1.19는 PDFKit Reader 전체가 아니라 canonical extraction/Anchor 변환 분기의 선행이다. 각 Story의 미래 기능 제외는 현재 동작을 가짜로 대체하거나 architecture의 pre-split 계약을 뒤로 미루는 허가가 아니다.

## Epic 2: 번역을 대조하고 논문 전체 근거로 질문하기

사용자는 원문과 문장별 번역을 대조하고, Paper 전체 근거로 질문하며, 답변의 원문 문장으로 돌아가고 저장된 대화를 다시 열 수 있다. 완료 책임은 FR-012~019다. Epic 1의 Provider·파싱·Reader·저장·삭제 경계를 재사용하며 Brief·Template이나 추가 테마 없이 번역·질문·대화 재방문까지 동작한다.

**공통 구현 경계:** 구현 선행은 Epic 1의 실제 완료다. 문서 승인만으로 구현이나 P-1~P-3/P-6 통과를 인정하지 않는다. 모든 Story는 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다. 새 데이터·Job은 해당 Story에서 실패·Retry·재실행·삭제 경합까지 검증하며 마지막 Story로 복구 구현을 미루지 않는다. 두 Provider는 동일한 Application-owned 요청·EvidenceBundle·budget을 사용하며 adapter가 근거를 추가·삭제·재정렬·축약하지 않는다. PDF는 AI 상태와 독립적으로 사용할 수 있어야 한다.

### Story 2.1: 번역 대상 언어를 설정하고 유지하기

As a 논문 독자,
I want 번역 대상 언어를 Settings에서 선택하고,
So that 이후 번역을 원하는 언어로 읽을 수 있다.

**Acceptance Criteria:**

**Given** 저장된 언어 설정이 없는 새 설치에서,
**When** Translation 설정을 열면,
**Then** 한국어가 기본 대상으로 표시된다.

**Given** 사용자가 대상 언어를 변경할 때,
**When** 저장이 성공하면,
**Then** 현재 선택을 표시하고 Settings 재진입·앱 재실행 후 복원한다.
**And** 저장 실패는 성공으로 표시하지 않는다.

**Given** 기존 번역 결과나 실행 중 Job이 있을 때,
**When** 언어 설정을 바꾸면,
**Then** 기존 결과·Job 입력을 몰래 변경하거나 새 요청을 시작하지 않는다.
**And** 새 Job과 명시적 재생성에 적용할 설정으로 저장한다.

**Given** Paper 삭제가 발생할 때,
**When** 앱을 재실행하면,
**Then** Paper-independent 언어 설정은 유지된다.

**범위:** native 언어 선택·저장·실패 표시와 Application 설정 계약. 지원 언어 목록과 validation은 Build Spec에서 명시한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 이 Story만으로 번역 생성 성공을 표시하지 않는다.

**추적/위험:** FR-013, UX-DR3/38, AD-1/6.

### Story 2.2: 페이지별 번역을 생성하고 PDF와 함께 읽기

As a 논문 독자,
I want 준비된 PDF의 페이지별 번역을 읽고,
So that 번역을 기다리는 동안에도 원문 읽기를 이어갈 수 있다.

**Acceptance Criteria:**

**Given** usable extraction과 실제 연결된 Provider가 있을 때,
**When** Translation Job을 생성하면,
**Then** 대상 언어·extraction revision·sentence identity를 입력으로 고정하고 공통 allowlist·budget을 적용한다.

**Given** 페이지별 결과가 반환될 때,
**When** typed validation과 publication guard를 통과하면,
**Then** 완료 페이지부터 표시하고 미완료 페이지는 pending/running으로 구분한다.
**And** PDF를 가리거나 Reader 진입을 막지 않는다.

**Given** Translation tab이 열렸을 때,
**When** PDF 페이지를 이동하면,
**Then** equal-split 화면의 Translation 대상 페이지도 바뀐다.
**And** Translation 내부 scroll은 PDF 페이지를 바꾸지 않는다.

**Given** 번역을 완료한 Paper를 다시 열 때,
**When** 같은 결과를 읽으면,
**Then** 저장된 번역을 재생성 없이 표시한다.
**And** 결과의 실제 대상 언어와 입력 revision을 잃지 않는다.

**Given** 실패·앱 중단·Paper 삭제·늦은 응답이 발생할 때,
**When** 상태를 복구하거나 결과를 공개하면,
**Then** 공통 Job·삭제 규칙을 적용한다.
**And** 실패에는 이유·explicit Retry를 제공하고 삭제한 번역·cache·Agent 임시 상태는 부활하지 않는다.

**범위:** Story 2.1을 선행으로 실제 페이지별 번역·저장·캐시·기본 실패 복구를 완결한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** sample 번역·가짜 진행률·30초 완료 약속은 없다.

**추적/위험:** FR-013/014, FR-007/008/032~034의 번역 기여, UX-DR11/15/35.

### Story 2.3: 원문과 번역 문장을 양방향 대조하기

As a 논문 독자,
I want 원문과 번역의 대응 문장을 함께 확인하고,
So that 번역의 의미를 원문으로 검토할 수 있다.

**Acceptance Criteria:**

**Given** 유효한 문장 대응 결과가 있을 때,
**When** 번역을 표시하면,
**Then** canonical source sentence와 대응 번역을 동일 identity의 1:1 pair로 연결한다.
**And** 문장 순서·페이지·citation 범위를 임의 변경하지 않는다.

**Given** 대응 pair가 있을 때,
**When** 원문 또는 번역 문장을 hover하거나 keyboard focus하면,
**Then** 양쪽의 동일 pair를 함께 강조한다.
**And** hover만으로 접근할 수 있는 기능으로 만들지 않는다.

**Given** 정렬 실패·보정·불확실한 대응이 있을 때,
**When** 상태를 표시하면,
**Then** 일반 정렬 성공과 구분한다.
**And** 잘못된 pair를 확정된 대응처럼 강조하거나 완전 정확도를 주장하지 않는다.

**Given** 페이지 이동·확대·resize·재방문이 발생할 때,
**When** 대응 강조를 다시 표시하면,
**Then** shared geometry 계약을 유지하고 stale pair를 현재 문장처럼 표시하지 않는다.
**And** 실제 페이지·match 상태를 StatusBar에 반영한다.

**범위:** Story 2.2를 선행으로 SentenceMatch·양방향 hover/focus·불확실성·실제 상태 표시를 완결한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** PDF 원본 내용·글꼴·파일 변경은 없다.

**추적/위험:** FR-012/015, UX-DR16/29/33, AD-8, R-002.

### Story 2.4: 번역 실패 페이지를 재시도하고 명시적으로 재생성하기

As a 논문 독자,
I want 실패한 번역만 복구하거나 현재 언어로 재생성하고,
So that 사용할 수 있는 번역을 잃지 않고 결과를 갱신할 수 있다.

**Acceptance Criteria:**

**Given** 일부 페이지 번역이 실패했을 때,
**When** inline Retry를 선택하면,
**Then** 실패 페이지의 새 attempt를 생성하고 완료 페이지·PDF는 유지한다.
**And** 불명확한 외부 요청을 자동 재전송하지 않는다.

**Given** 언어 설정 변경 후 기존 번역이 있을 때,
**When** 사용자가 명시적으로 재생성하면,
**Then** 현재 설정 언어를 새 입력에 고정한다.
**And** 설정 변경이나 화면 재방문만으로 기존 번역을 교체하지 않는다.

**Given** 재생성이 실패하거나 완료 순서가 뒤바뀔 때,
**When** 결과 publication을 시도하면,
**Then** 현재 유효한 attempt·입력 버전만 공개한다.
**And** 기존 usable 결과를 보존하며 다른 언어·revision 결과를 하나의 정상 번역처럼 섞지 않는다.

**Given** parsing 실패 후 Retry Parsing이 성공했을 때,
**When** AI 기능을 복구하면,
**Then** Translation tab의 현재 페이지와 실제 준비·진행 상태로 연결한다.
**And** 재실행 후에도 실패 이유·가능한 Retry·기존 결과를 복원한다.

**범위:** Story 2.3을 선행으로 실패 페이지 복구·언어 재생성·parsing 복구를 연결한다. 삭제 경합에도 재생성 결과가 부활하지 않아야 한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 조용한 자동 재생성·기존 결과의 언어 재라벨링은 없다.

**추적/위험:** FR-013~015, FR-011/033/034의 번역 기여, UX-DR15/34/35.

### Story 2.5: Paper 전체에서 일관된 질문 근거를 검색하기

As a 논문 독자,
I want 현재 페이지와 무관하게 논문 전체에서 질문 근거를 찾고,
So that 화면에 보이는 일부 문장에만 제한된 답변을 받지 않을 수 있다.

**Acceptance Criteria:**

**Given** 질문과 active extraction revision이 있을 때,
**When** 근거 검색을 실행하면,
**Then** 해당 Paper 전체를 대상으로 검색하고 한 요청은 하나의 revision에 pin한다.

**Given** 검색 결과로 요청 근거를 구성할 때,
**When** Application이 EvidenceBundle을 만들면,
**Then** Anchor identity·full source sentence·선택 metadata·순서·근거 부족 판단을 포함하고 P-3의 공통 ranking·budget을 적용한다.

**Given** Reader 페이지·selection·Highlight·Note가 있을 때,
**When** 동일한 질문의 근거를 구성하면,
**Then** 이 값을 자동 또는 수동 Chat context로 전달하지 않는다.
**And** 무제한 대화 history도 포함하지 않는다.

**Given** 근거 부족·revision 변경·Provider 한도 초과가 발생할 때,
**When** 요청을 검증하면,
**Then** typed 상태로 구분한다.
**And** adapter가 근거를 임의 축약하거나 부족 판단을 성공으로 승격하지 않는다.

**범위:** 실제 whole-paper retrieval과 공통 요청 구성·검증. 제품 Chat 화면 없이도 실제 추출 데이터로 검색 결과와 실패 조건을 검증할 수 있어야 한다. Epic 1 기반과 Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 일반 Chat 모드·현재 페이지 질문 모드·새 검색 엔진은 없다. 검색 검증은 미래 Chat UI에 의존하지 않는다.

**추적/위험:** FR-016, AD-3/7/8, AR-006~007, NFR-006.

### Story 2.6: 첫 질문에 근거 있는 답변을 받고 원문으로 이동하기

As a 논문 독자,
I want 논문 질문에 답을 받고 그 주장의 원문을 확인하고,
So that AI 답변을 검증하며 읽을 수 있다.

**Acceptance Criteria:**

**Given** Paper Chat의 empty composer가 있을 때,
**When** 첫 질문을 제출하면,
**Then** 해당 Paper의 Session·질문·dispatch intent를 저장하고 실제 요청을 실행한다.
**And** 일반 Chat/Paper QA 모드 토글은 없다.

**Given** 실제 Provider 응답이 반환됐을 때,
**When** 답변을 공개하면,
**Then** 논문 주장에 검증된 Evidence Anchor 또는 근거 부족 상태를 표시한다.
**And** Paper 밖 일반 지시에도 논문 근거 기반 범위를 유지한다.

**Given** 유효한 Anchor가 있을 때,
**When** hover 또는 keyboard focus하면,
**Then** 전체 원문 문장 preview를 제공한다.
**And** 시각적으로 줄인 경우 명시적 확장으로 전체 문장을 확인할 수 있다.

**Given** Anchor 이동을 실행할 때,
**When** click 또는 keyboard activation하면,
**Then** 해당 PDF 페이지·문장으로 이동해 visible highlight를 표시한다.
**And** `locationUnclear`·`navigationFailed`·`staleRevision`은 정상 anchored 성공과 구분한다.

**Given** 요청·저장 실패·앱 중단·Paper 삭제가 발생할 때,
**When** 복구하거나 늦은 응답이 도착하면,
**Then** 안전한 이유·가능한 explicit Retry를 제공하고 저장된 질문·답변을 복원한다.
**And** 실패를 완료 답변으로 표시하거나 삭제한 Session·응답을 부활시키지 않는다.

**범위:** Story 2.5를 선행으로 실제 첫 대화·자동 저장·Anchor preview/clickback·근거 부족·복구를 함께 완결한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 추정 Anchor 성공·완전 정확도 주장·Note를 evidence로 표시하는 기능은 없다.

**추적/위험:** FR-016~018, UX-DR17/18/33, NFR-005/006, R-002.

### Story 2.7: 여러 Chat Session을 만들고 이어 대화하기

As a 논문 독자,
I want 한 Paper에서 여러 대화를 분리하고 다시 열어 이어가며,
So that 서로 다른 연구 질문의 맥락을 보존할 수 있다.

**Acceptance Criteria:**

**Given** 기존 대화가 있을 때,
**When** 새 대화를 선택하면,
**Then** empty composer로 전환한다.
**And** 첫 질문 전에는 durable Session이나 replacement 대화를 만들지 않는다.

**Given** 새 대화에서 첫 질문을 제출할 때,
**When** Session을 생성하면,
**Then** 첫 질문에서 제목을 자동 생성하고 대화와 함께 저장한다.
**And** 제목 생성 때문에 질문을 중복 전송하지 않는다.

**Given** 여러 Session이 저장됐을 때,
**When** title dropdown에서 선택하거나 앱을 재실행하면,
**Then** 해당 Paper의 저장된 대화를 in-place 복원한다.
**And** 다른 Paper·Session의 메시지를 섞지 않는다.

**Given** 이어지는 질문에서 이전 대화가 필요할 때,
**When** 요청을 구성하면,
**Then** 공통 정책이 명시적으로 선택한 bounded prior turns만 포함한다.
**And** 원문 근거 검색은 계속 Paper 전체를 대상으로 한다.

**Given** Session 전환·저장 실패·늦은 응답이 경합할 때,
**When** 결과를 반영하면,
**Then** 원래 Session identity를 유지하고 현재 선택한 다른 대화에 응답을 삽입하지 않는다.
**And** 저장 실패는 성공으로 위장하지 않는다.

**범위:** Story 2.6을 선행으로 복수 Session·자동 제목·자동 저장·복원·bounded 대화 이어가기를 완결한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** Paper 간 대화 공유·무제한 history는 없다.

**추적/위험:** FR-018/019, UX-DR25/35, AD-3/10.

### Story 2.8: Chat Session 이름을 바꾸고 삭제하기

As a 논문 독자,
I want 대화 이름을 정리하고 필요 없는 Session을 삭제하며,
So that 남길 연구 대화만 관리할 수 있다.

**Acceptance Criteria:**

**Given** Session entry 또는 current more-actions를 사용할 때,
**When** Rename을 선택하면,
**Then** 동일한 native dialog에 현재 제목을 채운다.
**And** Cancel은 변경하지 않고 저장 성공 후 목록·재진입·재실행에 반영한다.

**Given** Delete를 선택했을 때,
**When** native warning dialog를 표시하면,
**Then** 대상 Session·삭제 범위와 Cancel/destructive Delete를 구분한다.
**And** Cancel은 원래 대화·선택·진행 상태를 유지한다.

**Given** 현재 Session 삭제가 완료됐을 때,
**When** Chat panel을 갱신하면,
**Then** 가장 최근 active remaining Session을 연다.
**And** 마지막 Session이면 replacement 생성 없이 empty composer로 돌아간다.

**Given** 응답·제목 저장과 Session 삭제가 경합할 때,
**When** 늦은 결과가 도착하거나 앱을 재실행하면,
**Then** 삭제된 Session·메시지·제목이 복원되지 않는다.
**And** 관련 요청의 결과 publication과 임시 상태를 정리하며 Paper·다른 Session·번역은 유지한다.

**Given** rename/delete 저장이 실패했을 때,
**When** 사용자에게 결과를 알리면,
**Then** 실패와 가능한 다음 행동을 표시하고 삭제·변경 완료를 위장하지 않는다.

**범위:** Story 2.7을 선행으로 Session 자체의 rename/delete·취소·실패·경합을 완결한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** Paper 삭제 saga와 Session 삭제 범위를 혼동하지 않는다.

**추적/위험:** FR-019, UX-DR25/26/33.

### Story 2.9: 번역·Chat을 포함한 Reader 복구·삭제 흐름 통합 검증

As a 논문 독자,
I want 번역과 질문을 함께 사용해도 읽기 맥락과 복구 상태가 일관되며,
So that 실패·재실행·삭제 후에도 앱 상태를 신뢰할 수 있다.

**Acceptance Criteria:**

**Given** PDF·Translation·Chat 준비/요청이 동시에 존재할 때,
**When** Reader와 JobStatusStrip을 표시하면,
**Then** 각 작업의 pending/running/succeeded/failed와 기능 가용성을 구분한다.
**And** AI 진행이나 실패가 PDF 접근을 막지 않는다.

**Given** parsing 실패 또는 재시도 성공이 발생할 때,
**When** 가용성을 갱신하면,
**Then** unusable extraction에 의존하는 생성은 이유와 함께 비활성화하고 성공 후 실제 준비 상태로 복구한다.
**And** 기존 usable 결과와 stale 상태를 혼동하지 않는다.

**Given** Provider 변경·앱 종료·재실행이 발생할 때,
**When** 복구하면,
**Then** 이전 running attempt는 interrupted 처리하고 완료 번역·대화·현재 사용 가능한 결과를 복원한다.
**And** old fence 재개·불명확한 자동 재전송은 없다.

**Given** 번역·여러 Session·응답 작업이 있는 Paper를 삭제할 때,
**When** 기존 삭제 saga가 완료되면,
**Then** 새 데이터·cache·참조 extraction·Agent 임시 상태까지 제거한다.
**And** 실패는 non-openable 삭제 미완료·동일 saga Retry Deletion으로 남고 늦은 결과나 재실행으로 부활하지 않는다.

**Given** tab 전환·Outline 이동·resize·keyboard/VoiceOver 사용이 발생할 때,
**When** 번역 대조와 Anchor 이동을 실행하면,
**Then** Paper·페이지·Session 맥락을 유지하고 접근 가능한 focus·preview·clickback·Retry를 제공한다.
**And** Outline/PDF navigation은 Translation 페이지에 반영하고 Translation 내부 scroll은 PDF를 움직이지 않는다.

**범위:** Story 2.1~2.8을 선행으로 각 Story에서 이미 구현한 경계를 실제 native 시나리오로 통합 회귀 검증한다. 두 Provider의 동일 의미를 확인한다. Epic 2 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** Brief·Template·세 테마 전체·공개 배포 검증은 포함하지 않는다. 앞선 Story의 실패·복구·삭제 구현을 이 Story까지 유예하지 않는다.

**추적/위험:** FR-007/008/011/029~034의 Epic 2 기여, UX-DR6/11/12/29/31~35/37, SM-001~003/005, CM-001/003.

### Epic 2 공통 UX 완료 조건

각 해당 Story에서 함께 검증하며 별도 polish 또는 통합 Story까지 미루지 않는다.

- 실제 원문·번역 대상 언어의 접근성 metadata.
- Korean wrapping·native text scaling·resize 시 읽기 상태 보존.
- 텍스트 대비 4.5:1, large text·meaningful non-text·focus 3:1 이상.
- 색 외 상태 신호, keyboard focus와 VoiceOver, dialog focus 진입·opener 복귀.
- progress/alert 중복 안내 방지와 짧은 한국어 상태·다음 행동.
- native 최소 창·Chat 열 비율·pointer target·Reduce Motion·단축키 등 열린 세부사항은 해당 Build Spec에서 결정.

### Epic 2 분해 검토 결과

사용자가 Story 2.1~2.9와 공통 조건을 일괄 승인했다. 이는 분해 문서의 범위·인수 조건 승인이지 구현 완료·IMPLEMENTATION 승인·기술 게이트 통과가 아니다. 이후 사용자의 명시적 진행 지시에 따라 Epic 3 일괄 분해·검토로 진행했다.

| Epic 2 완료 책임 FR | 승인된 Story |
| --- | --- |
| FR-012 | 2.3 |
| FR-013 | 2.1, 2.2, 2.4 |
| FR-014 | 2.2, 2.4 |
| FR-015 | 2.3 |
| FR-016 | 2.5, 2.6 |
| FR-017 | 2.6 |
| FR-018 | 2.6, 2.7 |
| FR-019 | 2.7, 2.8 |

FR-007/008/011/029~034는 Translation·Chat·Session의 상태·Reader 통합·파싱 복구·저장·삭제·restart 기여로 각 기능 Story와 2.9에서 추적한다. Brief/snapshot 추가 후 전체 범위의 통합 완료 책임은 Epic 3에 유지한다. UX-DR3/15~18/25는 언어·Translation·SentenceMatch·PaperChat·Anchor·Session으로 연결하고 UX-DR26의 Session warning을 2.8에서 완결한다. 공통 접근성·복구·copy와 Reader/Outline/Status 확장은 해당 Story 및 공통 UX 조건에 적용한다. NFR-005~006의 정확도 비보장·근거 부족·Anchor, NFR-007~010의 기존 저장·삭제·secret·외부 요청 경계는 계속 적용하며 새로운 사용자 고지나 consent를 만들지 않는다.

## Epic 3: 근거 있는 Brief와 재사용 Template으로 연구 기록 남기기

사용자는 자동 생성된 Markdown Brief를 Reader Drawer와 독립 화면에서 읽고, 자신의 Template을 편집해 명시적으로 재생성하며, 실패해도 기존 결과를 보존할 수 있다. Epic 1·2의 실제 구현을 선행으로 자동 Brief·Reader Drawer·사용자 Template·명시적 재생성·기록 재방문·전체 삭제 및 복구까지 완결한다.

**공통 구현 경계:** 각 Story 구현에는 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다. 기존 Application·persistence·Job·EvidenceAnchor·삭제 saga를 재사용한다. 새 데이터의 실패·재실행·삭제 지원은 해당 Story에서 구현하며 마지막 통합 검증까지 미루지 않는다. Provider 요청은 P-3의 Brief allowlist·공통 EvidenceBundle·수치 budget을 준수하고 임의 Note·workspace·무제한 Template/history를 전달하지 않는다. Template은 Paper-independent, generation snapshot과 Brief 결과는 Paper-owned다. 문서 승인은 구현 완료나 기술 게이트 통과가 아니다.

### Story 3.1: Paper 추가 후 기본 Brief를 생성하고 독립 화면에서 읽기

As a 논문 독자,
I want 추가한 논문의 기본 Brief를 자동으로 받고,
So that 구조화된 연구 기록과 원문 근거를 확인할 수 있다.

**Acceptance Criteria:**

**Given** 사용자가 Paper 추가를 확정했을 때,
**When** 기본 Brief 작업을 등록하면,
**Then** 기본 Template 버전·항목·프롬프트와 그 시점에 확정된 생성 입력을 Paper-owned immutable snapshot으로 캡처하고 자동 pending Job을 생성한다.
**And** usable extraction 전에는 요청을 전송하지 않으며 PDF 준비·Reader 진입은 기다리지 않는다.

**Given** extraction과 Provider가 준비됐을 때,
**When** 실제 Brief 요청을 실행하면,
**Then** dispatch 전에 Application이 최초 캡처한 Template·입력 값과 하나의 extraction revision에 pin된 공통 EvidenceBundle·실행 입력을 value-copy한 완전한 Paper-owned immutable generation snapshot을 새 identity/hash로 생성하고, 현재 Job 입력 버전·새 attempt와의 연결을 원자적으로 확정한다.
**And** 이미 생성된 snapshot을 수정하지 않으며 payload는 이 완전한 snapshot만 읽는다. Adapter가 live Template나 다른 active revision에서 입력·근거를 다시 읽지 않는다.
**And** 대기 중 Template 편집·Retry Parsing·재실행은 최초 캡처한 Template/provenance를 바꾸지 않는다. 실행 입력이 아직 봉인되지 않았다면 그 캡처 값을 보존해 준비 후 봉인하고, 이미 봉인된 입력을 사용한 attempt의 Retry는 새 attempt/fence로 동일한 입력을 사용하며 revision을 몰래 바꾸지 않는다. 봉인된 revision이 더 이상 유효하지 않으면 typed 실패로 처리하고 입력 변경은 명시적 새 생성·재생성으로만 수행한다.
**And** snapshot identity/hash는 완전한 실행 입력을 유일하게 식별하며 결과에는 해당 identity/hash·extraction revision·Provider config/result version·Paper generation을 기록한다. snapshot 생성·Job/attempt 연결 실패 또는 중단은 부분 입력의 dispatch를 허용하지 않는다.

**Given** 기본 Brief 결과가 반환됐을 때,
**When** 구조화된 Markdown을 표시하면,
**Then** 문제, 기존 방법 한계, 제안 방법, 논문 명시 한계, AI 분석 한계, 추가 최적화 가능성, 방법의 장점과 한계의 일곱 항목을 명확히 구분한다.
**And** 누락은 `missing-content`로 구분하고 논문 명시 내용과 AI 분석을 혼동하지 않는다.

**Given** 완료 Brief의 논문 주장이 있을 때,
**When** 독립 Brief 화면에서 근거를 확인하면,
**Then** 검증된 Anchor와 원문 preview를 제공하고 activation 시 Reader의 PDF 페이지·문장 강조로 이동한다.
**And** 근거 부족·위치 불명·이동 실패·stale revision을 성공으로 표시하지 않는다.

**Given** 요청 실패·앱 중단·Paper 삭제가 발생할 때,
**When** 복구하거나 늦은 결과가 도착하면,
**Then** 실제 상태·이유·가능한 explicit Retry를 제공한다.
**And** snapshot·Brief·Agent 임시 상태를 기존 삭제 경계에 포함하고 삭제한 결과를 부활시키지 않는다.

**범위:** 기본 Template, 자동 Job, immutable snapshot, 실제 생성, 독립 BriefView와 공통 Anchor 재사용. Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 사용자 Template 편집·기존 Paper 일괄 자동 생성·정확도 보장은 없다. 기존 Paper도 이후 명시적 생성 경로에서 사용할 수 있어야 하며 현재 자동 생성·독립 읽기는 미래 Story에 의존하지 않는다.

**추적/위험:** FR-020/021/024, FR-007/011/032~034의 Brief 기여, UX-DR20/18, AD-3/8/10/14.

### Story 3.2: PDF 맥락을 유지하며 Brief Drawer 열기

As a 논문 독자,
I want PDF를 읽던 위치에서 Brief를 열고 닫으며,
So that 원문과 연구 기록을 오가도 읽기 맥락을 잃지 않을 수 있다.

**Acceptance Criteria:**

**Given** Reader에서 Paper를 읽고 있을 때,
**When** Brief edge trigger로 Drawer를 열면,
**Then** 같은 Paper의 Markdown Brief와 실제 생성 상태를 표시하며 현재 PDF 페이지를 바꾸지 않는다.

**Given** Drawer 안에서 Anchor를 확인할 때,
**When** hover/focus 또는 activation을 실행하면,
**Then** 독립 화면과 동일한 preview·PDF 이동·실패 상태 계약을 사용한다.
**And** 명시적 Anchor 이동 외에는 페이지를 변경하지 않는다.

**Given** Drawer를 닫을 때,
**When** 닫기 또는 Escape를 실행하면,
**Then** Reader의 현재 읽기 맥락과 opener focus로 돌아온다.
**And** Anchor 이동 후라면 이동한 위치를 임의로 되돌리지 않는다.

**Given** 생성 중·실패·재생성 중 또는 기존 usable Brief가 있을 때,
**When** Drawer를 열거나 resize하면,
**Then** 실제 상태를 구분하고 기존 결과를 숨기거나 PDF 사용을 막지 않는다.

**범위:** Story 3.1을 선행으로 BriefTrigger·Drawer·공통 BriefView, keyboard/VoiceOver와 focus 복귀를 완결한다. Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** Drawer를 열었다는 이유만으로 새 생성·재시도를 실행하지 않는다. 재생성 기능 추가 전에는 해당 상태를 가짜로 표시하지 않는다.

**추적/위험:** FR-008/024/025, UX-DR19/20/32/33.

### Story 3.3: 독립 사용자 Template을 편집하고 저장하기

As a 논문 독자,
I want 재사용할 Markdown 항목과 프롬프트를 편집하고,
So that 논문마다 원하는 연구 기록 구조를 사용할 수 있다.

**Acceptance Criteria:**

**Given** Settings의 dedicated Template editor를 열었을 때,
**When** 사용자 Template을 만들거나 편집하면,
**Then** Markdown 섹션 추가·수정·삭제와 프롬프트 편집을 제공한다.

**Given** 유효한 편집 내용을 저장할 때,
**When** 저장 transaction이 성공하면,
**Then** 새 immutable Template version을 생성하고 current pointer만 갱신한다.
**And** 기존 version을 덮어쓰지 않는다.

**Given** validation 또는 저장 실패가 발생할 때,
**When** editor에 결과를 표시하면,
**Then** 오류와 다음 행동을 제공하고 편집 내용을 보존한다.
**And** 실패한 내용을 저장된 version처럼 표시하지 않는다.

**Given** 저장된 사용자 Template이 있을 때,
**When** 앱을 재실행하거나 관련 Paper를 삭제하면,
**Then** Template과 version은 관리 화면에서 유지된다.
**And** Paper 삭제 cascade에 포함하지 않는다.

**범위:** 실제 editor·저장·버전 보존. validation·허용 크기·입력 규칙은 공통 한도와 해당 Build Spec에서 명시한다. Epic 1·2 기반 및 Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 저장만으로 Brief 생성·재생성을 실행하거나 과거 Brief provenance를 수정하지 않는다.

**추적/위험:** FR-023, UX-DR24/38, AD-6/14.

### Story 3.4: Template을 선택하고 snapshot으로 Brief 생성·재생성하기

As a 논문 독자,
I want 기본 또는 사용자 Template을 선택해 명시적으로 생성하고,
So that 기존 결과를 보존하면서 원하는 구조의 Brief로 갱신할 수 있다.

**Acceptance Criteria:**

**Given** Brief 화면이나 Drawer에서 Template을 선택할 때,
**When** 기본/사용자 Template을 선택하거나 관리 editor를 열면,
**Then** 현재 선택을 표시한다.
**And** editor 저장 성공 후 저장한 사용자 Template의 새 current version을 선택한 상태로 originating Brief에 복귀하며 자동 재생성하지 않는다. 저장 실패·취소는 새 version을 선택한 성공 상태로 표시하지 않는다.
**And** 선택 변경이나 editor 저장은 기존 Brief의 snapshot/provenance를 변경하지 않는다.

**Given** 새 Paper 또는 기존 Paper에 생성 가능한 extraction이 있을 때,
**When** 사용자가 생성·재생성을 확정하면,
**Then** 선택한 version ID·Markdown sections·prompts·generation inputs를 transactionally value-copy한 Paper-owned snapshot과 ordered regeneration version·Job을 만든다.

**Given** 생성 중 live Template이 수정됐을 때,
**When** payload를 만들거나 결과 provenance를 읽으면,
**Then** 캡처한 snapshot만 사용한다.
**And** 이후 Template 편집으로 이전 입력·Brief의 provenance를 변경하지 않는다.

**Given** 재생성이 성공·실패하거나 역순으로 완료될 때,
**When** current Brief를 갱신하면,
**Then** 여전히 current인 fenced regeneration의 성공만 pointer를 이동한다.
**And** 실패·stale 결과는 prior usable Brief를 교체하지 않는다.

**Given** 재생성 중 앱 중단·Provider 변경·Paper 삭제가 발생할 때,
**When** 복구하거나 결과가 도착하면,
**Then** 입력 버전·config generation·attempt/fence·Paper generation을 검증한다.
**And** 실제 `regenerating`·`failed-with-prior`·ready 상태와 가능한 Retry를 표시하고 자동 중복 전송하지 않는다.

**범위:** Story 3.1~3.3을 선행으로 TemplateSelector·editor 왕복·명시적 생성·snapshot·winner 검증·기존 결과 보존을 완결한다. 기존 Paper의 생성도 포함한다. Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** Template 선택/저장만으로 생성하거나 모든 과거 Paper를 일괄 재생성하지 않는다.

**추적/위험:** FR-022/023, UX-DR20/23/24/35, AD-10/14.

### Story 3.5: Brief와 연구 기록을 Library에서 다시 확인하기

As a 논문 독자,
I want Brief를 다른 읽기 기록과 함께 다시 찾고,
So that 앱을 다시 열어도 축적한 연구 맥락을 이어갈 수 있다.

**Acceptance Criteria:**

**Given** Brief·Highlight·Note·Reading Status·마지막 읽은 위치가 저장됐을 때,
**When** Library 또는 Paper 세부 기록에 재진입하면,
**Then** 해당 Paper에 연결된 기록과 현재 Brief 상태를 확인할 수 있다.

**Given** 완료 Brief가 있을 때,
**When** 독립 화면 또는 Reader Drawer로 열면,
**Then** 같은 current result와 provenance를 사용하고 재방문만으로 재생성하지 않는다.

**Given** Brief가 없거나 pending·missing-content·failed-with-prior 상태일 때,
**When** 기록을 표시하면,
**Then** 빈 성공으로 표시하지 않는다.
**And** 기존 usable Brief가 있으면 계속 읽을 수 있다.

**Given** 앱 재실행 또는 Paper 삭제가 발생할 때,
**When** 기록을 복원하면,
**Then** durable 기록을 복원하되 삭제한 Paper의 Brief·snapshot·위치·Note를 재진입시키지 않는다.
**And** 개인 Note를 AI 근거로 표시하지 않는다.

**범위:** Story 3.4를 선행으로 Library 기록에 Brief를 통합하고 독립 화면·Drawer의 동일 결과를 검증한다. Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 새로운 Note 검색·지식 그래프·자동 연구 추천은 없다.

**추적/위험:** FR-029, FR-020/025의 재방문, UX-DR7/8/20/35, SM-004.

### Story 3.6: 모든 Paper 소유 데이터를 삭제하고 Template 보존하기

As a 논문 독자,
I want Paper와 그 연구 데이터를 삭제하되 재사용 Template은 남기고,
So that 삭제 범위를 정확히 이해하고 정리를 완료할 수 있다.

**Acceptance Criteria:**

**Given** 모든 v1 Paper 데이터가 있는 논문에서 삭제를 선택할 때,
**When** native confirmation을 표시하면,
**Then** 대상 이름·제품 삭제 범위·irreversible action과 Cancel/Delete를 구분한다.
**And** Cancel은 데이터·읽기·Job 상태를 유지한다.

**Given** 삭제를 확정했을 때,
**When** saga를 실행하면,
**Then** 새 dispatch·writer/publication permit을 차단하고 기존 작업을 취소·drain한다.
**And** Agent purge acknowledgment/verification과 파일 absence·DB cascade를 확인한 뒤에만 완료한다.

**Given** 삭제가 완료됐을 때,
**When** Library 검색·최근 목록·폴더·Reader·Brief·Chat에 재진입하거나 앱을 재실행하면,
**Then** PDF·추출/FTS·Translation·Brief·snapshot·Session·Highlight·Note·읽기 이력·마지막 위치와 기타 Paper 소유 결과를 복원하지 않는다.

**Given** Agent purge·파일 삭제·DB 정리 등 일부 단계가 실패했을 때,
**When** 결과를 표시하거나 Retry Deletion을 실행하면,
**Then** non-openable 삭제 미완료와 동일 idempotent saga의 재시도를 제공한다.
**And** 부분 삭제를 성공으로 표시하거나 일반 AI Retry를 허용하지 않는다.

**Given** 삭제한 Paper가 사용자 Template을 사용했을 때,
**When** 이후 다른 Paper에서 Template을 선택하면,
**Then** 독립 Template/version을 계속 사용할 수 있다.
**And** 늦은 생성 결과·cache scan·재실행으로 삭제한 Paper identity는 부활하지 않는다.

**범위:** Story 3.5를 선행으로 기존 삭제 saga의 전체 v1 데이터·snapshot·Agent 정리 통합 회귀를 검증한다. 앞선 Story의 삭제 구현을 유예하지 않는다. Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 새로운 삭제 작업 화면·accepted-limit 고지·외부 Provider/APFS forensic erasure 보장은 없다.

**추적/위험:** FR-030/031, NFR-007/008, UX-DR26/35, AD-11/14, SM-005.

### Story 3.7: 전체 연구 흐름의 Job·파싱·재실행 복구 완결하기

As a 논문 독자,
I want Import부터 Brief까지 실패와 재실행 상태가 일관되며,
So that 사용할 수 있는 결과를 유지하고 필요한 작업만 복구할 수 있다.

**Acceptance Criteria:**

**Given** Import·parsing·Translation·Chat 준비/요청·Brief가 함께 존재할 때,
**When** Library와 Reader의 상태를 표시하면,
**Then** pending/running/succeeded/failed와 각 기능 가용성을 구분한다.
**And** AI가 늦어져도 PDF 준비 후 Open Reader를 제공한다.

**Given** parsing 실패와 Retry Parsing이 발생할 때,
**When** 실패·성공을 반영하면,
**Then** PDF는 유지하고 extraction-dependent 생성은 이유와 함께 비활성화한다.
**And** 성공 후 기존 정책에 따라 필요한 AI 준비를 이어가되 ambiguous 외부 요청을 몰래 재전송하지 않는다.

**Given** 하나의 Job이 실패했을 때,
**When** 사용자가 다른 기능을 사용하면,
**Then** PDF·완료 번역·기존 Brief·저장 대화 등 usable 결과를 유지한다.
**And** 실패한 기능의 이유와 가능한 explicit Retry만 제공한다.

**Given** 앱 종료·재실행·Provider 변경이 발생할 때,
**When** 공통 reconciliation을 실행하면,
**Then** 이전 running attempt를 interrupted 처리하고 old fence를 재개하지 않는다.
**And** 완료 결과·실패·Retry 필요 상태와 적용 가능한 다음 행동을 복원한다.

**Given** 네 Import 경로·두 Provider·복수 Session·Template 편집·재생성·삭제 시나리오를 실행할 때,
**When** 성공·취소·실패·재실행 경로를 검증하면,
**Then** 실제 native 동작으로 전체 read→evidence→organize→revisit 흐름을 확인한다.
**And** 정적 mockup이나 기능 수 완료율로 실패를 가리지 않는다.

**범위:** Story 3.1~3.6을 선행으로 모든 v1 데이터/Job 유형의 누적 통합 검증을 수행한다. 각 기능의 개별 복구·삭제 검증은 계속 해당 Story 책임이다. Epic 3 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 테마 여섯 조합·공개 설치 산출물·release-ready 판정은 포함하지 않는다.

**추적/위험:** FR-007/008/011/032~034, UX-DR6/34/35/37, SM-001~005, CM-001~003.

### Epic 3 공통 UX 완료 조건

각 화면·기능 Story에 함께 적용한다.

- keyboard/VoiceOver로 Template 편집·선택·저장·재생성·Anchor·Drawer·Retry/Delete 사용.
- dialog/Drawer focus 진입, Escape 닫기, opener 복귀.
- 실제 배경의 대비·색 외 상태 신호·한국어 wrapping·native text scaling·resize 검증. 기존 UX 대비 floor를 유지한다.
- 짧은 한국어 상태와 다음 행동, 정확도·privacy·삭제에 대한 거짓 보장 금지.
- Template validation·modal 중첩·최소 창·Reduce Motion 등 열린 세부사항은 해당 Build Spec에 명시.

### Epic 3 분해 검토 결과

사용자가 Story 3.1~3.7과 공통 조건을 일괄 승인했다. 이는 분해 문서의 범위·인수 조건 승인이지 구현 완료·IMPLEMENTATION 승인·기술 게이트 통과가 아니다. 이후 사용자의 명시적 진행 지시에 따라 Epic 4 일괄 분해·검토로 진행했다.

| Epic 3 완료 책임 FR | 승인된 Story |
| --- | --- |
| FR-007 | 3.1, 3.7 |
| FR-008 | 3.2, 3.7 |
| FR-011 | 3.1, 3.7 |
| FR-020 | 3.1 |
| FR-021 | 3.1 |
| FR-022 | 3.1, 3.4 |
| FR-023 | 3.3, 3.4, 3.6 |
| FR-024 | 3.1, 3.2 |
| FR-025 | 3.2 |
| FR-029 | 3.5 |
| FR-030 | 각 데이터 Story, 3.6 |
| FR-031 | 각 데이터 Story, 3.6 |
| FR-032 | 각 Job Story, 3.7 |
| FR-033 | 각 Job Story, 3.7 |
| FR-034 | 각 Job Story, 3.7 |

FR-007/008/011/029~034의 전체 범위 통합은 Epic 1·2의 기존 기능에 Brief/snapshot을 추가해 검증하는 책임이다. 앞선 Epic의 실패·복구·삭제 완료를 유예하지 않는다. UX-DR19~20/23~24는 BriefTrigger/View·TemplateSelector/Editor로 연결하며 공통 Anchor와 접근성·복구·copy 계약을 재사용한다. NFR-005~006의 정확도 비보장·근거 부족·Anchor, NFR-007~010의 저장·전체 삭제·secret·외부 요청 경계를 유지한다. Paper-independent Template/version과 Paper-owned snapshot/result의 소유권을 별도로 검증한다.

## Epic 4: 읽기 맥락을 유지하며 테마와 명암 선택하기

사용자는 세 테마와 System/Light/Dark를 독립적으로 선택하고 앱을 다시 열어도 유지하며, 어떤 조합에서도 동일한 읽기·근거·오류 복구 동작을 사용할 수 있다. 완료 책임은 FR-037~039다. Epic 1~3의 실제 화면·데이터·Job을 기반으로 검증하며 초기 Native Canvas·semantic token 도입을 이 Epic까지 미루지 않는다.

**공통 구현 경계:** Story별 governing Issue·task branch·Build Spec 커밋 SHA의 별도 명시적 IMPLEMENTATION 승인이 필요하다. 설정은 기존 Application/persistence가 소유하는 Paper-independent 상태다. 각 Story에서 저장 실패·재실행·맥락 보존·Job 불변성을 검증한다. 원본 PDF의 내용·글꼴·파일은 변경하지 않는다. 정적 HTML 시안은 native 동작·접근성 검증을 대신하지 않는다. 문서 승인은 구현 완료나 기술 게이트 통과가 아니다.

### Story 4.1: 독립적인 System·Light·Dark 명암 정책 선택하기

As a 논문 독자,
I want 앱 명암을 시스템에 따르게 하거나 직접 선택하고,
So that 원하는 읽기 환경을 유지할 수 있다.

**Acceptance Criteria:**

**Given** 저장된 명암 정책이 없는 새 설치에서,
**When** 앱을 실행하면,
**Then** System을 기본으로 적용하고 현재 macOS 명암을 따른다.

**Given** Settings에서 명암을 선택할 때,
**When** System·Light·Dark를 변경하면,
**Then** 현재 정책을 표시하고 앱 전체에 반영한다.
**And** 테마 선택은 변경하지 않는다.

**Given** macOS 명암이 변경될 때,
**When** 앱이 변경을 관찰하면,
**Then** System에서만 반영한다.
**And** 명시적 Light/Dark는 유지한다.

**Given** 선택을 저장한 뒤 앱을 재실행할 때,
**When** 설정을 복원하면,
**Then** 직전 렌더링 색상이 아니라 정책을 복원한다.
**And** System은 현재 OS 명암을 다시 따른다.

**Given** 저장 실패 또는 Paper 삭제가 발생할 때,
**When** 설정 상태를 표시하거나 복원하면,
**Then** 저장 실패를 성공으로 표시하지 않고 실제 적용·저장 상태와 다음 행동을 구분한다.
**And** Paper 삭제는 명암 설정을 제거하지 않는다.

**범위:** AppearancePicker·OS 관찰·명시적 override·정책 저장. 현재 Native Canvas의 Light/Dark 화면을 실제로 검증한다. 저장 실패의 적용/복원 방식은 Build Spec에서 명시한다. Epic 4 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 명암 변경에 따른 Import·parsing·Translation·Chat·Brief 생성/Retry, 원본 PDF restyle은 없다.

**추적/위험:** FR-038/039, UX-DR28/38, AR-026.

### Story 4.2: 세 테마를 선택하고 앱 전체에 유지하기

As a 논문 독자,
I want Native Canvas·Scholarly Press·Focused Instrument를 선택하고,
So that 같은 연구 기능을 선호하는 시각 환경에서 사용할 수 있다.

**Acceptance Criteria:**

**Given** 저장된 테마가 없는 새 설치에서,
**When** 앱을 실행하거나 Settings를 열면,
**Then** Native Canvas를 기본으로 적용하고 세 테마 이름·현재 선택을 표시한다.

**Given** 사용자가 테마를 변경할 때,
**When** 선택이 적용되면,
**Then** Reader·Library·Brief·Settings와 Onboarding·Import·Template·dialog 등 제공되는 화면에 일관되게 반영한다.
**And** Native Canvas로 되돌릴 수 있다.

**Given** 각 테마를 Light/Dark로 표시할 때,
**When** 대응 semantic style을 적용하면,
**Then** Native Canvas의 따뜻한 matte/system chrome, Scholarly Press의 serif·제한 mono·firm rule/paper tone, Focused Instrument의 차가운 tonal 단계·fine border·조밀한 metadata 방향을 유지한다.

**Given** 테마를 저장하거나 명암 정책을 변경할 때,
**When** 앱을 재실행하면,
**Then** 테마와 명암을 각각 복원한다.
**And** 어느 선택도 다른 설정을 덮어쓰지 않는다.

**Given** 테마 저장 실패 또는 Paper 삭제가 발생할 때,
**When** 상태를 표시하거나 복원하면,
**Then** 저장 성공을 위장하지 않고 실제 상태와 다음 행동을 제공한다.
**And** Paper 삭제 후에도 테마 설정은 유지된다.

**범위:** Story 4.1을 선행으로 ThemePicker·세 테마의 전 화면 적용·Light/Dark·독립 저장을 완결한다. native semantic text role과 한국어 fallback을 사용한다. Epic 4 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 네 번째 혼합 테마·glossy 장식·theme editor/marketplace·HTML CSS의 그대로 이식은 없다.

**추적/위험:** FR-037~039, UX-DR27/30, AR-026, R-009.

### Story 4.3: 테마·명암 전환 중 읽기 맥락과 작업 보존하기

As a 논문 독자,
I want 시각 설정을 바꿔도 읽던 논문과 연구 작업이 유지되며,
So that 스타일 변경 때문에 연구 흐름이 끊기지 않을 수 있다.

**Acceptance Criteria:**

**Given** Reader에서 Paper·PDF 페이지·Chat Session을 열고 있을 때,
**When** 테마 또는 명암을 바꾸면,
**Then** 같은 Paper·페이지·Session을 유지하고 기존 Note·Highlight·Brief를 계속 사용할 수 있다.

**Given** Drawer·dialog·번역 대조·검색 또는 입력 중인 UI가 있을 때,
**When** 시각 설정을 전환하면,
**Then** 전환만으로 읽기·입력·선택 맥락이나 유효한 focus를 잃지 않는다.
**And** 창 resize·text scaling도 상태를 초기화하지 않는다.

**Given** Import·parsing·Translation·Chat·Brief Job이 진행·실패·완료 상태일 때,
**When** 테마·명암 또는 System 상태의 OS 명암이 바뀌면,
**Then** Job identity·입력·결과·Retry 필요 상태를 유지한다.
**And** 새 작업·중복 요청·자동 Retry를 생성하지 않는다.

**Given** 원본 PDF가 있을 때,
**When** 모든 테마·명암 전환을 실행하면,
**Then** 앱 chrome과 Translation 등 표시 스타일만 변경되고 PDF 원본 내용·글꼴·파일 hash는 유지된다.

**Given** 설정 변경과 Paper 삭제·늦은 AI 응답이 경합할 때,
**When** 화면을 갱신하거나 재실행하면,
**Then** 기존 삭제·publication 규칙을 유지한다.
**And** 테마 전환으로 삭제한 Paper나 stale 결과를 다시 공개하지 않는다.

**범위:** Story 4.2를 선행으로 실제 기존 화면·Job·데이터를 이용한 전환 불변성 검증과 발견된 전환 결함을 수정한다. 앞선 Story에서도 이 불변성을 지켜야 한다. Epic 4 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 새로운 작업 runner·설정별 데이터 복제·시각 전환을 근거로 한 재생성은 없다.

**추적/위험:** FR-038/039, UX-DR32/35, SM-007, AR-026.

### Story 4.4: 여섯 테마 조합의 가독성·접근성·복구 검증

As a 논문 독자,
I want 어느 테마와 명암에서도 같은 기능과 상태를 식별하고,
So that 스타일 선택에 따라 근거 확인이나 복구 기능을 잃지 않을 수 있다.

**Acceptance Criteria:**

**Given** 세 테마×Light/Dark의 여섯 조합이 있을 때,
**When** 주요 화면과 상태를 검증하면,
**Then** 텍스트·컨트롤·선택·진행·오류·삭제 미완료를 식별할 수 있다.
**And** normal text는 4.5:1, large text·meaningful non-text·focus는 3:1 이상 대비를 실제 배경에서 확인한다.

**Given** SentenceMatch와 Chat/Brief Anchor를 사용할 때,
**When** hover·keyboard focus·activation을 실행하면,
**Then** 모든 조합에서 양방향 강조·전체 원문 preview·PDF 이동이 동일하게 동작한다.
**And** 불확실성·근거 부족·이동 실패를 성공처럼 표시하지 않는다.

**Given** Job 실패·파싱 실패·삭제 미완료 상태가 있을 때,
**When** Retry·Retry Parsing·Retry Deletion·Cancel/Delete를 사용하면,
**Then** 모든 조합에서 동일한 가용성·복구·삭제 경계를 따른다.
**And** 색만으로 상태를 전달하지 않는다.

**Given** keyboard·VoiceOver·native text scaling·창 resize를 사용할 때,
**When** 화면과 drawer/dialog를 탐색하면,
**Then** label/role/state·읽기 순서·focus 진입/복귀를 유지하고 한국어 텍스트와 연구 맥락이 잘리거나 소실되지 않는다.

**Given** System 정책·명시 Light/Dark·재실행·Paper 삭제를 포함한 SM-007을 실행할 때,
**When** 결과를 판정하면,
**Then** 설정 독립성·OS 반영·맥락/데이터/PDF 보존·새 Job 부재를 확인한다.
**And** 하나라도 실패하면 테마 완료 기준 미통과로 기록한다.

**범위:** Story 4.1~4.3을 선행으로 여섯 렌더링 조합과 System/Light/Dark 세 정책을 구분해 실제 native 검증을 수행한다. 개별 Story의 접근성 구현을 이 단계까지 미루지 않는다. Epic 4 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** palette 계산·정적 HTML 검사만으로 전체 통과를 주장하거나 public release-ready로 판정하지 않는다.

**추적/위험:** FR-037~039, UX-DR27~33/35~38, SM-007, R-009.

### Epic 4 분해 검토 결과

사용자가 Story 4.1~4.4와 공통 조건을 일괄 승인했다. 이는 분해 문서의 범위·인수 조건 승인이지 구현 완료·IMPLEMENTATION 승인·기술 게이트 통과가 아니다. 이후 사용자의 명시적 진행 지시에 따라 Epic 5 일괄 분해·검토로 진행했다.

| Epic 4 완료 책임 FR | 승인된 Story |
| --- | --- |
| FR-037 | 4.2, 4.4 |
| FR-038 | 4.1~4.3, 4.4 |
| FR-039 | 4.1, 4.2, 4.4 |

UX-DR27/28/30의 ThemePicker·AppearancePicker·semantic styles는 4.1~4.2, UX-DR31~33/35~38의 대비·resize·접근성·복구·copy·열린 세부 결정은 각 Story와 4.3~4.4에서 추적한다. AR-026의 기존 Application/persistence 소유권과 Paper-independent 설정을 유지하며 SM-007의 모든 조건을 실제 native 검증 대상으로 한다. 전체 공개 산출물 및 release-ready 판정은 Epic 5에 남는다.

## Epic 5: 두 Mac 아키텍처에서 설치하고 전체 연구 흐름 사용하기

사용자는 macOS 15+ arm64 또는 x86_64 공개 산출물을 설치·실행하고 Provider를 연결해 전체 v1 흐름을 사용할 수 있으며 수동 앱 교체 후에도 지원되는 데이터 경계를 따른다. 완료 책임은 FR-035/036이며 Epic 1~4의 실제 기능을 최종 배포 후보에서 검증한다.

**공통 구현 경계:** 각 Story에는 별도 governing Issue·task branch·Build Spec 커밋 SHA의 명시적 IMPLEMENTATION 승인이 필요하다. P-1/P-2/P-3의 초기 증거를 재사용하되 최종 산출물의 검증을 생략하지 않는다. P-4 정책 확정 전 public release plan, P-5 통과 전 schema-bearing public release를 확정하지 않는다. P-6의 기존 timing 계약을 유지한다. 계획·Story 승인은 Push·PR·공개 업로드·배포·merge 지시가 아니다. 배포 채널은 direct Developer ID, 업데이트는 수동 앱 교체이며 App Store·updater·telemetry·cloud recovery는 없다.

**승인된 CPU 실행 배치:** arm64는 현재 Mac에서 빌드·로컬 검증하고 x86_64 빌드·패키징은 GitHub Actions에 위임한다. 실제 사용 가능한 Intel macOS runner, 고정 Xcode/SDK·runtime, signing/notary secrets 제공 여부를 Build Spec에서 확인한다. hosted runner가 필요한 조건을 충족하지 못하면 Intel self-hosted runner 또는 별도 Intel Mac을 사용하며 둘 다 없으면 차단 상태로 기록한다. 이는 제품 fallback이 아니라 검증 실행 환경의 선택이며 동일 locks/contracts/OS matrix 조건을 완화하지 않는다. Apple Silicon cross-build 성공은 실제 Intel 실행 검증을 대체하지 않는다. 원격 실행은 별도 명시적 지시와 승인 경계를 유지한다. 현재 단계에서는 CI 구현·실행을 하지 않는다.

### Story 5.1: 안전한 로컬 diagnostics 정책 확정·검증

As a 논문 독자,
I want 문제 진단 과정에서도 논문과 연결 정보가 진단 자료에 섞이지 않으며,
So that 안전한 오류 정보로 지원받을 수 있다.

**Acceptance Criteria:**

**Given** 공개 배포를 준비할 때,
**When** Application/Release의 P-4 정책을 확정하면,
**Then** 로컬 diagnostic 위치·보존 기간·사용자 export 방식·redaction·삭제 정책을 명시한다.
**And** 미결정 항목을 통과로 표시하지 않는다.

**Given** 성공·실패·취소·crash 진단 경로가 있을 때,
**When** diagnostic projection을 생성하면,
**Then** safe-code 정보만 사용한다.
**And** secret·raw URL·argv/environment·request/response·EvidenceBundle·생성 결과·문서 내용·raw process stream은 포함하지 않는다.

**Given** 민감 marker를 넣은 검증 시나리오를 실행할 때,
**When** 로컬 자료와 export 결과를 검사하면,
**Then** 금지 데이터가 없음을 확인한다.
**And** redaction 실패를 정상 diagnostic으로 내보내지 않는다.

**Given** 확정한 보존·삭제 조건에 도달했을 때,
**When** 정리 또는 export 실패를 처리하면,
**Then** 정책대로 동작하고 실패를 완료로 위장하지 않는다.
**And** telemetry backend나 자동 외부 전송을 추가하지 않는다.

**범위:** P-4 결정·정책 구현·실제 누출 방지 검증. 기존 기능의 safe diagnostic 제약은 계속 적용한다. Epic 5 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 새 개인정보 고지·accepted-limit disclosure·원문 로그를 통한 디버깅 우회는 없다.

**추적/위험:** P-4, AD-2/4, AR-022, NFR-009/010.

### Story 5.2: 앱 교체와 DB 호환·손상 경계 확정·검증

As a 논문 독자,
I want 앱을 교체할 때 지원되는 데이터 경계를 명확히 따르고,
So that 호환되지 않는 DB를 잘못 열거나 기록을 잃지 않을 수 있다.

**Acceptance Criteria:**

**Given** schema-bearing 공개 배포 전,
**When** Persistence/Release의 P-5 정책을 확정하면,
**Then** 지원 upgrade·downgrade/rollback 범위와 incompatible schema·corruption의 fail-closed 동작을 명시한다.
**And** 지원하지 않는 복구를 가능하다고 표시하지 않는다.

**Given** 지원되는 기존 DB fixture가 있을 때,
**When** 수동 앱 교체 후 실행하면,
**Then** 단일 ordered migration registry로 transactional forward migration을 수행한다.
**And** 중간 실패를 완료 migration으로 기록하지 않는다.

**Given** incompatible schema·durable DB 손상·migration 실패가 있을 때,
**When** 앱을 실행하면,
**Then** 확정한 정책대로 fail-closed하고 안전한 이유·지원되는 다음 행동을 제공한다.
**And** durable 데이터를 조용히 초기화하거나 cache에서 복원하지 않는다.

**Given** regenerable cache 손상과 durable 데이터가 구분될 때,
**When** 정리를 수행하면,
**Then** 허용된 cache만 재구축한다.
**And** 삭제한 Paper identity나 tombstone을 재활성화하지 않는다.

**Given** 앱 교체 전 Provider 설정·완료 결과·중단 Job이 있을 때,
**When** 교체 후 시작하면,
**Then** 기존 설정·Job reconciliation과 Agent startup purge를 적용한다.
**And** old fence를 재개하거나 시스템 Python/CLI로 우회하지 않는다.

**범위:** P-5 정책과 지원 fixture의 실제 교체·migration·실패 검증. Epic 5 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** updater·cloud backup/recovery·임의 backward compatibility 계층은 없다.

**추적/위험:** P-5, AD-6/10/11/13, FR-034/035, NFR-007/008.

### Story 5.3: 두 CPU의 self-contained 서명 배포 후보 만들기

As a macOS 논문 독자,
I want 내 CPU에 맞는 독립 실행 가능한 앱을 설치하고,
So that 개발 도구를 별도로 설치하지 않고 PaperLens를 사용할 수 있다.

**Acceptance Criteria:**

**Given** 최종 source와 release lock이 있을 때,
**When** arm64·x86_64 후보를 빌드하면,
**Then** 동일 source commit·dependency lock·RPC/Evidence/extraction 계약·migration registry·entitlements policy·smoke corpus를 사용한다.
**And** CPU별 binary 차이 외 계약 drift를 허용하지 않으며 arm64는 현재 Mac, x86_64는 승인된 GitHub Actions 실행 배치로 빌드·패키징한다.

**Given** Main App·PDFium XPC·Provider Agent·Python/SDK/CLI와 nested code가 있을 때,
**When** generated inventory를 검증하면,
**Then** 모든 executable의 identity·entitlements·App Sandbox·hardened runtime을 확인하고 unexpected/unsigned code를 거부한다.

**Given** 두 산출물의 signing을 수행할 때,
**When** inside-out signing·sealed-bundle verification·notarization·staple/validate를 실행하면,
**Then** 각 산출물의 성공 증거를 기록한다.
**And** signing/notary credentials는 bundle·로그에 포함하지 않는다.

**Given** 개발 환경 의존성이 없는 clean machine에서,
**When** Gatekeeper launch와 Provider/PDF 경로를 실행하면,
**Then** packaged runtime만 사용한다.
**And** 설치된 Python·CLI fallback이나 app container/group 공유가 없다.

**Given** 최소 macOS 15와 현재 지원 OS×두 CPU matrix가 있을 때,
**When** packaged DB open/migration·FTS5 create/query/delete와 Agent purge smoke를 실행하면,
**Then** 각 지점의 OS·Xcode/SDK·SQLite·artifact provenance를 기록한다.
**And** Provider 성공/실패·restart·앱 교체·Paper 삭제 후 marker-content absence/purge를 확인한다. Actions 빌드 성공만으로 실제 Intel 실행·clean-machine Gatekeeper·전체 OS matrix 통과를 인정하지 않는다.

**범위:** Story 5.1~5.2와 P-1/P-2/P-3의 해당 실제 통과를 선행으로 실제 최종 signed/notarized 배포 후보와 CPU/OS parity 증거를 만든다. Intel runner·도구·secret 가용성은 Build Spec에서 확인하고 부족한 환경은 차단한다. Epic 5 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** universal binary·App Store·공개 업로드 실행은 없다. 시스템 runtime으로 packaged runtime 결함을 숨기지 않는다.

**추적/위험:** FR-035, AD-2/6/13, P-1/P-2, SM-006.

### Story 5.4: 설치·Provider 연결·라이선스 안내 완결하기

As a 새 사용자,
I want 설치 방법과 첫 연결 절차, 오픈소스 정보를 확인하고,
So that 지원되는 환경에서 앱을 시작할 수 있다.

**Acceptance Criteria:**

**Given** 두 CPU의 배포 후보가 있을 때,
**When** 공개용 안내를 작성하면,
**Then** macOS 15+·CPU별 산출물 선택·실행·수동 앱 교체 방법이 실제 후보와 일치한다.

**Given** 첫 실행 Provider 설정이 필요할 때,
**When** 안내를 따라 실행하면,
**Then** API key와 공식 ChatGPT browser/device-code 경로 및 실제 연결 테스트·Retry·explicit Continue 흐름을 확인할 수 있다.

**Given** 앱과 배포용 자료를 검토할 때,
**When** 라이선스·source·dependency notices를 확인하면,
**Then** 확정된 AGPL-3.0-only와 필요한 source/notices가 산출물·저장소 안내와 일치한다.

**Given** v1 기능·보안·삭제 문구를 검토할 때,
**When** UI와 공개 설명을 대조하면,
**Then** 추천·지식 그래프·로컬 모델·cloud sync를 v1 기능처럼 약속하지 않는다.
**And** 거짓 정확도/privacy/forensic deletion 보장이나 새 consent·accepted-limit 고지를 추가하지 않는다.

**범위:** Story 5.3을 선행으로 기존 안내·배포용 자료·앱 copy의 실제 기능 및 라이선스 일치를 검증한다. Epic 5 공통 IMPLEMENTATION 승인·검증 경계를 적용한다.

**비목표/후속 의존성:** 이 Story 승인만으로 문서 push·PR·공개 게시를 하지 않는다.

**추적/위험:** FR-035/036, UX-DR36, AD-4/11/13, SM-006.

### Story 5.5: 최종 산출물에서 전체 연구 흐름 검증하기

As a 논문 독자,
I want 설치한 앱에서 논문 추가부터 기록 재방문·삭제까지 사용할 수 있으며,
So that 기능 목록이 아니라 완결된 연구 도구를 사용할 수 있다.

**Acceptance Criteria:**

**Given** 두 CPU의 최종 후보와 지원 OS matrix에서,
**When** UJ-1~4의 검증 corpus를 실행하면,
**Then** 네 Import 경로·두 Provider 경로·PDF·Translation·whole-paper Chat·Anchor·Brief·Note·Library 재방문이 실제로 동작한다.

**Given** Provider/파싱/AI 실패·취소·재실행 시나리오가 있을 때,
**When** 복구를 수행하면,
**Then** 이유·explicit Retry·prior usable 결과·PDF 가용성을 유지한다.
**And** 가짜 완료나 ambiguous 자동 재전송은 없다.

**Given** 복수 Session·Template 편집·재생성 경합이 있을 때,
**When** 저장·재방문·역순 완료를 검증하면,
**Then** Session identity·immutable snapshot/provenance·current winner·기존 Brief 보존을 확인한다.

**Given** 작업 중 Paper 삭제와 Agent purge 실패가 있을 때,
**When** 삭제·동일 saga Retry·재실행을 수행하면,
**Then** 전체 Paper 소유 데이터는 부활하지 않고 독립 Template은 유지된다.
**And** 부분 삭제를 완료로 표시하지 않는다.

**Given** 여섯 테마 조합과 세 명암 정책에서,
**When** SM-007과 keyboard/VoiceOver·resize 검증을 실행하면,
**Then** 동일한 기능·가독성·상태·맥락 보존을 확인한다.
**And** 정적 HTML이나 기능 수 완료율로 실패를 가리지 않는다.

**범위:** Story 5.3~5.4와 Epic 1~4를 선행으로 동일 corpus·expected results로 두 산출물의 UJ-1~4, SM-001~007, CM-001~003을 회귀 검증한다. x86_64 자동 smoke·DB/FTS·Agent purge는 적합한 Actions runner에서 실행하고 artifact hash에 연결한다. GUI·VoiceOver·clean-machine Gatekeeper·지원 OS matrix 중 CI에서 검증할 수 없는 항목은 별도 Intel 환경에서 확인하며 미검증은 차단으로 남긴다. Epic 5 공통 IMPLEMENTATION 승인·원격 실행 경계를 적용한다.

**비목표/후속 의존성:** 앞선 Epic의 결함을 미검증 상태로 인정하거나 이 단계까지 기본 검증을 유예하지 않는다.

**추적/위험:** 전체 FR 회귀, UX-DR37, SM-001~007, CM-001~003.

### Story 5.6: PDF readiness 측정과 초과 사례 판정하기

As a 논문 독자,
I want PDF를 실제로 사용할 수 있는 시점이 일관되게 검증되며,
So that 단순 창 표시를 빠른 읽기 성공으로 오인하지 않을 수 있다.

**Acceptance Criteria:**

**Given** P-6에 고정된 fixture/profile·공통 probe가 있을 때,
**When** 각 source와 두 CPU 후보를 측정하면,
**Then** `ImportAcceptedAt`부터 `FirstInteractivePageAt`까지 동일 계약으로 측정하고 provenance를 기록한다.

**Given** 첫 PDF 페이지가 표시됐을 때,
**When** readiness를 판정하면,
**Then** instrumentation이 시작한 navigation 또는 zoom probe의 main-thread expected visible update 완료 신호를 사용한다.
**And** 수동 입력·think time·control enable·document open을 종료 시점으로 쓰지 않는다.

**Given** arXiv 측정 결과가 있을 때,
**When** 30초 기준을 평가하면,
**Then** soft target으로 보고한다.
**And** AI 생성 시간은 제외하고 단일 초과만으로 자동 실패 또는 무조건 통과로 판정하지 않는다.

**Given** 일반 PDF URL·로컬 PDF 또는 material/repeated 초과 사례가 있을 때,
**When** 결과를 평가하면,
**Then** 승인된 source criteria와 disposition을 적용한다.
**And** 미해결 material/repeated 초과는 release-ready를 차단한다.

**범위:** Story 5.3 및 기존 P-6 실제 통과를 선행으로 최종 후보의 실제 timing 증거·초과 분석·disposition을 추적한다. x86_64는 적합한 Actions Intel runner에서 측정하고 고정 profile 조건을 충족하지 못하면 별도 Intel 환경을 사용하거나 차단한다. CI 성능 결과를 조건 대조 없이 다른 profile의 증거로 사용하지 않는다. Epic 5 공통 IMPLEMENTATION 승인·원격 실행 경계를 적용한다.

**비목표/후속 의존성:** UI 30초 timer 약속·source/CPU별 다른 probe·임의 기준 완화는 없다.

**추적/위험:** NFR-001~004, AD-12, P-6, A-002, CM-002.

### Story 5.7: 전체 증거로 v1 출시 준비 상태 판정하기

As a 논문 독자,
I want 검증된 지원 산출물만 v1로 제공받고,
So that 미완료 기능이나 미통과 게이트를 출시 완료로 오인하지 않을 수 있다.

**Acceptance Criteria:**

**Given** 최종 source commit과 두 artifact hash가 있을 때,
**When** 출시 검증 결과를 취합하면,
**Then** P-1~P-6·FR/NFR·UX·SM/CM의 증거를 정확한 후보에 연결한다.
**And** 이전 prototype 통과를 최종 산출물 통과로 대체하지 않는다.

**Given** 자동·manual/native·CI/remote 검증 결과가 있을 때,
**When** 판정 기록을 작성하면,
**Then** 실행한 검증·한계·실패·남은 위험을 구분한다.
**And** 미실행 항목을 통과로 표시하지 않는다. x86_64 Actions 빌드 성공은 실제 Intel 실행·GUI·VoiceOver·Gatekeeper·전체 지원 OS matrix 증거를 대체하지 않는다.

**Given** 필수 기능 실패·누락 증거·미통과 게이트·미해결 timing disposition이 있을 때,
**When** 출시 준비 상태를 판단하면,
**Then** 차단 사유를 명시한다.
**And** 중간 Epic 완료·기능 개수·AI 유창성으로 실패를 상쇄하지 않는다.

**Given** 모든 필수 기준의 실제 증거가 충족됐을 때,
**When** human release decision에 필요한 결과를 제시하면,
**Then** 검증된 후보와 준비 상태만 보고한다.
**And** 별도 명시적 지시 없이 push·PR·업로드·공개 배포·merge를 실행하지 않는다.

**범위:** Story 5.1~5.6을 선행으로 정확한 후보에 대한 출시 준비 판정과 human decision용 검증 기록을 작성한다. Epic 5 공통 IMPLEMENTATION 승인·원격 실행 경계를 적용한다.

**비목표/후속 의존성:** 사람의 출시/merge 승인을 생성·추론하거나 운영 backlog를 위한 추측성 후속 작업을 만들지 않는다.

**추적/위험:** FR-035/036, P-1~P-6, SM-001~007, CM-001~003, repository governance.

### Epic 5 분해 검토 결과

사용자가 Story 5.1~5.7과 공통 조건, x86_64 GitHub Actions 위임 및 실제 Intel 검증 경계 수정을 포함해 일괄 승인했다. 이는 분해 문서의 범위·인수 조건 승인이지 구현 완료·IMPLEMENTATION 승인·기술 게이트 통과·원격 실행·공개 배포 승인이 아니다. 다섯 Epic의 Story 저장을 마쳤으며 Step 3 최종 메뉴의 사용자 C 선택 전 Step 4 최종 검증에 진입하지 않는다.

| Epic 5 완료 책임 FR | 승인된 Story |
| --- | --- |
| FR-035 | 5.3~5.5, 5.7 |
| FR-036 | 5.4, 5.7 |

| 교차 검증 책임 | 승인된 Story |
| --- | --- |
| P-4 로컬 diagnostics 정책 | 5.1 |
| P-5 교체·schema·손상 경계 | 5.2 |
| P-1/P-2 최종 packaging·runtime 재검증 | 5.3 |
| P-3 실제 요청 계약 회귀 | 5.5, 5.7 |
| P-6 timing·disposition | 5.6 |
| 전체 사용자 흐름·출시 증거 | 5.5, 5.7 |

NFR-001~004의 timing·PDF-first, NFR-005~006의 근거·정확도 비보장, NFR-007~010의 데이터·삭제·secret·외부 요청 경계를 최종 산출물에서 재검증한다. UX-DR37 및 SM-001~007/CM-001~003을 두 CPU의 실제 검증 증거로 추적하며 공개 문구 제약과 설치·라이선스 안내를 5.4에서 확인한다. Actions runner 가용성·권한·secrets·실행 가능한 GUI/OS matrix는 아직 확인하지 않았고 workflow도 현재 작업에서 만들거나 실행하지 않았다.

### Party 검토에 따른 승인된 순서·실행 환경 수정

사용자가 두 수정을 명시적으로 승인했다. Job-class 정책 Story를 첫 제품 Import 앞에 배치하고 관련 선행·추적 참조를 갱신했다. 기존 큰 Import Story의 기능 범위는 그대로 유지한다. 이동한 정책 Story의 미래 제품 데이터 선행을 제거하고 현재 Provider/prototype 및 계약 검증으로 먼저 확정하도록 정리했다.

| 이전 번호 | 현재 번호 | Story |
| --- | --- | --- |
| 1.17 | 1.13 | Job 종류별 실패·재실행·Retry 계약 확정 |
| 1.13 | 1.14 | 연결 후 Library에서 로컬 PDF 추가·삭제 |
| 1.14 | 1.15 | 추가한 PDF를 Reader에서 읽고 이어 읽기 |
| 1.15 | 1.16 | PDF에 Highlight·Note 남기고 다시 확인하기 |
| 1.16 | 1.17 | Library 폴더와 중복 확인 후 가져오기 |

1.1~1.12 및 1.18 이후 번호는 유지한다. Intel Actions/별도 Intel 환경 경로는 Epic 1의 P-1/P-2부터 적용한다. 이 수정은 구현·게이트 통과·원격 실행 승인이 아니다. 사용자의 명시적 검토 종료 지시에 따라 Party 검토를 종료하고 Step 3 최종 메뉴로 복귀했다. 사용자 C 선택 전 Step 4에는 진입하지 않는다.

## 최종 검증 기록

사용자의 Step 3 `C` 선택으로 Step 4에 진입해 요구사항·아키텍처·Story 품질·Epic 구조·의존성을 순서대로 검토했다. 초회 판정은 두 인수 조건의 명확화 필요였다. 이후 사용자의 명시적 보완·재검증 지시에 따라 Story 3.1·3.4를 수정하고 재검증했다. **현재 판정: 분해 문서의 최종 검증 통과, workflow 종료 C 선택 대기.** 아래는 문서 검증 기록이며 제품 구현 계획·IMPLEMENTATION 승인·실행 검증 통과가 아니다.

### 검증 증거와 범위

- 입력 문서 6개의 현재 bytes를 PRODUCT/UX `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `cdabe4419606ab0c1efebcfeb79bded0fe344512`의 Git artifact와 비교해 동일함을 확인했다.
- 다섯 Epic·53개 Story의 정확한 번호 연속성, 사용자 형식·Acceptance Criteria·범위·비목표·추적 필드, Given/When/Then 218개 triple을 확인했다. Epic별 AC 수는 94/41/32/20/31이다.
- FR 39개와 원문의 `Consequences (testable)` 123개를 실제 AC·범위·공통 계약에 대조했다. 완료 책임 매핑 누락은 없으며 초회 의미 검토의 두 계약 명확화는 아래 재검증에서 해소했다. 매핑 존재를 의미 coverage 통과와 혼동하지 않는다.
- NFR 10개·AR 26개·UX-DR 38개의 Story 본문 참조를 확인하고 관련 공통 계약·개별 surface와 대조했다. UX UJ-4의 저장 후 선택 대상과 AD-14의 실행 입력 봉인을 보완·재검증했다. 식별자 검사는 실제 native 동작·접근성 통과 증거가 아니다.
- Architecture는 외부 starter template을 지정하지 않고 structural seed를 제공한다. 최소 topology 및 packaged DB/FTS prototype Story와 기능별 필요한 schema 생성은 그 경계에 맞으며 전체 제품 table 선생성을 요구하지 않는다.
- Application durable authority, 단일 persistence/DB, RPC·Provider-neutral 근거, writer/publication permit, canonical geometry, Paper/Template 소유권, Intel 실제 검증 및 게이트 차단 경계를 확인했다. AD-14 입력 권위는 snapshot 불변·value-copy·새 identity 및 원자적 연결·snapshot-only payload 조건으로 명확화했다. 구체 schema·저장 표현·claim transaction 구성은 해당 Build Spec에서 확정한다.
- 명시적 Given/범위의 미래 Story 선행은 발견하지 않았다. 1.3/1.6의 자기 포함 범위는 해당 Story 결과까지 포함한 gate 증거 집계이며 미래 의존성이 아니다. 재배치한 1.13은 첫 제품 Import 1.14보다 먼저 공통 Job 정책을 확정한다.
- Epic 2는 Brief 없이, Epic 3은 추가 테마/공개 packaging 없이 사용자 결과를 완결한다. 공유 Reader/Application/persistence 수정은 신규 데이터·기능의 점진적 통합이며 다섯 Epic 분리는 앞선 승인 검토의 사용자 결과·위험·feedback 경계 근거를 유지한다. 제품 소스가 아직 없어 실제 파일별 churn 횟수는 정량 측정하지 않았다.
- 단일 개발 에이전트의 work unit 형식·현재 범위·검증 경계를 확인했다. 승인된 큰 Story 1.14 범위는 재분해하지 않았으며 실제 작업량·stage 구성은 해당 Build Spec에서 관리한다. 문서 검증만으로 구현 소요나 실제 실행 성공을 보장하지 않는다.
- YAML·template placeholder·파일 자체 trailing whitespace 및 `git diff --check`를 검증했다. untracked `epics.md`의 공백 검사는 별도로 수행했다. 제품 테스트·formatter·prototype·Actions 실행·commit·push·PR은 하지 않았다.

### 초회 발견 명확화와 해소 기록

| ID | 대상 | 근거 | 현재 문제와 최소 보완 |
| --- | --- | --- | --- |
| FV-001 | Story 3.1 AC1~2 | FR-022, AD-14, SOLUTION-DESIGN §6.6 | Paper 추가 시 extraction 준비 전 immutable generation snapshot과 Job을 만들지만 실행 시 새 revision-pinned 근거를 결합한다. extraction revision/EvidenceBundle이 언제 어떤 immutable 실행 입력에 봉인되고 snapshot-only payload와 연결되는지 불명확하다. 자동 pending Job은 유지하되 실행 입력 봉인 시점·identity/provenance 연결·대기 중 Template 편집/Retry Parsing/재실행에서도 기존 immutable 입력 불변을 인수 조건에 명시해야 한다. 구체 저장 표현은 Build Spec 사항이며 여기서 새 아키텍처를 임의 확정하지 않는다. |
| FV-002 | Story 3.4 AC1 | EXPERIENCE UJ-4 단계 3 | UX는 editor 저장 후 새 Template이 selected여야 하지만 현재 '선택 상태 유지'는 이전 Template을 유지하는 구현도 허용한다. 저장 성공 후 저장한 사용자 Template의 새 current version을 선택한 상태로 originating Brief에 복귀하며 자동 재생성하지 않는다고 명시해야 한다. 기존 Brief snapshot/provenance는 유지한다. |

두 보완은 새 기능을 추가하는 것이 아니라 승인된 요구·계약의 모호함을 제거한다. 사용자의 명시적 보완 지시에 따라 해당 Story 본문을 수정했다.

- **FV-001 해소:** Paper 추가 시 Template와 당시 확정 입력의 immutable capture 및 자동 pending Job을 유지한다. 준비 후 dispatch 전에 캡처 값·revision-pinned EvidenceBundle·실행 입력을 value-copy한 완전한 immutable generation snapshot을 새 identity/hash로 만들고 Job 입력 버전·새 attempt와 원자적으로 연결한다. 기존 snapshot은 수정하지 않고 payload는 완전한 snapshot만 읽는다. 대기 중 Template 편집·Retry Parsing·재실행의 캡처 값 보존, 봉인 후 Retry의 입력 불변, 유효하지 않은 revision의 typed 실패, 부분 입력 dispatch 금지를 명시했다. 기존 Paper-owned snapshot과 Application/Job 경계 안에서 처리하며 새 durable owner나 제품 기능을 만들지 않는다.
- **FV-002 해소:** editor 저장 성공 후 저장한 사용자 Template의 새 current version을 선택한 상태로 originating Brief에 복귀한다. 자동 재생성을 하지 않으며 실패·취소는 선택 성공으로 표시하지 않고 기존 Brief snapshot/provenance를 유지한다.
- **재검증:** 해당 두 Story의 AC와 AD-10/14·FR-022·UX UJ-4를 다시 대조했다. 53개 Story·218개 Given/When/Then triple·FR 완료 책임 매핑·6개 pinned 입력 문서 bytes·YAML·파일 자체 공백 검사를 재실행했다. 수정된 계약에 더 이상 두 모호함이 남지 않으며 Story 번호·범위·미래 선행 경계를 유지한다. 이는 문서 인수 조건 검사이지 실제 런타임 race·DB·Provider 테스트가 아니다.

Step 4의 문서 최종 검증 통과 후 사용자가 `[C] Complete Workflow`를 선택하여 전체 Epic·Story 분해 workflow를 완료했다. P-1~P-6의 실제 미통과 상태와 별도 IMPLEMENTATION·원격 실행·배포 승인 경계는 그대로 유지한다. 제품 소스·prototype·CI·commit·push·PR은 이 작업에서 수행하지 않았다. 다음 필수 BMAD 단계는 Sprint Planning의 readiness 검토와 tracking이며, 해당 단계도 구현 승인을 대체하지 않는다.

### Sprint Planning readiness 검토 — 2026-10-05

- **초회 판정 CONCERNS:** Story 1.23의 성공 요약은 Paper·입력 revision 연결만 명시하여 NFR-006의 Evidence Anchor 연결 또는 근거 부족 표시 조건이 불명확했다.
- **해소:** 사용자 진행 지시에 따라 Story 1.23에 기존 공통 근거 계약을 통한 Evidence Anchor 연결 또는 명시적 근거 부족 표시, 저장·Library 표시·재실행 복원 시 동일 경계 유지 및 NFR-006 추적을 추가했다. 새 제품 기능·Anchor UI·아키텍처 결정을 추가하지 않았다.
- **재판정 PASS:** 제품 요구사항 추적과 Epic·Story 선행 순서, 기록된 Architecture/UX 계약을 검토했다. explicit Open Reader와 사용자 think time 제외의 측정 시나리오는 timing 구현 전 Story 1.8/P-6에서 확정하므로 별도의 미소유 blocker가 아니다.
- **경계:** 이 판정은 sprint tracking을 생성할 수 있다는 계획 준비도 판단이다. P-1~P-6의 실행 증거·통과, Build Spec의 IMPLEMENTATION 승인, 원격 실행·공개 배포·merge 승인으로 사용하지 않는다.
