---
title: 'Epic 1 — Story 1.1~1.27 전체 계획·구현·검증'
status: in-progress
issue: 'https://github.com/jinzer0/PaperLens/issues/3'
branch: main
product_baseline: 5eac3bb9424ad893eca7d63bc319b71f580838ed
architecture_baseline: 1195c92227cc628e325f5ff24d70cc93639bf7a9
approval: explicit-human-story-range-execution
---

# 전체 실행 계약

## Integrated native checkpoint — 2026-11-07

**Fixed-design correction:** The unapproved generation pool, alternate package
output option and `WorkerProcessScopeProof`/`exitWorker` cleanup replacement were
withdrawn. The precision-based boundary projection was also withdrawn: the fixed
contract rejects outside-CropBox geometry. Historical tests/builds below remain
evidence for their original source snapshots, not approval of the restored tree.
Approved asynchronous retirement, exclusive key ownership, GRDB build recovery
and the failed single calibration receipt are preserved. Feature implementation
and integration must finish before grouped tests and signed verification.

**Notarization and verification correction:** The user completed Keychain profile
`PaperLens`. Submission `5658d135-096a-486f-b75e-fe0628e85808` of the earlier packaged
snapshot was rejected: 19 nested/main signing findings report missing secure
timestamps. The original submission and Apple log are retained in
`.build/epic1-notarization-submission.json` and `.build/epic1-notarization-log.json`.
The packaging signer now requests secure timestamps and rejects signatures without
one. Packaging 32 and SDK 63 tests subsequently passed, but executing these partial
repair checks before complete feature integration violated the user's intended
test sequencing; they are not whole-feature acceptance. No corrected notarization
submission or current-source final signed build has completed. Further tests/builds
remain deferred until the requested feature implementation is complete.

- Pinned GRDB arm64 preparation succeeded in a private APFS workspace with the
  unchanged output-only build sandbox. Process `CCHROOT` resolves the build
  service's session-cache path; target cache settings alone did not. Failed
  attempts remain preserved. The verified output is installed under
  `.build/product-dependencies`; native builds validate its receipt, source,
  driver, framework and logs before and after compilation.
- The complete arm64 unsigned application build passed at
  `.build/topology/unsigned-arm64-7vd76wir/products`. Local packaging and signing
  passed at `.build/topology/arm64/PaperLens.app`. This is not notarization,
  distribution, minimum-OS acceptance or whole-Epic completion.
- At the user's explicit request, Xcode Release compilation also ran with
  Developer ID signing enabled. The signed product at
  `.build/topology/signed-arm64-lgrywb7k/products/PaperLens.app` passed deep,
  strict signature verification, including after the geometry correction below.
- Integrated isolated suites passed: API-key/HTTP transport 28, PDF geometry 13,
  native retirement 31 and owned transport 12. An additional real synthetic
  pre-launch broker/worker reap case passed and verifies that process-resource
  proof does not erase remaining namespace debt. Python SDK suites passed 66.
  GRDB preparation tests passed 39; build-consumer tests passed 9 plus 21 driver
  cases after correcting the signed-success fixture's normal exit handling.
- Reader advisory re-review resolved both admitted-identity and failed-observation
  freshness findings. Persisted repaired Reader results are 36 binding, 7 metadata
  and 21 annotation cases; these are not a fresh whole-product run.
- Exactly one authorized signed synthetic geometry run executed:
  `aa33c129-1e67-4ced-a768-d5763134cf26`. Its matching terminal receipt reports
  failure. Extraction completed once, cleanup was confirmed, and 4/24 cells
  passed. The other cells rejected roundtrip coordinates at page edges despite
  small measured residuals. The original report is preserved under the app's
  `Application Support/PaperLensSyntheticGeometryCalibration/<run-id>/`.
  No retry, fitted bound or production/P6 promotion was performed.
- Withdrawn experiment: the adapter projected inverse-conversion boundary noise only within the
  existing caller-supplied precision. The affine and PDFKit observations must
  agree with each other and with the returned point; excessive/nonfinite inputs
  still fail and strict canonical geometry validation is unchanged.
  Geometry unit tests passed 15, including deterministic edge-budget regressions.
  This experiment and its added tests were removed to retain the fixed boundary
  contract. Its passing results do not replace the failed signed calibration receipt.
- Genuine bounded HTTP transport exists, including actual completion/invalidation
  drainage. Summary composition/profile admission is not finished. Public model
  documentation does not establish the current hidden-server-control proof;
  no certification flags were fabricated and real API-key tests remain skipped.
  The alternate SDK process-scope retirement implementation was withdrawn;
  required SDK closure, Paper/account ownership and namespace-purge integration
  remain incomplete under the fixed contract.

## Epic 1 implementation checkpoint — 2026-11-06

The user requested Epic 1 implementation from the existing specifications and
parallel GJC sessions in Orca. Library, Reader and Provider lanes compared the
current root source with those contracts; no historical workflow was restored.

- Reader now presents the actual PDF title and valid native Contents without
  requiring a published extraction. Extraction-derived metadata retains its
  revision guards; native presentation validates Paper, PDF and Reader ownership.
- Reopening Reader requests a validated saved within-page destination once,
  preserving the existing page/zoom restoration. Current location and section
  are confirmed from the actual PDF position, not the requested destination.
  Invalid, stale, replaced and revoked contexts cannot overwrite the saved state.
- API-key startup and pre-promotion inventory reconciliation preserve separately
  validated last-good availability while blocking replacement on unknown slot
  ownership. Unknown slots are not adopted or deleted. This contains uncertainty;
  it does not implement crash-orphan deletion without durable ownership proof.
- The Main-only cancellation adapter moved from shared `OwnedChildRetirement`
  into `AgentConnectionLifecycle`. This fixes the helper-target compile error
  without changing cancellation or closure semantics.

Fresh Swift test discovery/build passed. The first isolated Product run passed
575/576; the new startup fixture failed before composition because it omitted the
selector's initial snapshot read. After correcting that setup, the exact case
passed. Independent Reader review then found pre-mount hash rebinding and
equal-coordinate refresh supersession defects. The binding now requires the
immutable admitted document identity and tracks observation freshness, including
failed observations. Four new regressions cover both findings. A throwing test
callback initially failed compilation; explicit error assertions fixed the
callback without weakening the regression.

