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

## Current-arm64 full topology acquisition — preparation only

Independent next-operation review admits complete pinned public topology input acquisition under existing Whole-Epic scope. Missing signing permission and exhausted live trials do not prohibit this input preparation. This is a distinct operation after the unsigned materialization checkpoint, not a fallback from failed normal acquisition.

Commit this same-Spec phase before execution. Use unchanged `scripts/topology/acquire.py` owners `load_lock`, `toolchain`, `fetch`, `source_graph` and `validate_receipt`, with the same native Darwin/arm64 and untranslated-host checks as `main`. Bind actual manifest/source bytes to a newly owned empty `full-acquisition-arm64-<uuid>` namespace outside canonical `.build/topology/arm64`. Use the existing verified cache, preserving its prior entries and all historical acquisition/runtime/packages plus the runtime-assets-only artifact. Acquisition may read public PyPI metadata and retrieve fixed-revision upstream source; do not claim an offline/cache-only operation. Existing domain/hash/revision/patch/source-tree/CIPD/GCS controls, noninteractive hooks-disabled Git and safe failures remain unchanged.

Run only unchanged `fetch(lock, freshwork, host, arch, cache)` after all entrypoint preconditions, then unchanged `validate_receipt` against that same namespace/current lock. This produces a genuine new acquisition.json with Python/eight wheels/SDK-source and complete currently implemented topology graph, not a copied or relabelled historical receipt. Stop on host/toolchain/input/provenance/graph/output conflicts and preserve failed partial inputs; do not retry by relaxing a check. Parent records outcome and source/manifest/receipt hashes, real asset/repository/archive counts, validator result and unchanged historical bindings in existing Story1.4 evidence, then obtains independent scoped review and a local evidence commit.

Stop before `pdfium_stage`, `verify_pdfium_roll.py`, `build.sh`, `package.py`, compilation, signing or app/SDK/native-isolation execution. Do not bypass the build launcher's historical Spec guard or automatic signing. No credentials/CODEX_HOME/user-document access, paid Provider request, renewed renderer/control/collector trial, Intel/Rosetta execution, remote writes/notary/stapler/spctl or release operation is admitted.

Here full acquisition means precisely the existing acquire.py contract; its loader does not consume the added GRDB source pin, so this cannot certify GRDB materialization or the full P2 release lock. Acquisition success is preparation-only, with current arm64 runtime cell still not_run, P1/P2/P3 not promoted and Story1.4 not Done. Later unsigned compilation requires a separately bounded operation respecting existing entrypoint safeguards, not optimistic use of build.sh.

## Validated topology input → unsigned PDFium static library

The new full acquisition ae7a27c9-e584-40ef-a164-e9631d68d11a under Spec7c5b912 succeeded through unchanged fetch and validate_receipt: ten assets, 26 repositories, thirteen archives. Its manifest/script bindings and historical receipts remained unchanged. This concrete input enables ordinary local unsigned compilation under existing Story-range authority, without authorizing signing or compiled-component trials.

Commit this phase before execution. Run unchanged `acquire.pdfium_stage` only against that owned full-acquisition namespace and its genuinely validated current receipt. Re-run unchanged toolchain/native-untranslated-arm64/full-receipt preconditions; bind manifest/source/acquisition bytes before and after. Retain the primitive's exact source/patch checks, cached archive/hash/inventory rules, SDK alias, GN args, pinned linker verification, deny-network GN/Ninja execution, single static-library output, actual arm64 lipo result and exclusive artifact/receipt writes. No source/build configuration, version, warning policy, permission or guard changes are permitted. Occupied mismatching outputs and compilation failures remain FAILED; do not reset, overwrite or retry by weakening a check.

Parent executes the existing approved Python driver and fetched pinned build tools. The resulting PDFium code is not executed. Observe subprocess output without changing return codes/arguments or discarding diagnostic evidence; persist only closed byte/count summaries, not raw paths/logs. If diagnostic classification is unmeasured, say UNKNOWN rather than no warnings. Verify actual deps/libpdfium.a bytes and pdfium-build.json arch/hash/source/linker binding, original historical receipts and previous runtime-assets-only records unchanged. Append scoped outcome/fingerprints to the existing Story1.4 evidence, obtain independent review and make a local evidence commit.

