---
title: PaperLens PRD
status: final
created: 2026-08-27
updated: 2026-08-28
---

# PRD: PaperLens

## 1. 제품 개요

PaperLens는 논문을 빠르게 열고, 원문 근거를 확인하며, 개인 연구 라이브러리에 정리해 다시 꺼내 쓰도록 돕는 macOS용 오픈소스 AI 논문 워크스페이스다. v1의 약속은 사용자가 논문 하나를 가져와 Reader에서 읽고, 문장 정렬 번역을 대조하고, 논문 전체 근거 기반 Paper Chat으로 질문하고, Markdown Brief와 노트로 남기고, 나중에 Library에서 다시 찾는 end-to-end 흐름을 실제로 사용할 수 있게 만드는 것이다.

제품 중심 루프는 `read -> evidence -> organize -> revisit -> compound`다. PaperLens는 넓고 모호한 올인원 리서치 코파일럿이 아니라 빠른 AI Reader와 축적되는 AI Library를 연결하는 도구다. PaperLens는 이해도를 채점하지 않고, 사용자가 핵심을 빠르게 파악하고 근거를 확인하며 자신의 연구 지식으로 보존하도록 돕는다.

v1은 공개 오픈소스 제품으로 배포될 수 있어야 하며, 커뮤니티가 읽기 UX, Evidence Anchor, AI Provider 연결, 연구 정리 흐름을 개선할 수 있는 구조와 문맥을 남긴다. 다만 v1은 기술적 moat, 완전한 정확도, 완전한 표/그림/수식 분석, 프라이버시 제품을 주장하지 않는다.

## 2. 대상 사용자와 JTBD

주요 사용자는 논문을 자주 읽지만 읽기와 정리가 분리되어 불편한 대학원생, 연구자, 엔지니어, 독립 학습자다. 이들은 PDF 원문, 번역, 질문 답변, 요약 노트, 하이라이트, 읽기 이력을 여러 도구 사이에서 옮겨 다닌다.

- JTBD-1: 새 논문을 발견했을 때 빠르게 가져와 PDF 원문을 열고 읽기 준비 상태를 확인한다.
- JTBD-2: 논문을 읽는 중 원문과 번역을 문장 단위로 대조해 이해 속도를 높인다.
- JTBD-3: 논문 내용에 대해 질문할 때 답변이 어떤 원문 근거에 기대는지 확인한다.
- JTBD-4: 읽은 뒤 논문의 문제, 방법, 한계, 가능성을 Brief와 개인 노트로 보존한다.
- JTBD-5: 나중에 Library에서 논문, 하이라이트, 노트, Brief, 마지막 읽은 위치를 다시 찾는다.

## 3. Glossary

- Reader: Paper의 PDF 원문, Translation, Paper Chat, Brief Drawer, 하이라이트와 노트를 함께 사용하는 읽기 화면.
- Library: Paper, 폴더, 태그, 읽기 상태, 즐겨찾기, 하이라이트, 노트, Brief, Paper Chat 세션, 읽기 이력을 관리하는 로컬 연구 라이브러리.
- Paper: PaperLens에 가져온 단일 논문 항목. PDF 원문과 그 파생 데이터 전체를 포함한다.
- Paper Chat: 한 Paper에 대해 항상 논문 전체 검색 근거로 답하는 단일 QA 채팅. 일반 채팅 모드나 근거 모드 토글을 갖지 않는다.
- Chat Session: 한 Paper 안에 저장되는 Paper Chat 대화 단위. 자동 저장, 재개, 목록, 새 세션, 제목 자동 생성, 이름 변경, 삭제를 지원한다.
- Brief: Paper에 대해 생성되는 구조화된 Markdown 정리본. 기본 템플릿 또는 사용자 정의 Template으로 생성된다.
- Template: Brief 생성을 위한 Markdown 섹션 구조와 프롬프트 묶음. 사용자가 항목과 프롬프트를 편집할 수 있다.
- Evidence Anchor: [ASSUMPTION A-001] PDF 페이지, 추출 문장 식별자, 화면에서 보이는 강조 위치로 구성되는 근거 연결 단위. UX/Architecture에서 세부 계약을 확정한다.
- Provider: AI 기능을 실행하기 위해 연결하는 외부 AI 서비스. v1 Provider 연결은 OpenAI API key와 공식 Codex SDK의 ChatGPT 로그인 또는 device-code 흐름이다.
- Job: 가져오기, 파싱, 번역, Brief 생성처럼 사용자에게 진행률, 오류, 재시도, 복구 상태를 보여야 하는 비동기 작업.
- Local App Data: macOS 앱 로컬 저장 영역에 보관되는 Paper와 파생 데이터. 계정이나 클라우드 동기화를 전제로 하지 않는다.
- Translation: Paper의 추출 문장을 사용자가 설정한 대상 언어로 번역하고 원문 문장과 1대1 대조해 보여주는 결과.
- Highlight: 사용자가 Reader에서 남긴 Paper 위치 기반 표시.
- Note: 사용자가 Paper 또는 Paper 위치에 남기는 개인 메모.
- Reading Status: Paper의 읽기 진행 상태를 사용자가 Library에서 관리하기 위한 상태값.
- Favorite: 사용자가 Library에서 중요한 Paper를 빠르게 다시 찾기 위해 표시하는 즐겨찾기 상태.

