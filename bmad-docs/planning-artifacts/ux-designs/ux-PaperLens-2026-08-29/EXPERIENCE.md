---
name: PaperLens
status: final
updated: 2026-09-27
sources:
  - path: bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/prd.md
    commit: 3bb2edf6a8d3d7f4942dd439325136b6fcb50456
    role: 승인된 제품 기준 (FR-001..FR-036, NFR-001..NFR-010, SM-001..SM-006)
  - path: bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/addendum.md
    commit: 3bb2edf6a8d3d7f4942dd439325136b6fcb50456
    role: 승인된 제품 부록 및 캡처된 UX 결정의 기준
  - path: bmad-docs/planning-artifacts/architecture/architecture-PaperLens-2026-08-28/ARCHITECTURE-SPINE.md
    commit: cdabe4419606ab0c1efebcfeb79bded0fe344512
    role: 승인된 아키텍처 계약 (AD-1..AD-14, P-1..P-6는 증거 전까지 게이트)
  - path: bmad-docs/planning-artifacts/architecture/architecture-PaperLens-2026-08-28/SOLUTION-DESIGN.md
    commit: cdabe4419606ab0c1efebcfeb79bded0fe344512
    role: 승인된 솔루션 설계 동반 문서
pending_sources:
  - path: bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/prd.md
    status: UNAPPROVED thematic amendment (FR-037..FR-039, SM-007); not implementation authority
  - path: bmad-docs/planning-artifacts/prds/prd-PaperLens-2026-08-27/addendum.md
    status: UNAPPROVED thematic amendment context; not implementation authority
---

# PaperLens — Experience Spine

> **문서 완성과 승인 경계.** `status: final`은 UX 문서 작성·검토가 끝났다는 뜻이며 제품·구현 승인이 아니다. 제품 기준은 `APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456`, 아키텍처 기준은 `APPROVED: ARCHITECTURE @ cdabe4419606ab0c1efebcfeb79bded0fe344512`이다. 작업 트리 PRD/addendum의 FR-037..FR-039와 SM-007 및 관련 테마·명암 계약은 **UNAPPROVED thematic amendment**로 `pending_sources`에 분리했으며, 새 PRODUCT 승인 전 구현 권한이 아니다. `docs/ai-governance.md`에 따라 침묵은 승인 아님이다.
>
> `DESIGN.md`는 시각 계약을, 이 문서는 정보 구조·행동·상태·상호작용·접근성 계약을 소유한다. [`direction-native-canvas.html`](./mockups/direction-native-canvas.html), [`direction-scholarly-press.html`](./mockups/direction-scholarly-press.html), [`direction-focused-instrument.html`](./mockups/direction-focused-instrument.html)는 세 방향의 Light/Dark 정적 비교 참조다. 앱 구현이나 상호작용 QA 증거가 아니며 HTML과 충돌하면 두 문서의 해당 영역 계약이 우선한다.

## Foundation

PaperLens v1은 macOS 15+ native desktop 앱이다. Main App의 SwiftUI/PDFKit Reader, Application 소유의 durable state, PDFium extraction 경계와 Provider 경계는 승인된 Architecture Spine의 구조적 맥락이며 이 문서는 framework API나 저장 schema를 정하지 않는다. 모바일, 웹, cloud account/sync, Provider 없는 제한 모드는 이 UX 범위가 아니다. `DESIGN.md`는 visual identity이고 이 spine은 그 identity를 어떤 상태와 행동으로 경험하는지 정의한다.

**[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]** Native Canvas가 새 설치의 기본 테마다. Settings에서 Scholarly Press와 Focused Instrument를 선택할 수 있고, 세 방향 각각에 Light/Dark가 있다. 테마 선택은 Library·Reader·Brief·Settings 전반에 일관되게 적용하고 다음 launch에도 유지한다. Appearance의 기본값은 **System**이며 Settings의 별도 `System`/`Light`/`Dark` 선택으로 관리한다. 테마와 appearance를 바꿔도 Paper, 현재 PDF page, 열린 Chat Session, Note, Brief, Job 상태를 바꾸거나 새 AI Job을 시작하지 않는다. 이 thematic amendment는 제품 재승인 전 구현 권한이 아니다.

HTML 시안의 browser `color-scheme`, `:hover`, `:focus-visible`, `:has()`, CSS media query, `progress`, `overflow: auto`, traffic-light 원은 비교 artifact의 관찰 가능한 표현이다. Native runtime은 그 표현을 복사하는 대신 macOS native titlebar/control, keyboard focus, VoiceOver semantics, window resizing 규칙으로 같은 의미를 제공한다. HTML의 30px control, 1440×900 frame, 1240px media rule은 native hit-area·breakpoint·window policy를 승인하지 않는다. HTML의 paper 색과 읽기 서체는 종이 모형이며 실제 `Original PDF` content와 PDF가 지정한 글꼴은 테마로 restyle하지 않는다. 테마는 PDF 주변 chrome과 Translation surface에 적용된다.

## Information Architecture

| Surface | 진입 | 역할과 완료 지점 |
|---|---|---|
| `ProviderOnboarding` | 새 설치 launch | OpenAI API key와 공식 Codex SDK ChatGPT 로그인/device-code 중 하나를 선택하고 실제 인증 v1 요청을 성공시킨다. 성공 전 Library/Reader를 열지 않는다. |
| Library | Onboarding의 Continue, titlebar 뒤로가기 | Paper 폴더·최근 읽은 Paper·카드/목록·검색/필터·태그·Reading Status·Favorite·삭제를 관리한다. `LibraryOrganizationControls`와 `LibrarySearchFilters`가 정리·탐색을 맡고, supported file/URL drag-over 시 `ImportDropTarget`이 된다. |
| Import | Library의 drop, URL paste 또는 local file action | arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF를 인식하고 `ImportConfirmationSheet`에서 Folder/default와 duplicate를 확인한 뒤 Import Job을 시작한다. |
| `ReaderShell` | Library Paper 선택 또는 `Open Reader` | 왼쪽 `ReaderOutline`, `PdfPanel`, 오른쪽 `TranslationPanel`/`PaperChatPanel`, `BriefTrigger`, Highlight/Note를 한 Paper context로 제공한다. PDF 원문은 AI Job과 독립적으로 먼저 읽힌다. |
| Brief | Reader `BriefTrigger` 또는 독립 Brief 진입 | `BriefView`에서 기본/사용자 Template으로 생성된 Markdown Brief와 Evidence Anchor를 읽는다. Drawer를 열고 닫아도 Reader page는 유지한다. |
| Settings | 앱 설정 진입 | `ProviderSettings`, `TranslationLanguageControl`, user Template, `ThemePicker`, `AppearancePicker`를 관리한다. Template 편집은 `TemplateEditor` 전용 화면으로 이동한다. Theme/appearance 항목은 **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]**다. |
| Template editor | Settings의 Template 관리 | Paper와 독립적인 reusable Template의 Markdown sections와 prompts를 수정·저장한다. 저장 후 원래 Brief context로 돌아간다. |

