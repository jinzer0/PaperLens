# Story 1.11 Build Spec — ChatGPT Browser-Login Connection

## Current explicit product-policy approval

User approved proposals1/2 and cancelled the entire Intel build plan at source
baseline51e2603. Story1.9 current admission now pins product-v1 handshake, bounded
login observation, stage/intent/selector correlation and cleanup proof separately
from cancellation; browser authUrl4KiB is the sole approved limit increase.
Agent-only stages/configs/attempts/quarantine app namespaces, protected creation,
backup exclusion, no permission repair and no persistent Paper metadata are
approved. SDK filenames/auth export/home layouts are not guessed. Old missing
policy/source-admission labels below are superseded for these named decisions,
not public SDK support or genuine authentication. Implementation follows the
existing whole-Epic authority; no extra per-edit approval, live login/cost/user
credential/CODEX_HOME/protected-trial renewal/remote permission is inferred.

## Current whole-Epic source continuation — 2026-10-14

### Bounded account presentation / packaged-resource continuation

Continue after312fd1c without reopening the approved RPC/private-state choices.
The shared account controller is not currently installed by the runtime packager,
and its SDK instruction projection has no byte bounds. Deliver that concrete
integration slice in ProviderAgent/account_login.py, its existing paired test,
scripts/topology/package.py and its existing test. Import limits from the same
packaged provider_rpc module: loginId/userCode/device verificationUrl stay256
decoded UTF-8 bytes; browser authUrl alone permits4096. Accept equality, reject
one-over and malformed surrogate input, and count UTF-8 bytes rather than Unicode
characters, without exposing SDK instructions/errors.
Keep current closed mode/key/URL/correlation/terminal rules; owner registers every
SDK loginId before projection and retains cleanup responsibility on rejection.

Install account_login.py beside agent.py/provider_rpc.py/contract.json using the
same owned regular-source / no-symlink-destination resource-copy rules. Actual
runtime packaging owns Python resources; adding an isolated Xcode resource with
missing Python dependencies is not an alternative. Private synthetic packaging
tests must check exact copied bytes and refusal of missing/symlink source or
symlink destination, without invoking signing, downloading or executing the SDK.
This makes the real controller available to the packaged endpoint; it does not
implement SDK dispatch, private-root enforcement, auth, polling, CAS or purge.

Parent result: shared canonical limits now enforce decoded UTF-8 boundaries in
the actual browser/device projector, including fail-closed current intent and no
private display on overflow. The packager installs account_login.py and preflights
all four regular sources/no-symlink destinations before copying the runtime.
554 offline union tests PASS; standalone account27 PASS. Copied-module import uses
the copied provider_rpc/contract bytes, exercises the4096/4097 browser boundary
and never imports/initializes the SDK. Missing/directory/symlink source or linked
destination leaves the whole owned fixture inventory and marker unchanged, with
no commands/signing. Native Swift and build inputs are unchanged from312fd1c;
no native build, live auth, physical SDK/backup/purge acceptance or trial is claimed.

The Story1.1–1.26 execution request resumes this existing work unit on integration
branch `issue/epic-1-product-vertical-integration-20261010`, baseline `57fa3c4`.
The historical planning/source-session restrictions below describe those sessions;
they do not prohibit current parent-owned in-scope implementation/tests/commits.
P1/P2/P3 and StoryDone remain false; source progress is not runtime admission.

Unify the existing device presentation controller with the evidenced browser SDK
projection in `ProviderAgent/account_login.py`; remove the old device-only module
and controller rather than leave aliases or a second lifecycle. The controller
requires explicit `chatgpt` or `chatgptDeviceCode` mode and accepts only that mode's
closed SDK projection. Browser fields are exactly type/loginId/authUrl, as evidenced
below, not newly invented outer RPC fields. Share URL safety, immutable private-repr
instructions, exact current-token correlation, one terminal and auth-completed-only
probe handoff. Reject cross-mode payloads and all late/duplicate/missing-login effects;
never open a browser, import/start the SDK, poll, persist, fabricate a probe or promote
the selector from this layer. The lifecycle owner still registers every late loginId
and owns actual cancellation/closure, stage/CAS and trusted bounded SDK admission.