## 4. 범위

### 4.1 v1 출시 필수 범위

아래 모든 기능 그룹은 출시 차단 범위다. 범위 리스크는 수용되었으며 기능 축소가 아니라 release gate와 위험 관리로 다룬다.

- macOS 데스크톱 앱.
- 필수 첫 실행 Provider 설정과 성공한 연결 테스트.
- OpenAI API key 연결.
- 공식 Codex SDK의 ChatGPT 로그인 또는 device-code 흐름 연결.
- arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF 파일 가져오기.
- PDF 탐색, 확대/축소, 검색, 텍스트 선택이 가능한 Reader.
- 문장 정렬 Translation, 양방향 hover 강조, 언어 설정, 진행률, 오류, 재시도, 캐시.
- 논문 전체 검색 근거로 답하는 Paper Chat과 Chat Session 관리.
- 자동 생성 및 재생성 가능한 Brief, 기본/사용자 Template, Evidence Anchor 연결.
- Library 폴더, 태그, 검색/필터, 최근 읽은 논문, 한 줄 요약, 읽기 상태, 즐겨찾기, 중복 경고, 하이라이트, 노트, 마지막 읽은 위치, 삭제.
- Job 진행률, 오류, 재시도, 재실행 후 복구 상태.
- Local App Data 저장과 Paper 삭제 시 전체 파생 데이터 삭제.

### 4.2 v1 비목표

- 추천 시스템.
- 개인 지식 그래프.
- 로컬 모델 연결.
- Provider 없는 제한 모드.
- Cloud account, cloud storage, cloud sync.
- 모바일 앱.
- 협업 기능.
- Zotero 동기화.
- OCR.
- 완전한 표/그림/수식 분석.
- Paper Chat의 일반 채팅 모드, 근거 모드 토글, 일반 AI Chat 분리.
- 별도 데이터 전송 고지 또는 필수 동의 절차.
- 이해도 채점, 학습 평가, 퀴즈형 평가 기능.

## 5. 사용자 여정

### UJ-1. 연구자 김철수의 논문 읽기와 정리

- Entry: 김철수는 새 논문 PDF 링크를 발견하고 PaperLens에 입력한다.
- Path: 첫 실행이라면 Provider 설정과 연결 테스트를 완료한 뒤 저장할 Library 폴더를 선택하고 가져오기를 시작한다.
- Climax: Reader에서 PDF 원문을 먼저 읽고, 준비된 Translation을 문장별로 대조하며, Paper Chat 질문의 Evidence Anchor를 클릭해 원문으로 돌아간다.
- Resolution: 김철수는 Brief 독립 화면과 Reader Drawer에서 Markdown 정리본을 확인하고, 태그, 읽기 상태, 하이라이트, 노트, 마지막 읽은 위치를 남긴다.
- Edge case: Translation이나 Brief Job이 아직 끝나지 않아도 PDF 원문은 먼저 보이고 각 Job 진행률이 분리되어 보인다.
- Covers: FR-001, FR-003, FR-005, FR-006, FR-007, FR-008, FR-010, FR-012, FR-014, FR-016, FR-017, FR-020, FR-024, FR-025, FR-028, FR-029, FR-032.

### UJ-2. 박민지의 Provider/파싱 실패와 복구

- Entry: 박민지는 PaperLens를 처음 실행하고 OpenAI API key를 입력한다.
- Path: 연결 테스트가 실패하면 PaperLens는 실패 상태와 재시도 동작을 보여주며 Reader/Library 제한 모드로 우회시키지 않는다.
- Climax: 박민지가 유효한 Provider 연결을 완료한 뒤 스캔본에 가까운 PDF를 가져오지만 파싱이 실패한다.
- Resolution: 원본 PDF Reader는 계속 열리고, Translation, Paper Chat, Brief는 비활성화되며 오류 정보와 파싱 재시도 동작이 보인다.
- Edge case: 파싱 재시도에 성공하면 비활성화된 AI 기능 Job이 다시 시작되고, 실패 상태는 재실행 후에도 이해 가능한 상태로 남는다.
- Covers: FR-001, FR-002, FR-003, FR-005, FR-007, FR-011, FR-032, FR-033, FR-034, NFR-004.

### UJ-3. 이서연의 Library 재방문과 완전 삭제

