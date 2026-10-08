---
title: 'Story 1.4 — Candidate common lock와 OS×CPU 증거 매트릭스'
status: precursor-ready; packaged-prerequisites-blocked
story: '1.4'
issue: 'https://github.com/jinzer0/PaperLens/issues/7'
branch: issue/7-story-1-4
parent_epic: 'https://github.com/jinzer0/PaperLens/issues/3'
approval_record: 'https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229'
product_baseline: 5eac3bb9424ad893eca7d63bc319b71f580838ed
architecture_baseline: 1195c92227cc628e325f5ff24d70cc93639bf7a9
---

## Authority / scope

Canonical epics.md1.4(461–488), SOLUTION-DESIGN P2/AD13, existing scripts/topology/dependencies.json을 소비한다. 현재 일괄승인은 local in-scope Spec/구현/검증이며 gate completion이 아니다. 이 offline validator slice는 candidate lock/매트릭스의 conformance를 검증한다. Actual1.1~1.3 packaged prerequisites 및 P1/P2가 없어 final release lock promotion/helper/CI/persistence/public-packaging product split은 blocked다.

## Exact implementation targets

1. scripts/topology/dependencies.json: 기존 모든 pins/metadata 보존, 아래 grdb source pin만 추가.
2. scripts/topology/runtime-matrix.json: common candidate lock binding과 exactly4 typed cells.
3. scripts/topology/validate_dependency_lock.py: pure offline validators/deterministic CLI. Resolver/download/build/execution/automatic promotion 없음.
4. Tests/Topology/test_dependency_lock.py: actual local synthetic bytes와 adversarial manifest/matrix/evidence tests.

Committed Spec 후 구현한다. Existing acquisition/packaging runtime callsites를 이 slice에서 바꾸지 않는다. Current acquire.load_lock은 extra top-levelgrdb를 소비하지 않으므로 GRDB materialization을 검증했다고 주장하지 않는다. 전체manifest bytes/hash 변경은 historical receipts를 새 lock 증거로 무효화하며 기존 outputs/receipts를 수정·덮어쓰지 않는다. Historical source/version의 evidence는 그 original binding으로 남긴다.

## Exact candidate inputs / decisions

기존 manifest의 schemaRevision/approvalCommit/team/developerDir/systemLinker 및 URL/filename/version/SHA256/git tree/DEPSblob/patch(before/after)/GCS generations/CIPD instances/GN args 전부 그대로 유지한다. Compatibility target으로 실제 SDK/runtime/CLI 조합을 대신하지 않는다.