Do not run `verify_pdfium_roll.py`, Xcode app build, `build.sh`, `package.py`, SDK/CLI/authentication, GUI/PDFKit/collector/control/isolation trials or the compiled PDFium library. Do not sign/notarize/release or claim GRDB, loaded SQLite, actual packaged cells, P1/P2/P3/P6 or Story completion. This phase compiles an already-approved prototype dependency with its existing owner, not a new product/helper implementation or alternate build recipe.

## Parallel implementation: explicit unsigned topology build mode

Independent admission identifies a routine owner-local capability, not a new architecture or signing consent. Exact mutable implementation files are `scripts/topology/build.sh` and `Tests/Topology/test_acquire.py`; commit this phase before editing them. Keep project.pbxproj, package.py, the dependency lock and Story1.1 frozen intent unchanged. Parent owns actual builds/tests/review/commits; executor edits only these two files and skips execution gates.

Add one explicit unsigned-only mode to the existing build launcher. Reuse its Xcode argv/Release/architecture/deployment/Team/entitlement/hardened-runtime settings with CODE_SIGNING_ALLOWED=NO. Retain toolchain/native-arm64/approval-ancestry/real-input checks. In this mode only, compare the exact unique `<frozen-after-approval>` section of the current Story1.1 Spec against the existing approved baseline; reject missing/ambiguous/changed intent. The current signing-capable path keeps its original whole-file guard. Do not introduce ignore-Spec, skip-validation, fallback or generic best-effort modes.

Unsigned mode consumes the genuinely validated full-acquisition/PDFium artifact ae7a27c9-e584-40ef-a164-e9631d68d11a with actual library d584abe4d10355cb242b3b0a83bc46b1327c173e009cf2f1413b69dc26374401. Validate current source/manifest/acquisition/PDFium receipt and actual archive bytes/CPU before use. In the isolated Story1.4 source root only, require fresh canonical dependency/DerivedData/products destinations, exclusively copy the actual verified archive into the project's existing library location, and recheck its bytes. Never modify the original parent-root canonical arm64 outputs or manufacture acquisition/build receipts.

The unsigned branch must not fetch/recompile dependencies, execute verify_pdfium_roll/tests/package.py, sign, launch compiled app/XPC/SDK/CLI/library or access credentials/CODEX_HOME. Paired driver tests cover genuine unsigned Xcode arguments/no forbidden calls, changed/missing/ambiguous frozen intent, stale/wrong input bindings and occupied destinations, plus unchanged signing-capable guard rejection. Parent then performs the bounded real unsigned build and statically inspects its actual app/XPC CPU/link/output identities and absence of signing tasks. Persist truthful diagnostics; no product/runtime-cell/P1/P2/P3/Story completion claim follows.

## Known prerequisite: exact pinned GRDB source preparation

The current manifest already approves GRDB.swift 7.11.1 at b83108d10f42680d78f23fe4d4d80fc88dab3212 from https://github.com/groue/GRDB.swift.git. Existing full topology acquisition deliberately does not consume this pin. A direct attempt using the Chromium checkout helper rejected undeclared_git_host before any Git/network/source operation; it did not materialize GRDB or renew a runtime trial.

Add only grdb_source_stage(lock, work) and deterministic tests in the existing acquire.py/test_acquire.py owner. Validate that exact pin before mutation, require a fresh exclusive destination, use the existing Git wrapper with global configuration/prompts/hooks disabled to fetch only the approved commit, validate actual HEAD/tree/clean tracked source, and write an exclusive source-only receipt binding the current manifest, pin, actual tree and Package.swift bytes. Do not broaden GIT_HOSTS, change full acquisition/packaging schemas, create a fallback or invent another product owner. Parent uses the approved driver interpreter and a fresh named namespace; no historical output is overwritten.

This is ordinary public input preparation under existing Story authority. Do not execute Package.swift, vendor scripts, SwiftPM, GRDB/native/SDK code, sign, package or authenticate. Receipt and actual source are not GRDB runtime, loaded SQLite, full release-lock, P1/P2/P3 or Story completion proof. Record this routine follow-up Spec and verification with the implementation commit under current change-based policy; no additional admission audit or unrelated gate rerun is required.

## Materialized GRDB → isolated unsigned compilation

The source-only phase above is complete at cfc8c4b8-0ebb-4728-9575-5db33532443b (receipt12c2b0afc3e89a076e550a970a1724293b901237f9bc3cdc5054bebcddd4eafd). This separate routine preparation phase may compile the pinned vendor's GRDB-dynamic product using the installed approved Xcode Swift toolchain, Release configuration and arm64-apple-macosx15.0 triple. Verify the actual commit/clean source, receipt and Package.swift SHA4118b6c48dcb87f91d95fe40420371b8a474a44b0b0be2bf0417e0be1ebf7853 before use. Use a fresh owned scratch/HOME/cache namespace, cleared environment and network-denied sandbox; keep SwiftPM's own sandbox enabled. SPI_BUILDER and optional preupdate flags remain unset, so the inspected manifest declares no external package dependencies or plugins.