- Entry: 이서연은 지난주 읽던 논문을 다시 찾기 위해 Library를 연다.
- Path: 최근 읽은 논문 영역에서 후보를 확인하고, 검색/필터로 태그, 읽기 상태, 즐겨찾기 여부를 좁힌다.
- Climax: 논문 카드에서 제목, 발행연도, 한 줄 요약을 보고 Reader로 들어가 마지막 읽은 위치에서 이어 읽는다.
- Resolution: 더 이상 필요 없는 Paper를 삭제하면 PDF와 Translation, Brief, Chat Session, Highlight, Note, 읽기 이력이 함께 사라진다.
- Edge case: 삭제 중 실패하면 PaperLens는 삭제 미완료 상태를 표시하고 재시도할 수 있어야 하며, 완료 전에는 부분 삭제를 성공처럼 보이지 않는다.
- Covers: FR-010, FR-026, FR-027, FR-028, FR-030, FR-031, NFR-007, NFR-008.

### UJ-4. 최준호의 Template과 다중 Chat Session 관리

- Entry: 최준호는 같은 Paper를 세미나 준비용과 구현 검토용으로 다르게 정리하고 싶다.
- Path: 기본 Template으로 생성된 Brief를 확인한 뒤 사용자 Template의 Markdown 섹션과 프롬프트를 편집하고 Brief를 재생성한다.
- Climax: Paper Chat에서 세미나 질문 세션과 구현 질문 세션을 따로 만들고, 첫 질문 기반 자동 제목을 알아보기 쉽게 바꾼다.
- Resolution: 최준호는 세션 목록에서 필요한 대화를 다시 열어 이어 질문하고, 필요 없는 세션을 삭제한다.
- Edge case: Paper Chat은 현재 페이지나 선택 문장을 별도 맥락으로 받지 않아도 논문 전체 검색 근거로 답하며, 충분한 근거가 없으면 근거 부족을 명시한다.
- Covers: FR-016, FR-017, FR-018, FR-019, FR-020, FR-021, FR-022, FR-023.

## 6. 정보 구조

- Onboarding: Provider 선택, Provider 연결 입력, 연결 테스트, 실패/재시도.
- Import: arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF, 저장 폴더 선택, 중복 경고, Job 상태.
- Reader: PDF 원문, PDF 탐색/확대/검색/선택, Translation, Paper Chat, Brief Drawer, Highlight, Note, Job 상태.
- Brief: 독립 Brief 화면, 기본 Template, 사용자 Template, 재생성, Evidence Anchor 확인.
- Library: 최근 읽은 논문, 폴더, 목록/카드, 태그, 검색/필터, 읽기 상태, 즐겨찾기, 하이라이트, 노트, 삭제.
- Settings: Provider 연결 관리, 번역 대상 언어, 사용자 Template 관리.

## 7. 기능 요구사항

### FG1. Onboarding과 Provider 연결

- FR-001: 첫 실행 사용자는 지원 Provider 중 하나를 설정하고 연결 테스트를 성공해야 앱의 전체 기능에 진입한다.
  - Consequences (testable): 새 설치 상태에서 Provider 설정 화면이 먼저 나타난다.
  - Consequences (testable): 연결 테스트 실패 시 전체 앱 진입 버튼은 활성화되지 않고 실패 사유와 재시도 동작이 보인다.
  - Consequences (testable): 연결 테스트 성공 후 Import 또는 Library 진입이 가능하다.
- FR-002: Provider 설정은 OpenAI API key와 공식 Codex SDK의 ChatGPT 로그인 또는 device-code 흐름을 지원한다.
  - Consequences (testable): Provider 선택 UI에 OpenAI API key와 공식 Codex SDK ChatGPT/device-code 선택지가 있다.
  - Consequences (testable): 각 선택지는 성공/실패 연결 테스트 결과를 사용자에게 표시한다.
  - Consequences (testable): generic Codex OAuth라는 Provider 명칭이나 선택지는 UI와 문서화된 v1 요구에서 나타나지 않는다.
- FR-003: 사용자는 Onboarding과 Settings에서 Provider를 선택하고 현재 연결 상태를 확인한다.
  - Consequences (testable): Provider 설정 화면은 지원하는 Provider와 각 연결 방식을 보여준다.
  - Consequences (testable): Settings에서 현재 연결된 Provider와 연결 상태를 확인할 수 있다.
  - Consequences (testable): 별도 데이터 전송 고지, 필수 동의 checkbox, consent gate는 제공하지 않는다.
- FR-004: 사용자는 Settings에서 Provider 연결 정보를 갱신하고 다시 테스트할 수 있다.
  - Consequences (testable): Settings에서 Provider 연결 상태, 재입력/재로그인 동작, 연결 테스트 동작이 보인다.
  - Consequences (testable): 테스트 실패 후 기존 기능 사용 가능 여부는 마지막 성공 연결 상태를 기준으로 일관되게 표시된다.

### FG2. Paper 가져오기

- FR-005: 사용자는 arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF 파일로 Paper를 가져온다.
  - Consequences (testable): 네 입력 유형이 Import 화면에서 구분되거나 동일 입력이 올바른 유형으로 해석된다.
  - Consequences (testable): arXiv abstract URL 입력 시 PDF 가져오기가 시작된다.
  - Consequences (testable): 로컬 PDF 선택 시 네트워크 URL 없이 Paper 생성이 시작된다.
