<!-- bmad:context -->
<!-- Verified 2026-08-28 against d8031298329c8de113ab4bd1ea8a329dd3c0f8ee plus the current uncommitted governance worktree. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->
<!-- Local risk-based policy revision pending normal managed refresh; the historical verification above does not verify these local edits. -->

## PaperLens

PaperLens는 macOS용 오픈소스 AI 논문 워크스페이스다. 제품 요구사항은 승인된 final PRD와 부록에 있으며, AI 지원 개발은 BMAD Method와 repository governance를 따른다. GitHub Issue, Git artifact, 승인 기록을 durable project memory로 사용하고 chat history를 source of truth로 사용하지 않는다.

## Policy

- 모든 AI 지원 작업에서 `docs/ai-governance.md`를 따른다. 침묵이나 과거 승인을 현재 승인으로 추론하지 않는다.
- 현재 요구사항은 명시적 `APPROVED: PRODUCT @ <commit-sha>` 기록이 가리키는 최신 final PRD와 addendum을 canonical source로 사용한다. 파일명 날짜나 수정 시각만으로 canonical artifact를 추론하지 않는다.
- Product Brief는 discovery input과 historical context다. 새 단계의 PRD를 만드는 근거로 사용할 수 있지만 구현을 승인하지 않으며, 승인된 final PRD를 덮어쓰지 않는다.
- 비사소한 source 변경은 BMAD Story, GitHub Issue, task branch, Pull Request를 1:1:1:1 work unit으로 구성한다.
- LOW는 요청 범위 안에서 자율 실행하고 MEDIUM은 명확한 실행 요청으로 범위 내 계획·구현·검증·리뷰·수정·기록을 수행한다. 비사소한 구현의 Build Spec은 commit이 허용되면 구현 전에 commit하되 매 SHA별 구현 승인은 요구하지 않는다.
- HIGH 위험 결정이나 scope/architecture/acceptance의 실질적 변경은 해당 행동만 중단하고 관련 artifact와 영향·대상을 제시해 명시적 승인을 받는다. 안전하게 분리 가능한 작업은 계속한다.
- Stage 전환과 계획·검증·상태 기록은 비차단 checkpoint다. BMAD Build 완료 후 허용된 local commit과 검증 결과를 먼저 제시한다. Push와 Pull Request 생성·갱신은 명시적인 human instruction 후에만 수행한다.
- Pull Request는 현재 HEAD SHA에 대한 명시적 `APPROVED: MERGE @ <current-pr-head-sha>` 없이는 merge하지 않는다. HEAD가 바뀌면 기존 merge 승인을 폐기한다.

## Where things are

- Product requirements and approved baselines: `bmad-docs/planning-artifacts/prds/`
- Product Brief discovery inputs and history: `bmad-docs/planning-artifacts/briefs/`
- AI governance: `docs/ai-governance.md`
- BMAD Build repository override: `_bmad/custom/bmad-build.toml`
- Governed work entry points: `.github/ISSUE_TEMPLATE/task.yml` and `.github/pull_request_template.md`

<!-- /bmad:context -->

## Risk-based policy precedence

- 저장소 승인 정책의 canonical source는 `docs/ai-governance.md`다. managed block이 refresh되어 오래된 일반 승인 요약이 돌아와도 이 공통 정책을 적용하며 LOW/MEDIUM 구현·계획·Stage 승인을 중복 추가하지 않는다. 전역·번들 강제 Gate를 변경했다고 주장하지 않는다.
- LOW는 요청된 안전한 작업을 즉시 수행하고 MEDIUM은 명확한 실행 요청 자체로 범위 내 lifecycle을 위임받는다. 계획만·리뷰만·정보 질문은 구현 권한이 아니며 no-test/no-commit/no-remote와 상위 플랫폼·도구 제한을 지킨다.
- HIGH는 실제 위험 결정/행동만 승인받는다. Checkpoint는 Evidence 기록이며 Stage 수는 작업 규모·위험에 비례한다. 안전한 다음 단계와 허용된 실패 수정·재검증은 자동 진행한다. 파일 수·Stage·일반 Spec SHA 변화는 재승인 사유가 아니다.