SwiftPM executes only the inspected pinned Package.swift build-description code and approved compiler/linker tools; record this explicitly rather than claiming no vendor code executed. Do not run tests, GRDB/library/app/SDK code, open a database, authenticate, sign with Developer ID, package, or integrate an unproved runtime cell. Preserve complete stdout/stderr and warnings; inspect actual library CPU/deployment/link identities statically. No runtime/P1/P2/P3/Story completion follows from compilation. This phase does not change the frozen prototype recipe or historical source-only restrictions.

Actual SwiftPM attempt9b9ca006-f9d9-4444-8c60-07d569960a1c failed with nested sandbox_apply Operation not permitted before a GRDB build. Its driver unconditionally marked packageManifestExecuted=true; that flag is not observed execution proof and is superseded by this explicit uncertainty correction. Preserve the failed original output; do not disable SwiftPM or outer network sandboxing and do not repeat the same failing invocation.

Use the vendor's existing GRDB.xcodeproj GRDB framework target instead, not a handwritten replacement recipe: Release, macOS arm64, deployment15.0, CODE_SIGNING_ALLOWED=NO, fresh owned build/products/HOME paths and the same network-denied outer sandbox. Target inspection shows no dependencies or test invocation; its public Swiftlint script invokes optional local lint only and does not fetch/install tools. Preserve its output and do not claim lint success from its vendor-supplied ignored exit status. No vendor source/configuration edits, signing, runtime/library execution or gate promotion are permitted. Both the build outcome and static library identities must be recorded truthfully.

## Renewed human batch execution instruction and prepared-input signing

Actual human instruction: “좋아 story 1.1 ~ 1.26 일괄 구현 검증 승인이야 작업 중간중간 커밋과 푸시 merge는 승인할테니 알아서 진행하고, 모두 일괄 승인할테니 story 1 완수를 목표로해”. Preserve the full existing Epic1 objective; reuse existing Story Specs and record follow-ups with implementation commits. This follows the concrete request for local Developer ID signing/packaging of verification artifacts, admitting that bounded local operation. Availability check found exactly one matching approved-team identity without exporting key material.

Adapt only existing package.py and test_package.py so the actual unsigned products can consume separately named actual complete acquisition and actual runtime directories in the parent-owned namespaces. Validate full acquisition/native CPU/toolchain/frozen intent and prepared PDFium target before invoking its unchanged validator; validate runtime lock/CPU/actual tree separately. Do not treat the runtime-only receipt as complete acquisition, relabel/copy receipts, repeat acquisition/compilation, mutate borrowed inputs or weaken signature/entitlement/resource/output guards. Signed staging and final outputs remain exclusive in this isolated worktree. Use the existing signer and nested verification, not another signing recipe. Parent alone runs affected tests and actual packaging.

The human's promise of intermediate push/merge approvals is not a current-HEAD merge token or an instruction to push now; keep remote operations pending applicable instruction. Actual user documents/credentials/existing CODEX_HOME, unapproved paid requests, deployment/notarization and separately exhausted live/renderer/collector allowances remain excluded. A new bounded signing operation does not renew those trials or certify P1/P2/P3, runtime cells or Story Done. No admission or editorial-review loop is required for this already-specified implementation.

## Owned product preparation driver (independent Story 1.4 session)

Exact new owners are `scripts/product/prepare-grdb.py` and
`Tests/Topology/test_product_grdb.py`; topology drivers, manifests, historical
receipts and vendor source remain frozen. Implement the already-admitted official
`GRDB.xcodeproj` / `GRDB` target recipe, not SwiftPM or cached-binary acceptance.
CLI consumes `--source-receipt`, optional `--manifest` (default current topology
lock), and a mandatory fresh `--output`. Inputs are read-only. Validate the closed
source-only receipt, current lock bytes, exact approved source pin, actual Git
commit/tree and every tracked worktree blob, Package.swift digest and absence of
extra source files. Revalidate the same input fingerprints after compilation.
Reject symlink ancestors, changed inputs, source/output overlap and occupied
outputs with typed fixed codes; never erase or resume partial outputs.