- FR-006: 가져오기 시 사용자는 저장할 Library 폴더를 지정하고 중복 가능성을 경고받는다.
  - Consequences (testable): 가져오기 완료 전 폴더 선택 또는 기본 폴더 확인 단계가 있다.
  - Consequences (testable): 기존 Paper와 같은 제목, URL, 또는 식별자로 판단되는 항목은 중복 경고를 표시한다.
  - Consequences (testable): 사용자는 경고 상태에서 가져오기를 중단하거나 계속할 수 있다.
- FR-007: 가져오기 Job은 Reader 진입 가능 상태와 후속 AI Job 상태를 분리해 보여준다.
  - Consequences (testable): PDF 원문이 준비되면 Translation, Paper Chat, Brief가 진행 중이어도 Reader 진입이 가능하다.
  - Consequences (testable): 실패한 가져오기 Job은 오류 정보와 재시도 동작을 표시한다.
  - Consequences (testable): 앱 재실행 후 완료 상태에는 Reader 열기 동작이, 실패 상태에는 오류 정보와 재시도 동작이 표시된다.

### FG3. Reader와 PDF 기본 기능

- FR-008: Reader는 PDF 원문, Translation, Paper Chat, Brief Drawer, Highlight/Note를 한 Paper 맥락에서 제공한다.
  - Consequences (testable): Reader 화면에서 PDF 원문과 Translation 패널, Paper Chat 진입점이 동시에 접근 가능하다.
  - Consequences (testable): Brief Drawer를 열어도 현재 PDF 페이지는 유지된다.
  - Consequences (testable): Highlight와 Note 생성 결과는 해당 Paper의 Library 기록에 남는다.
- FR-009: Reader는 PDF 페이지 이동, 확대/축소, 텍스트 검색, 텍스트 선택을 지원한다.
  - Consequences (testable): 사용자는 다음/이전 또는 페이지 지정 방식으로 이동할 수 있다.
  - Consequences (testable): 확대/축소 후 PDF 내용이 읽을 수 있는 상태로 갱신된다.
  - Consequences (testable): 검색어 입력 시 PDF 안의 일치 위치로 이동하거나 일치 없음 상태를 표시한다.
  - Consequences (testable): 선택 가능한 PDF 텍스트는 사용자가 드래그로 선택할 수 있다.
- FR-010: Reader는 Paper별 마지막 읽은 위치를 저장하고 재진입 시 복원한다.
  - Consequences (testable): Paper A의 페이지를 이동한 뒤 다른 화면으로 갔다 돌아오면 마지막 페이지가 복원된다.
  - Consequences (testable): 앱 재실행 후에도 마지막 읽은 위치가 유지된다.
  - Consequences (testable): 삭제된 Paper의 마지막 읽은 위치는 더 이상 복원되지 않는다.
- FR-011: PDF 파싱 실패 시 원본 PDF Reader는 유지되고 AI 의존 기능은 비활성화된다.
  - Consequences (testable): 파싱 실패 Paper를 열면 PDF 원문은 볼 수 있다.
  - Consequences (testable): Translation, Paper Chat, Brief 생성은 비활성 상태와 이유를 표시한다.
  - Consequences (testable): 사용자는 파싱 재시도를 실행할 수 있다.

### FG4. Translation

- FR-012: Translation은 원문과 번역을 문장 단위 1대1 대조로 보여준다.
  - Consequences (testable): 추출된 원문 문장은 대응 번역 문장과 쌍으로 표시된다.
  - Consequences (testable): 원문 문장 hover 시 대응 번역 문장이 함께 강조된다.
  - Consequences (testable): 번역 문장 hover 시 대응 원문 문장이 함께 강조된다.
- FR-013: 사용자는 번역 대상 언어를 설정할 수 있고 기본값은 한국어다.
  - Consequences (testable): 새 설치 기본 Translation 대상 언어는 한국어로 표시된다.
  - Consequences (testable): Settings에서 대상 언어를 바꾸면 새 Translation Job에 변경값이 적용된다.
  - Consequences (testable): 이미 생성된 Translation을 재생성할 때 현재 설정 언어가 사용된다.
- FR-014: Translation Job은 진행률, 오류, 재시도, 캐시 재사용을 제공한다.
  - Consequences (testable): 진행 중 Paper에는 Translation 진행 상태가 표시된다.
  - Consequences (testable): 실패한 페이지 또는 작업은 오류와 재시도 동작을 표시한다.
  - Consequences (testable): 완료된 Translation은 같은 Paper를 다시 열 때 다시 생성하지 않고 표시된다.
- FR-015: Translation은 정렬 불확실성을 정확도 보장으로 포장하지 않는다.
  - Consequences (testable): 정렬 실패 또는 보정 상태는 일반 정렬 성공과 구분되는 상태로 표시된다.
  - Consequences (testable): UI copy나 release copy는 문장 정렬의 완전 정확도를 주장하지 않는다.

### FG5. Paper Chat과 Chat Session