`Translation` tab이 활성인 Reader의 기본 composition은 PDF와 Translation을 equal split으로 둔다. PDF page navigation이 현재 Translation page를 제어하고, Translation 내부 이동은 PDF page를 움직이지 않는다. 오른쪽 work area의 tab은 Translation과 Paper Chat이며 Brief는 drawer다. `Paper Chat` tab의 정확한 열 비율은 이 시안에서 확정하지 않는다. 이 구조는 [`direction-native-canvas.html`](./mockups/direction-native-canvas.html)에서 Light/Dark로 비교되며 다른 두 HTML도 같은 Reader outline·toolbar·job strip·comparison skeleton을 보여준다.

## Voice and Tone

짧고 차분한 한국어 상태 문구를 사용한다. 문구는 현재 상태와 사용자가 할 수 있는 다음 행동을 함께 말하되, 정확도·privacy·삭제 범위를 과장하지 않는다. 제품을 홍보하는 배너나 추천 문구는 사용하지 않는다.

| Do | Don't |
|---|---|
| `재시도`, `Retry Parsing`, `Template 관리`, `새 대화`, `삭제 미완료`처럼 행동과 상태를 구분한다. | 실패를 녹색 성공처럼 보이게 하거나, 상태를 색/아이콘 하나로만 말한다. |
| `Translation`, `Paper Chat`, `Brief`, `Original PDF`처럼 Reader의 고정 용어를 일관되게 쓴다. | `generic Codex OAuth`, 일반 AI Chat, 근거 모드 토글처럼 승인되지 않은 용어를 만든다. |
| “원본 PDF는 계속 볼 수 있음”처럼 사용 가능한 결과와 제한된 AI 결과를 분리한다. | “모든 내용이 정확히 번역됨”, “외부로 전송되지 않음”, “외부에서도 완전히 삭제됨”처럼 검증되지 않은 보장을 한다. |
| 삭제 확인에서 Paper 이름과 제품에서 제거되는 local content를 명확히 적고 `Cancel`/destructive `Delete`를 분리한다. | AD-4/AD-11의 내부 accepted limit을 onboarding, Settings, 삭제 UI, 문서, consent 또는 공지로 노출한다. |
| 저장·재시도·복구 상태를 짧은 완결 문장과 explicit action으로 제시한다. | 진행률을 기다리기 위해 PDF 원문 접근을 막거나, 실패한 external work를 몰래 자동 재시도한다. |

## Component Patterns

행동 규칙은 아래 표에, 시각 anatomy는 `DESIGN.md`의 같은 이름에 있다. 명시적인 custom layout이 없는 control은 macOS inherited control과 native interaction을 사용하며, 이 표는 필요한 behavioral delta만 추가한다. `{colors.native-canvas-panel-light}`/`{colors.native-canvas-panel-dark}`는 Native Canvas baseline이며, 테마가 바뀌면 같은 semantic role을 `{colors.scholarly-press-panel-light}`/`{colors.scholarly-press-panel-dark}` 또는 `{colors.focused-instrument-panel-light}`/`{colors.focused-instrument-panel-dark}`로 치환한다. 이 치환은 상태 의미를 바꾸지 않는다.