Final affected Reader binding, metadata and annotation suites passed 36, 7 and
21 cases. The initial run plus these affected reruns covers all **588 currently
discovered Product cases** with passing latest results; this is not a single
588-case rerun. Offline topology
637, Python request 35, native request 32 and native RPC 24 tests passed. Existing
warnings remain visible; no protected readiness/renderer trial was executed.
Reports are `.build/epic1-product-tests.json`, `epic1-reader-binding-tests.json`,
`epic1-reader-metadata-tests.json`, `epic1-startup-retest.json`,
`epic1-reader-binding-review-fixes.json` and `epic1-reader-annotation-tests.json`
under `.build/`.

The whole unsigned app build remains unsuccessful: helper compilation proceeds,
but Main cannot resolve GRDB. Pinned GRDB preparation fails while persisting the
PIF cache under the unchanged sandbox; logs remain in
`.build/epic1-grdb-framework/logs/`. Ordinary output-file creation succeeds, but
Foundation replacement-directory acquisition fails. The exact denied staging
operation is not established; scoped filesystem tracing requires root access.
No sandbox expansion, unsandboxed preparation or fabricated receipt was used.

Epic 1 is **not complete**. Genuine SDK closure/containment and Paper purge,
production Summary enforcement/binding, independently admitted geometry
calibration, actual authenticated execution, signed isolation and the two arm64
OS environments remain unresolved. The pinned SDK's public close operation does
not establish the required bounded checked resource closure. The dependency
audit and verification scope are recorded in
`.build/epic1-library-dependency-audit.json` and
`.build/epic1-verification-summary.json`. Intel remains cancelled; Story 1.27
remains undefined. No credentials, user documents, paid requests, protected
trial retries, remote writes or release operations were used.

## Toolchain update selection — 2026-11-05

After deleting `.build`, the user explicitly selected “27.2로 갱신·재빌드”
after being informed that the approved 27.0 toolchain conflicts with installed
27.2 and that rebuilding regenerates `.build`. Observed local probes reported
Xcode 27.2 / Build 27B52, macOS SDK 27.2, Apple Swift 6.4.2 and
`xcrun ld -version_details` version 27106.1. The dependency lock and acquisition
linker pin now reflect that selection; deployment target 15.0, arm64 scope and
dependency source hashes are unchanged. `approvalCommit` remains the historical
PDFium patch approval, not a new toolchain approval commit.
This entry records selection and pin changes only, not a successful rebuild,
test result, signing or acceptance. Real authentication, paid requests and
protected trial retries remain unauthorized.

## Root checkout consolidation — 2026-11-05

Subsequent instruction “정리할 건 정리하자”: removed only the historical
`.build/out` and index-build `arm64-apple-macosx` generated products (918,300,031
logical bytes; not a measured physical disk-space gain). Remaining nested artifacts
were moved from `.build/topology/product-vertical-integration-20261009` to
`.build/archive/product-integration-20261009`. Historical paths below describe
their original locations; use that prefix mapping for retained evidence.
Current root build, active GRDB source mirror, all recovery archives, session records,
historical signed/failed-trial evidence and dependency source remain preserved.
The local `.build/detached-consolidation/cache-cleanup.json` records the disposition.

Actual instruction: “detached checkout도 main에 통합하자”.
The canonical product location is now the repository root on `main`, superseding
the nested execution path below. The detached root's 29 unique discovery/planning/
review documents are retained byte-for-byte, without promoting historical briefs or
reviews into approved requirements. Its ignore-policy changes are adopted while
retaining main's `.build` and `.gjc` exclusions. Main's newer GitHub templates retain
all older content plus functional-delivery guidance; they are not downgraded.

The pre-integration 33 user files are hash-verified in
`.build/detached-consolidation/root-user-files.tar.gz` and `root-files.json`.
The original detached HEAD and committed snapshot remain under
`refs/archive/detached-consolidation-20261105/`. No historical product code replaces
the previously tested main implementation. The nested checkout's untracked/ignored
build outputs, local SwiftPM configuration and session records remain at their old
paths as local artifacts, not a second registered worktree. User runtime state is
not copied into the active session or presented as completed workflow evidence.
Remote and protected acceptance restrictions remain unchanged.

Completed with one registered worktree and one local branch, both root `main`.
The nested checkout was removed using `git worktree remove` after parking all nine
untracked/ignored artifact roots. Restored artifact contents, modes, symlinks and
inodes were verified across 73,739 entries; `retirement-receipt.json` records them.
The 29 integrated documents match the original recorded SHA-256 hashes.

Fresh root SwiftPM build/discovery used `.build/root-main-verification` and the
preserved local pinned dependency mirror, not an external fetch or old test binary.
The repository's isolated runner functions verified **558/558** fresh product cases;
`.build/detached-consolidation/root-product-tests.json` records exact discovery and
case results. Root offline topology **631**, Python request **35**, native request
**32** and RPC **24** tests passed. The readiness bundle ran zero cases under the
explicit native-contract selector; protected trials were not retried. Existing
compiler/asyncio diagnostics remain visible. Product source is byte-identical to
the previously verified main; this relocation adds no product acceptance claim.
Root `.swiftpm/` and `Package.resolved` remain machine-local, uncommitted dependency
configuration. Historical build/packaging and genuine SDK acceptance debt remains.

## Local main consolidation and branch closure — 2026-11-05

Actual instruction: “branch도 정리해 다 merge하든 없애든 간에 일단 다 통합해서
검수하고 테스트 돌려서 branch 다 정리하자”.
The existing local main had no commits outside the reviewed product integration.
It was fast-forwarded from `b83ebb4` to `08dbcd2`; no conflict resolution or
whole-file replacement altered product source. This supersedes the integration
branch name below: the canonical product checkout now holds **main** at the same
original-root-relative `.build/topology/product-vertical-integration-20261009` path.
The original root is detached at `58f3dba` to preserve unrelated dirty/untracked work.

All **41** local branch tips were captured before integration in
`refs/archive/branch-consolidation-20261105/` and the verified
`.build/branch-consolidation/before.bundle` under the original root.
The **40** non-main local branches were removed after checking each live tip against
its archived SHA. Earlier source-to-integration review below accounts for reimplemented
and superseded work; historical branches were not blindly merged to resurrect old
contracts. `branches.json` and `removed.json` retain the exact mapping. Historical
commits remain recoverable, including root policy commits, without keeping working
branches open. Remote refs, push, PR and release state were not changed.

On main, SwiftPM build/discovery passed; isolated product tests passed **558/558**,
offline topology tests **631**, Python request tests **35**, and native request/RPC
tests **32/24**. `.build/branch-consolidation-product-tests.json` holds the product
receipt. Readiness bundle executed zero cases in the explicit native-contract filter;
no protected renderer/allocation trial ran. Existing warnings were retained.
Main fast-forward tree identity and final whitespace checks were verified.
The earlier packaged GRDB/toolchain blocker and genuine SDK/signed acceptance debt
remain unchanged; branch closure is not whole-product acceptance.

