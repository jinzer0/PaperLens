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

Cells: minimum×arm64, minimum×x86_64, current×arm64, current×x86_64. Each exact keys: cpu,osRole,osVersion,exact target osBuild,status(blocked/not_run/failed/verified),blockers,nullable artifact/evidence refs,nullable SQLite provenance. Cell `verified`는 실제 packaged evidence를 요구하는 structural claim이며 script가 authenticity/P1/P2를 판정하거나 synthetic fixture를 promotion하지 않는다.

- Historical candidate minimum15.0 build was unresolved. Parent now pins target15.0/24A335 from Apple's public Xcode Cloud release notes, September30,2025 macOS list: `macOS Sequoia 15 (24A335)`, separately distinguishing15.0.1/24A348. Primary source https://developer.apple.com/xcode-cloud/release-notes/ establishes release identity only, not local/minimum runtime/SQLite/Agent provenance or Xcode Cloud execution permission. Both minimum native environments remain unavailable; keep NATIVE_EXEC_UNAVAILABLE/PACKAGED_PROOF_NOT_RUN/artifact/SQLite blockers and no promotion. Current-host-as-min, null minimum build, other24-series builds including15.0.1/24A348 or15.1/24B83 must reject; missing target uses MIN_OS_BUILD_UNPINNED failure, wrong target IDENTITY_MISMATCH. No relaxed nullable compatibility path.
- current26.7.1/25G241은 부모 /usr/bin/sw_vers의 관측이다. arm64 not_run PACKAGED_PROOF_NOT_RUN; x86_64 blocked NATIVE_EXEC_UNAVAILABLE/PACKAGED_PROOF_NOT_RUN.
- Artifact/evidence/SQLite proof가 없으면 각cell에 별도blocker를 남긴다. Current host query는 minOS/packaged execution evidence가 아니다. Missing cell/point reuse/host-as-min substitution은 reject한다.

SQLite는 Apple OS-system provenance다.1.5 실제 packaged app의 loaded system image/shared-cache identity, OSbuild,sqlite_version/sqlite_source_id/compile options,GRDB open/ordered migration/FTS5 create-query-delete를 요구한다.1.6 실제 SDK success/failure/restart/appReplacement/PaperDelete의 owned purge proof도 각각 필요하다. Developer host/SDK header/probe를 다른cell의 증거로 복사하지 않는다. Raw paths/logs/test records를 durable diagnostics에 저장하지 않고 provenance는 approved code/system identity만 projection한다.

## Validator / safe failure contract

Closed exact type/key/schema, strict duplicate-aware JSON, subordinate inventory complete, exact pin/URL/version/source identity/digest syntax, bothCPU assets,4uniquecells, status/evidence/source/artifact/digest consistency를 검증한다. Hash supplied **code/artifact bytes** against pinned digest; absent bytes나 self-declared synthetic status를 actual evidence로 accept하지 않는다. Unknown/missing/conflicting fields/valid-looking changed hash/placeholder 모두 fail closed. Candidate pin이 바뀌면 bound evidence를 invalidates.

Fixed safe diagnostics {code,pointerOrPoint,cause,retestCondition}: pointer는 known schema path/closedcellID만, unknown key/value/exception/URL/localpath는 echo하지 않는다. Code enums LOCK_INPUT_MISSING/LOCK_INPUT_CHANGED/HASH_INVALID/HASH_MISMATCH/ARTIFACT_MISSING/ARTIFACT_CHANGED/ARTIFACT_UNVERIFIED/MATRIX_POINT_MISSING/MATRIX_POINT_DUPLICATE/IDENTITY_MISMATCH/MIN_OS_BUILD_UNPINNED/NATIVE_EXEC_UNAVAILABLE/PACKAGED_PROOF_NOT_RUN/PACKAGED_PROOF_FAILED/SQLITE_PROVENANCE_MISSING. cause/retestCondition도 fixedenum이며 상세 private metadata를 포함하지 않는다.

CLI exit1=invalid conformance, exit2=conformant candidate but blocked/not-run/not promoted. Offline validator는 **final lock을 promote하거나 P1/P2 PASS를 emit하지 않는다**. Fully complete synthetic fixtures도 conformance만 입증한다. No dummy resolver/no accepted placeholder/no generic success default.

## Parent proof and remaining human/environment work

Tests: each missing/changed pin class/CPU asset, valid-looking changed hashes, stale lock/artifact binding, omitted/duplicate/crosspoint evidence, unknown/incorrect key/types, fake verified/synthetic promotion, missing/wrong minimum target in both CPU cells, host-as-min substitution, safe diagnostics. Verify public target binding removes only the historical unpinned-build blocker, never unavailable native environments or actual packaged/artifact/SQLite requirements. Real synthetic code bytes의 hash mismatch tests. Exact candidate remains blocked/not_run and nonpromoting; published release identity is not actual cell evidence.