| Component | 사용 surface | 행동 계약 |
|---|---|---|
| `ProviderOnboarding` | Onboarding | 첫 launch에 full-window로 먼저 보인다. API key와 공식 Codex SDK ChatGPT 로그인/device-code를 동등한 선택지로 보여준다. 연결 테스트가 실패하면 현재 form에 머물고 안전한 입력은 보존하며 redacted reason, `Retry`, `Change Provider Path`를 제공한다. 실제 인증 v1 요청이 성공한 뒤에도 자동 이동하지 않고 `Continue`로 Library에 들어간다. |
| `ProviderSettings` | Settings | 현재 연결된 Provider와 상태, 재입력/재로그인, 연결 테스트를 macOS inherited settings control로 제공한다. 재테스트가 실패해도 기존 기능 사용 가능 여부는 마지막 성공 연결 상태를 기준으로 일관되게 표시하며, 실패를 새 성공으로 승격하지 않는다. |
| `TranslationLanguageControl` | Settings | 번역 대상 언어를 native selection control로 보여주며 새 설치 기본값은 한국어다. 선택 변경은 새 Translation Job과 명시적 재생성 Job에만 적용하고, 이미 생성된 Translation을 조용히 바꾸지 않는다. |
| `ImportDropTarget` | Library | 평상시 Library content를 유지한다. 지원 file/URL이 window 위에 drag-over될 때 surface 전체를 drop target으로 바꾼다. URL paste와 local file 선택은 secondary explicit action으로 남긴다. `{spacing.4}` 단위의 hover/drag state는 label과 함께 표시한다. |
| `ImportConfirmationSheet` | Import | arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF 중 인식된 branch와 recognized Paper, destination Folder/default, duplicate status를 한 compact sheet에서 확인한다. 사용자가 Cancel 또는 Continue를 선택하기 전 Import Job을 시작하지 않는다. Continue 뒤에는 자동으로 Reader로 보내지 않고 Library에 남긴다. |
| `JobStatusStrip` | Library·Reader·Brief | Import, parsing, Translation, Paper Chat 준비, Brief 생성의 pending/running/succeeded/failed를 구분한다. 30초 soft target을 UI timer로 약속하지 않는다. 실패에는 이유와 explicit retry를 붙이고, 재실행 후 persisted state를 복원한다. `{colors.native-canvas-error-light}`/`{colors.native-canvas-error-dark}`는 text/outline과 함께 쓴다. |
| `LibraryPaperCard` | Library card view | 카드 default view에서 title, publication year, one-line summary, reading state/favorite와 more-actions를 보여준다. 클릭은 저장된 last-read position의 Reader를 연다. duplicate warning이나 deletion state가 card를 성공처럼 보이게 하지 않는다. |
| `LibraryPaperRow` | Library list view | list alternate view에서 카드와 같은 식별 정보를 선형으로 보여준다. 사용자가 고른 card/list preference를 local preference로 유지한다. 카드/row의 hover 또는 detail에서 abstract 일부와 topic tags를 확인할 수 있다. 삭제 중·실패 row는 openable하지 않고 `삭제 미완료`와 `Retry Deletion`만 제공한다. |
| `LibraryOrganizationControls` | Library | macOS inherited controls로 Folder 생성·Paper 배치/이동, tag 추가·수정·삭제, Reading Status 변경, Favorite 전환을 제공한다. 변경한 값은 Library 재진입 시 유지하며, card/list presentation과 독립적으로 같은 Paper에 적용한다. |
| `LibrarySearchFilters` | Library | top toolbar search와 left sidebar의 tag·Reading Status·Favorite filter를 제공한다. title, tag, Reading Status, Favorite로 검색·필터하고 card/list presentation 모두에 같은 결과를 적용한다. 결과 없음은 populated/empty와 구분한다. |
| `ReaderShell` | Reader | Paper 하나의 PDF, Translation, Paper Chat, Brief, Highlight/Note context를 묶는다. PDF가 준비되면 AI Job이 pending이어도 openable하다. 저장된 last-read position을 재진입·재실행 때 복원한다. `{rounded.native-window}`를 semantic window token으로 사용하며 native window corner 자체는 macOS가 소유한다. |
| `ReaderOutline` | Reader left sidebar | Paper metadata, Contents, active section, last position을 제공한다. section 선택은 PDF navigation을 바꾸고 Translation을 그 page로 맞춘다. Parsing failure recovery action은 여기 두지 않고 오른쪽 work panel에 둔다. |
| `ReaderToolbar` | Reader top | 이전/다음 page, page count, zoom, PDF search를 제공한다. PDF navigation은 Translation page를 제어하고, Translation navigation은 PDF를 움직이지 않는다. `⌘F` 같은 native shortcut은 macOS convention과 충돌하지 않는 범위에서만 쓴다. |
| `PdfPanel` | Reader left comparison | Original PDF는 Translation 준비 여부와 무관하게 scroll/search/select 가능하다. page·zoom·selection은 feature-local state이며 durable Paper state는 Application use case가 저장한다. `{spacing.paper-page-width}`와 paper typography는 시각 기준이지 PDF source의 실제 page size를 뜻하지 않는다. |
| `TranslationPanel` | Reader right comparison | current PDF page의 Translation을 보여준다. pending은 in-place loading/progress, failure는 reason과 inline `Retry`를 보인다. PDF는 계속 읽을 수 있으며, alignment uncertainty를 anchored success로 표현하지 않는다. |
| `SentenceMatch` | PdfPanel·TranslationPanel | 원문 sentence와 번역 sentence의 bidirectional hover highlighting을 제공한다. hover에 대응하는 pair를 강조하고, keyboard focus도 같은 highlight를 만든다. 문장 순서·citation range·PDF page를 임의로 바꾸지 않는다. `{colors.native-canvas-match-light}`/dark는 text만으로 대체하지 않는다. |
| `PaperChatPanel` | Reader right tab | 처음에는 empty question composer다. 첫 질문 submit 때만 Chat Session을 만든다. current page·selection·highlight를 context로 전달하지 않으며, 항상 해당 Paper 전체 search evidence를 사용한다. 일반 Chat/Paper QA mode toggle은 없다. |
| `EvidenceAnchor` | Paper Chat·Brief | 논문 주장에 inline으로 붙는다. hover/focus는 full source sentence preview, click은 PDF page와 visible highlight로 이동한다. 상태는 `anchored`, `insufficientEvidence`, `locationUnclear`, `navigationFailed`, `staleRevision`을 서로 구분하며 불명확 위치를 성공으로 바꾸지 않는다. `{colors.native-canvas-accent-light}`/dark는 anchor 의미에만 쓴다. |
| `BriefTrigger` | Reader comparison edge | 현재 PDF page를 유지한 채 Brief Drawer를 연다. Drawer 안에서 Markdown Brief와 anchor를 읽고 닫으면 같은 Reader position으로 돌아온다. Brief generation failure는 prior usable Brief를 대체하지 않는다. |
| `BriefView` | 독립 Brief·Brief Drawer | 기본 Brief는 `문제`, `기존 방법 한계`, `제안 방법`, `논문 명시 한계`, `AI 분석 한계`, `추가 최적화 가능성`, `방법의 장점과 한계`를 별도 섹션 또는 명확한 Markdown 항목으로 보여준다. 논문 명시 한계와 AI 분석 한계를 분리하고, 근거 또는 입력이 없는 항목은 빈 성공처럼 보이지 않는 missing-content 상태로 남긴다. |
| `SelectionActionBar` | PDF selection | 텍스트 선택 후 `Highlight`, `Add Note`, `Copy`를 보여준다. 선택 문장을 Paper Chat context로 보내는 action은 없다. `Add Note`는 현재 PDF position과 selected source를 보존한 `NotesDrawer`를 연다. |
| `NotesDrawer` | Reader | Add Note에서 right drawer로 열린다. 저장된 Note는 Paper의 Library 기록에 남고, drawer close는 같은 Reader context로 돌아간다. anchored claim과 개인 Note를 같은 evidence type으로 표시하지 않는다. |
| `TemplateSelector` | Brief | 기본 또는 reusable user Template을 선택한다. `Template 관리`는 Settings의 `TemplateEditor`로 이동하며, 저장 후 originating Brief로 돌아오되 자동 regenerate하지 않는다. 선택만으로 generation Job을 만들지 않는다. |
| `TemplateEditor` | Settings | Markdown section 추가/수정/삭제와 prompt 저장을 담당한다. 저장은 immutable Template version을 만든다는 Architecture 계약을 따르며, 특정 Paper 삭제 후에도 user Template은 남는다. validation 규칙은 `[열린 결정]`으로 남겨 제품 기능을 추가하지 않는다. |
| `ChatSessionMenu` | PaperChatPanel | 현재 title dropdown에서 여러 Chat Session을 선택하고 in-place로 복원한다. beside title의 `새 대화`는 empty composer를 열고 첫 질문 전에는 새 session을 만들지 않는다. entry와 current session 양쪽 more-actions가 같은 rename/delete action을 호출한다. |
| `DeleteAlert` | Library Paper, Chat Session | Paper 삭제는 macOS system alert에서 Paper 이름, 제품에서 제거될 local content, irreversible action, `Cancel`/destructive `Delete`를 명시한다. Chat Session 삭제도 title을 확인하는 warning dialog가 필요하다. accepted-limit disclosure는 추가하지 않는다. |
| `ThemePicker` | Settings | **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]** Native Canvas·Scholarly Press·Focused Instrument 세 테마만 선택한다. 선택한 theme은 유지하고 appearance와 독립적으로 전환하며, 읽기 위치·열린 session·데이터·Job을 건드리지 않는다. `{colors.native-canvas-accent-soft-light}`/dark 또는 선택 theme의 대응 token으로 selected theme state를 표시한다. |
| `AppearancePicker` | Settings | **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]** Theme과 별도의 macOS inherited appearance control로 `System`을 기본값으로 하고 `System`/`Light`/`Dark`를 선택한다. 선택한 appearance는 재실행 후 복원하며 theme, Paper, 현재 page, session, data, Job을 바꾸지 않는다. |
| `StatusBar` | Reader bottom | 현재 page, PDF navigation이 Translation을 제어한다는 관계, sentence match 같은 status를 text로 제공한다. HTML의 `Match 03`은 비교 label이며 모든 alignment가 항상 성공한다는 보장이 아니다. |

**테마·명암의 정책과 소유권 — 제품 개정 승인 대기:** System은 현재 macOS 명암을 따르며 OS 명암이 바뀌면 화면에 반영한다. Light/Dark 명시 선택은 OS 변경으로 덮어쓰지 않는다. 재실행 시 직전 색상이 아니라 선택한 정책을 복원한다. 두 설정은 AD-1의 Application use case와 기존 persistence 경계가 소유하는 Paper-independent 상태이며 Paper 삭제 후에도 유지된다. Feature가 별도 durable owner를 만들거나 SQLite에 직접 접근하지 않는다. 구체 저장 기술은 Build Spec에서 정하며, 설정·OS 명암 변경이 Paper/Job 상태 또는 원본 PDF를 변경하거나 AI 요청을 만들지 않는다.

## State Patterns