## Current consolidation instruction and result — 2026-11-05

Actual instruction: “1 2 3 4 5 진행해 정책 수정부터 해서 기존 작업 통합후
워크트리 정리까지 진행해 goal이든 뭐든 해서 완료해”.
This authorizes local policy consolidation, adoption of existing implementations,
affected verification/corrections, local commits and preservation-first worktree
cleanup. It does not grant new product acceptance, remote writes, real credentials,
paid requests, protected trial retries, PR merge or release.

Integration target remains `issue/epic-1-product-vertical-integration-20261010` in
the original-root-relative `.build/topology/product-vertical-integration-20261009`.
Source baseline was `acefd56fae91ae977954ebcdecf5e31e0f5e8d7d` plus its existing dirty
native ABI/worker/connection/UI/test changes. The parent owns shared DB/RPC/app
composition. Root policy commit `92211ff` supplies consolidated guidance; canonical
policy is `docs/ai-governance.md`, with short AGENTS/Build references instead of
parallel approval checklists. Existing implementation is completed/integrated before
expanding concurrent work. Independent lanes need an explicit integration destination.

### Source-to-integration disposition

| Existing sources | Disposition |
| --- | --- |
| Original Story 1.10, 1.14–1.18 dirty product lanes | Aggregated at `ab00379`; original Reader/annotation/folder sources match that checkpoint. Differences in API key/import/DB paths are later owner, configuration, cancellation, folder and read-lease integration, not missing features. |
| Functional 1.19, 1.20, 1.22, 1.24, 1.26 | Aggregated at `ab00379`, with later geometry, parsing, metadata and Settings extensions retained. |
| Functional 1.25 | Concurrent organization CAS/query fencing adopted at `ca3c301`; no duplicate cherry-pick. |
| Session 1.11, 1.14 | `45acff8` already in integration ancestry. |
| Session 1.4, 1.9, 1.12, 1.13, 1.19, 1.21–1.23 | Adopted/extended at `5e15c4a`; preserve newer contracts and tests, not obsolete whole-file copies. |
| Session 1.20 | Typed PDFium producer adopted at `e06ae42`; specs at `497db66`/`fb3fa60`, followed by actual Library input/resource ownership. |
| Parallel Agent / Story 1.2 | Exclusive producer callback latch already in `e3f4a93`. |
| Parallel RPC / Story 1.9 | EOF sealing and invalid-input poisoning already in `abf6aed`. |
| Story 1.7 / dirty parallel 1.8 | MIME UTF-8 bound already in `1b6d0f8`; retry epoch guard already in `ab00379`. |
| Historical Story 1.1 collector | Missing `33e96f57` cleanup/framing correction recovered surgically; later arm64-only policy preserved. |
| Root Story 1.8 readiness | Missing bitmap preflight/production allocation/alpha guards and tests recovered from root source and existing Spec. No protected allocation/renderer trial rerun. |
| Other historical planning/evidence, local sessions and generated artifacts | Preserved in original Git refs plus verified archives. Preservation is not a claim of implemented or accepted product behavior. |

Independent source comparisons confirmed product and contract adoption rather than
inferring it from commit subjects. Review of the dirty integration found and fixed
the deterministic loginCancel enqueue/revoke race; Story 1.9 records its bounded
dispatch/retirement semantics and follow-up CLEAR review.

### Verified integrated behavior and limits

- SwiftPM build/test discovery passed without executing readiness trials.
- Final isolated product union: **558 passed, zero failures/errors**:
  `.build/consolidation-final-product-tests.json`. Includes actual local SQLite,
  import/delete/read/annotation/organization/recovery flows and scripted native
  worker/channel cases; no genuine SDK authentication or paid Provider proof.
- Affected cancellation suites separately passed RPC lifecycle 25 and owner 31,
  including actual cancel-frame receipt, late-response fencing and stalled-writer
  deadline protection.
- Final offline topology/tooling union: **631 passed**; Python request contract:
  **35 passed**. Recovered collector suite separately passed **28**.
- Native ProviderRequest **32** and ProviderRPC **24** passed. Pure readiness alpha
  invariants **2** passed with exact selectors. No renderer or allocation trial ran.
- Changed Swift files formatted once; Xcode project plist, Build override TOML and
  diff whitespace checks passed. Existing SwiftPM unhandled pycache, compiler
  deprecated/unused-await and asyncio slow-fixture diagnostics were not hidden.
- The previously recorded unsigned-app build blocker remains: the retained pinned
  GRDB framework is incompatible with the installed SDK. It was not overwritten,
  its toolchain lock was not changed, and the unchanged failing build was not retried.
  SwiftPM product verification is not packaged-app or signed-isolation proof.
- Intel remains cancelled, Story 1.27 undefined. SDK scope cleanup/reconnection,
  remaining product activation and actual minimum/current-arm64/P1/P3/P6 acceptance
  remain as recorded below; this consolidation does not complete those older goals.

### Preservation and cleanup evidence

Verified product integration was committed locally as `a8604f5`. Cleanup then
removed **46** unchanged, archived historical worktrees and pruned **2** broken
registrations. `git worktree list --porcelain` now contains exactly **2** valid
worktrees: the original root and the product integration target. No branch refs,
unrelated root changes, active integration files or preserved archive were deleted.
`cleanup-receipt.json` records every removed path, original HEAD and archive digest.
All requested consolidation/cleanup actions are complete; the older product goals
and external acceptance limits above remain explicitly unfinished.

Preservation lives outside removed checkouts, under the original root's
`.build/worktree-consolidation/` (owner-only directory). `manifest.json` maps all
50 original registrations to HEAD, durable `refs/archive/worktree-consolidation-20261105/`
refs, status and snapshot. `all-refs.bundle` passed `git bundle verify`.
All 48 valid checkouts have SHA-256-verified archive entries; snapshots preserve
file bytes/modes, symlinks, ignored artifacts and local session records. Only the
retained root/integration omit their `.build`/`.gjc` contents, which remain in place.
Original index copies and staged/unstaged binary patches are retained too.

Cleanup requires unchanged source/HEAD/status, archive digest, preserved ref and no
live process cwd in each candidate. The machine-readable `cleanup-receipt.json`
records actual removals and final registrations; no historical branch refs are
deleted. The retained root preserves unrelated user/planning work and the archives;
the retained integration checkout is the sole product execution target. Machine-local
SwiftPM mirror/resolution files stay uncommitted rather than publishing local paths.

