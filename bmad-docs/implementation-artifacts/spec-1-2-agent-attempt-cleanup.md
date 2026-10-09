---
title: 'Story 1.2 — Agent attempt 종료·재시작 정리'
status: ready-for-dev
story: '1.2'
issue: 'https://github.com/jinzer0/PaperLens/issues/4'
parent_epic: 'https://github.com/jinzer0/PaperLens/issues/3'
branch: issue/4-agent-attempt-cleanup
risk: HIGH
product_baseline: 5eac3bb9424ad893eca7d63bc319b71f580838ed
architecture_baseline: 1195c92227cc628e325f5ff24d70cc93639bf7a9
approval_record: 'https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229'
---

## Intent / permission

Epic의 명시적 일괄 SCOPE+IMPLEMENTATION 승인으로 구현한다. 이 Spec을 commit한 뒤 반복 승인 요청 없이 구현/회귀/독립 리뷰를 수행한다. canonical Story1.2 AC는 epics.md다.

이번 단위는 Agent 내부의 **실제 synthetic filesystem attempt-cleanup 검증 substrate**다. Provider SDK 요청을 fake success로 대체하지 않는다. terminal outcome은 synthetic fixture의 시험 사건이고 실제 SDK success/failure 증거가 아니다. Story1.1 전체 gate, 실제 packaged official SDK request/worker-drain, two-CPU/OS evidence가 없으므로 이 구현만으로 Story1.2/P1/P2/P3 PASS나 제품 연결 완료를 주장하지 않는다.

## Existing authority / file slice

Renewed human Story1.1–1.26 batch implementation/verification and explicit worktree parallelism admit a concrete same-owner repair in only ProviderAgent/agent.py and Tests/Topology/test_agent.py. A duplicate registered prepare callback could publish another still-active callback's producer.closed event from its own failing finally. Add one irreversible nonblocking per-producer execution latch; only the winning callback enters completion accounting. Keep bounded census/descriptor/filesystem validation inside its actual completion finally, preventing the reviewed state-lock timeout from leaving ended work undrained. Do not remove descriptor-closure failure guards, renew SDK/live/control/collector/renderer trials or create another owner. Six parent registered-synthetic tests pass, including real duplicate-writer barriers and held-state timeout followed by purge/session release; independent delta rereview CLEAR/APPROVE resolves that specific finding. Verified bytes are integrated without rerunning unchanged inputs. Existing signed artifacts do not contain this later source fix and must not be promoted as its runtime proof.

- `ProviderAgent/agent.py`: fixture_profile, descriptor ownership/closed diagnostics/Server dispatch 패턴 재사용. 작은 `AttemptFixtures` store와 아래 topology methods를 실제 연결한다. 임의 generic storage engine/DB/product provider는 추가하지 않는다.
- `Contracts/ProviderRPC/contract.json`: 유일 wire schema에 세 method와 generation/outcome definitions를 추가한다. 기존 topology major/minor/capability를 유지하는 additive 시험 method이며 제품 RPC Story1.9로 전용하지 않는다.
- `Tests/Topology/test_agent.py`: 실제 temporary filesystem과 Server RPC를 이용한 lifecycle/재시작/충돌/오류 tests.
- `Tests/Topology/test_provider_rpc.py`: closed schema와 bounds/extra key/enum/kind/error tests. Native validator는 같은 contract resource를 읽으므로 별도 policy 복제 없이 부모 native suite도 실행한다.
- `Tests/Topology/ProviderRPCTests.swift`: 새 세 method의 실제 native encode/decode/request/terminal 검증과 generation/UUID/outcome/boolean 경계 사례를 기존 exhaustive fixtures에 추가한다. 기존14 tests만 통과했다고 새 method coverage를 주장하지 않는다.
- `Package.swift`/native protocol/앱 UI/runtime/package source는 이 slice에서 바꾸지 않는다. 패키징/실제 SDK lifecycle integration은 unresolved acceptance evidence로 남긴다.

## Closed topology wire

1. `topology.attemptPrepare`: params `{runID,paperID,generation,correlationID}`, result `{prepared: boolean}`.
2. `topology.attemptTerminal`: 위 identity params + `{outcome: success|failure|cancelled}`, result `{absent: boolean}`.
3. `topology.attemptRecover`: params `{runID}`, result `{absent: boolean}`. 새 Store/Server instance에서 동일 trusted fixture run을 복구하여 restart를 검증한다.