상태는 색·아이콘 하나가 아니라 이름, 설명, 다음 행동으로 전달한다. visual surface는 선택한 theme의 대응 token을 사용하며 `{colors.native-canvas-success-light}`/dark 및 `{colors.native-canvas-error-light}`/dark는 semantic role일 뿐 실제 대비 QA 완료를 뜻하지 않는다.

| Surface | 반드시 다루는 상태 | 사용자에게 보이는 계약 |
|---|---|---|
| Onboarding | cold/selection/input/testing/succeeded/failed | 새 설치에는 Provider form만 보인다. 실패는 form을 떠나지 않고 redacted reason·Retry·Change Provider Path를 보인다. 성공은 connected Provider와 explicit Continue를 보인다. |
| Settings | cold/loading/provider-connected/provider-retest-failed/language-selected/template-return/theme-selected/appearance-selected/relaunched | `ProviderSettings`는 current status와 재테스트를 보여준다. 재테스트 실패는 last-good 연결 상태 기준의 기능 가용성을 유지한다. `TranslationLanguageControl`은 한국어 기본값과 새/재생성 Job 적용 상태를 구분한다. Template 저장 후 originating Brief로 돌아간다. Theme/appearance 상태는 **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]**이며, appearance는 System 기본과 System/Light/Dark 선택을 복원한다. |
| Library | cold-loading/populated/empty/no-match/card/list/drop-over/organization-changed/organization-reloaded/deleting/deletion-failed | loading 중에는 구조가 유지된다. empty에는 Import로 갈 수 있는 짧은 next action이 필요하다. no-match는 검색·filter 결과 없음으로 구분한다. drop-over는 전체 surface가 target이다. Folder·tag·Reading Status·Favorite 변경은 현재 값과 재진입 후 값을 보여준다. deleting/deletion-failed row는 non-openable이다. |
| Import | idle/recognized-arxiv-abstract/recognized-arxiv-pdf/recognized-general-pdf/recognized-local-pdf/duplicate/cancelled/running/pdf-ready/failed/recovered | 네 입력 branch를 구분해 인식한 뒤 sheet에서 모든 import 전 결정을 끝내고 Job을 만든다. arXiv abstract URL은 PDF 가져오기로 해석하고 local PDF는 네트워크 URL 없이 Paper 생성을 시작한다. PDF-ready면 AI Job과 무관하게 Library row에 `Open Reader`를 노출한다. 실패는 reason과 Retry를 보이고 앱 relaunch 후에도 필요한 상태를 복구한다. |
| Reader/PDF | page-ready/loading/search-no-match/selected/zoomed | PDF page·zoom·search·text selection은 Translation/Chat/Brief Job과 독립적이다. no-match 검색은 결과 없음으로 말하고 selection은 `SelectionActionBar`를 연다. |
| Reader/parsing | parse-pending/parse-failed/retry-running/retry-failed/parse-ready | parse failure를 즉시 in-app floating notification으로 알리고 right work panel에 latest reason과 `Retry Parsing`을 둔다. left `ReaderOutline`에는 recovery action을 두지 않는다. PDF는 계속 usable하며 attempt history를 노출하지 않는다. |
| Translation | page-pending/running/succeeded/failed/alignment-uncertain/cached | 완료 page부터 보이고 미완료 page는 PDF와 in-place loading/error를 동시에 유지한다. 실패 page만 inline Retry한다. alignment uncertainty는 normal 1:1 성공과 다른 상태다. |
| Paper Chat | empty/creating/loading/answer/insufficientEvidence/locationUnclear/navigationFailed/staleRevision | first question submit 때 session을 만든다. 답변 claim에는 anchor 또는 근거 부족 상태가 있고, anchor click이 실패해도 성공 link로 위장하지 않는다. |
| `Brief` | auto-pending/ready/missing-content/regenerating/failed-with-prior/empty | Paper 추가 시 default Template Brief Job이 시작된다. `BriefView`는 일곱 required section을 표시하고, 논문 또는 AI 분석 근거가 없는 항목은 missing-content로 구분한다. regeneration failure는 prior usable Brief를 보존하고 Retry/명확한 실패 상태를 보인다. Drawer close는 Reader page를 바꾸지 않는다. |
| Library deletion | confirm/deleting/deletion-failed/deleted | success 전에는 Paper를 부분 삭제 성공처럼 숨기지 않는다. exceptional failure에는 기존 card/row를 non-openable로 유지하고 `삭제 미완료`와 같은 saga를 재개하는 `Retry Deletion`만 보인다. 성공하면 Paper 소유 데이터와 Library entry가 사라지고 independent user Template은 남는다. |
| Template | selecting/editing/saved/returning | Settings editor에서 저장 후 originating Brief로 돌아오고 Template을 선택 상태로 두지만 자동 regenerate하지 않는다. 저장 규칙 외의 validation copy는 `[열린 결정]`이다. |
| Chat Session | empty/creating/autosaving/current/list/relaunch-restored/renaming/delete-confirmed/remaining-restored/no-session | 첫 질문 후 대화와 session을 자동 저장한다. 앱 종료·재실행 후 같은 Paper에서 이전 session을 다시 열 수 있고 목록 선택은 대화를 복원한다. title dropdown에서 선택하면 현재 panel이 in-place로 바뀐다. rename은 현재 title이 미리 채워진 macOS dialog다. current session 삭제 후 가장 최근 active session을 열고 마지막이면 replacement를 만들지 않은 empty composer로 돌아간다. |
| Theme/appearance | native-default/selected-theme/system-default/selected-light/selected-dark/switching/restored | **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]** Native Canvas가 저장된 theme 없음의 기본값이다. Appearance는 System 기본이며 Settings에서 System/Light/Dark를 선택·복원한다. theme switch는 same Paper/page/session/data/Job을 보존하고 AI request·retry를 새로 만들지 않는다. |

## Interaction Primitives