To recover a removed checkout, create a new worktree at its archived HEAD/ref,
extract its matching archive into that new checkout, and restore staged state using
the saved staged binary patch against that HEAD. Use the verified bundle if Git
objects need recovery. Do not overwrite either retained dirty checkout to restore.

## Current human scope amendment — product policy approved, Intel cancelled

Actual user instruction: “1,2 제안 승인, intel 빌드 계획 자체를 완전히 폐끼”.
Baseline51e2603 on the integration branch below. Product-v1 RPC and Agent-private
state policy proposed in Story1.9 are approved for bounded local implementation;
browser authUrl alone receives the approved4KiB limit. Existing ordinary256-byte
strings, queues, deadlines, actual300ms cleanup, one selector/CAS and privacy remain.
No actual login, paid probe, credentials, CODEX_HOME, consumed trial, signing,
remote publication or release permission follows from this design approval.

Intel build planning, x86_64 acquisition/build/packaging, Intel GRDB cross-build,
the proposed VM build alternative and required Intel CPU matrix cells are cancelled
entirely, not paused or counted as passing. Current target is Apple Silicon arm64.
Minimum/current macOS still require two independent arm64 DB executions and five
Agent events each (ten rows), with actual signed isolation/P3/P6 proof unchanged.
Old two-artifact/four-cell/twenty-row wording below or in approved historical
baseline artifacts is superseded only for this explicitly cancelled CPU scope.
Retain historical manifests/receipts/failures and generated artifacts; no deletion
of user work, synthetic matrix results or claim that failed Intel preparation passed.
Existing Story/Issue links remain; remote synchronization is pending authorization.

### Approved-policy / Intel-cancellation verification

- Parent final offline union: 549 Python tests PASS across acquisition, Agent, both
  matrices, dependency lock, packaging, PDFium recipe, RPC, account presentation,
  isolated verifier and GRDB preparation. Async slow-fixture diagnostics retained.
- Native contracts: 32 ProviderRequest and 24 ProviderRPC tests PASS; no renderer
  or protected collector trial executed. Typed results are fixtures, not SDK auth.
- Full fresh-process product union: 496 PASS, zero failures/errors, preserving
  production unknown-closure debt. No shared-process quota reset or guard weakening.
- Actual unsigned Release arm64 Main/nested XPC build PASS at
  .build/approved-policy-arm-only. Intel shell CLI rejects before environment/tool
  execution; shell syntax, project plist and diff whitespace checks PASS. Existing
  unnecessary-await/deprecated-onChange, AppIntents metadata and PDFium dSYM
  duplicate/debug-symbol warnings remain visible; not signed execution/P1/P3/P6.
- Current runtime-matrix.json was regenerated from actual pinned lock/validator
  bytes using candidate_matrix, not fabricated hashes. Two arm64 cells remain
  blocked/not_run with missing artifacts/runtime/SQLite proof and not_promoted.
  Original four-cell source-bound candidate remains in Git51e2603 and is not
  rebadged as current proof. Pinned historical x86 dependency records are unused,
  not downloads or active Intel deliverables.
- Independent scoped wire review found Swift Character-based authority scanning
  rejected an allowed URL whose delimiter precedes a combining mark. The paired
  native regression failed before correction (one failure). All ASCII authority
  syntax now scans UTF-8 bytes; identical browser/device slash/query/fragment
  vectors pass in both languages. Follow-up review CLEAR/APPROVE, no findings;
  final Python/native/Product/unsigned-build union reverified after the correction.
  This advisory review is not the required final native QA/acceptance cohort.
- Actual lipo checks of Main, ProviderAgent/PDFium nested XPC, FixtureGroupOwner
  and embedded GRDB binaries each report only arm64; not runtime/physical proof.
- This slice delivers exact typed product wire and cancels active Intel tooling;
  actual SDK dispatch/private filesystem enforcement/login/reconnection/purge
  integration remain engineering work. No goal or Story is completed by this slice.

## Successor execution checkpoint — 2026-11-04

- The current user explicitly authorized adoption of all five unfinished Ultragoal
  goals into this existing integration worktree, not the historical root.
  Target session: `.gjc/_session-01a1a52a-4297-750a-84f0-a33c830de875/ultragoal/`.
  Succession operation:
  `4b1f0b279c54cbef5278bda4a0f83530b3c0e7697d250bcafbba6aad1279d457`.
  Actual integration HEAD at adoption: `acefd56fae91ae977954ebcdecf5e31e0f5e8d7d`;
  branch remains `issue/epic-1-product-vertical-integration-20261010`.
  Existing dirty Provider/ABI/pipe/UI work is preserved. No new plan, source-root
  execution, historical receipt reuse, remote write, merge or protected trial.
- Fresh shared-process lifecycle verification failed because intentionally retained
  unknown resource debt affects later tests; the failure remains recorded. The
  repository's fresh-process runner then verified real SQLite/import/job ownership:
  Library lifecycle 53/53, Job recovery 24/24 and persistence/journal suites passed.
  G001 has a targeted-verification deferred checkpoint, not final boundary approval.
- The first isolated product union passed 539/550. Eleven worker tests failed before
  launch because Foundation retained the `/var` symlink in their temporary roots.
  Fixtures now follow the existing repository-owned `.build` namespace convention,
  resolve the actual Python interpreter rather than the Xcode shim, and leave the
  control socket to its sole production reader. Exact spawn environment assertions
  remain; observed CoreFoundation locale metadata is distinguished from inheritance.
- A real startup defect was exposed: `markRunning` could discharge its timer before
  transport handoff. `OwnedChildRetirement` now rejects missing transport ownership.
  Scoped independent review also identified armed readiness sources after terminal
  unknown. Notification cancellation now runs on the owning operation/MainActor lanes
  without closing descriptors, releasing debt or reporting clean. New regressions
  cover EOF before broker offer and notification-only cancellation of a pending read.
- Exact edited source/tests in this successor slice:
  `PaperLensApp/Application/OwnedChildRetirement.swift`,
  `PaperLensApp/Adapters/OwnedPipeAgentRPCChannel.swift`,
  `Tests/Product/OwnedChildRetirementTests.swift`,
  `Tests/Product/OwnedPipeAgentRPCChannelTests.swift`.
  Final current isolated union: 552/552 passed, zero failures/errors, report
  `.build/succession-product-union-quiescence.json`. Offline worker/broker/Agent/
  wire/account suite: 230 passed. These are private fixtures/scripted contracts,
  not genuine SDK authentication or signed acceptance. Existing compiler and asyncio
  diagnostics were not suppressed. Scoped re-review returned CLEAR with no remaining
  implementation blocker. Its advisory request to assert that the read stays pending
  before explicit closure was implemented and the focused regression passed again.
  This scoped review is not the final workflow cohort or external acceptance.
