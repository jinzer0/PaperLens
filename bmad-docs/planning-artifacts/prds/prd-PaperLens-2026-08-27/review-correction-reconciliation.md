# Minimal Correction Reconciliation Review

## Review basis

- Approved comparison baseline: `prd.md` and `addendum.md` at `d8031298329c8de113ab4bd1ea8a329dd3c0f8ee`.
- Corrected candidate: current `prd.md` and `addendum.md`, both intentionally marked `status: draft` pending a new commit-bound PRODUCT approval (`prd.md:3`, `addendum.md:3`).
- Change authority and limit: `.memlog.md:60` limits the correction to timing semantics, macOS 15+ dual-architecture distribution, and Template lifecycle ownership while preserving all other approved scope and stable IDs; `.memlog.md:64` explicitly says the changed baseline remains unapproved until a new PRODUCT approval.
- Triggering architecture findings: `reviews/reconcile-prd.md:54` identified the timing contradiction; `reviews/reconcile-prd.md:56` identified the unapproved platform/artifact expansion; `reviews/reconcile-addendum.md:20` and `:60` identified the Template deletion contradiction.
- Method: exact-line comparison against the approved commit, full current-file review, current memlog change review, both architecture reconciliation reviews, zero-context Git diff, and ordered stable-ID declaration comparison.

## Five-row minimal reconciliation matrix

| Test | Result | Judgment |
| --- | --- | --- |
| T1 — timing semantics | **PASS** | `NFR-001`, `SM-001`, and `CM-002` now form one consistent contract: measure and report the accepted-to-interactive-PDF interval against a 30-second soft target; keep the functional end-to-end flow release-blocking; do not make one 30-second miss an automatic failure; block release readiness when material or repeated exceedance remains undispositioned. |
| T2 — product-approved platform/artifacts | **PASS** | The corrected candidate explicitly carries macOS 15+ and separate arm64/x86_64 public artifacts in the requirement, platform section, release metric, and addendum, exactly matching the recorded product correction decision. |
| T3 — Template ownership/deletion | **PASS** | Paper-bound Brief results and generation snapshots are Paper-owned and deleted with the Paper; reusable user Templates are independent resources and survive Paper deletion. The rule is consistent across glossary, FRs, NFR, release metric, deletion gate, and addendum inventory. |
| T4 — unchanged stable IDs/scope | **PASS** | The ordered requirement declaration list is identical to the approved baseline: 72 declarations in both versions, from `FR-001` through `D-006`, with no added, removed, or reordered stable ID. The complete diff contains only draft-status governance metadata and the three authorized correction topics; unrelated launch-blocking scope and non-goals are unchanged. |
| T5 — no architecture-only leakage | **PASS** | The correction adds observable product contracts and ownership semantics only. It does not adopt parser, database, queue, credential-format, indexing, rendering, scheduler, retry, or Template-storage mechanisms; those remain explicitly outside the PRD and assigned downstream. |

## Exact evidence

### T1 — timing semantics

- Approved baseline `prd.md:312`: `- NFR-001: arXiv URL 제출 후 PDF 원문을 볼 수 있을 때까지 최대 30초를 목표로 한다.`
- Approved baseline `prd.md:341`: `- SM-001: 샘플 arXiv abstract URL에서 Provider 설정, 가져오기, 30초 목표 기준 내 PDF-visible Reader 진입, Translation/Brief/Paper Chat Job 상태 표시가 한 흐름으로 검증된다.`
- Approved baseline `prd.md:351`: `- CM-002: v1 기능 개수 완료율이 end-to-end 루프 검증 실패를 가리지 않는다. SM-001부터 SM-005 중 하나라도 실패하면 release-ready로 보지 않는다.`
- Current `prd.md:318`: `- NFR-001: arXiv URL 제출이 수락된 시점부터 첫 PDF 페이지가 표시되고 navigation/zoom에 응답할 때까지 30초를 soft target으로 측정하고 보고한다.`
- Current `prd.md:347`: `- SM-001: 샘플 arXiv abstract URL에서 Provider 설정, 가져오기, PDF-visible Reader 진입, 30초 soft target 측정 증거, Translation/Brief/Paper Chat Job 상태 표시가 한 흐름으로 검증된다. 전체 흐름은 필수이며, material 또는 반복 초과는 release review와 disposition을 요구한다.`
- Current `prd.md:357`: `- CM-002: v1 기능 개수 완료율이 end-to-end 루프 검증 실패를 가리지 않는다. SM-001부터 SM-005의 기능적 release gate 중 하나라도 실패하면 release-ready로 보지 않는다. 30초 soft target 초과는 그 자체만으로 자동 실패가 아니지만, material 또는 반복 초과가 disposition 없이 남으면 release-ready로 보지 않는다.`
- Current `prd.md:52`: `아래 모든 기능 그룹은 출시 차단 범위다. 범위 리스크는 수용되었으며 기능 축소가 아니라 release gate와 위험 관리로 다룬다.`
- Current `addendum.md:28`: `- 30-second test gate: PDF-visible 30초 soft target 관련 QA/story acceptance는 Architecture/QA가 일반 네트워크 상태, 정상 접근 가능한 arXiv/PDF URL, 과도하게 크지 않은 텍스트 기반 논문 PDF 조건, source별 측정 경계, material 또는 반복 초과의 review/disposition 기준을 기록하기 전에는 확정하지 않는다. Existing owner/revisit: PRD A-002의 Architecture/QA, release QA plan 전. Impacts: PRD FR-007, FR-032, NFR-001, NFR-002, NFR-003, SM-001.`
- Current `.memlog.md:61`: `- (decision) 30초 목표는 import accepted부터 첫 PDF page가 navigation/zoom에 응답할 때까지 측정·보고하는 soft target이며 material 또는 반복 초과는 review와 disposition을 요구하되 기능적 end-to-end release gate는 유지한다.`