- FR-016: Paper Chat은 한 Paper에 대해 논문 전체 검색 근거로 답하는 단일 Chat이다.
  - Consequences (testable): Reader에는 일반 Chat과 Paper QA를 나누는 모드 토글이 없다.
  - Consequences (testable): 현재 페이지나 선택 문장을 자동 또는 수동으로 전달하지 않아도 Paper 전체 근거 검색으로 답변한다.
  - Consequences (testable): Paper 범위를 벗어난 일반 지시에는 논문 근거 기반 답변 범위가 유지된다.
- FR-017: Paper Chat 답변의 논문 주장에는 Evidence Anchor가 붙고, 근거 부족은 명시된다.
  - Consequences (testable): 논문 내용 질문의 답변에는 하나 이상의 Evidence Anchor 또는 근거 부족 상태가 표시된다.
  - Consequences (testable): Evidence Anchor hover 시 원문 미리보기가 보인다.
  - Consequences (testable): Evidence Anchor click 시 해당 PDF 페이지와 문장 강조 위치로 이동한다.
- FR-018: Paper Chat 대화는 Paper별 Chat Session으로 자동 저장되고 재개된다.
  - Consequences (testable): 질문 후 앱을 종료/재실행하면 같은 Paper에서 이전 대화를 다시 열 수 있다.
  - Consequences (testable): 한 Paper 안에 여러 Chat Session을 만들 수 있다.
  - Consequences (testable): Chat Session 목록에서 선택한 세션의 대화가 복원된다.
- FR-019: 사용자는 Chat Session을 생성, 이름 변경, 삭제할 수 있고 제목은 첫 질문에서 자동 생성된다.
  - Consequences (testable): 첫 질문 제출 후 세션 제목이 자동으로 채워진다.
  - Consequences (testable): 사용자가 제목을 수정하면 목록과 재진입 화면에 수정된 제목이 보인다.
  - Consequences (testable): 삭제된 Chat Session은 목록과 Paper 재진입 후에도 나타나지 않는다.

### FG6. Brief와 Template

- FR-020: Paper를 Library에 추가하면 구조화된 Markdown Brief가 생성된다.
  - Consequences (testable): Paper 추가 후 Brief Job이 생성되고 완료 상태를 표시한다.
  - Consequences (testable): 완료된 Brief는 독립 Brief 화면에서 Markdown 구조로 읽힌다.
  - Consequences (testable): Brief 생성 실패 시 오류와 재시도 동작이 표시된다.
- FR-021: 기본 Brief는 문제, 기존 방법 한계, 제안 방법, 논문 명시 한계, AI 분석 한계, 추가 최적화 가능성, 방법의 장점과 한계를 포함한다.
  - Consequences (testable): 기본 Brief 결과에는 위 항목들이 별도 섹션 또는 명확한 Markdown 항목으로 존재한다.
  - Consequences (testable): 논문이 명시한 한계와 AI가 분석한 가능성 있는 한계는 분리된 라벨로 표시된다.
  - Consequences (testable): 누락된 항목은 빈 성공처럼 보이지 않고 생성 결과에서 확인 가능한 상태를 갖는다.
- FR-022: 사용자는 기본 Template과 사용자 Template으로 Brief를 생성하거나 재생성한다.
  - Consequences (testable): Brief 생성 또는 재생성 시 Template 선택이 가능하다.
  - Consequences (testable): 재생성된 Brief는 이전 Brief와 구분되거나 현재 Brief로 명확히 교체된다.
  - Consequences (testable): 재생성 실패 시 기존 사용 가능한 Brief를 잃지 않는다.
- FR-023: 사용자는 사용자 Template의 Markdown 항목과 프롬프트를 편집한다.
  - Consequences (testable): Template 편집 화면에서 Markdown 섹션 목록을 추가/수정/삭제할 수 있다.
  - Consequences (testable): Template 프롬프트를 수정하고 저장할 수 있다.
  - Consequences (testable): 저장된 Template은 이후 Brief 생성 선택지에 나타난다.
- FR-024: Brief는 Evidence Anchor로 원문 근거를 확인할 수 있다.
  - Consequences (testable): Brief의 논문 주장에는 Evidence Anchor가 표시된다.
  - Consequences (testable): Anchor hover 시 짧은 원문 미리보기가 표시된다.
  - Consequences (testable): Anchor click 시 Reader가 해당 PDF 페이지와 문장 강조 위치로 이동한다.
- FR-025: Reader는 현재 PDF 페이지를 유지한 채 Brief Drawer를 제공한다.
  - Consequences (testable): Drawer를 열기 전후 Reader의 현재 PDF 페이지가 유지된다.
  - Consequences (testable): Drawer 안에서 Markdown Brief와 Evidence Anchor를 확인할 수 있다.
  - Consequences (testable): Drawer를 닫으면 Reader 읽기 상태로 돌아온다.

### FG7. Library와 재방문

- FR-026: Library는 Paper 폴더, 최근 읽은 Paper, 목록/카드 탐색을 제공한다.
  - Consequences (testable): 사용자는 폴더를 만들고 Paper를 폴더에 배치하거나 이동할 수 있다.
  - Consequences (testable): Library 첫 화면 또는 기본 영역에서 최근 읽은 Paper가 보인다.
  - Consequences (testable): Paper 카드 선택 시 Reader로 이동한다.