- Current unsigned arm64 Release build was attempted with signing disabled and
  automatic package resolution disabled. It failed because the existing
  `.build/product-dependencies/GRDB.framework` Swift module is incompatible with
  the installed macOS 27.2 SDK. The old framework was not overwritten and the
  approved dependency/toolchain lock was not changed. This narrowly blocks that
  native build, not the passing SwiftPM product build/tests or independent work.
- Verification-scope violation: a combined native Request/RPC/Readiness filter
  inadvertently executed the protected
  `testRealGeneratedPDFKitZoomCacheDisplayPixels` again despite the retained
  exhausted-trial restriction. It failed `blankCapture`. This was disclosed to
  the user and recorded in the target ledger; it is not approved proof, a new
  allowance or acceptance. No renderer/protected trial retry is authorized.
  Future commands must inspect exact test execution boundaries and exclude these
  trials. Separate offline infrastructure/request tests passed 428; native Request
  32 and RPC 24 passed. The Readiness execution remains failed/unapproved history.
- G002–G005 remain unfinished. Actual SDK resource/content closure, safe reconnect/
  purge integration and activation of remaining parsing/summary flows must not be
  inferred from test totals. Signed P1/P3/P6 and the minimum/current arm64 matrix,
  actual authenticated paid probes and consumed protected trials remain unproven or
  operation-blocked. Intel remains cancelled and Story 1.27 undefined. The aggregate
  remains active; no final completion or human-only pause has been claimed.
- Additional G002 corrections removed the unapproved one-second/100-observation
  login policy. Actual private native broker/control tests cover both handshake
  orderings and wrong-order rejection. A scripted pending-login test exercises the
  real NativeCodex owner and channel for 102 immediate observations, same-turn
  coalescing, one loginStart, zero authentication/probe/selector changes. Final
  current private Product union: 556/556 passed. Scoped source review CLEAR/APPROVE;
  not SDK authentication, complete reconnect/purge, or final boundary approval.
  Additional modified files: `ProviderSettingsService.swift`,
  `ProviderSettingsView.swift`, and existing `spec-1-9-product-provider-rpc.md`.
- All original remaining goals are preserved as blocked, not completed. G003's
  real deletion needs the absent genuine Agent Paper-scope purge binding; G004's
  production geometry activation needs the owning precision/zoom profile and
  specifically admitted independent calibration, while real Summary dispatch
  needs certified model enforcement (`requireCertifiedEnforcement` currently
  rejects every unverified profile). G005 also lacks the pinned build toolchain:
  dependencies require Xcode 27.0/27A266a/SDK 27.0, but the only installed Xcode
  candidate reports 27.2/27B52/SDK 27.2. No pin, closure or calibration guard was
  weakened to bypass these prerequisites.

## Prior execution entry point — 2026-10-14

- Objective: Epic 1 Stories 1.1–1.26; 1.27 remains undefined. This is product work,
  not the historical policy-refactoring G001. Native receipts in other sessions
  remain historical and are not rewritten or reused as current execution admission.
- Product source baseline: `62e1b3e`; policy integration baseline: `35f93ae`.
  Working integration branch: `issue/epic-1-product-vertical-integration-20261010`.
  Delivery branch: local `main`; resolve its HEAD at use time after integration.
  The old root branch `issue/10-story-1-8` is not the current product checkout.
- Actual human instruction: “모든 해결 방법 적용해. 적용후 main 이든 devel이든
  최상위 브랜치에도 merge해”. Authority covers these execution corrections and
  local main integration, not push, PR merge, credentials, paid probes or release.
- Implemented/integrated source includes product RPC/API-key connection, durable
  Paper/Job/import/delete, Reader/annotations/folders/URL import, extraction and
  recovery, metadata/summary, Library presentation/organization and Settings.
  Source presence is not compilation, runtime, genuine authentication or Done.
  Browser/device-code acceptance and actual P1/P2/P3/P6 remain unproven.
- Verification debt: prior implementation-first source slices explicitly deferred
  product tests, builds, independent review and rendered accessibility/runtime
  proof. Those debts remain open; policy checks do not discharge them. Verify the
  affected integrated flows when permitted, without renewing consumed trials.
- Blockers are operation-scoped: absent hosts block their OS×CPU cells; absent
  auth/cost authority blocks real probes; exhausted trials block those reruns;
  unknown shared contracts block dependent splits. No blanket Epic pause follows.
- Each next slice delivers one usable flow or concrete correction with affected
  tests, necessary Spec delta and Evidence. Batch risk-required review and parent
  verification; no per-edit selection/admission/review agent chain or five-file cap.
  Reuse prior unchanged findings and stop evidence-only loops. Current policy in
  docs/ai-governance.md supersedes historical phase ceremony, not acceptance facts.

### Execution-correction verification

- Policy/schema/progress/visibility checks: 41 assertions PASS; actual TOML and
  YAML parsing PASS; changed diff whitespace check PASS. Generated `.build`/`.gjc`
  are excluded from Git discovery without deleting artifacts or user work;
  application source remains visible. This does not prove native source-hash capture.
- Integrated `swift build --target PaperLensProduct --skip-update
  --disable-automatic-resolution`: PASS using materialized dependencies. Observed
  warnings remain: deprecated skip-update option, unnecessary await in
  ExtractionRevisionService and two deprecated onChange uses in URLImportView.
  No warning suppression or unrelated source cleanup was performed.
- Product tests, app executable packaging, native UI/accessibility scenarios,
  authentication, consumed trials and CPU/OS acceptance were not run by this
  correction. A successful library target compile does not discharge those debts.
- Independent execution-boundary review found two concrete stale Epic clauses:
  actual gate PASS before source and universal Story independent review. Both were
  corrected; affected SOLUTION-DESIGN sequencing was aligned. The bounded final
  delta verdict is CLEAR/APPROVE (`agent://0-ExecutionBoundaryReview`), not product
  acceptance or runtime proof. Subsequent editorial evidence updates need no new
  independent review unless their authority/safety/acceptance meaning changes.

사용자 명시적 지시: **Story 1.1~1.27 전체 계획·구현·검증을 워크플로대로 진행**. 승인 provenance는 Epic #3이다. 현재 열린 Story1.1의 진단만으로 전체 목표를 축소하지 않는다. 각 in-scope 단계마다 승인을 다시 요청하지 않는다.