**Consistency conclusion:** Functional `SM-001` through `SM-005` remain release-blocking. `SM-001` requires the complete flow and timing evidence, not an unconditional sub-30-second result. A single miss is therefore not automatic failure, while unresolved material or repeated misses prevent release readiness. This closes architecture finding F-01 without weakening the functional gate.

### T2 — product-approved platform/artifacts

- Current `.memlog.md:62`: `- (decision) PaperLens v1은 macOS 15+에서 arm64와 x86_64 공개 release artifact를 각각 제공한다.`
- Current `prd.md:299`: `- FR-035: v1 공개 패키지는 macOS 15+에서 설치 또는 실행 가능한 arm64와 x86_64 별도 공개 오픈소스 산출물이어야 한다.`
- Current `prd.md:310`: `- v1은 macOS 15+만 지원한다.`
- Current `prd.md:311`: `- v1 공개 배포는 arm64와 x86_64 산출물을 각각 제공한다.`
- Current `prd.md:352`: `- SM-006: 공개 macOS 15+ v1 arm64와 x86_64 별도 오픈소스 산출물에서 실행 방법, Provider 설정 방법, 최종 확정된 라이선스가 확인된다.`
- Current `addendum.md:82`: `- public v1 패키징은 macOS 15+ 실행 방법, arm64와 x86_64 별도 산출물, Provider 설정 방법, 최종 확정된 오픈소스 라이선스를 사용자가 확인할 수 있어야 한다.`

**Consistency conclusion:** Minimum OS and both public release artifacts are explicit at every product acceptance surface. This resolves architecture finding F-03 at the candidate-content level. It does not itself create PRODUCT approval; `.memlog.md:64` and draft status preserve that governance boundary.

### T3 — Template ownership/deletion

- Current `.memlog.md:63`: `- (decision) Paper에 사용된 Brief generation snapshot과 생성 결과는 Paper와 함께 삭제하고, 재사용 가능한 user Template은 독립 자원으로 유지해 Paper 삭제 후에도 보존한다.`
- Current `prd.md:35`: `- Brief: Paper에 대해 생성되는 구조화된 Markdown 정리본. 기본 Template 또는 사용자 Template으로 생성되며, 생성 결과와 Paper-bound generation snapshot은 해당 Paper에 속한다.`
- Current `prd.md:36`: `- Paper-bound generation snapshot: 한 Paper의 Brief 생성을 위해 캡처된 Template 버전과 입력값. Paper 삭제 시 생성 결과와 함께 삭제된다.`
- Current `prd.md:37`: `- Template: Brief 생성을 위한 Markdown 섹션 구조와 프롬프트 묶음. 사용자가 항목과 프롬프트를 편집할 수 있는 독립 재사용 자원이며, Paper 삭제 후에도 보존된다.`
- Current `prd.md:232`: `- FR-022: 사용자는 기본 Template과 독립 재사용 사용자 Template으로 Brief를 생성하거나 재생성한다.`
- Current `prd.md:237`: `- FR-023: 사용자는 Paper와 독립된 사용자 Template의 Markdown 항목과 프롬프트를 편집한다.`
- Current `prd.md:272`: `- FR-030: 사용자는 Library에서 Paper를 삭제하고 Paper 소유 파생 데이터 전체 삭제 결과를 확인한다.`
- Current `prd.md:274`: `  - Consequences (testable): 삭제 후 해당 Paper의 PDF, Translation, Brief, Paper-bound generation snapshot, Chat Session, Highlight, Note, 읽기 이력, 마지막 읽은 위치가 앱에서 재진입되지 않는다.`
- Current `prd.md:275`: `  - Consequences (testable): 삭제한 Paper에서 사용된 독립 사용자 Template은 삭제되지 않고 이후 Brief 생성에 다시 사용할 수 있다.`
- Current `prd.md:325`: `- NFR-008: Paper 삭제는 PDF와 Paper 소유 파생 데이터를 함께 삭제하는 완료 동작이어야 하며, 독립 재사용 사용자 Template은 Paper 삭제와 분리해 보존한다.`
- Current `prd.md:351`: `- SM-005: Paper 삭제 후 Library 검색/필터/최근 읽은 Paper/Reader 재진입에서 해당 Paper와 PDF, Translation, Brief, Paper-bound generation snapshot, Chat Session, Highlight, Note, 읽기 이력, 마지막 읽은 위치가 보이지 않고, 재실행 후에도 복원되지 않는다. 독립 사용자 Template은 보존됨이 확인된다.`
- Current `addendum.md:72`: `- Paper 삭제 시 PDF, Translation, Brief, Paper-bound generation snapshot, Paper Chat Session, Highlight, Note, Reading Status, Favorite, 마지막 읽은 위치처럼 Paper가 소유한 파생 데이터 전체가 삭제되어야 한다.`
- Current `addendum.md:73`: `- 독립 재사용 사용자 Template은 Paper 삭제 후에도 보존되며, Template 관리와 이후 Brief 생성 선택지에 남아야 한다.`

