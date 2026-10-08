# Story 1.11 Build Spec — ChatGPT Browser-Login Connection

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

Protocol-only stdout and fixed safe diagnostics. No raw browser URL/query/code/token/secret/argv/environment/path/SDK exception/request/response/document projection to UI/logs. Exact validated environment only; no secret argv.

## Missing admission decisions

Actual P1 dual-artifact isolation/nested-runtime/content cleanup; actual P2 exact lock/two artifacts/four physical OS×CPU DB and twenty Agent event cases; actual P3 common Application/Provider/Import/PDF budgets remain missing. Local GRDB17/purge103/contract parity do not pass them.

Story1.9 must finalize product handshake/auth/request/cancel/cleanup/startup/purge schemas and safe errors. Story1.10 must implement sole selector, stage/CAS/current-intent/config generation/lease ownership. This Spec invents none of their fields.

Pin public SDK initiation/handoff/completion/failure/cancel, authenticated generation/output and bounded shutdown/reaping signatures/effects. Pin controlled auth/config paths, descendant mutation/log/session behavior, protected environment and actual no-durable-Paper/closure mechanism. No guessed home layout, user CODEX_HOME inspection or private implementation substitute. Reconcile browser waits and cleanup with admitted budgets, never silently widen prototype limits or add alternate transport.

## Conditional delivery and verification

After actual gates and exact same-Spec amendment: Agent/browser phase `ProviderAgent/agent.py` and `Tests/Topology/test_agent.py` (two files). Native integration follows finished Story1.9/1.10 contracts; name at most five exact files including paired tests in an amendment before edits, not guessed fields or auth/SQLite/product UI grafted onto the smoke entry. Remove superseded paths, no aliases/stubs/fallbacks.

Verify actual login plus authenticated correlated probe/current CAS; auth-only/wrong/suffixed/malformed/unauthenticated results rejected. Race usable versus cancel/timeout/path change/promotion/old generation, one terminal/no stale activation. Hold old work through replacement and actual drain. Restart selected versus abandoned/incomplete stage. Refuse unsafe SDK descendants/owner/backup state without repair. Exercise actual SDK marker bytes through all lifecycle events and late/missing/stale ACKs; preserve unrelated active state. Unsupported public API/output/environment fails closed, not system-runtime substitution. Deterministic cases supplement, never replace actual auth and physical matrix proof.

Device code, final Provider-choice/Settings/Library integration are separate. No accepted-limit disclosure/consent or FR-002 completion claim. Architect40 COMMENT on planning only; no product approval. No edits/tests/gates/build/GUI/SDK/auth/network/credential/paid-request/permission changes performed for this Spec. Done requires exact admitted contracts, real gates/authenticated usable response, paired lifecycle/privacy/race evidence and independent review.