Parent pinnedPython3.13.16으로 focused+union tests, unchanged existingpins/acquire contract/whitespace/independentstaticreview 및 local evidence commit. Child는 gates/formatter/build/sign/live operation/commit을 하지 않는다. Existing historical live batch 재실행 없음.

External prerequisites: pinnedinputs+two nativeCPU packaged outputs/nestedinventory, actualP1 isolation and all4 P2 runtimecells including1.5DB/FTS5+1.6Agent events. Minimum OS native hosts and Intel/Rosetta dynamic work unavailable/banned; public target metadata/static inventory가이를PASS로 바꾸지 않는다. Missing environment/evidence마다 cause/retestcondition을 고정하고 P2/downstreamblock 유지. Push/PR/remoteCI/notary/stapler/spctl/upload/배포 승인으로 해석하지 않는다.

Minimum-target follow-up edits only validate_dependency_lock.py/test_dependency_lock.py and parent-generated runtime-matrix.json after this own-branch Spec commit; sole manifest bytes/canonical digest and historical outputs remain unchanged. Bind fresh matrix source/spec hashes, reject stale bindings, and append scoped public-source/test/static-review evidence in the existing1.4 record. Parent verifies focused/full Python union and actual offline CLI exit2; no native build/OS execution/SDK/auth/trial is renewed.

## Resumed unsigned runtime-assets-only phase

The human request to complete Stories1.1–1.26 continues scoped local execution under the risk-based governance now committed on main. Signing, authentication, exhausted trials and actual P1/P2 remain separate boundaries. Current arm64 acquisition/runtime receipts do not match the current lock, and historical package destinations are occupied. Preserve them rather than relabel, overwrite or resume them as successful inputs.

New direct evidence: the current cache contains the pinned arm64 Python archive and all eight selected wheel archives; parent discovery hashes match every manifest pin. Independent architecture review admits a finite **runtime-assets-only** preparation operation, not the ordinary full-acquisition CLI stage or product implementation. The existing approved pinned Python interpreter executes the preparation driver; newly materialized Python, SDK and CLI binaries are not executed. No network request, credential/CODEX_HOME access, signing or native/renderer/collector trial is admitted.

Exact source/test scope: add focused primitive safety tests to `Tests/Topology/test_acquire.py` only. `scripts/topology/acquire.py`, `package.py`, `dependencies.json`, the canonical matrix and all existing receipt/output namespaces remain unchanged. Parent uses the existing `load_lock`, `select_asset`, `safe_path`, `check_hash`, `runtime_stage`, `tree_inventory` and exclusive `save_json` owners; no new CLI mode, product API, partial-acquisition fallback or duplicate extractor.

Before materialization, bind the actual manifest bytes and script bytes; derive exactly one arm64 Python archive and eight wheels in manifest order. Reject omitted/extra/duplicate/wrong-CPU inputs, symlinked/missing/changed archive bytes or occupied destinations. Rehash all nine consumed cache files immediately, not merely rely on discovery. Construct only the in-memory runtime input list (`arch`, and exact `kind`/`filename`/`sha256` entries); do not call it a full acquisition receipt.

Execute unchanged `runtime_stage` once in a newly owned empty `runtime-assets-only-<uuid>` namespace outside canonical `.build/topology/arm64`. Retain its actual `runtime.json` and an exclusive, separately scoped `runtime-assets-only.json` containing current manifest/script hashes, nine actual input identities and actual materialized tree inventory. Recheck input/manifest/script bindings after extraction; mismatch or partial failure is FAILED, with no resume, promotion or historical-output modification.

Parent verification: fresh Python layout, all eight installed distribution metadata/RECORDs, actual file/link/mode inventory, unchanged historical acquisition/runtime/package bindings; no `acquisition.json`, source graph or verified runtime-cell claim. Focused synthetic tests cover actual extraction/install/inventory behavior, no network/process invocation, malformed/missing Python layout, wheel collisions/tampering, immutable destination refusal and unchanged packaging refusal without full acquisition. These fixtures are unit evidence only. Parent runs focused and union offline tests once, performs the real cached-byte operation, obtains independent source/evidence review, and commits scoped evidence locally. No project formatter is configured for these Python files; retain existing style and check whitespace.

The resulting artifact is **unsigned runtime materialization only**. Do not copy/relabel it into canonical packaging, assert GRDB/PDFium/source-graph acquisition, release-lock promotion, SDK authentication, actual cell execution, P1/P2 PASS or Story completion. Full acquisition remains mandatory for the existing CLI/package path, and arm64 remains not_run.

Independent review RUNTIME-EVIDENCE-01 corrects the ambiguous execution phrase in the original f40d67d phase: the parent driver used the already approved interpreter, not the newly materialized executables. This records the actual operation without changing its scope or renewing a trial; retain f40d67d and the original exclusive materialization report as historical evidence.
