<!-- bmad:context -->
## PaperLens

PaperLens는 macOS용 오픈소스 AI 논문 워크스페이스다. BMAD Story와 Git artifact를 durable project memory로 사용한다.

## Canonical references

- 실행·승인·검증·안전 정책: `docs/ai-governance.md`. 이 파일과 workflow override는 별도의 gate를 추가하지 않는다. 상위 플랫폼·도구 제한은 유지한다.
- 제품 baseline: 명시적 `APPROVED: PRODUCT @ <commit-sha>` 기록이 가리키는 `bmad-docs/planning-artifacts/prds/`의 final PRD와 부록. 날짜로 baseline을 추론하지 않는다.
- Story 및 기존 Spec·결과: `bmad-docs/implementation-artifacts/`
- BMAD Build override: `_bmad/custom/bmad-build.toml`
- Product Brief는 discovery/history이며 구현 승인이나 final PRD의 대체물이 아니다.
<!-- /bmad:context -->

## Current execution context

- 기존 Story 1.1~1.27 범위 지시는 실제 존재하는 Story 정의 안에서 적용한다. 없는 Story를 만들지 않는다. Story 1.1 prototype non-goal을 다른 Story에 확대하지 않는다.
- 현재 지시는 정책 중복 축소 → 기존 구현 통합·검증 → 고유 작업을 보존한 워크트리 정리다. 기존 Spec·Issue·branch 추적성을 유지한다.
- 통합 책임은 상위 실행 agent에 있다. 기존 `issue/epic-1-product-vertical-integration-20261010` 브랜치와 최초 저장소 루트 기준 `.build/topology/product-vertical-integration-20261009` 워크트리를 제품 통합 기준으로 사용한다. 해당 브랜치 안에서는 현재 워크트리가 기준이다. 변경이 필요하면 기존 Epic 실행 Spec에 이유를 기록한다.
- 새 작업 확대보다 진행 중인 변경의 통합·영향 테스트·로컬 commit을 우선한다. 공유 DB/RPC/앱 조립은 통합 기준에서 다룬다. 병렬 작업은 독립성과 수용 가능한 통합 경로가 확인된 경우에만 제한적으로 수행한다.
- 실제 사용자 문서·인증정보·기존 CODEX_HOME 접근, 무승인 유료 요청, 소진된 trial 재실행은 하지 않는다. 이번 통합·정리는 push/PR/원격/배포/merge 승인이 아니다.
- 완료는 검증된 동작으로 보고한다. 로컬 구현·synthetic·packaged·외부 acceptance를 구분하고 미검증 상태를 완료로 표시하지 않는다.