**Consistency conclusion:** The ownership split is explicit and testable, and no line still treats the reusable Template as Paper-owned. This resolves the Template contradiction identified by the addendum reconciliation review.

### T4 — unchanged stable IDs and unrelated scope

- Mechanical declaration comparison result: approved baseline `72`, current candidate `72`, ordered lists identical, no missing ID, no added ID; first declaration `FR-001`, last declaration `D-006` in both.
- Stable IDs edited semantically but not renamed or renumbered: `FR-022`, `FR-023`, `FR-030`, `FR-035`, `NFR-001`, `NFR-002`, `NFR-008`, `SM-001`, `SM-005`, `SM-006`, `CM-002`, and `A-002`.
- Current `.memlog.md:60`: `- (decision) Architecture reconciliation에 따른 PRD 최소 정정은 30초 측정 의미, macOS 15+ dual-architecture 배포, Template lifecycle ownership 세 항목으로 제한하며 나머지 승인 범위와 stable ID를 유지한다.`
- Current `prd.md:52` keeps every feature group launch-blocking, and the complete baseline-to-current diff shows no feature-group, non-goal, risk, assumption owner, or deferred-item addition/removal outside the three authorized topics.
- The only non-semantic document change is `status: final` to `status: draft` in both corrected candidates, consistent with pending re-approval rather than scope change.

### T5 — no architecture-only leakage

- Current `prd.md:335`: `- [제약] 구체적인 PDF 파싱 기술, 저장 구조, 구현 라이브러리, 데이터베이스 스키마는 PRD 본문에 포함하지 않고 Architecture 단계에서 결정한다.`
- Current `addendum.md:101`: `- 구체 PDF 파서와 라이브러리 선택.`
- Current `addendum.md:102`: `- 저장소 구조와 데이터베이스 스키마.`
- Current `addendum.md:103`: `- Translation 큐, 병렬 처리 방식, 캐시 키 설계.`
- Current `addendum.md:104`: `- Provider token 저장 포맷.`
- Current `addendum.md:105`: `- PDF 문장 위치 인덱싱 구현 방식.`
- Current `addendum.md:106`: `- hover 강조와 scroll sync의 구체 렌더링 전략.`
- Current `addendum.md:107`: `- Job scheduler와 retry backoff 구현.`
- Current `addendum.md:108`: `- Template 저장 포맷.`

**Leakage conclusion:** No correction hunk introduces an architecture technology or mechanism. `Paper-bound generation snapshot` is present only as a product-visible ownership/deletion concept and leaves storage format and schema downstream.

## Overall verdict

# PASS

All five minimal reconciliation tests pass. The corrected PRD/addendum candidate is semantically red-to-green for the authorized correction: timing semantics are mutually consistent, functional `SM-001` through `SM-005` remain release-blocking, one isolated 30-second miss is not automatic failure, undispositioned material/repeated exceedance blocks release readiness, dual public artifacts are explicit, Template/snapshot ownership is coherent, all stable IDs and unrelated scope remain intact, and no architecture-only mechanism leaked into the product artifacts.

This is a semantic reconciliation verdict only. It is not PRODUCT or ARCHITECTURE approval, does not clear implementation, and does not alter the stated pause: the corrected draft still requires a new commit-bound `APPROVED: PRODUCT` before Architecture resumes.