- Xcode27.0/27A266a, SDK27.0, Swift6.4, deployment15.0, linker27037.1.
- Python3.13.16 standalone20261003의 두CPU archives; openai-codex SDK source/wheel 및 CLI-bin 두CPU wheels0.160.0.
- Existing8wheel groups: annotated-types0.8.0, packaging26.3, pydantic2.13.5, pydantic-core2.46.5, typing-extensions4.16.0, typing-inspection0.4.4와 SDK/CLI; CPU-specific 및 any entries 모두 검증.
- PDFiumad5bc13610718aefe737bd9b2f1b258d08e39428 및 recorded tree/DEPS/patch/subordinate source/compiler/gn/ninja pins 전체 검증.
- Add exactly grdb={url:https://github.com/groue/GRDB.swift.git,version:7.11.1,commit:b83108d10f42680d78f23fe4d4d80fc88dab3212}. 부모가 public GitHub git-ref API로 tag→commit을 관측했다. 이 값은 git source identity이며 downloaded archive hash/actual build materialization은 미검증이다. Placeholder checksum을 넣지 않는다.

## Matrix / independent provenance

Matrix binds 실제 candidate manifest bytes의 SHA256 및 Spec/source identity. 두CPU outputs는 같은 manifest digest를 써야 한다. Digest를 real file에서 계산하며 zero/example hash는 reject한다.

Cells: minimum×arm64, minimum×x86_64, current×arm64, current×x86_64. Each exact keys: cpu,osRole,osVersion,nullable osBuild,status(blocked/not_run/failed/verified),blockers,nullable artifact/evidence refs,nullable SQLite provenance. Cell `verified`는 실제 packaged evidence를 요구하는 structural claim이며 script가 authenticity/P1/P2를 판정하거나 synthetic fixture를 promotion하지 않는다.

- minimum15.0 exact build는 unresolved: both blocked MIN_OS_BUILD_UNPINNED; x86_64는 NATIVE_EXEC_UNAVAILABLE도 추가.
- current26.7.1/25G241은 부모 /usr/bin/sw_vers의 관측이다. arm64 not_run PACKAGED_PROOF_NOT_RUN; x86_64 blocked NATIVE_EXEC_UNAVAILABLE/PACKAGED_PROOF_NOT_RUN.
- Artifact/evidence/SQLite proof가 없으면 각cell에 별도blocker를 남긴다. Current host query는 minOS/packaged execution evidence가 아니다. Missing cell/point reuse/host-as-min substitution은 reject한다.

SQLite는 Apple OS-system provenance다.1.5 실제 packaged app의 loaded system image/shared-cache identity, OSbuild,sqlite_version/sqlite_source_id/compile options,GRDB open/ordered migration/FTS5 create-query-delete를 요구한다.1.6 실제 SDK success/failure/restart/appReplacement/PaperDelete의 owned purge proof도 각각 필요하다. Developer host/SDK header/probe를 다른cell의 증거로 복사하지 않는다. Raw paths/logs/test records를 durable diagnostics에 저장하지 않고 provenance는 approved code/system identity만 projection한다.

## Validator / safe failure contract

Closed exact type/key/schema, strict duplicate-aware JSON, subordinate inventory complete, exact pin/URL/version/source identity/digest syntax, bothCPU assets,4uniquecells, status/evidence/source/artifact/digest consistency를 검증한다. Hash supplied **code/artifact bytes** against pinned digest; absent bytes나 self-declared synthetic status를 actual evidence로 accept하지 않는다. Unknown/missing/conflicting fields/valid-looking changed hash/placeholder 모두 fail closed. Candidate pin이 바뀌면 bound evidence를 invalidates.

Fixed safe diagnostics {code,pointerOrPoint,cause,retestCondition}: pointer는 known schema path/closedcellID만, unknown key/value/exception/URL/localpath는 echo하지 않는다. Code enums LOCK_INPUT_MISSING/LOCK_INPUT_CHANGED/HASH_INVALID/HASH_MISMATCH/ARTIFACT_MISSING/ARTIFACT_CHANGED/ARTIFACT_UNVERIFIED/MATRIX_POINT_MISSING/MATRIX_POINT_DUPLICATE/IDENTITY_MISMATCH/MIN_OS_BUILD_UNPINNED/NATIVE_EXEC_UNAVAILABLE/PACKAGED_PROOF_NOT_RUN/PACKAGED_PROOF_FAILED/SQLITE_PROVENANCE_MISSING. cause/retestCondition도 fixedenum이며 상세 private metadata를 포함하지 않는다.

CLI exit1=invalid conformance, exit2=conformant candidate but blocked/not-run/not promoted. Offline validator는 **final lock을 promote하거나 P1/P2 PASS를 emit하지 않는다**. Fully complete synthetic fixtures도 conformance만 입증한다. No dummy resolver/no accepted placeholder/no generic success default.

## Parent proof and remaining human/environment work

Tests: each missing/changed pin class/CPU asset, valid-looking changed hashes, stale lock/artifact binding, omitted/duplicate/crosspoint evidence, unknown/incorrect key/types, fake verified/synthetic promotion, unresolved minimumbuild, host-as-min substitution, safe diagnostics. Real synthetic code bytes의 hash mismatch tests. Exact candidate의 initialblocked 상태를 유지함을 assertion한다.

Parent pinnedPython3.13.16으로 focused+union tests, unchanged existingpins/acquire contract/whitespace/independentstaticreview 및 local evidence commit. Child는 gates/formatter/build/sign/live operation/commit을 하지 않는다. Existing historical live batch 재실행 없음.

External prerequisites: reliable exactminimum15 build pin, pinnedinputs+two nativeCPU packaged outputs/nestedinventory, actualP1 isolation and all4 P2 runtimecells including1.5DB/FTS5+1.6Agent events. Intel/Rosetta dynamic work unavailable/banned, static inventory가이를PASS로 바꾸지 않는다. Missing exactbuild/environment/evidence마다 cause/retestcondition을 고정하고 P2/downstreamblock 유지. Push/PR/remoteCI/notary/stapler/spctl/upload/배포 승인으로 해석하지 않는다.