1. **입력과 이동.** macOS trackpad/mouse click은 control의 primary action을 실행한다. PDF drag selection은 `SelectionActionBar`로 이어지고 long-press나 custom gesture가 native text selection을 대신하지 않는다. `Tab`/`Shift-Tab`은 읽기 순서 focus를 따르고 `Escape`는 가장 위의 drawer/dialog/menu를 닫는다. 구체적인 global shortcut 목록은 `[열린 결정]`이며 HTML의 `⌘F` 표기를 전역 기능 약속으로 해석하지 않는다.
2. **Import.** Library는 drag-and-drop first다. URL paste와 local file selection은 명시적인 secondary path다. 입력은 arXiv abstract URL, arXiv PDF URL, 일반 PDF URL, 로컬 PDF의 네 branch로 인식한다. arXiv abstract URL은 PDF 가져오기로 해석하고 local PDF는 네트워크 URL 없이 처리한다. Drop 후 `ImportConfirmationSheet`에서 recognized Paper, Folder/default, duplicate status를 확인하고, confirmation 전에는 Job을 생성하지 않는다. Continue 후 Library에서 progress를 관찰하고 Reader 자동 이동을 하지 않는다.
3. **Reader comparison.** PDF navigation은 Translation page를 바꾸며 Translation 내부 scroll/navigation은 PDF page를 바꾸지 않는다. `SentenceMatch`는 source 또는 translation의 hover와 keyboard focus 모두에서 대응 pair를 강조한다. HTML은 `:has(.source-s3:hover)`로 pair를 표현하지만 native runtime은 CSS selector가 아니라 shared sentence identity와 accessible focus state로 같은 결과를 낸다.
4. **Selection·evidence.** PDF 선택은 Highlight/Add Note/Copy만 노출한다. Paper Chat은 current page나 selection을 받지 않고 whole-paper evidence contract를 따른다. Evidence Anchor hover/focus preview는 full source sentence를 보여주며 click은 immutable page/sentence identity와 visible highlight를 사용한다. `insufficientEvidence`, `locationUnclear`, `navigationFailed`, `staleRevision`은 anchored state와 섞지 않는다.
5. **비동기 Job.** 진행률은 PDF reader를 막지 않는다. 실패한 external work는 explicit user Retry만 만들며 ambiguous request를 자동 재시도하지 않는다. 앱 restart에서는 persisted Job state를 복구하고 prior usable result를 유지한다. HTML의 `<progress>`와 84% 숫자는 비교 콘텐츠이며 runtime timing promise가 아니다.
6. **Drawer·dialog.** Brief와 Notes는 Reader context 위에 열리며 현재 page를 변경하지 않는 drawer다. Paper 삭제와 Chat Session 삭제는 macOS system alert/warning dialog에서 Cancel과 destructive Delete를 분리한다. 모달 간 중첩 방식은 `[열린 결정]`이며, 현재 활성 dialog와 취소 동작을 구분할 수 있어야 한다.
7. **Library·deletion.** Paper의 more-actions에서 Delete를 시작한다. deletion 시작 후 새 Paper-scoped work를 publish하지 않으며, 성공 전에는 partial deletion을 성공처럼 표시하지 않는다. 실패 row는 `삭제 미완료`/Retry Deletion으로 같은 deletion saga를 재개하고, `deleting/deleted` Paper를 다시 열거나 새 AI Job을 만들지 않는다.
8. **Template·sessions.** Template 관리 action은 dedicated Settings editor로 이동하고 save 후 originating Brief로 돌아온다. save와 regenerate는 분리된다. Chat Session title dropdown은 current session을 in-place 복원하고 `새 대화`는 첫 question 전까지 durable session을 만들지 않는다. Rename/Delete는 entry menu와 current menu에서 동일한 dialog contract를 사용한다.
9. **Settings.** `ProviderSettings`의 재테스트 실패는 last-good Provider 연결을 기준으로 기존 기능 가용성을 표시한다. `TranslationLanguageControl`의 변경은 새 Translation Job 또는 명시적 재생성 Job에만 적용한다. Template 저장은 originating Brief로 돌아오되 자동 regenerate하지 않는다.
10. **Theme.** **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]** Settings의 `ThemePicker`에서 theme만 바꿀 때 appearance mode를 유지하고 `AppearancePicker`에서 appearance만 바꿀 때 theme을 유지한다. Appearance 기본은 System이고 선택지는 System/Light/Dark다. 전환 중에도 Paper/page/session/data/Job identity가 그대로이며, 새 Import/parsing/Translation/Paper Chat/Brief request를 만들지 않는다. theme/appearance 저장의 구체적인 preference store는 Architecture와 구현 단계의 소유이며 이 문서는 저장 기술을 정하지 않는다.
11. **Browser/native 구분.** HTML `:hover`, `:focus-visible`, `:has()`, scrollbar/overflow와 media query는 comparison artifact 동작이다. Native는 같은 hover/focus/scroll semantics를 VoiceOver·keyboard와 함께 제공하되 CSS pseudo-class나 browser DOM을 요구하지 않는다.

## Accessibility Floor

행동 접근성은 이 문서가 소유하고 시각 color role은 `DESIGN.md`가 소유한다. 다음은 구현이 지켜야 할 floor이며 실제 contrast audit, screen-reader QA, keyboard QA를 완료했다는 주장이 아니다.

- 모든 버튼·탭·row·more-actions·drawer·dialog·theme/appearance 선택은 이름, 역할, 현재 상태, 가능한 next action을 VoiceOver가 읽을 수 있어야 한다. `JobStatusStrip`의 실패와 retry는 polite/status 또는 alert semantics를 구분해 중복 안내를 피한다.
- `SentenceMatch`와 `EvidenceAnchor`는 hover에만 의존하지 않는다. keyboard focus에서도 대응 문장/원문 preview/clickback을 제공하고, source/translation의 어느 쪽에서든 동일한 pair identity를 유지한다.
- Tab order는 titlebar → ReaderOutline → ReaderToolbar → PdfPanel → TranslationPanel/PaperChatPanel → Brief/Status의 시각·읽기 순서를 따른다. drawer/dialog가 열리면 focus가 그 안으로 이동하고 닫을 때 opener로 돌아온다. 정확한 native focus ring rendering은 macOS convention을 따른다.
- `Original PDF`는 실제 원문 언어를, Translation은 설정된 번역 대상 언어를 접근성 정보에 반영한다. 시안의 영어 원문과 한국어 번역은 예시이지 모든 논문의 언어를 고정하는 계약이 아니다. 한국어 Translation에는 strict/keep-all paragraph flow를 적용하고, 숫자·수식·PDF selection의 의미를 언어 변환으로 손상시키지 않는다.
- 색은 선택·성공·실패·진행·삭제 미완료의 유일한 신호가 아니다. label, text, icon-independent status, focus/outline을 함께 제공한다. 구현 acceptance target은 normal text 4.5:1 이상, large text·meaningful non-text·focus indicator 3:1 이상이다. `DESIGN.md`에 기록된 source-palette pair 계산은 렌더링 감사를 대신하지 않으며 universal 4.5:1 통과를 주장하지 않는다. 이 수치는 목표이지 측정 성공이 아니다.
- Native text scaling과 macOS accessibility setting을 존중해 Korean line wrapping과 PDF/Translation 비교가 유지되어야 한다. 고정 px를 확대 가능한 native semantic text role의 대체로 사용하지 않는다.
- keyboard focus와 VoiceOver가 hover/focus preview 및 Retry/Cancel/Delete를 실행할 수 있어야 한다. 정확한 pointer target size와 Reduce Motion 전환 정책은 캡처된 결정이 없으므로 `[열린 결정]`이며 HTML의 30px control을 native minimum으로 승격하지 않는다.
- 외부 Provider 전송과 OS keychain 미사용 등 AD-4/AD-11 accepted limit은 내부 architecture/review 사실이다. UX는 privacy-first 또는 forensic deletion claim을 하지 않지만, 사용자-facing accepted-limit disclosure/consent surface를 새로 만들지 않는다.

## Responsive & Platform

v1 surface는 macOS desktop이다. 모바일·웹 layout을 만들지 않는다. comparison HTML은 1440×900 frame을 사용하며, `max-width: 1240px` media rule에서는 720px 높이, 180px sidebar, 더 작은 padding을 보여준다. Native 창을 좁혀도 Reader의 PDF 접근, 현재 page, Translation state, Chat/Brief context가 사라지지 않아야 한다. Native breakpoint와 compact height의 정확한 적용은 `[열린 결정]`이다.

HTML-specific behavior와 native requirement를 구분한다.