- FR-027: Paper 카드와 목록은 재방문에 필요한 식별 정보를 보여준다.
  - Consequences (testable): 카드에는 제목과 발행연도가 항상 보인다.
  - Consequences (testable): 목록 또는 카드에는 제목과 함께 한 줄 요약이 표시된다.
  - Consequences (testable): Abstract 일부와 주제 태그는 카드 hover 또는 세부 표시에서 확인할 수 있다.
- FR-028: 사용자는 태그, 검색/필터, 읽기 상태, 즐겨찾기로 Library를 정리한다.
  - Consequences (testable): Paper에 태그를 추가/수정/삭제할 수 있다.
  - Consequences (testable): 제목, 태그, 읽기 상태, 즐겨찾기 여부로 검색 또는 필터링할 수 있다.
  - Consequences (testable): 읽기 상태와 즐겨찾기 변경은 Library 재진입 후 유지된다.
- FR-029: Reader에서 만든 Highlight, Note, Brief, Reading Status, 마지막 읽은 위치는 Library에 남는다.
  - Consequences (testable): Reader에서 Highlight와 Note를 생성한 뒤 Library 또는 Paper 세부 정보에서 확인할 수 있다.
  - Consequences (testable): Brief와 읽기 상태는 해당 Paper의 Library 기록에 연결된다.
  - Consequences (testable): 앱 재실행 후에도 기록이 유지된다.

### FG8. 삭제와 Local App Data

- FR-030: 사용자는 Library에서 Paper를 삭제하고 연결된 파생 데이터 전체 삭제 결과를 확인한다.
  - Consequences (testable): 삭제 확인 후 해당 Paper는 Library 검색, 최근 읽은 Paper, 폴더 목록에서 보이지 않는다.
  - Consequences (testable): 삭제 후 해당 Paper의 PDF, Translation, Brief, Chat Session, Highlight, Note, 읽기 이력, 마지막 읽은 위치가 앱에서 재진입되지 않는다.
  - Consequences (testable): 삭제 완료 후 앱 재실행 시 삭제된 Paper가 복원되지 않는다.
- FR-031: 삭제 실패 또는 진행 중 Job과의 충돌은 완료로 오인되지 않게 표시된다.
  - Consequences (testable): 삭제 중 실패하면 삭제 미완료 상태와 재시도 동작이 보인다.
  - Consequences (testable): 진행 중 Job이 있는 Paper 삭제 시 Job 결과가 삭제 완료 후 Library에 다시 나타나지 않는다.
  - Consequences (testable): 부분 삭제 상태는 성공 완료 메시지로 표시되지 않는다.

### FG9. Job 상태와 복구

- FR-032: Import, parsing, Translation, Paper Chat 준비, Brief 생성은 Job 상태를 사용자에게 표시한다.
  - Consequences (testable): 각 Job은 pending/running/succeeded/failed 중 사용자가 이해할 수 있는 상태로 보인다.
  - Consequences (testable): 30초 안에 준비되지 않은 AI Job은 Reader 진입을 막지 않고 진행률 또는 대기 상태를 표시한다.
  - Consequences (testable): 동시에 여러 Job이 진행될 때 어떤 기능이 사용 가능한지 구분된다.
- FR-033: 실패한 Job은 오류 정보, 재시도, 사용 가능한 결과 유지 원칙을 따른다.
  - Consequences (testable): 실패한 Job은 어떤 기능이 실패했는지 표시한다.
  - Consequences (testable): 재시도 가능한 실패에는 재시도 동작이 제공된다.
  - Consequences (testable): Translation 실패가 PDF 원문 보기와 기존 Brief 읽기를 막지 않는다.
- FR-034: 앱 재실행 후 Job 완료/실패/재시도 필요 상태가 복구된다.
  - Consequences (testable): 앱 종료 전 실패한 Job은 재실행 후에도 실패 또는 재시도 필요 상태로 확인된다.
  - Consequences (testable): 완료된 결과는 재실행 후에도 사용 가능하다.
  - Consequences (testable): 복구 상태에는 Reader 열기, 재시도, 사용 불가 중 적용 가능한 다음 동작이 표시된다.

### FG10. Release Packaging

- FR-035: v1 공개 패키지는 macOS에서 설치 또는 실행 가능한 공개 오픈소스 산출물이어야 한다.
  - Consequences (testable): 공개 저장소 또는 배포 산출물에서 macOS 실행 방법을 확인할 수 있다.
  - Consequences (testable): 첫 실행 Provider 설정 절차가 공개 문서 또는 앱 안에서 설명된다.
  - Consequences (testable): public v1 배포 산출물에는 최종 확정된 오픈소스 라이선스가 명시된다.