모든 ID는 기존 canonical lowercase UUIDv4 definition. generation은 exact integer 1..2147483647 (bool 금지). Extra keys/unknown outcome은 기존 typed invalidParams. filesystem/ownership/cleanup error는 고정 `unavailable`, busy는 기존 busy. Raw marker/paths/manifest/exception은 result/diagnostic/stdout에 포함하지 않는다. 결과 true는 해당 bounded fixture의 ownership/absence 검사를 완료했을 때만 반환한다.

## Store ownership and caps

- Root는 실제 UID OS account metadata와 fixture_profile()이 검증한 **Agent container**의 `Library/Application Support/PaperLensAttemptFixturesV1`이다. arbitrary argv/env/home override를 추가하지 않는다. Unit tests만 fixture_profile을 synthetic TemporaryDirectory로 patch한다.
- 기존 topology reports/fixtures/runtime/CODEX_HOME과 다른 새 namespace다. 알 수 없는 preexisting root/run/child/symlink/receipt는 adopt/replace/move/delete하지 않는다. Store root의 fixed ownership marker를 exclusive 생성하고 schema/version/UID/type/mode를 no-follow descriptor로 검증한다. Root marker는 고정 package/fixture metadata이며 Paper content를 포함하지 않는다.
- Root/run/attempt directory mode700, leaf/functional ownership receipt mode600, current UID, regular file/dir, no symlink. 모든 부모는 component-by-component O_DIRECTORY/O_NOFOLLOW traversal; root/run/attempt descriptor-relative operations를 사용한다. 외부 target/recursive shutil.rmtree는 금지.
- 모든 regular-file open에는 O_NONBLOCK도 적용하고 type/UID/mode/link-count를 열린 descriptor에서 확인한다. 디렉터리 열거는 bounded iterator로 수행하며 unbounded listdir 결과를 먼저 materialize하지 않는다.
- 한 run은 최대32 attempts. 한 root의 startup 검사는 하지 않고 `attemptRecover(runID)`의 **named run만** 검증한다. 모든 디렉터리 열거/receipt read는 bound(최대64 entries, receipt≤4096 bytes)로 제한한다. Store의 used-correlation set은 최대256으로 bounded; full이면 새 attempt를 거절하고 자동 eviction/reuse하지 않는다. Store 내 mutating calls는 nonblocking owned lock으로 serialize하며 busy 상태에 기다리지 않는다.
- Process-local thread lock만으로 여러 Agent process를 serialize했다고 주장하지 않는다. 검증한 root ownership receipt FD를 context 종료까지 보유하고 kernel flock의 LOCK_EX|LOCK_NB로 cooperating processes를 serialize한다. Contention은 busy이며 filesystem state를 변경하지 않는다.
- run은 생성한 Agent의 ownership receipt에 정확 run identity와 owned directory inode identity를 남긴다. attempt는 고정 correlation child와 immutable receipt에 runID/paperID/generation/correlationID 및 소유 directory/marker inode identity만 기록한다. 이는 새 시험 namespace의 **functional crash-recovery ownership metadata**이며 diagnostics/evidence로 복사하지 않는다. Paper-linked metadata는 cleanup 후 제거한다. UID/path/PID/time/내용/log/secret/hash를 safe evidence에 남기지 않는다.
- root/run/attempt ownership receipt 모두 **자신의 exclusive-creation FD에서 얻은 device/inode identity**도 자기 body에 기록한다. Recovery는 no-follow로 연 receipt FD와 그 self-identity를 비교한 뒤에만 사용한다. 동일 bytes를 다른 inode로 복사한 replacement는 foreign/unavailable이며 삭제하지 않는다. Same-UID의 의도적 receipt forgery 자체를 cryptographic authentication으로 막았다고 주장하지 않는다.
- Marker는 고정 synthetic bytes만 쓴다. directory와 empty marker의 ownership을 먼저 확보하고 exclusive receipt를 완전히 작성/fsync한 다음 marker bytes를 쓴다. receipt가 없는 pre-provenance crash residue는 삭제하지 않고 unavailable로 남긴다. Failure rollback도 이미 확보한 inode ownership만 정리한다.
- Duplicate run/correlation/다른 paper 또는 generation 매핑을 새 prepare로 덮어쓰지 않는다. 이미 종료된 correlation의 동일 Store 내 재사용도 거절한다. RPC request 자체의 nonreuse/terminal fence는 기존 Server policy를 유지한다.