Canonical Story 정의는 `bmad-docs/planning-artifacts/epics.md`의 Epic1이다. 현재 정의와 sprint registry에는 **1.1~1.26만 존재**하며 1.27은 정의 공백이다. 미존재 Story의 요구/AC를 만들어내거나 전체 완료로 계산하지 않는다. 기존 Product/Architecture 승인과 Story 분해의 AC를 baseline으로 삼는다. Draft/pending frontmatter보다 실제 human 승인 기록을 우선한다.

## BMAD 실행 순서

현재 human 실행 지시: **Story1.1~1.26 제품 기능 완성을 우선하고 P1/P2/P3 미통과를 모든 제품 코드 구현의 중단 조건으로 사용하지 않는다. 미구현 Paper·Job·저장소 소유권은 구현할 대상이다. 공통 계약 확정 후 독립 기능을 실제 worktree/실행 agent로 병렬 구현한다. 환경 부족은 해당 검증만 보류하며, 개인정보·인증·유료 요청·배포 제한과 실제 완료 판정은 유지한다.** 실제 아키텍처 조항과 충돌하는 특정 단계는 정확한 조항과 최소 순서 변경안만 제시하며 일반적인 재조사를 하지 않는다. 라이브 인증·소진 시험·실제 OS×CPU proof를 synthetic 상태로 대체하거나 gate/Story Done을 승격하지 않는다.

1. Story의 AC/선행 계약/검증 경계를 확인하고 governing Issue·task branch·Build Spec을 연결한다.
2. 기존 Spec/workunit을 재사용하고 새 human 지시·구체적인 owner/API 갱신을 연결한다. routine in-scope 후속 Spec delta는 구현 commit과 함께 보존할 수 있다. 미정인 실제 계약만 source 전에 확정한다.
3. 명세에 정의한 최소 end-to-end 단위를 구현한다. 다른 Story의 변경은 별도 work unit으로 분리한다.
4. 독립 기능은 별도 실제 worktree의 실행 agent가 구현·회귀 테스트를 작성한다. 부모만 변경 묶음의 focused/union tests·설정된 formatter·build/scenario 검증을 실행한다. evolving shared contract 의존 작업은 그 계약 확정 뒤에 연결한다.
5. 위험도에 맞는 묶음 리뷰와 부모 검증 후 로컬 구현/증거 commit을 만든다. 실패/미관측/외부 차단을 숨기지 않는다. 테스트·커밋 수를 사용자 기능 완성으로 계산하지 않는다.
6. 다음 dependency-ready 실제 기능을 진행한다. 코드 구현, 통합, 실제 외부 실행, acceptance/gate 판정을 분리한다. 미통과 gate를 blanket source blocker로 재사용하지 않으며, 정확한 frozen architecture 충돌이 있는 해당 단계와 보호된 실행만 제한한다. 소유권의 부재 자체를 human-only blocker나 fake owner/store 생성 근거로 취급하지 않는다.

## 전체 Story 작업 목록

| Story | Canonical 책임 | 실행 및 검증 deliverable |
| --- | --- | --- |
| 1.1 | 두 CPU 격리 실행 topology | 기존 Spec/Issue#2와 signed/static/live 증거 유지. OS collector/denial 귀속·TCC·두 CPU·공증/Gatekeeper 미입증은 blocked |
| 1.2 | Provider 종료·재시작 정리 | Issue#4. Paper UUID/generation/correlation attempt ownership, terminal/cancel/startup purge 및 safe Agent acknowledgement. 실제 packaged SDK 사건 증거는 synthetic 테스트와 별도 |
| 1.3 | 앱 교체·Paper 삭제 정리 | 1.2 ownership 기반 replacement/startup/paper purge, 늦은 writer 부활 방지·idempotency. P1 항목별 검증 |
| 1.4 | P2 lock·OS 매트릭스 | 정확 toolchain/runtime/SDK/CLI/PDFium/hash provenance와 최소/현재 OS×CPU 실행 matrix. candidate를 final lock으로 오인하지 않음 |
| 1.5 | packaged DB/FTS5 | 1.4 lock의 GRDB open/ordered migration/FTS create-query-delete 및 실패 재오픈. host-only DB test는 packaged matrix 증거 아님 |
| 1.6 | packaged Agent matrix | 1.2~1.5 기반 success/failure/restart/replacement/delete 사건의 OS×CPU evidence 및 P2 판정 |
| 1.7 | 공통 요청 허용·자원 한도 | ProviderRequest 단일 versioned allowlist/item-byte-token-message-stream/import-parser numeric ceilings와 Application 공통 budget policy |
| 1.8 | PDF readiness 측정 계약 | 단일 자동 navigation 또는 zoom probe, main-thread visible completion, ImportAcceptedAt/FirstInteractivePageAt·네 입력·두 CPU·초과 disposition |
| 1.9 | Main/Agent 제품 RPC | 고정된 공통 계약으로 단일 framing/handshake/method/correlation/terminal/cancel/purge/error/bounds를 구현·검증한다. 실제 P1/P2/P3 proof는 acceptance와 보호된 실행에 별도로 요구한다 |
| 1.10 | OpenAI API key 연결 | 실제 최소 인증 요청·typed response·staged slot/SQLite selector CAS·기존 active 보존. secret/유료 real request 검증은 필요한 human 입력 없이 실행하지 않음 |
| 1.11 | Codex ChatGPT 로그인 | packaged official SDK browser login·stage/usable request/config generation·정리와 safe auth 상태 |
| 1.12 | device-code 연결 | 동일 Provider 계약의 device-code 로그인·취소/기한/실패/old active 보존 |
| 1.13 | Job 실패·재실행·Retry | 제품 Import 이전 공통 class recovery, startup interrupted, attempt fence·dispatch·explicit Retry·writer/publication permit 계약 |
| 1.14 | 연결 후 local PDF Library | Provider gate·Job 정책 기반 import/독립 PDF ownership·삭제 경합. fake 연결 성공으로 gate 우회하지 않음 |
| 1.15 | Reader 읽기·이어 읽기 | 실제 PDFKit navigation/zoom/search/selection/read position·readiness instrumentation·복구 |
| 1.16 | Highlight/Note | 안정 geometry/persistence/annotation·현재 데이터 삭제·재실행·accessibility |
| 1.17 | folder/duplicate import | content hash와 Paper UUID 분리, duplicate 결정·별도 copy·folder·permit·실패 복구 |
| 1.18 | 세 URL import | HTTPS/arXiv abstract/PDF/general URL·redirect/credential/type/resource validation·취소·readiness 네 입력 통합 |
| 1.19 | sentence/geometry/Anchor | canonical extraction revision·PDF coordinates·shared tolerance/round trip·PDFKit transform·immutable sentence identity |
| 1.20 | parse/search revision 공개 | no-network PDFium XPC typed batch·inactive build·FTS·atomic active revision/fence·old refs 보존 |
| 1.21 | parse 실패/복구 | PDF 읽기 보존·typed failure·사용자 Retry·stale result/삭제 경합 방지 |
| 1.22 | metadata/outline | 실제 Paper metadata와 PDF outline/Reader navigation·실패/부재 처리·접근성 |
| 1.23 | 근거 한 줄 요약 | 공통 allowlisted summary operation·fenced Provider result·정확 provenance·실패 시 기존 결과 보존 |
| 1.24 | Library 보기/정렬/재방문 | card/list/sort·실제 저장 기록·DeleteAlert·namespace/Agent purge·작업 경합 |
| 1.25 | tag/read/favorite/search | transactional 분류·필터/search·FTS·삭제/재실행·UI 접근성 |
| 1.26 | Settings Provider 재연결 | active/staged 슬롯·config generation CAS·기존 정상 연결 보존·실제 reconnect 결과·안전한 UI |
| 1.27 | 정의 없음 | epics/sprint/기존 Issue에서 식별되지 않음. 승인된 정의를 받기 전 구현/완료 판정 금지 |

