# PRD Quality Review — PaperLens 최소 정정 후보

## Overall verdict

현재 `status: draft` 후보는 승인 baseline의 제품 범위와 stable ID를 유지하면서, 허용된 세 가지 정정인 30초 soft target의 측정 의미, macOS 15+ arm64/x86_64 별도 산출물, Paper-bound generation snapshot과 독립 재사용 user Template의 lifecycle 분리를 일관되게 반영했다. 일곱 차원의 종합 판단은 **adequate**이며 critical/high blocker는 없다. 다만 아래 medium finding 세 건은 Architecture/QA와 story acceptance에서 닫혀야 하며, 이 품질 판단은 새 commit-bound PRODUCT 재승인을 대신하지 않는다.

- Finding counts: critical 0, high 0, medium 3, low 1.

## Decision-readiness — adequate

세 정정은 고려사항이 아니라 결정으로 드러난다. PRD NFR-001, SM-001, CM-002는 30초를 자동 release pass/fail이 아닌 측정·보고 대상 soft target으로 두고, material 또는 반복 초과에는 review/disposition을 요구한다. FR-035와 §8은 macOS 15+ 및 arm64/x86_64 별도 공개 산출물을 명시하고, Glossary와 FR-022, FR-023, FR-030은 Paper가 소유하는 generation snapshot과 Paper와 독립된 재사용 Template을 구분한다.

정정 전후의 핵심 trade-off도 숨기지 않았다. 성능 초과를 즉시 기능 실패로 만들지 않는 대신 disposition 없는 반복 문제를 release-ready로 보지 않고, universal binary가 아니라 아키텍처별 산출물을 선택하며, 재현을 위한 Paper-bound snapshot을 보존하는 대신 재사용 Template은 Paper 삭제 경계 밖에 둔다. `.memlog.md` 마지막 change가 새 commit-bound PRODUCT 승인 전에는 변경 baseline이 미승인이라고 명시하므로 PRD와 addendum의 `status: draft`는 현재 상태를 정확히 표현한다.

### Findings

- 없음. 아래 done-ness의 medium finding은 후속 acceptance 정밀화 항목이며 현재 제품 결정을 다시 열어야 하는 blocker는 아니다.

## Substance over theater — strong

정정 문구의 반복은 문서 장식이 아니라 Glossary, 범위, UJ, FR, NFR, release metric, Architecture gate 사이의 실제 추적성을 만든다. 특히 Template lifecycle은 정의에만 머물지 않고 Brief 생성, Template 편집, Paper 삭제, release acceptance까지 관찰 가능한 동작으로 이어진다.

30초 성능 항목도 일반적인 “빠르게”라는 NFR 문구가 아니라 시작점, 종료점, 측정·보고 의무와 초과 처리 원칙을 담는다. dual-architecture 범위 역시 막연한 macOS 지원이 아니라 OS 하한과 두 공개 artifact를 명시한다.

### Findings

- 없음.

## Strategic coherence — adequate

세 정정은 `read -> evidence -> organize -> revisit -> compound` thesis를 훼손하지 않는다. PDF-visible soft target은 첫 가치 도달을, 두 아키텍처의 공개 산출물은 공개 오픈소스 제품의 접근 가능 범위를, snapshot/Template 분리는 Paper 재현성과 반복 가능한 연구 정리 흐름을 각각 강화한다.

기존의 모든 feature group을 launch-blocking으로 유지하는 일정 리스크는 여전히 크지만, 이는 §4.1, §10, R-007, CM-002에서 명시적으로 수용된 제품 결정이다. 최소 정정은 이 우선순위나 비목표를 조용히 바꾸지 않았다.

### Findings

- 없음.

## Done-ness clarity — adequate

FR-001부터 FR-036까지 testable consequence가 있고, 정정된 핵심 요구도 대체로 검증 가능하다. NFR-001은 arXiv URL 제출 수락부터 첫 PDF page가 표시되고 navigation/zoom에 응답할 때까지를 clock으로 정의한다. FR-035는 두 아키텍처별 산출물을 요구하고, FR-022/FR-023/FR-030과 SM-005는 snapshot 캡처, Template 독립성, 삭제 경계를 연결한다.

남은 공백은 제품 결정을 불명확하게 만들 정도는 아니지만, 그대로 release QA에 전달하면 서로 다른 합리적 판정이 나올 수 있다.

### Findings

- **medium** FR-032의 별도 30초 문구에는 clock boundary가 없다 (§7 FR-032, §9 NFR-001, §10.1 30-second test gate, addendum §2) — NFR-001의 30초는 arXiv import acceptance부터 interactive first page까지지만, FR-032는 “30초 안에 준비되지 않은 AI Job”에 대해 어떤 Job event부터 재는지 밝히지 않는다. addendum gate가 FR-032까지 NFR-001의 PDF-visible target과 함께 묶어 두어 하나의 clock인지 별도 progress-display threshold인지도 모호하다. *Fix:* FR-032의 30초가 NFR-001과 독립된 UI threshold라면 시작 event를 정의하고, 그렇지 않다면 숫자를 제거해 AI Job이 준비되지 않은 동안 progress/waiting 상태를 표시한다고 명시한다.
- **medium** dual-architecture release metric이 artifact 존재 확인에 치우쳐 있다 (§7 FR-035, §8, §11 SM-006, addendum §8) — FR-035의 본문은 “설치 또는 실행 가능한” 산출물을 요구하지만 consequence와 SM-006은 두 artifact 제공 및 실행 방법 확인만으로도 통과할 수 있어, 한 아키텍처의 artifact가 실제로 실행되지 않아도 release evidence가 충족된 것으로 읽힐 수 있다. *Fix:* arm64와 x86_64 각각에 대해 대표 macOS 15+ 환경에서 설치 또는 launch와 최소 first-run Provider 화면 도달을 검증하는 release evidence를 요구한다.
- **medium** snapshot 캡처는 명시됐지만 Template 편집 후의 불변성 시나리오는 암시적이다 (§3 Glossary, FR-022, FR-023, FR-030, SM-005) — 현재 문구는 Template version과 입력값을 캡처한다고 하므로 의도는 읽히지만, 재사용 Template을 수정한 뒤 기존 Paper의 snapshot/Brief가 바뀌지 않는지, 재생성 시 새 snapshot이 생기는지에 대한 관찰 가능한 consequence가 없다. *Fix:* 기존 Paper-bound snapshot은 이후 Template 편집에 의해 소급 변경되지 않고, 재생성은 선택한 현재 Template으로 새 snapshot을 캡처한다는 acceptance를 추가한다.

