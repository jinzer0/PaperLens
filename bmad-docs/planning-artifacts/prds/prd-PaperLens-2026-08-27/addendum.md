---
title: PaperLens PRD 부록
status: draft
created: 2026-08-27
updated: 2026-09-27
---

# PaperLens PRD 부록

이 부록은 PRD 본문에 넣지 않을 기술적 배경, 참조 제약, Architecture 검토 메모, superseded 결정을 보존한다. PRD 본문은 사용자에게 관찰 가능한 capability와 release acceptance를 정의하고, 이 문서는 후속 UX, Architecture, 구현 계획의 참고 자료다.

## 1. 권위와 Superseded 결정

- 이 개정은 3개 테마 지원에 대한 재승인 대기 초안이다. 새 PRODUCT 승인 전까지 `APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456`의 PRD와 부록이 승인 기준이며, 이번 문서 변경은 구현 승인이 아니다.
- `.memlog.md`의 결정이 제품 브리프와 제품 브리프 부록보다 우선한다.
- 브리프의 `Codex OAuth` 표현은 최신 결정에 따라 `공식 Codex SDK의 ChatGPT 로그인 또는 device-code 흐름`으로 대체한다.
- generic Codex OAuth provider contract는 확인되지 않았고 v1에서 금지된다.
- Codex SDK의 `chatgptAuthTokens` protocol mode는 internal-only이므로 사용하지 않아야 한다.
- 브리프의 로컬 모델 선택 가능성은 v1에서 제외되며, Ollama 등 로컬 모델은 후속 후보로만 남긴다.
- Paper Chat은 Paper QA와 일반 AI Chat의 두 모드가 아니라, 항상 논문 전체 검색 근거로 답하는 하나의 Chat이다.
- Reader 현재 페이지, 선택 문장, 하이라이트를 Paper Chat에 자동 또는 수동으로 전달하는 요구는 최신 결정으로 제거되었다.
- PDF 파싱 기술과 라이브러리 선택은 PRD가 아니라 Architecture 단계에서 결정한다.

## 2. Architecture Must Decide Before Implementation

- Provider secret gate: Provider 비밀정보를 다루는 구현 story는 Architecture가 local storage location/class, at-rest protection decision, file permissions, log redaction, backup inclusion/exclusion, deletion behavior, OS keychain 미사용에 대한 threat acceptance를 기록하기 전에는 시작하지 않는다. 이 gate는 저장/암호화 기술 선택이 아니라 pass/fail handoff 조건이다. Impacts: PRD FR-002, FR-003, FR-004, NFR-009, A-003.
- Deletion gate: Paper 삭제 구현 story는 Architecture가 PDF, Translation, Brief, Paper-bound generation snapshot, Chat Session, Highlight, Note, Reading Status, Favorite, 마지막 읽은 위치의 데이터 경계와 삭제 실패/복구 상태를 기록하기 전에는 시작하지 않는다. 독립 재사용 사용자 Template은 Paper 삭제 경계 밖에 둔다. Impacts: PRD FR-030, FR-031, NFR-008, SM-005.
- Evidence Anchor gate: Evidence Anchor 관련 QA/story acceptance는 UX/Architecture가 PDF 페이지, 추출 문장 식별자, visible highlight의 세부 계약과 근거 없음/근거 위치 불명확/이동 실패 상태를 기록하기 전에는 확정하지 않는다. Existing owner/revisit: PRD A-001의 UX/Architecture, UX detail/Architecture/QA stories 전. Impacts: PRD FR-017, FR-024, SM-002.
- 30-second test gate: PDF-visible 30초 soft target 관련 QA/story acceptance는 Architecture/QA가 일반 네트워크 상태, 정상 접근 가능한 arXiv/PDF URL, 과도하게 크지 않은 텍스트 기반 논문 PDF 조건, source별 측정 경계, material 또는 반복 초과의 review/disposition 기준을 기록하기 전에는 확정하지 않는다. Existing owner/revisit: PRD A-002의 Architecture/QA, release QA plan 전. Impacts: PRD FR-007, FR-032, NFR-001, NFR-002, NFR-003, SM-001.
- Job recovery gate: Job 상태와 앱 재실행 후 복구 구현 story는 Architecture가 pending/running/succeeded/failed 상태 전이와 재실행 후 복구 규칙을 기록하기 전에는 시작하지 않는다. Impacts: PRD FR-032, FR-033, FR-034, SM-003.
- Provider connection gate: Provider 연결 테스트 구현 story는 Architecture가 성공/실패 판정 기준과 마지막 성공 연결 상태 처리 방식을 기록하기 전에는 시작하지 않는다. Impacts: PRD FR-001, FR-002, FR-004, SM-001.
- Local App Data boundary gate: Local App Data 관련 story는 Architecture가 cloud backup/sync/recovery를 제품 기능으로 제공하지 않는 상태에서 사용자가 기대할 수 있는 데이터 보존 경계를 기록하기 전에는 시작하지 않는다. Impacts: PRD FR-029, FR-030, NFR-007.