| HTML comparison observation | Native runtime contract |
|---|---|
| `:hover`/`:focus-visible`와 `:has()`가 source/translation pair를 동시에 강조함 | hover와 keyboard/VoiceOver focus 모두 shared SentenceMatch identity를 강조한다. CSS selector를 요구하지 않는다. |
| `overflow: auto`와 42px statusbar가 frame 내부 scroll을 만듦 | native scroll container는 page/translation/status context를 보존하고, OS scroll/keyboard behavior를 따른다. |
| `<progress>`와 84% sample, 30px buttons | Job state와 retry를 semantic status로 제공한다. 숫자와 hit-area는 제품 runtime contract로 확정하지 않는다. |
| `@media (max-width: 1240px)`가 720px compact frame을 선택함 | macOS resize에서 adaptive layout을 제공하되 exact breakpoint/height는 별도 결정한다. |
| traffic-light 원, browser `color-scheme`, `font-family` fallback | **[PENDING PRODUCT AMENDMENT — NOT IMPLEMENTATION AUTHORITY]** macOS titlebar와 native font fallback를 사용한다. Appearance 기본값은 System이고 Settings 선택지는 System/Light/Dark라는 사용자 결정은 반영하되, 시안 CSS를 앱 bundle implementation으로 복사하지 않는다. |

## Inspiration & Anti-patterns

- **참조로만 사용:** EasyPaper의 번역·문장 1:1 대조·양방향 hover 개념은 UX inspiration이다. 저장소 코드를 재사용하거나 구현을 그 제품과 동일하다고 주장하지 않는다. 세 `mockups/direction-*.html` 방향은 PaperLens 내부 비교 artifact다.
- **의도적으로 거부:** 일반 목적 AI Chat, Paper Chat의 page/selection injection, Provider-free 제한 모드, recommendation/knowledge graph, 모바일·cloud sync, streak/achievement/promotion은 v1 경험에 넣지 않는다.
- **근거 우선:** 유창한 답변보다 Evidence Anchor와 근거 부족 상태를 우선한다. Translation alignment나 AI 정확도를 완전 정확도로 포장하지 않는다.
- **삭제 경계:** Paper 소유 데이터는 하나의 삭제 작업으로 다루되, 전부 제거되기 전에는 완료로 표시하지 않는다. 실패 시 삭제 미완료와 재시도를 제공하며 independent reusable Template은 보존한다. AD-4/AD-11 accepted limits는 내부 사실로 남기고 별도 disclosure surface나 거짓 보장을 추가하지 않는다.

## Mock Coverage & Source Classification

세 방향 comparison artifact와 아래 8개 key-screen mockup은 `mockups/`에 보존된 정적 시각 참조다. 링크된 mockup은 앱 구현, native behavior, automated/manual test proof, accessibility 또는 contrast QA 증거가 아니다. HTML과 충돌하면 두 문서의 해당 영역 계약이 우선한다.

| IA surface / state | Coverage | Evidence와 한계 |
|---|---|---|
| ReaderShell, ReaderOutline, ReaderToolbar, JobStatusStrip, PdfPanel, TranslationPanel, SentenceMatch, BriefTrigger, StatusBar | **static comparison mockup** | [`direction-native-canvas.html`](./mockups/direction-native-canvas.html), [`direction-scholarly-press.html`](./mockups/direction-scholarly-press.html), [`direction-focused-instrument.html`](./mockups/direction-focused-instrument.html)의 Light/Dark frame. `Translation` tab equal split, sidebar/chrome, sample progress/error/retry, source↔translation match를 비교한다. `Paper Chat` exact ratio나 실제 app behavior는 아니다. |
| `ProviderOnboarding`, `ProviderSettings` | **static key-screen mockup** | [`key-onboarding.html`](./mockups/key-onboarding.html)의 onboarding composition과 [`key-settings.html`](./mockups/key-settings.html)의 settings context를 참조한다. 연결 테스트, last-good 상태, native behavior의 실행 증거가 아니다. |
| `ImportDropTarget`, `ImportConfirmationSheet` 및 네 import branch | **static key-screen mockup** | [`key-import.html`](./mockups/key-import.html)는 confirmation 상태를 보여준다. 네 입력 branch의 전체 동작은 문서 계약을 따르며 실제 import·network·duplicate 처리의 증거가 아니다. |
| `LibraryPaperCard`, `LibraryPaperRow`, `LibraryOrganizationControls`, `LibrarySearchFilters`, deletion/empty/no-match | **static key-screen mockup** | [`key-library.html`](./mockups/key-library.html)는 card/list, search/filter와 삭제 상태의 시각 참조다. 모든 organization 편집 상태를 묘사하지 않으며 local persistence, deletion saga, retry의 테스트 증거가 아니다. |
| `TranslationLanguageControl`, `TemplateEditor`, `ThemePicker`, `AppearancePicker` | **static key-screen mockup** | [`key-settings.html`](./mockups/key-settings.html)의 controls는 Settings 배치 참조다. Theme/appearance는 pending product amendment이며 mockup은 구현 권한이나 product approval이 아니다. |
| `PaperChatPanel`, `EvidenceAnchor`, `ChatSessionMenu` | **static key-screen mockup** | [`key-chat.html`](./mockups/key-chat.html)은 chat/anchor/session composition 참조다. answer provenance, autosave, relaunch 복원, clickback의 실행 증거가 아니다. |
| `BriefView`, `BriefTrigger`, required/missing-content sections | **static key-screen mockup** | [`key-brief.html`](./mockups/key-brief.html)은 독립 Brief와 Drawer 시각 참조다. 생성·재생성·prior usable Brief 보존의 테스트 증거가 아니다. |
| `SelectionActionBar`, `NotesDrawer` | **static key-screen mockup** | [`key-notes.html`](./mockups/key-notes.html)은 selection과 Note context의 정적 참조다. PDF selection persistence나 Library 기록의 실행 증거가 아니다. |
| `TemplateSelector`, `TemplateEditor` | **static key-screen mockup** | [`key-template.html`](./mockups/key-template.html)은 Template 관리/editor composition 참조다. immutable version, return, regeneration race의 실행 증거가 아니다. |
| Onboarding/Reader/Library/Brief/Settings cold, failure, deletion, relaunch states | **spine + static mockup reference** | 위 mockup과 state matrix는 표면 범위를 설명한다. rendered QA, screen-reader QA, contrast audit, restart recovery, deletion saga proof는 포함하지 않는다. |

## Key Flows

### UJ-1. 연구자 김철수의 논문 읽기와 정리

**Protagonist:** 김철수 — 컴퓨터과학 연구자로 deep-learning 논문을 읽으며, 현재는 PDF viewer와 web AI chat 사이를 오가고 chat에 논문을 reference로 쓰라고 매번 지시한다.