## Whole-Story execution authority

- 특정 Story 전체에 대한 명확한 실행 지시는 기존 acceptance criteria 안의 로컬 조사·명세 갱신·구현·허용된 검증·리뷰·기록에 적용한다. 후속 Spec은 commit이 허용되면 구현 전에 commit하되 매 SHA별 재승인은 요구하지 않는다.
- Story ID, Issue, baseline Spec 및 현재 commit, 실제 human 지시와 유지되는 제한을 기록한다. 원격 기록은 별도 지시와 접근 권한이 있을 때만 수행하며, 그 전에는 로컬에 동기화 대기 상태를 남긴다. 승인 토큰을 만들어내거나 다른 Story로 확대하지 않는다.
- architecture/acceptance criteria 변경, privacy/safety 완화, 소진된 단일 실행 허용의 갱신, push/PR/배포/merge는 일반 범위 위임에 포함되지 않는다. 개인정보·인증·권한·데이터·비용의 새로운 위험은 행동 전에 별도로 판단한다.

## Story 범위 전체 실행 지시

- 사용자의 **Story 1.1~1.27 전체 계획·구현·검증을 워크플로대로 진행** 지시는 해당 전체 범위에 적용한다. 열린 Story1.1의 진단만으로 축소하거나 각 단계마다 재승인을 요구하지 않는다.
- `docs/ai-governance.md`의 Explicit Story-Range Execution을 따른다. Epic Issue의 human 지시 기록과 각 Story의 Spec/Issue/task branch를 연결하고, 허용된 명세 commit → 구현 → 부모 검증 → 독립 리뷰 → 로컬 증거 commit을 수행한다. 원격 권한이 없으면 로컬에 연결 근거와 동기화 대기를 기록한다.
- 한 Story의 외부 환경 검증 차단은 독립적인 다음 Story의 구현을 막지 않는다. 실제 존재하는 Story 정의를 기준으로 진행하고 없는 번호의 요구사항은 만들어내지 않는다.
- Story1.1 prototype의 제품 로그인/PDF/Library 구현 non-goal은 그 Story에만 적용한다. 다른 승인된 Story의 제품 구현은 해당 제품/아키텍처 계약을 따르되 실제 사용자 문서·인증정보·기존 CODEX_HOME 접근과 무승인 유료 요청은 하지 않는다.
- 승인된 로컬 검증은 각 committed Spec의 bounded 절차대로 실행한다. 과거 소진된 trial의 blind retry, 개인정보/권한/안전 제한 완화, push/PR/원격/배포/merge는 자동 허용하지 않는다.

## 실행 우선과 조사 종료

- 이미 확인한 승인 경계나 source finding을 새로운 근거 없이 다시 조사·위임하지 않는다. 조사는 결정할 구현 문제, 정확한 입력, 종료 조건을 먼저 특정한다.
- 독립 리뷰가 허용한 구체적인 로컬 구현이 있으면 같은 경계를 재검토하는 대신 구현·직접 검증·증거 커밋을 수행한다. 상태 기록만 늘리는 작업을 제품 진척으로 계산하지 않는다.
- bounded 조사가 끝났는데 실행 가능한 다음 slice가 없으면 미충족 prerequisite과 필요한 human 입력·권한을 명시한다. 이를 피하려고 새로운 감사, 가짜 owner/store, placeholder 기능을 만들지 않는다.
- 실제 gate와 source-only proof를 구분하며, 전체 잔여 작업이 human action에만 의존한다는 직접 근거가 없으면 goal을 pause하거나 완료하지 않는다. 위 원칙은 승인·개인정보·시험 소진·원격 실행 제한을 완화하지 않는다.