## 3. Reader와 Translation 구현 메모

- 전체 PDF를 한 번에 번역하지 않고 페이지 단위 Translation 태스크로 나누는 방향이 결정되어 있다.
- 완료된 페이지부터 보여주며, 미번역 페이지에서는 PDF 원문을 즉시 표시하고 Translation 패널은 로딩 상태로 둔다.
- 사용자가 다른 페이지로 이동해도 Translation 작업 순서는 변경하지 않는다.
- 페이지별 Translation은 독립 태스크로 두고 병렬 처리해 대기 시간을 줄인다.
- 실시간 준비 UX에서는 가능한 결과부터 보여주며 Translation 결과를 먼저 노출한다.
- 문장 수가 맞지 않을 때 원문-Translation 정렬이 흔들릴 수 있다.
- 직접 매핑 실패 시 위치 비례 휴리스틱 같은 fallback은 후보로 참고할 수 있으나 정확도 보장으로 표현해서는 안 된다.
- EasyPaper의 명시적 shared-scrollTop 동기화 여부는 확인되지 않았다.

## 4. Evidence Anchor 기술 후보

- PRD 본문은 Evidence Anchor를 PDF 페이지, 추출 문장 식별자, visible highlight로 가정한다.
- Architecture는 추출 문장 식별자의 안정성, PDF 위치 매핑, 페이지 이동 후 강조 표시, hover preview 텍스트 범위를 결정해야 한다.
- Evidence Anchor 실패 상태는 사용자에게 근거 없음, 근거 위치 불명확, 이동 실패 중 무엇인지 구분될 필요가 있다.
- Evidence Anchor는 완전한 정확도 보장이 아니라 검증 가능한 clickback 단위로 다뤄야 한다.

## 5. EasyPaper 참조와 라이선스 제약

- EasyPaper는 번역, 문장 1대1 대조, 스크롤 매칭 등 Reader UX의 핵심 레퍼런스 후보다.
- 참고 가능한 UX 패턴은 원문 PDF, AI 번역, 채팅, 라이브러리, 그래프, 읽기 기록, 추천의 통합이다.
- 세부 참고 패턴은 문장 태그, 페이지별 스트리밍 번역, 번역과 PDF 사이의 양방향 hover 강조, 페이지 높이 동기화, 연속 스크롤, lazy rendering이다.
- EasyPaper 저장소에는 명시적 LICENSE 파일이 없으므로 코드 재사용 권한을 전제로 삼을 수 없다.
- EasyPaper는 UX 영감으로만 사용하고 구현은 독립적으로 해야 한다.

## 6. Provider와 보안 메모