## 선행 경계 및 순서

- 검증 substrate: 1.1 → 1.2 → 1.3, 이후 1.4 → 1.5/1.6; P1/P2 증거를 CPU/OS/사건별로 검증한다.
- 공통 계약: 1.7 및 1.8의 required source/limit/readiness 결정을 의존 제품 분기 전에 고정한다. 1.9 source는 고정된 계약을 소비하며 실제 P1/P2/P3 proof는 acceptance와 보호된 실행에 요구한다.
- 제품 Provider: 1.9 공통 계약 확정 후 독립적인 1.10~1.12 source를 병렬 구현한다. 공통 Job1.13 계약 후 local import1.14를 구현한다. 실제 credentials/device/browser input·billable request를 synthetic success로 대체하지 않는다.
- Reader/import: 1.14 → 1.15/1.16/1.17 → 1.18. 화면 별 native semantic styling/한국어 copy/resize/focus/keyboard/VoiceOver와 해당 데이터의 복구·삭제 경합을 같이 검증한다.
- extraction: 1.19 계약 후 1.20 → 1.21. metadata/outline1.22, summary1.23, Library1.24~1.25, Settings1.26은 각 canonical AC/공통 gate를 소비한다.
- 구현 가능 여부는 synthetic prototype와 downstream 제품 분기를 분리해 판단한다. 외부 환경이 없다는 이유로 전체 작업을 한 log control에 고정하지 않지만, architecture의 필수 gate를 승인만으로 PASS 처리하지도 않는다.

## 검증 matrix와 완료 증거

각 Story는 기존 Spec/Issue/branch/구현 commit, 영향받는 focused+통합 검증, 실제 scenario 증거와 limitations를 보유해야 한다. 독립 리뷰는 HIGH·공통 핵심 계약·동시성·데이터 무결성 또는 명시적 acceptance 요구에만 적용하며 관련 변경을 묶어 Story별 결과를 구분할 수 있다. 실제 사용자가 제공하지 않은 auth/문서로 검증하지 않는다. macOS15/현재 OS×arm64/x86_64 packaged execution, signed sandbox negative-access attribution, TCC/coverage/clock, 실제 인증 요청은 해당 실제 환경/권한/입력의 증거가 없으면 해당 검증만 blocked다. Intel 동적 실행은 현 요청에서 자동 복구되지 않았고 면제는 PASS가 아니다.

로컬 구현 테스트와 physical CPU·packaged execution·public distribution 완료를 혼동하지 않는다. push/PR/remote CI/notary/stapler/spctl/upload/배포/merge는 별도 human 지시 대상이다. 사용자의 `.gitignore` 및 unrelated untracked와 기존 report/fixture/receipt/package namespace를 보존한다. raw request/response/log/path/secret는 safe diagnostics에 남기지 않는다.

## Historical pre-product checkpoint (current state is the entry point above)