1. 김철수는 Provider setup이 이미 완료된 PaperLens의 Library를 연다. UJ-1에서는 첫 실행 Provider 선택을 반복하지 않는다.
2. 새 논문 PDF link/file을 Library window 위로 drag한다. Library content 전체가 `ImportDropTarget`이 되고, URL paste/local file 선택도 secondary path로 남는다.
   **UJ-1 하위 흐름 — 네 가지 Import branch (김철수):** (a) arXiv abstract URL은 PDF 가져오기로 해석한다. (b) arXiv PDF URL은 PDF branch로 인식한다. (c) 일반 PDF URL은 PDF branch로 인식한다. (d) 로컬 PDF file은 네트워크 URL 없이 Paper 생성을 시작한다. 네 branch 모두 `ImportConfirmationSheet`에서 recognized Paper로 확인한 뒤 같은 Folder/default·duplicate 결정으로 이어진다.
3. `ImportConfirmationSheet`에서 recognized Paper, destination Folder/default, duplicate status를 확인하고 Import를 확정한다.
4. 그는 Library에 남아 Import·parsing·Translation·Brief Job의 progress를 관찰한다. PDF first page가 읽을 수 있게 되면 row에 `Open Reader`가 나타나고 AI progress는 별도로 계속된다.
5. 김철수는 `Open Reader`를 선택한다. `PdfPanel`은 Translation이 pending이어도 즉시 원문을 보여준다.
6. Reader는 PDF와 Translation을 equal split으로 보여준다. PDF page 6으로 이동하면 Translation도 page 6을 표시하고, Translation 안에서 scroll해도 PDF page는 움직이지 않는다.
7. 현재 page Translation이 준비되면 자연스러운 paragraph flow로 읽는다. source sentence나 translation sentence를 hover/focus하면 `SentenceMatch`가 양쪽을 강조한다.
8. 그는 `PaperChatPanel`의 empty composer에 Paper 전체에 대한 질문을 제출한다. 첫 질문이 이 Chat Session을 만든다. current page/selection을 별도 context로 보내지 않는다.
9. 답변의 `EvidenceAnchor`를 hover/focus해 full source sentence를 확인하고 click해 PDF page와 visible highlight로 돌아간다. 근거 부족이면 anchored success 대신 명시된 insufficiency 상태가 보인다.
10. PDF text를 선택하면 `SelectionActionBar`에서 `Highlight`, `Add Note`, `Copy` 중 하나를 고른다. Add Note는 현재 위치를 유지하는 `NotesDrawer`를 열며 Paper Chat으로 보내지 않는다.
11. Paper 추가로 시작된 default Brief가 완료되면 `BriefTrigger` Drawer와 독립 `BriefView`에서 Markdown 결과를 확인한다. 기본 결과에는 `문제`, `기존 방법 한계`, `제안 방법`, `논문 명시 한계`, `AI 분석 한계`, `추가 최적화 가능성`, `방법의 장점과 한계`가 보이며, 근거가 없는 항목은 missing-content로 표시된다. Template, tags, Reading Status, Favorite, Highlight, Note, last-read position은 Paper Library 기록에 남긴다.
12. **Climax:** 김철수는 English source와 Korean Translation을 직접 비교하고, Chat 답변의 Evidence Anchor를 클릭해 원문으로 돌아가며 논문을 더 빠르게 이해한다. 이것이 PaperLens를 계속 쓸 가치가 있다고 느끼는 순간이다.
13. 나중에 Library에서 같은 Paper를 열면 저장된 last-read position과 이전 기록이 복원된다.

**Failure path:** Translation current-page Job이 실패하면 PDF는 계속 usable하고 Translation panel에 reason과 inline `Retry`를 남긴다. Brief generation이 실패하면 prior usable Brief를 보존하고 재시도 상태를 보인다. Evidence Anchor가 `insufficientEvidence`, `locationUnclear`, `navigationFailed`, `staleRevision`이면 anchored success처럼 보이지 않는다. Import 자체가 실패한 경우 Library row에는 실패 reason과 explicit retry가 남고 Reader로 자동 이동하지 않는다.

**Covers:** PRD UJ-1 및 FR-001, FR-003..FR-005, FR-007..FR-010, FR-012..FR-014, FR-016..FR-017, FR-020..FR-025, FR-028..FR-029, FR-032..FR-034.

**UJ-1 하위 흐름 — Settings 재확인 (김철수):**

1. 김철수는 Settings에서 `ProviderSettings`를 열어 현재 Provider 연결 상태를 확인하고 재입력/재로그인 또는 연결 테스트를 선택한다.
2. 재테스트가 실패하면 Settings는 redacted reason과 Retry를 보여주고, 기존 기능 가용성은 마지막 성공 연결 상태를 기준으로 일관되게 표시한다. 실패를 새 성공으로 표시하지 않는다.
3. `TranslationLanguageControl`은 새 설치에서 한국어를 보여준다. 대상 언어를 바꾸면 새 Translation Job과 명시적 재생성 Job에만 현재 언어를 사용하고 이미 생성된 Translation은 조용히 바꾸지 않는다.

### UJ-2. 박민지의 Provider/파싱 실패와 복구

**Protagonist:** 박민지 — 첫 실행에서 Provider를 연결하고 scan본에 가까운 PDF의 parsing failure를 복구해야 한다.

1. 박민지는 첫 launch에서 dedicated `ProviderOnboarding`을 본다. OpenAI API key와 official Codex SDK ChatGPT login/device-code가 동등한 선택지로 나타난다.
2. API key를 입력하고 connection test를 실행한다. 실패하면 form에 머물며 안전한 입력을 보존하고 redacted reason, `Retry`, `Change Provider Path`를 제공한다. 성공 전 Library/Reader 제한 모드로 우회하지 않는다.
3. 실제 authenticated v1 request가 성공하면 connected Provider와 success confirmation을 확인하고, 자동 이동 대신 `Continue`를 선택해 Library로 간다.
4. 박민지는 scan본에 가까운 PDF를 가져오고 `ImportConfirmationSheet`에서 folder/duplicate 결정을 끝낸다.
5. parsing이 실패하면 즉시 in-app floating notification을 보고, Reader의 `JobStatusStrip`과 right work panel에서 latest parsing reason과 persistent `Retry Parsing`을 본다. left `ReaderOutline`은 탐색만 제공한다.
6. Original PDF는 열리고 page navigation·zoom·selection을 계속 사용할 수 있다. Translation, Paper Chat, Brief는 unavailable reason과 함께 비활성 상태다.
7. `Retry Parsing`이 성공하면 right work area가 Translation tab으로 전환되고 current-page Translation progress가 다시 시작된다. PDF는 계속 읽힌다.
8. **Climax:** 박민지는 AI 기능이 즉시 준비되지 않아도 원본 PDF를 잃지 않고, 명확한 최신 오류와 한 번의 명시적 retry로 Reader를 복구한다.

**Failure path:** Provider test가 다시 실패하면 last successful connection을 기준으로 기능 가용성을 표시하되, 재테스트 결과를 새 연결 성공으로 표시하지 않는다. parsing retry가 다시 실패하면 right panel에는 최신 reason과 `Retry Parsing`만 남기고 attempt count/timestamp/history를 노출하지 않는다. 앱 relaunch 뒤에도 failed/retry-needed 상태가 복원되며 자동 재시도를 하지 않는다.

**Covers:** PRD UJ-2 및 FR-001..FR-003, FR-005, FR-007, FR-011, FR-032..FR-034, NFR-004.

### UJ-3. 이서연의 Library 재방문과 완전 삭제