- v1 AI 연결 방식은 OpenAI API key와 공식 Codex SDK의 ChatGPT 로그인 또는 device-code 흐름으로 제한한다.
- Provider 연결은 앱 사용의 필수 Onboarding이며, 성공한 연결 테스트 전 제한 Reader/Library 모드는 제공하지 않는다.
- 외부 Provider로 논문 및 개인 데이터 전송을 수용하는 제품 결정은 privacy promise로 포장하지 않아야 한다.
- 별도 데이터 전송 고지, 필수 동의 절차, consent gate는 두지 않는다.
- OpenAI API key 등 Provider 비밀정보를 OS keychain에 저장하지 않는 것은 사용자 결정으로 남아 있으나 보안 리스크다.
- Architecture review는 keychain 미사용 상태에서 local storage location/class, at-rest protection decision, file permissions, log redaction, backup inclusion/exclusion, deletion behavior, threat acceptance를 명시적으로 기록해야 하며, 기록 전 Provider secret 구현 story는 시작하지 않는다.

## 7. Local App Data와 삭제 메모

- Local App Data에는 PDF, Translation, Brief, Paper-bound generation snapshot, 독립 재사용 사용자 Template, Paper Chat Session, Highlight, Note, Reading Status, Favorite, 마지막 읽은 위치가 포함된다.
- Paper-bound generation snapshot은 한 Paper의 Brief 생성을 위해 캡처된 Template 버전과 입력값이다.
- Paper 삭제 시 PDF, Translation, Brief, Paper-bound generation snapshot, Paper Chat Session, Highlight, Note, Reading Status, Favorite, 마지막 읽은 위치처럼 Paper가 소유한 파생 데이터 전체가 삭제되어야 한다.
- 독립 재사용 사용자 Template은 Paper 삭제 후에도 보존되며, Template 관리와 이후 Brief 생성 선택지에 남아야 한다.
- 진행 중 Job과 삭제가 충돌할 때 Job 결과가 삭제된 Paper를 되살리지 않아야 한다.
- 삭제 요구사항은 사용자에게 관찰 가능한 제품 동작으로 PRD에 남기고, 구체 저장 메커니즘과 스키마는 Architecture에서 결정한다.

## 8. Open Source와 라이선스 메모

- PaperLens 공개 저장소와 v1 공개 패키징은 최종 채택된 오픈소스 라이선스 `AGPL-3.0-only`를 명시해야 한다.
- PaperLens는 잠재 사용자와 오픈소스 커뮤니티를 위한 공개 소개 제품이며 투자자용 성장 서사가 아니다.
- 커뮤니티 개선 가능 영역은 읽기 UX, Evidence Anchor, AI Provider 연결 방식, 연구 정리 흐름이다.
- public v1 패키징은 macOS 15+ 실행 방법, arm64와 x86_64 별도 산출물, Provider 설정 방법, 최종 확정된 오픈소스 라이선스를 사용자가 확인할 수 있어야 한다.

## 9. 후속 범위 후보

- 개인 지식 그래프.
- Library 논문 기반 최신 논문/관련 논문 추천.
- 연구 관계 그래프.
- AI 채팅 내용을 연구 기록으로 정리.
- 읽기 전 브리핑의 핵심 개요와 연구 계보.
- 파인만식 설명.
- 용어집.
- 질문 거리 제공.
- 인용, 그림, 표, 수식 참조를 읽는 위치에서 오버레이 표시.
- QA 이후 후속 질문 추천.
- 로컬 모델 연결.
- 일반 목적 독립 AI Chat 병행은 v1에서 제외되며, 장기 후보로 재검토하더라도 v1 Paper Chat의 항상 근거 기반 원칙과 혼동하지 않는다.

## 10. PRD 본문에서 제외한 구현 항목

- 구체 PDF 파서와 라이브러리 선택.
- 저장소 구조와 데이터베이스 스키마.
- Translation 큐, 병렬 처리 방식, 캐시 키 설계.
- Provider token 저장 포맷.
- PDF 문장 위치 인덱싱 구현 방식.
- hover 강조와 scroll sync의 구체 렌더링 전략.
- Job scheduler와 retry backoff 구현.
- Template 저장 포맷.

## 11. 테마 확장과 UX / Architecture 후속 계약