## Cleanup / recovery invariants

- Terminal success/failure/cancelled는 같은 실제 cleanup을 사용한다. Outcome은 cleanup exemption이 아니다. 실제 terminal 신호의 의미 검증은 SDK integration 후 별도다.
- Cleanup은 immutable receipt를 strict bounded JSON으로 검증하고 exactly matched identity, UID/type/mode/expected inode와 고정 file layout만 소비한다. Unknown/foreign/replaced/hard-linked/symlink/extra entry는 실패이며 그대로 보존한다. Receipt duplicate fields/wrong schema/generation/UUID도 fail closed다.
- marker가 있으면 동일 owned inode/control 검증 후 descriptor-relative unlink한다. marker가 이미 없고 attempt directory가 검증된 empty이면 crash-after-unlink recovery로 directory 제거 가능하다. attempt directory도 이미 없으면 receipt가 입증한 named fixture absence만 확인하고 receipt를 정리한다. directory가 다른 inode로 존재하면 absence라 주장하지 않는다.
- receipt는 marker/directory removal/absence 확인 후 마지막에 제거한다. run은 모든 owned attempts/receipts를 제거하고 empty/owned inode 확인 후 마지막에 제거한다. Atomic replacement race를 private API로 해결하지 않으며 same-UID hostile tampering race는 explicit limitation이다. 안전 확인 실패를 성공으로 세지 않는다.
- 동일 terminal/recover를 반복해도 이미 정리한 fixture에는 absent=true이며 unknown 남은 entry에는 unavailable다. 재시작은 새 Store instance의 named-run recover를 통해 ledger와 ownership 검증을 처음부터 수행한다. Native app이 Agent zone을 열어 cleanup하지 않는다.
- cleanup failure는 primary result를 success로 바꾸지 않고 retryable unavailable다. 기존 worker/protocol cancellation/timeout/queued terminal behavior를 변경하지 않는다. Future actual SDK lifecycle은 worker drain 이후 store cleanup 후 acknowledgement라는 순서를 반드시 소비해야 한다.

## Verification and observable completion

- Parent approved Python3.13.16로 focused Agent/ProviderRPC tests 및 전체 `Tests/Topology/test_*.py` union을 실행한다. Native ProviderRPC Swift suite도 central resource consumer로 실행한다. Child는 gates/formatter/build/sign/live queries를 실행하지 않는다.
- Real temp filesystem: prepare writes marker; all3 terminal outcomes remove marker + Paper metadata; fresh-instance recover; repeat terminal/recover; distinct Papers/generations/correlations; bounds와 typed failure; caps/exhaustion.
- Adversarial cases: foreign root/run/file, changed inode, symlink at each traversed component, hard links, extra child, malformed/duplicate receipt fields, partial marker/receipt creation, absent-marker/absent-directory interruption, cleanup failure, contention, wrong identity; foreign bytes/inode remain unchanged.
- Fresh-instance recovery에서 valid receipt를 동일 bytes/different inode로 교체하는 regression을 추가하고 replacement inode/bytes와 marker를 그대로 보존함을 검증한다.
- Server wire: hello then3 methods, wrong/extra fields rejected, result/diagnostics contain only closed ack/error and correlation envelope, no raw filesystem/input/exception; existing one terminal/cancel/timeout tests unchanged.
- Independent static review after implementation; parent union/whitespace gate and source/Spec joins; local commit and Issue4 evidence. No app/SDK login/model/thread/turn/PDF/GUI/Intel/Rosetta/notary/stapler/spctl/push/PR/upload operation in this unit.
- Local substrate完成는 이 Spec의 동작과 tests/review/evidence에 한정한다. 실제 canonical Story1.2 acceptance는 packaged SDK 성공·실패·취소/worker-drain/startup integration 및 missingCPU/sandbox evidence 없이 **blocked**다. Synthetic signal을 실제 Provider 성공으로 표시하지 않는다.