**Protagonist:** 이서연 — 지난주 읽던 Paper를 Library에서 다시 찾고, 필요 없어진 Paper와 소유 파생 데이터를 완전히 삭제한다.

1. 이서연은 Library를 연다. 기본 정렬은 recently read이며 name, recently added, recently read, publication year로 바꿀 수 있다.
2. 기본 presentation은 card다. 그녀가 list로 바꾸면 그 card/list preference가 다음 launch에도 복원된다.
3. top toolbar search와 left sidebar의 tag·Reading Status·Favorite filter를 함께 사용해 후보를 좁힌다. 두 presentation 모두 같은 search/filter를 사용한다.
   **UJ-3 하위 흐름 — Library organization (이서연):** `LibraryOrganizationControls`로 Folder를 만들고 Paper를 배치·이동한다. 같은 controls에서 tag를 추가·수정·삭제하고 Reading Status와 Favorite를 바꾼다. `LibrarySearchFilters`의 title/tag/Reading Status/Favorite 검색·필터 결과는 card/list 모두에 적용되고, 변경한 organization 값은 Library 재진입 후 유지된다. 카드/row의 hover 또는 detail에서 abstract 일부와 topic tags를 확인한다. empty Library와 no-match 결과는 서로 다른 상태로 보인다.
4. `LibraryPaperCard` 또는 `LibraryPaperRow`에서 title, publication year, one-line summary를 확인하고 Paper를 클릭한다.
5. Reader는 저장된 last-read position에서 열리고, 이서연은 읽던 지점부터 계속 읽는다.
6. **Climax:** 이서연은 Library에서 필요한 Paper를 정확히 찾아 마지막 읽은 위치로 바로 돌아간다.
7. 더 이상 필요 없는 Paper의 more-actions에서 Delete를 선택한다. `DeleteAlert`는 Paper 이름, 제품에서 제거될 PDF·Translation·Brief·Paper-bound generation snapshot·Chat Session·Highlight·Note·Reading Status·Favorite·reading history·last-read position을 설명하고 Cancel과 destructive Delete를 제공한다.
8. Delete를 확정하면 deletion saga가 시작된다. 성공 전에는 Paper가 부분 삭제 성공처럼 사라지지 않고, 진행 중 Job이 삭제된 결과를 되살리지 않는다.
9. 성공하면 Paper와 Library entry, Paper-owned data가 다시 검색·최근 목록·Reader에서 열리지 않는다. 앱을 재실행해도 복원되지 않는다. Paper-independent reusable user Template은 보존된다.

**Failure path:** deletion이 예외적으로 실패하면 기존 card/row를 non-openable로 유지하고 상태를 `삭제 미완료`로 표시하며 `Retry Deletion`만 제공한다. 별도 deletion work area나 성공으로 보이는 partial result를 만들지 않는다. `deleting/deleted` Paper에 Reader 재진입이나 새 AI retry를 허용하지 않는다.

**Covers:** PRD UJ-3 및 FR-010, FR-026..FR-031, NFR-007..NFR-008, SM-004..SM-005.

### UJ-4. 최준호의 Template과 다중 Chat Session 관리

**Protagonist:** 최준호 — 같은 Paper를 seminar preparation과 implementation review에 서로 다른 Template·Chat Session으로 정리한다.

1. 최준호는 Paper Brief에서 `TemplateSelector`를 연다. 기본 Template으로 생성된 Brief를 먼저 읽고 `Template 관리`를 선택한다.
2. Settings의 dedicated `TemplateEditor`에서 reusable user Template의 Markdown sections와 prompts를 편집하고 저장한다.
3. 저장 후 originating Brief context로 돌아오며 새 Template이 selected 상태다. 자동 Brief regeneration은 시작되지 않는다.
4. 그는 명시적으로 `Brief 재생성`을 실행한다. 재생성 성공 전 prior usable Brief를 유지하고 실패 시에도 prior result와 실패 reason을 함께 보인다.
5. `PaperChatPanel`의 current session title을 열어 `ChatSessionMenu`에서 기존 session을 선택한다. 선택한 conversation은 같은 panel에서 in-place로 복원된다.
6. beside title의 `새 대화`를 선택하면 empty composer가 열린다. 첫 question을 submit할 때만 추가 Chat Session이 만들어진다.
7. 질문과 답변은 Paper별 Chat Session으로 자동 저장된다. 최준호가 앱을 종료하고 다시 실행하면 같은 Paper에서 이전 session을 다시 열 수 있고, session 목록에서 선택한 대화가 복원된다.
8. 각 session entry의 more-actions 또는 current session의 top-level more-actions에서 Rename을 선택한다. current automatic/user-edited title이 채워진 macOS rename dialog에서 저장한다.
9. Delete를 선택하면 title을 확인하는 macOS warning dialog가 나타난다. 즉시 삭제하지 않고 Cancel 또는 destructive Delete를 선택한다.
10. 삭제된 session이 현재 것이면 가장 최근 active remaining session을 자동으로 연다. 마지막 session이면 replacement를 만들지 않고 empty composer로 돌아간다.
11. **Climax:** 최준호는 seminar와 implementation 질문을 독립된 제목의 session으로 다시 열어 이어가며, 각 논문 claim의 Evidence Anchor를 통해 전체 Paper 근거를 확인한다.

**Failure path:** Template regeneration이 실패하면 prior Brief를 current usable result로 유지한다. Chat answer에 충분한 근거가 없으면 `insufficientEvidence`를 명시하고 일반 chat으로 우회하지 않는다. session delete/rename dialog를 취소하면 current session과 title은 그대로다.

**Covers:** PRD UJ-4 및 FR-016..FR-024.

## Open Questions & Finalization Gates

| 항목 | 현재 상태 / 필요한 결정 |
|---|---|
| Appearance 선택 | 사용자가 Appearance 기본값을 **System**으로 정했고 Settings에 별도 `System`/`Light`/`Dark`를 둔다. Theme과 appearance를 독립적으로 유지한다. |
| 대비 acceptance target | 정상 텍스트 4.5:1 이상, 큰 텍스트·meaningful non-text·focus indicator 3:1 이상을 구현 acceptance target으로 둔다. DESIGN.md에 기록한 네 색상 쌍은 보정 후 목표를 만족하지만, 전체 렌더링·native 접근성 QA 완료를 뜻하지 않는다. |
| 추가 시각 참조 | 세 방향 comparison과 8개 key-screen mockup 링크를 `mockups/`에 분류했다. 정적 mockup은 앱 구현·테스트 증거가 아니다. |
| 제품 재승인 | FR-037..FR-039 / SM-007 thematic amendment는 아직 승인되지 않았다. Theme/appearance rows와 mockup은 제품·구현 권한이 아니며 별도 PRODUCT 재승인이 필요하다. |
| 후속 세부 설계 | Native 창 최소 크기·adaptive breakpoint, pointer target 수치, Reduce Motion 전환, Template 유효성 검사, 전역 shortcut, 모달 중첩 세부사항은 구현/Build Spec에서 확정한다. 현재 문서의 수치 예시로 임의 확정하지 않는다. 이는 남은 implementation-level detail이며 별도 사용자 선택 blocker로 취급하지 않는다. |