The paired test is now `Tests/Topology/test_account_login.py`; update Package.swift
for the renamed test and the already-added Python isolated-verifier test exclusion.
Exactly these two source/test files, Package.swift and the existing Story1.11/1.12
Specs form this continuation. No native production wire/UI activation is delivered
by this component. Full usable browser login remains unfinished, not a successful
login fixture or permission to bypass the actual shared owner/SDK requirements.

Observed verification: 24 private pure account-login regressions PASS, including all
17 existing device cases plus browser projection, URL/type/extra-field denial,
explicit/cross-mode refusal, one-time correlated handoff, replacement and cancellation
without cleanup or connection claims. No user URL/credentials/CODEX_HOME, SDK, paid
request, signing, renderer trial or remote action occurred.

## Status and sources

Issue#13 / `issue/13-story-1-11`, base `b1ef1d85116f56ac9b4fdbedd101c918591ff1e6`. Planning ONLY, not implementation-ready: P1=false, P2=false, P3=false, StoryDone=false; product implementation BLOCKED by actual gates and missing Story1.9/1.10 boundaries.

Caller approval provenance: PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`, https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. In-scope Whole-Epic authority permits own-branch Spec commit without repeated unchanged-scope approval; neither gate passes nor new credentials/live/paid/remote/distribution permissions follow. SDK/CLI-bin0.160.0 is caller pin provenance, not proven capability.

Architect40 inspected exactly canonical ROOT epics.md:660–688, own SOLUTION-DESIGN, Story1.9 Spec, ProviderRequest contract.json and PaperLensApp.swift. Missing worktree epics was not copied. Stale draft labels do not override approved baselines. Current sdkImported/cliInitialized topology label is not authentication or usable connection.

## Required browser-login and activation

- Application requests a never-reused stage/config identity through the admitted boundary; Agent creates/owns auth state. Last-good selector/config and its in-flight leases remain untouched during login/testing.
- Only packaged official Python Codex SDK supported ChatGPT browser login. No generic Codex OAuth, internal chatgptAuthTokens, private APIs, system Python/CLI, plugins, simulated login or fallback.
- After actual login, perform smallest real authenticated v1 connectionTest with staged configuration and shared typed contract: empty input, fixed prompt `Reply exactly PAPERLENS_OK.`, exact result `{text:"PAPERLENS_OK"}` with unchanged version/request/operation. Never synthesize/echo the sentinel locally or treat it as an auth RPC field.
- Browser return, token presence, SDK startup, identity/model listing, HTTP success, capability advertisement and auth completion alone are not connection success.
- A current typed usable response makes the stage eligible, not active. Application applies Story1.10 serialized SQLite CAS against expected selector/config/current intent. Only the winner exposes success; Agent/slot/directory names never select Provider.
- New work uses new config generation; old calls may finish but cannot publish in the new generation. Old slot survives until its actual in-flight lease terminates.
- Login cancel/failure, probe failure/timeout/exit, unsafe zone, stale intent or CAS loss never promote/change last-good or leased configuration. Safe redacted reasons plus explicit Retry/path switch; new identities and invalidated abandoned stage, no ambiguous automatic replay.
- One terminal across usable/failure/cancel/timeout/exit; stale/duplicate/wrong correlation/operation/generation cannot revive a stage or complete new work.
- Startup validates selected complete state and cleans abandoned stages/prior attempt content through their owner. No leftover-stage promotion or abandoned-login resume.

## Agent-private zone and content lifecycle

Agent alone owns its sandboxed auth/config zone. Main neither mounts/shares it nor reads credentials/SDK files; Agent cannot access Main PDF/DB/cache/native API-key storage. Persistent Provider metadata is separate from Paper content.

Protected creation and directory0700/file0600 plus backup exclusion must cover every descendant, including SDK-created entries, after writes/auth and at startup. Wrong owner/mode/exclusion blocks probe/promotion and invalidates owned stage; failed removal remains safe visible barrier, not permission repair/default/fake absence. Active/leased last-good state is never removed by failed-stage cleanup.

Paper request/response/EvidenceBundle/generated result/document content cannot persist in auth/session/log metadata. Required local Paper bytes are attempt-scoped to Paper UUID/generation/correlation and cleaned idempotently on terminal/cancel/startup. Revoke first, observe actual producers stopped/handles closed, then ownership validation/unlink/absence. Cancel ACK or process disappearance alone is not drain proof.

Correlated cleanup ACK crosses Story1.9 only after actual owner verification; its exact fields remain unresolved authority. Stale/wrong-generation/missing/failed ACK retains affected publication/deletion barriers. Main cannot substitute a broad filesystem scan; no caller-selected sweep.

Protocol-only stdout and fixed safe diagnostics. Only validated minimal auth instructions may reach the intentional live browser/login surface; no raw browser URL/query/code/token/secret/argv/environment/path/SDK exception/request/response/document diagnostics or unrelated UI projection. Exact validated environment only; no secret argv.

## Missing admission decisions

Actual P1 dual-artifact isolation/nested-runtime/content cleanup; actual P2 exact lock/two artifacts/four physical OS×CPU DB and twenty Agent event cases; actual P3 common Application/Provider/Import/PDF budgets remain missing. Local GRDB17/purge103/contract parity do not pass them.

Story1.9 must finalize product handshake/auth/request/cancel/cleanup/startup/purge schemas and safe errors. Story1.10 must implement sole selector, stage/CAS/current-intent/config generation/lease ownership. This Spec invents none of their fields.

Parent static follow-up inspected controlled installed openai-codex metadata declaring0.160.0 plus its public client/generated types/router, without import/init/auth/network. Public `CodexClient.account_login_start`, `account_login_cancel`, `next_login_notification`, `wait_for_login_completed` exist. Browser params type is `chatgpt`; response has loginId/authUrl; completion has success, optional loginId/error. Those public shapes are NOT final product wire fields or runtime/capability proof. Null/wrong correlation and raw error cannot certify success.

Observed admission hazards: SDK start copies os.environ then overlays config.env (not an environment replacement); default approvals accept command/file-change requests; login/global queues and pending login storage have no configured capacity; login waits block without a timeout argument. SDK close calls wait(timeout=2), then may kill without subsequent wait, and may join each reader/stderr thread with timeout0.5s. These timeouts are not fixed waits or a total-duration bound. None proves bounded cumulative300ms owned cleanup, reaping or authenticated absence. Generated types supply no closed byte/URL/expiry policy. Do not patch private SDK internals, invent a poll timer or widen budgets; prove a supported public boundary and actual resource/termination controls before admission.

Authenticated generation/output, exact public bounded shutdown effects, private auth/config paths, SDK descendant/log/session behavior and no-durable-Paper mechanism remain unresolved. No guessed home layout, user CODEX_HOME inspection or private implementation substitute. Reconcile waits/cleanup with admitted budgets, no alternate transport. Static source follow-up is separate from architect40's original five-file proposal and executes no runtime.

Independent reviewer47 CLEAR/COMMENT for the five-file source-fact amendment only; no product/gate approval. Parent verified metadata declaration/source identities; reviewer did not independently inspect metadata/version provenance. Durable bounded receipt: evidence/1-11/sdk-source-inspection.json.

## Conditional delivery and verification

After actual gates and exact same-Spec amendment: Agent/browser phase `ProviderAgent/agent.py` and `Tests/Topology/test_agent.py` (two files). Native integration follows finished Story1.9/1.10 contracts; name at most five exact files including paired tests in an amendment before edits, not guessed fields or auth/SQLite/product UI grafted onto the smoke entry. Remove superseded paths, no aliases/stubs/fallbacks.

Verify actual login plus authenticated correlated probe/current CAS; auth-only/wrong/suffixed/malformed/unauthenticated results rejected. Race usable versus cancel/timeout/path change/promotion/old generation, one terminal/no stale activation. Hold old work through replacement and actual drain. Restart selected versus abandoned/incomplete stage. Refuse unsafe SDK descendants/owner/backup state without repair. Exercise actual SDK marker bytes through all lifecycle events and late/missing/stale ACKs; preserve unrelated active state. Unsupported public API/output/environment fails closed, not system-runtime substitution. Deterministic cases supplement, never replace actual auth and physical matrix proof.

Device code, final Provider-choice/Settings/Library integration are separate. No accepted-limit disclosure/consent or FR-002 completion claim. Architect40 COMMENT on planning only; no product approval. No edits/tests/gates/build/GUI/SDK/auth/network/credential/paid-request/permission changes performed for this Spec. Done requires exact admitted contracts, real gates/authenticated usable response, paired lifecycle/privacy/race evidence and independent review.