- 전체 human SCOPE+IMPLEMENTATION 및 workflow 기록: Epic#3.
- Story1.1: 구현/진단 evidence 존재, 전체 AC와 P1 blocked; 과거 소진된 batch 재실행 없음.
- Exactly26 canonical Story Issues와 별도 local task branches가 존재한다. Issue 생성은 Story 완료가 아니다.
- Story1.2: Issue#4, Spec551dab9 / concrete synthetic cleanup68b8f41. Python315 + native15 tests, independent static CLEAR. 실제 packaged SDK/dualCPU lifecycle 및 P1/P2/P3 완료 아님.
- Story1.3: Issue#6 own-branch amended Spec9c90218 / binding82f558c / true-only wirea85b764. Retained verified session, actual registered synthetic prepare writer/FD drain and truthful purge runtime14dd7b3: focused103 + topology347 PASS/static35 final CLEAR. F1–F5 namespace/state/deadline/capacity/recovery-fence findings and failed101-test descriptor-uncertainty teardown repaired; explicit ExitStack/inode-bound callbacks preserve recycled foreign FDs. Lower-fence fresh recovery race rejects before unlink. Native18 wire proof remains separate. Unknown SDK lifecycle/product deletion/permanent post-lease fencing/hostile same-UID protection/P1/P2 remain unproved.
- Story1.4: Issue#7 Spec243a0ec / candidate source2da39b9. Closed offline validator와 nonpromoting four-cell matrix 구현. Story1.5 consumer integrationeff8349에서 single16-fact export policy와 actual source digest 갱신, focused21 + topology355 PASS/static CLEAR. MinimumOSbuild 및 실제 packaged matrix 미입증.
- Story1.5: Issue#8 initial Specd7c43ba / offline phase validatoreff8349; Spec7b48957/correctionaa18bfa keeps two CPU artifacts/four independent executions (DB20/topology356/static26 CLEAR). Local native ownership/isolated-driver Spec3f4ad18 BEFORE implementationc93e873. Actual pinned GRDB on-disk migrations/FTS/delete/rollback/same-inode reopen/observed-close and queued-operation/publication barriers: native17 PASS, compile4 GRDB warnings, 30s watchdog not exceeded/loader reaped, static36 final CLEAR after two ordinary races repaired. Earlier compiler failures and 15-test historical PASS remain recorded. CODE artifact ownership is not Main-container identity; loaded Apple image, Main wiring, minimum OS/Intel/physical four-cell/signed SDK/P1/P2 remain unproved. Existing explicit Xcode source membership excludes the native-only Probe; root Package/project/CI unchanged.
- Story1.6: Issue#9 own-branch Specf3c3500 precedes offline twenty-row validatord59ee3c. Repaired upstream DB pairingaa18bfa integrated at0d3cb71. Agent16 focused + topology372 PASS/static30 CLEAR; cyclic foreign-DB fixture explicitly rejects unequal bytes, not a same-cell no-op. Complete synthetic assertions remain blocked/not_promoted; no SDK/native matrix/P2/Story completion claim.
- Story1.7: Issue#5, Specaf2d9d1 / Python SliceA762b385 / native 및 fixed-authority security boundary7a06389. Python34 + native31/RPC15 + concurrent offline topology355 PASS, independent static CLEAR. Fixed-v1 definition/resource rewrites·Unicode closed-key aliases·typed source-kind downgrade 수정. Actual Provider certification/authentication/import/parser enforcement·측정된 allocation/runtime 한도 및 Story 완료 미입증.
- Story1.8: Issue#10 own-branch Spec99b5409 precedes reviewed checkpointcef0fb9. Pure state13 + request31/RPC15 PASS(artifact37996ee6-2bb8-42c4-b8d1-3347956c4183), zero warnings; independent source review28 CLEAR/COMMENT with renderer BLOCK. Actual public offscreen PDFKit trialea270b54-0010-437b-a552-b9656d026e0e remains FAILED with blankCapture after public layout/display setup corrections; no raster proof or full-suite PASS. Raster and visible-interactive completion remain separate; visible witness/source×CPU×OS/P6/Story completion unproven.
- Reviewed local 1.3/1.5/1.6 substrate integration: topology404 + shared request34 PASS. This is integration regression evidence, not new SDK/native packaged matrix execution, Story completion or release approval.
- Readiness branch integration: native pure13/request31/RPC18 PASS with zero warnings (artifact246c0e36-39f7-444a-8c5a-a397de451e96). Only the previously failed renderer test was excluded; no renderer rerun or raster/visible/P6 proof. Package.swift explicitly excludes independent DB Swift and Agent Python tests from the RPC target; no GRDB root target/dependency, project or CI wiring added.
- Exactly26 canonical Stories 모두 own Issue/branch/committed Spec을 감사했다. 1.9–1.26 gated planning checkpoints를 로컬 통합했으며 planning은 실제 gate나 ready-for-dev/Story completion이 아니다. 각 dependency-ready work unit을 진행하며 mandatory architecture gates를 synthetic precursor로 대체하지 않는다.
- Story1.13: Issue#15, initialSpec119a28a / completion amendmentf14f15f BEFORE purepolicyf4bc76b; helper-ownership amendmentdb3702b BEFORE composition387c578. Native25pure +4actual registered producer/purge +6negative lifecycle =35 PASS/0warnings (bc9763fd), static59 pure CLEAR and63 corrected-delta registered-synthetic CLEAR. Fresh scoped cleanup/removal invocation IDs, immutable target/debt, observed writer-FD closure, lower-fence recovery no-unlink, all-exit helper/pipe reap, complete4096-byte/2s controls and single earliest300ms teardown proved only CODE/synthetic. Initial20PASS/review48BLOCK, compile-label failure,29PASS/review61BLOCK and35/16failed cross-clock trial preserved. Public CLOCK_UPTIME_RAW/Python mach_absolute_time test clock pairing is not signed P1 clock proof. Actual Main publisher/durable Job allocation/SQLite/SDK/P1/P2/P3/P6 remain unproved; Story not done.
- Story1.27: requirements gap. 이 공백은 나머지 정의된 Story의 계획/검증용 선행 작업을 막지 않는다.

## Historical own-branch planning checkpoints (not current source status)

| Story / Issue | Spec/source checkpoint | Current scope |
| --- | --- | --- |
| 1.9 / #11 | b1ef1d8 | Product RPC unknown capabilities; actualP1/P2/P3 before implementation |
| 1.10 / #12 | d250331 | Native staged key/probe/last-good CAS; actual secret/storage/transport owners unknown |
| 1.11 / #13 | 685374f | Official browser auth shapes/static SDK inspection; no auth/runtime admission |
| 1.12 / #14 | c2ba962 | Device-code shapes; expiry/wait/resource/cleanup capability gaps preserved |
| 1.13 / #15 | 119a28a/f14f15f/db3702b → f4bc76b/387c578 | Accepted pure and registered-synthetic precursor, not durable product |
| 1.14 / #16 | f267ee9 | Real onboarding/local immutable import/delete owners and gates missing |
| 1.15 / #17 | 578c7ec | Native functional Reader/last-read; actual P6 separately gates timing |
| 1.16 / #18 | 4449322 | Original selection/Highlight/Note/durable return and delete guards |
| 1.17 / #19 | 773f1a6 | Durable folder/confirmation/independent duplicate physical copies |
| 1.18 / #20 | 2608fbc | Shared HTTPS/arXiv routes/redirect resources/Library stay; timing actualP6 only |
| 1.19 / #21 | 7597ef4 | Actual PDFium↔PDFKit calibration/shared tolerance remains unknown before split |
| 1.20 / #22 | 4174c65 | No-network typed parser/inactive revision/atomic FTS publication/pinned refs |
| 1.21 / #23 | bf73dd5 | Retained PDF/floating failure/latest reason/explicit Retry/no attempt history |
| 1.22 / #24 | a2155a8 | Truthful metadata/confirmed Contents/last-read/no Outline recovery |
| 1.23 / #25 | bdfd1d5 | Bounded summary claims need EvidenceAnchor or insufficiency, not provenance alone |
| 1.24 / #26 | 7bcd382 | Actual card/list/sorts/records/native DeleteAlert/same-saga retry |
| 1.25 / #27 | 68e370f | Durable tags/status/Favorite/current query projection/distinct Library states |
| 1.26 / #28 | 77672e3 | Actual authenticated reconnect/last-good CAS/leases/no covert replay |

Future paths/APIs/schema/geometry tolerance unknown인 곳은 기존 Spec에서 실제 공통 계약을 확정하고 완결된 기능 단위로 구현한다. 일반 후속 Spec delta는 구현·증거와 함께 commit하며 파일 수 제한이나 단계별 독립 리뷰를 추가하지 않는다. Native semantic/Korean/accessibility/focus/resize/current-data lifecycle 조건은 해당 기능의 영향받는 검증으로 확인한다. Public SDK generated login shapes는 expiry/interval/bounded queues/environment/approval/shutdown/auth-zone/actual generation capability를 입증하지 않는다. 인증·필수 packaged CPU/OS·실제 sandbox/P6 검증 없이 acceptance를 승격하거나 제품을 scaffold/mock/fallback으로 대체하지 않는다.