- FR-036: v1 문구는 후속 후보를 출시 약속처럼 표현하지 않는다.
  - Consequences (testable): v1 UI와 공개 설명은 추천, 지식 그래프, 로컬 모델, cloud sync를 v1 기능처럼 표시하지 않는다.
  - Consequences (testable): 후속 후보는 roadmap/candidate 표현으로만 나타난다.

## 8. 플랫폼 요구사항

- v1은 macOS만 지원한다.
- v1은 데스크톱 사용 맥락을 우선한다.
- v1은 모바일, 웹 동기화, 다중 기기 동기화를 제공하지 않는다.
- v1은 PaperLens 계정 생성이나 PaperLens 클라우드 로그인을 제공하지 않는다.

## 9. 교차 비기능 요구사항

- NFR-001: arXiv URL 제출 후 PDF 원문을 볼 수 있을 때까지 최대 30초를 목표로 한다.
- NFR-002: [ASSUMPTION A-002] 30초 목표는 일반 네트워크 상태, 정상 접근 가능한 arXiv/PDF URL, 과도하게 크지 않은 텍스트 기반 논문 PDF를 기준으로 검증한다.
- NFR-003: 로컬 PDF와 일반 PDF URL은 PDF 원문 접근을 AI Job 완료보다 우선하며, source별 세부 시간 기준은 Architecture/QA에서 측정 가능한 기준으로 확정한다.
- NFR-004: 느린 Reader 준비는 사용자가 첫 가치를 경험하기 전 이탈하게 만드는 핵심 리스크이므로 PDF 원문 접근을 우선한다.
- NFR-005: PaperLens는 AI 답변, Brief, Translation, Evidence Anchor의 완전한 정확도를 주장하지 않는다.
- NFR-006: 논문 주장에 대한 AI 출력은 Evidence Anchor와 연결되거나 근거 부족 상태를 명시해야 한다.
- NFR-007: Local App Data는 macOS 앱 로컬 데이터로 저장되며 cloud backup/sync/recovery를 제품 기능으로 제공하지 않는다.
- NFR-008: Paper 삭제는 PDF와 모든 파생 데이터를 함께 삭제하는 완료 동작이어야 한다.
- NFR-009: [ASSUMPTION A-003] Provider 비밀정보는 OS keychain에 저장하지 않는 최신 결정을 따른다.
- NFR-010: 외부 Provider 사용에 따라 논문 및 개인 데이터가 외부로 전송될 수 있음을 제품 전제로 삼는다.

## 10. 제약과 가드레일

- [제약] v1 개발 맥락은 개발자 1명이 agentic coding으로 첫 공개 버전을 만드는 것이다. 범위 리스크는 수용되었고, 확정 기능 그룹은 출시 필수로 유지한다.
- [제약] EasyPaper 등 외부 제품은 UX 영감으로만 참고하고 코드를 재사용하지 않는다.
- [제약] PaperLens는 기술적 moat, 완전 정확도, privacy-first/local-first 제품을 주장하지 않는다.
- [제약] generic Codex OAuth라는 표현은 사용하지 않는다. 공식 Codex SDK ChatGPT 로그인 또는 device-code 흐름만 v1 연결 방식으로 표현한다.
- [제약] 구체적인 PDF 파싱 기술, 저장 구조, 구현 라이브러리, 데이터베이스 스키마는 PRD 본문에 포함하지 않고 Architecture 단계에서 결정한다.
- [제약] PaperLens 공개 저장소와 v1 공개 패키징은 `AGPL-3.0-only`를 최종 오픈소스 라이선스 제약으로 따른다.
- [제약] v1 UI와 공개 문서는 후속 후보를 release promise로 표현하지 않는다.

### 10.1 Architecture Gate

- Provider secret gate: Provider 비밀정보를 다루는 구현 story는 Architecture가 local storage location/class, at-rest protection decision, file permissions, log redaction, backup inclusion/exclusion, deletion behavior, OS keychain 미사용에 대한 threat acceptance를 기록하기 전에는 시작하지 않는다. 이 gate는 기술 선택이 아니라 downstream pass/fail handoff 조건이다. Applies to: FR-002, FR-003, FR-004, NFR-009, A-003.
- Evidence Anchor gate: Evidence Anchor 관련 QA/story acceptance는 UX/Architecture가 PDF 페이지, 추출 문장 식별자, visible highlight의 세부 계약과 실패 상태를 기록하기 전에는 확정하지 않는다. Existing owner/revisit: A-001의 UX/Architecture, UX detail/Architecture/QA stories 전.
- 30-second test gate: PDF-visible 30초 목표 관련 QA/story acceptance는 Architecture/QA가 A-002의 테스트 조건과 source별 측정 경계를 기록하기 전에는 확정하지 않는다. Existing owner/revisit: A-002의 Architecture/QA, release QA plan 전.

## 11. Release Acceptance Metrics