- 사용자는 Native Canvas를 기본 디자인으로 선택하고 Scholarly Press와 Focused Instrument를 Settings에서 바꿀 수 있는 추가 테마로 요청했다. 기존의 세 시안 중 하나만 채택하는 방향을 대체한다.
- 사용자에게 관찰 가능한 요구사항과 출시 검증은 PRD FG11 / FR-037..FR-039 / SM-007에 정의한다. 세 테마는 별도 기능 모드가 아니며, 모두 같은 사용자 여정과 Light/Dark 지원을 제공한다.
- 시각 참조는 이 문서 기준 `../../ux-designs/ux-PaperLens-2026-08-29/mockups/`의 `direction-native-canvas.html`, `direction-scholarly-press.html`, `direction-focused-instrument.html`이다. HTML 시안 자체는 제품 구현이나 최종 UX 계약을 대신하지 않는다.
- UX는 DESIGN.md에 테마별 색상·서체·표면·간격·상태·접근성 기준을, EXPERIENCE.md에 Settings 선택과 읽기 맥락 보존 동작을 정의한다. 사용자 결정에 따라 명암 모드 기본값은 시스템 설정 따름이며, Settings에서 테마와 별도로 시스템 설정 따름 / Light / Dark를 선택한다. 이 보완 역시 새 PRODUCT 승인 전까지 재승인 대기 개정에 속한다.
- Architecture 검토는 테마의 앱 전역 적용과 환경설정 보존 책임을 확인한다. 구체 저장 방식이나 UI 구현 기술은 PRD에서 지정하지 않는다. 기존 승인 아키텍처의 실질적 변경이 필요하면 별도 수정·커밋·ARCHITECTURE 재승인을 받는다.
- 이번 개정은 사용자 정의 테마 편집기, 테마 다운로드 또는 marketplace를 요구하지 않는다.

### 11.1 정합성 검토 — 2026-09-27

- 대조 기준: 승인된 Architecture Spine AD-1·AD-6·AD-11과 SOLUTION-DESIGN §4·§7, 현재 PRD FG11/SM-007, UX DESIGN/EXPERIENCE. 승인된 아키텍처 파일 자체는 변경하지 않았다.
- 아키텍처 영향: 테마·명암은 기존 Main App의 표현과 앱 전역 환경설정이다. 프로세스 구성, ProviderRPC, 비밀정보, 네트워크, Paper/Job 생명주기와 삭제 범위를 바꾸지 않으므로 이번 문서 개정으로 ARCHITECTURE 재승인은 필요하지 않다. 이는 검토 결론이지 새 아키텍처 승인 기록이 아니다.
- 소유권: 지속되는 cross-feature 설정 변경은 AD-1의 Application use case와 기존 persistence 경계를 따른다. Feature가 별도 durable owner를 만들거나 SQLite를 직접 쓰지 않는다. 설정은 Paper UUID/generation에 속하지 않으므로 Paper 삭제 cascade 밖에 둔다.
- 보완한 불일치: UX에서 확정된 System 기본값·System/Light/Dark 독립 선택·재실행 복원이 PRD 본문에는 빠져 있었다. FR-038/039와 SM-007에 정책 보존, OS 명암 변경 반영, 명시적 Light/Dark 유지, Paper 삭제 후 설정 유지, 원본 PDF 불변성을 반영했다. 여섯 렌더링 조합과 세 가지 명암 정책을 구분한다.
- UX 현황 문구: 실제로 존재하는 `mockups/` 화면을 “생성 진행 중”으로 표시하던 내용을 정리했다. 정적 시안의 존재는 native 앱 동작 검증이나 제품 승인을 의미하지 않는다.
- Build Spec에 남는 내용: 설정 표현·저장 연산·migration 필요 여부·native appearance 관찰 및 갱신 구현·설정 저장 실패 처리. 구체 기술 선택은 이번 PRD/UX 문서에서 새로 고정하지 않는다.
- 승인 상태: PRD/부록은 재승인 대기 draft, UX의 final은 문서 완성 상태다. 이 문서들이 포함된 새 커밋에 대한 PRODUCT 승인과 이후 Build Spec의 IMPLEMENTATION 승인 없이 구현을 시작하지 않는다.
