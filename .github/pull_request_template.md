## Governing Issue

Closes #

---

## 변경 목적

이 변경이 필요한 이유를 간단히 작성합니다.

-

---

## Implementation Plan / 실행 근거

BMAD Build Spec / 사소한 작업의 비례 기록:

`<artifact path>`

- 위험도와 영향·가역성 판단:
- 실제 실행 요청 / Task·Story·Issue 참조 / baseline:
- 허용된 작업·제외 조건 / trial 상태:
- 필요한 HIGH 결정과 실제 승인 (해당할 때만):

`docs/ai-governance.md`를 따릅니다. LOW는 요청 범위 자율 실행,
MEDIUM은 명확한 실행 요청으로 범위 내 lifecycle을 위임받으며 별도 구현 승인
토큰은 필요하지 않습니다. 계획만·리뷰만과 명시적 작업 제한은 유지합니다.
HIGH가 없으면 승인 항목에 “해당 없음”을 기록합니다. 기록 자체는 권한이 아닙니다.

---

## 변경 내용

실제로 구현한 내용을 요약합니다.

-

---

## 요청 범위 / 계획과의 차이 및 권한 변경

없음.

계획과 실제 구현 사이에 차이가 있다면 아래에 작성합니다.

- 변경된 내용:
- 변경 이유:
- 범위 내 detail인지 새로운 보호 경계인지:
- 관련 artifact / Evidence:
- 위험 결정·scope 변경 승인과 대상 참조 (필요할 때만):

---

## 자동 검증

| 검증 | 결과 | 증거 / 비고 |
|---|---|---|
| Unit Tests |  |  |
| Integration Tests |  |  |
| Lint |  |  |
| Type Check |  |  |

사용하지 않는 검증 항목은 삭제할 수 있습니다. 실제 수행/차단/해당 없음을
구분하고 source-only 검토를 제품·런타임 통과로 보고하지 않습니다.

---

## 수동 / Scenario 검증

실제 사용자 흐름 또는 사람이 확인해야 하는 동작을 기록합니다.

-

---

## CI / Remote 검증

CI, Preview Deployment, Staging 또는 외부 환경에서 수행한 검증을 기록합니다.
이 항목은 실행 권한이 아닙니다. 미수행 검증과 원격 동기화 대기를 명시합니다.

-

---

## 검증하지 못한 부분

이번 PR에서 검증하지 못했거나 환경상 확인하지 못한 부분을 작성합니다.

없다면:

없음.

---

## 남아 있는 위험

Merge 이후에도 남아 있는 위험, 추후 작업 또는 주의사항을 작성합니다.

없다면:

없음.

---

## Merge Gate

현재 PR HEAD:

`<current-pr-head-sha>`

Merge에는 다음 형식의 명시적인 Human Approval이 필요합니다.

`APPROVED: MERGE @ <current-pr-head-sha>`

Merge Approval 이후 PR HEAD가 변경되면 기존 승인은 무효가 되며
새로운 Merge Approval을 받아야 합니다.

## Release / 보호 작업 경계

Push·Issue/PR 기록·원격 정리는 별도 human instruction과 접근 권한을 따릅니다.
Merge는 Release/배포·운영 데이터 삭제·유료 요청을 허용하지 않습니다.
Release와 보호 작업은 실제 대상/revision/환경에 대한 별도 명시 권한이 필요하며
대상 변경은 해당 승인을 무효로 합니다. 개인정보·tool permission과 소진 trial
제한은 유지합니다. 로컬 완료를 위해 원격·Merge/Release 단계를 강제하지 않습니다.