- SM-001: 샘플 arXiv abstract URL에서 Provider 설정, 가져오기, 30초 목표 기준 내 PDF-visible Reader 진입, Translation/Brief/Paper Chat Job 상태 표시가 한 흐름으로 검증된다.
- SM-002: 샘플 Paper에서 Translation 문장 hover 양방향 강조, Paper Chat Evidence Anchor hover/click, Brief Evidence Anchor hover/click이 모두 PDF 페이지와 visible highlight로 돌아간다.
- SM-003: 파싱 실패 샘플에서 PDF Reader 유지, AI 기능 비활성화, 오류 정보, 재시도 동작, 재실행 후 실패 상태 복구가 검증된다.
- SM-004: Library에서 최근 읽은 Paper, 폴더 이동, 태그 검색/필터, 읽기 상태, 즐겨찾기, 하이라이트, 노트, 마지막 읽은 위치 복원이 검증된다.
- SM-005: Paper 삭제 후 Library 검색/필터/최근 읽은 Paper/Reader 재진입에서 해당 Paper와 파생 데이터가 보이지 않고, 재실행 후에도 복원되지 않는다.
- SM-006: 공개 macOS v1 오픈소스 산출물에서 실행 방법, Provider 설정 방법, 최종 확정된 라이선스가 확인된다.

### Counter-Metrics

- CM-001: PDF-visible 속도 개선이 Evidence Anchor 생성 실패, 잘못된 clickback, 근거 부족 미표시 증가를 정당화하지 않는다.
- CM-002: v1 기능 개수 완료율이 end-to-end 루프 검증 실패를 가리지 않는다. SM-001부터 SM-005 중 하나라도 실패하면 release-ready로 보지 않는다.
- CM-003: AI 응답 유창성이 원문 근거 없는 논문 주장 생성을 정당화하지 않는다.

## 12. 리스크

- R-001: PDF 파싱 실패나 품질 저하가 Translation, Paper Chat, Brief의 사용 가능성을 제한할 수 있다. Impacts: FR-011, FR-012, FR-017, FR-020, NFR-006.
- R-002: 문장 수 불일치로 원문-Translation 정렬과 Evidence Anchor 품질이 흔들릴 수 있다. Impacts: FR-012, FR-015, FR-017, FR-024, NFR-005.
- R-003: Provider 필수 Onboarding은 첫 사용 진입 장벽을 높일 수 있다. Impacts: FR-001, FR-002, FR-003, SM-001.
- R-004: 외부 Provider 전송 전제와 별도 consent gate 없음은 사용자 기대와 충돌할 수 있다. Impacts: FR-003, NFR-010.
- R-005: OS keychain을 쓰지 않는 비밀정보 저장 결정은 보안 리뷰와 Architecture 단계에서 별도 acceptance boundary가 필요하다. Impacts: FR-004, NFR-009.
- R-006: macOS only와 no cloud sync는 초기 범위를 줄이지만 다중 기기 사용 기대와 충돌할 수 있다. Impacts: FR-035, NFR-007.
- R-007: 확정 feature group이 모두 launch-blocking이므로 1인 개발 v1에서 일정과 품질 리스크가 크다. Impacts: all FG, SM-001 through SM-006.
- R-008: 느린 Reader 진입은 사용자가 핵심 가치를 경험하기 전에 이탈하게 만들 수 있다. Impacts: FR-007, FR-032, NFR-001, NFR-004.

## 13. Assumptions Index

- A-001: Evidence Anchor는 PDF 페이지, 추출 문장 식별자, 화면에서 보이는 강조 위치로 검증한다. Source: memlog. Owner: UX/Architecture. Needed before: UX detail, Architecture, QA stories.
- A-002: 30초 PDF-visible 목표는 일반 네트워크 상태, 정상 접근 가능한 arXiv/PDF URL, 과도하게 크지 않은 텍스트 기반 논문 PDF를 기준으로 검증한다. Source: PRD synthesis. Owner: Architecture/QA. Needed before: release QA plan.
- A-003: Provider 비밀정보를 OS keychain에 저장하지 않는 결정은 유지하되, Architecture는 local storage location/class, at-rest protection decision, file permissions, log redaction, backup inclusion/exclusion, deletion behavior, OS keychain 미사용에 대한 threat acceptance를 기록해야 한다. Source: memlog/review. Owner: Architecture. Needed before: Provider secret implementation/stories.

## 14. Deferred Items

- D-001: 추천 시스템과 개인 지식 그래프는 v1 이후 후보이며 v1 release promise가 아니다.
- D-002: 로컬 모델 연결은 v1 이후 후보이며 v1 Provider 없는 사용을 의미하지 않는다.
- D-003: 읽기 전 브리핑은 핵심 개요, 연구 계보, 파인만식 설명, 용어집, 질문 거리 제공을 포함할 수 있는 이후 후보다.
- D-004: 인용, 그림, 표, 수식 참조 오버레이와 완전한 표/그림/수식 분석은 v1 이후 후보다.
- D-005: 일반 목적 독립 AI Chat 병행은 v1에서 제외되며, 장기 후보로 재검토하더라도 v1 Paper Chat의 항상 근거 기반 원칙을 바꾸지 않는다.
- D-006: AI 채팅 내용을 연구 기록으로 정리하고 QA 이후 후속 질문을 추천하는 기능은 v1 이후 후보다.
