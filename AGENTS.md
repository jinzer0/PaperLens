<!-- bmad:context -->
<!-- Verified 2026-08-28 against d8031298329c8de113ab4bd1ea8a329dd3c0f8ee plus the current uncommitted governance worktree. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## PaperLens

PaperLens는 macOS용 오픈소스 AI 논문 워크스페이스다. 제품 요구사항은 승인된 final PRD와 부록에 있으며, AI 지원 개발은 BMAD Method와 repository governance를 따른다. GitHub Issue, Git artifact, 승인 기록을 durable project memory로 사용하고 chat history를 source of truth로 사용하지 않는다.

## Policy

- 모든 AI 지원 작업에서 `docs/ai-governance.md`를 따른다. 침묵이나 과거 승인을 현재 승인으로 추론하지 않는다.
- 현재 요구사항은 명시적 `APPROVED: PRODUCT @ <commit-sha>` 기록이 가리키는 최신 final PRD와 addendum을 canonical source로 사용한다. 파일명 날짜나 수정 시각만으로 canonical artifact를 추론하지 않는다.
- Product Brief는 discovery input과 historical context다. 새 단계의 PRD를 만드는 근거로 사용할 수 있지만 구현을 승인하지 않으며, 승인된 final PRD를 덮어쓰지 않는다.
- 비사소한 source 변경은 BMAD Story, GitHub Issue, task branch, Pull Request를 1:1:1:1 work unit으로 구성한다.
- 구현 전 Build Spec을 commit하고 그 SHA에 대한 명시적 `APPROVED: IMPLEMENTATION`을 받는다.
- 승인된 scope나 architecture가 실질적으로 바뀌면 구현을 중단하고 관련 artifact를 갱신·commit한 뒤 재승인을 받는다.
- BMAD Build 완료 후 local commit과 검증 결과를 먼저 제시한다. Push와 Pull Request 생성·갱신은 명시적인 human instruction 후에만 수행한다.
- Pull Request는 현재 HEAD SHA에 대한 명시적 `APPROVED: MERGE` 없이는 merge하지 않는다. HEAD가 바뀌면 기존 merge 승인을 폐기한다.

## Where things are

- Product requirements and approved baselines: `bmad-docs/planning-artifacts/prds/`
- Product Brief discovery inputs and history: `bmad-docs/planning-artifacts/briefs/`
- AI governance: `docs/ai-governance.md`
- BMAD Build repository override: `_bmad/custom/bmad-build.toml`
- Governed work entry points: `.github/ISSUE_TEMPLATE/task.yml` and `.github/pull_request_template.md`

<!-- /bmad:context -->

## Whole-Story approval override

- 위 managed block의 매 Spec SHA 승인 요건 대신, `docs/ai-governance.md`의 Whole-Story Approval을 사용할 수 있다.
- 사람이 특정 Story 전체를 명시적으로 승인하면 기존 acceptance criteria 안의 로컬 조사·명세 갱신·구현·검증·증거 커밋은 Story 단위로 승인된다. 각 후속 Spec은 구현 전에 commit하되 매 SHA별 재승인은 요구하지 않는다.
- Story ID, Issue, baseline Spec 및 현재 commit, 실제 human 지시와 유지되는 제한을 Issue에 기록한다. 승인을 에이전트가 만들어내거나 다른 Story로 확대하지 않는다.
- architecture/acceptance criteria 변경, privacy/safety 완화, 소진된 단일 실행 허용의 갱신, push/PR/배포/merge는 이 승인에 포함되지 않는다.