## Scope honesty — strong

§4.1과 §4.2는 출시 필수와 비목표를 분리하고, 이번 정정은 허용된 세 영역 밖의 기능 범위를 늘리거나 줄이지 않는다. baseline 비교에서 FR 번호와 기존 기능 그룹은 유지됐으며, 제품 문서 변경은 세 correction family와 pending reapproval을 나타내는 frontmatter status 변경에 한정된다.

Assumption A-001부터 A-003까지는 inline tag, Assumptions Index, owner, needed-before 조건을 갖는다. 특히 A-002는 아직 Architecture/QA가 정할 test corpus, source별 경계, material/repeated 기준을 숨기지 않고 명시적인 gate로 남긴다. open item의 수와 owner가 이 chain-top PRD의 stakes에 비해 과도하지 않다.

### Findings

- 없음.

## Downstream usability — adequate

Glossary의 `Brief`, `Paper-bound generation snapshot`, `Template` 정의는 FR-022, FR-023, FR-030, NFR-008, SM-005 및 addendum §7과 의미상 일치한다. downstream workflow는 Paper 삭제 시 snapshot과 결과는 삭제하고 user Template은 보존한다는 경계를 source-extract할 수 있다.

ID 체계도 정정 과정에서 보존됐다. FR-001~FR-036, NFR-001~NFR-010, UJ-1~UJ-4, SM-001~SM-006, CM-001~CM-003, R-001~R-008, A-001~A-003, D-001~D-006은 각각 contiguous하고 unique하며, PRD와 addendum에서 이 ID 집합 밖을 가리키는 unresolved reference가 없다.

### Findings

- **low** addendum이 Glossary의 canonical `Chat Session` 대신 `Paper Chat Session`을 일부 사용한다 (Glossary, addendum §7) — 의미 혼동은 없지만 자동 source extraction에서는 별도 noun으로 분리될 수 있다. *Fix:* 다음 허용된 prose pass에서 addendum §7의 명칭을 `Chat Session`으로 맞춘다.

## Shape fit — adequate

PaperLens는 의미 있는 desktop UX를 정의하고 UX, Architecture, QA, story creation으로 이어지는 chain-top 문서이므로, named UJ, stable IDs, testable FR consequence, cross-cutting NFR, release metric, counter-metric, risk, assumption, technical addendum을 갖춘 현재 형식이 적절하다. 이번 최소 정정도 별도 architecture 설계를 PRD에 끌어오지 않고, 사용자에게 관찰 가능한 product boundary와 downstream gate만 보강했다.

`status: draft`는 품질 미달 표지가 아니라 승인 상태를 정확히 나타내는 governance 표지다. 따라서 reviewer는 이 후보의 품질을 평가할 수 있지만, 문서 자체나 이 review가 새 PRODUCT 승인을 선언해서는 안 된다.

### Findings

- 없음.

## Mechanical notes

- **Correction boundary:** approved baseline `d8031298329c8de113ab4bd1ea8a329dd3c0f8ee` 대비 PRD/addendum 변경은 30초 soft target 의미, macOS 15+ arm64/x86_64 별도 artifact, snapshot 대 reusable Template lifecycle, 그리고 pending reapproval을 표시하는 `status: draft`에 집중된다.
- **Status:** PRD와 addendum 모두 `status: draft`; `.memlog.md`의 마지막 change가 새 commit-bound PRODUCT 승인 전 변경 baseline은 미승인이라고 기록하므로 정확하다.
- **Stable IDs:** FR-001~FR-036, NFR-001~NFR-010, UJ-1~UJ-4, SM-001~SM-006, CM-001~CM-003, R-001~R-008, A-001~A-003, D-001~D-006은 contiguous/unique하다. 정정으로 ID 추가, 삭제, 재번호화가 발생하지 않았다.
- **Cross-references:** PRD와 addendum에서 검사한 FR/NFR/UJ/SM/CM/R/A/D 참조는 모두 정의된 ID로 해소된다.
- **Assumptions roundtrip:** inline `[ASSUMPTION A-001]`, `[ASSUMPTION A-002]`, `[ASSUMPTION A-003]`는 §13의 A-001, A-002, A-003과 각각 왕복하고, index의 세 항목 모두 inline 사용처가 있다.
- **Template glossary:** `Template`은 독립 재사용 자원, `Paper-bound generation snapshot`은 Paper 소유 캡처로 일관되게 구분된다. 기본/사용자 Template 표현은 이 canonical lifecycle과 충돌하지 않는다.
- **UJ protagonists:** UJ-1 김철수, UJ-2 박민지, UJ-3 이서연, UJ-4 최준호로 모두 named protagonist를 갖는다.
- **Whitespace:** baseline 대상 PRD/addendum의 `git diff --check`는 오류를 보고하지 않았다.