Reserve output exclusively and isolate HOME, caches, intermediates and products
there. Clear inherited environment, require native untranslated arm64 and the
existing pinned Xcode/SDK/Swift/linker, deny network and all writes outside the
owned output in the outer sandbox. Build Release/macOS/arm64/deployment 15.0 with
CODE_SIGNING_ALLOWED=NO using the vendor project and its unchanged lint phase.
Preserve complete build stdout/stderr even on failure; vendor ignored lint exit
status is not lint success. Statically validate actual framework CPU, Mach-O
type/install ID, macOS deployment/SDK, system-only dependencies including SQLite,
module/header/plist presence and contained framework symlinks. Bind real output
inventory, source/receipt/manifest/driver hashes and toolchain identities in an
exclusive preparation receipt. Linker-generated ad-hoc signatures, if present,
are not Developer ID signing or runtime evidence.

Parent owns tests, formatter, real bounded build, independent review and commits.
This child authors offline mocked-subprocess/adversarial tests but runs no gates,
builds or commits. Parent wires the returned `products/GRDB.framework` into the
existing native dependency destination after validation; this driver never
copies into or overwrites that destination. No GRDB/library/app execution,
SQLite provenance, runtime cell promotion, P1/P2/P3 or StoryDone follows.

### Actual preparation failure / predicate correction (2026-10-10)

The parent reports 20 offline tests passing. The single actual unsigned official
Xcode recipe in `.build/product-grdb-prepare-20261010-a` failed during
`ComputePackagePrebuildTargetDependencyGraph`: NSCocoaErrorDomain513 with
NSPOSIXErrorDomain1/EPERM saving a workspace PIFCache file under the exclusive
output's `intermediates/XCBuildData/PIFCache/workspace`. Complete original
`logs/build.stdout` and `logs/build.stderr` remain read-only retained evidence;
there is no successful preparation receipt. The previously reused product GRDB
framework from ef5f012 is unaffected, not proof this preparation succeeded.

Bounded read-only inspection found the output and workspace directory's
`realpath` and Darwin `F_GETPATH` identical to the recipe's logical paths, with
directory modes0755. The pinned receipt identifies tree
ff52b3c22f4fc259de0adb63560b968cc4f0722a and the same approved source pin; the
recipe already directs OBJROOT and other writes into that output. These findings
do not support symlink/physical-path repair, permission changes or vendor edits.
They do not establish the effective sandbox denial's origin or rule precedence.

The narrowly scoped correction makes write predicates mutually exclusive:
deny `file-write*` only outside the output subpath and literal `/dev/null`, and
allow those exact same locations. Read-only input commands allow only the
existing `/dev/null` exception. Network remains denied; no ancestor, borrowed
source/receipt/manifest, shared cache or other writable location is added. This
removes overlap between unconditional write denial and the output allowance,
but is not evidence of the actual cause being resolved. Offline regressions
cover the exact predicates/escaping, retained PIFCache-style failure logs,
unchanged borrowed inputs and no retry/cache success on an occupied namespace;
the existing byte-identical preexisting-success-receipt assertion is preserved.

This child runs no tests, gates, builds, formatters or vendor/product code.
Parent owns focused tests, actual allowed/denied-write and network checks and
any admitted fresh-namespace compilation; the failed namespace must not be
repaired, erased or reused. Until those checks succeed, preparation remains
failed/unverified, without signing, runtime, SDK/helper trials or gate promotion.
No broader authority is requested or exercised by this predicate-only change.

### Parent verification of corrected preparation scope

22 offline preparation regressions pass. The controlled synthetic Seatbelt proof in
`.build/grdb-policy-proof-20261010-a/outcome.json` observes an output-contained write
allowed, sibling/borrowed-marker writes denied with EPERM, and loopback network access
denied with EPERM; the immutable marker remains byte-identical. This executes only the
previously approved Python and system sandbox tool, not product/helper/vendor binaries.
The admitted corrected fresh preparation in `.build/product-grdb-prepare-20261010-b`
still fails package dependency-graph preparation with the same output-contained PIFCache
EPERM. Its complete logs and the earlier failed `-a` namespace remain preserved, without
a successful receipt. Predicate enforcement is observed; effective Xcode denial origin
and fresh preparation success remain unproved. No further blind retry, sandbox disabling,
broader writable scope or permission repair is admitted by this result. Current native
product compilation reuses the independently prepared pinned ef5f012 framework, not a
framework returned by either failed preparation. Story/gate status remains unchanged.
