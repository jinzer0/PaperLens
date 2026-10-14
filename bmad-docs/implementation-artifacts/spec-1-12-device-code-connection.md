# Story 1.12 Build Spec — Device-code Connection

## Current shared account-login continuation — 2026-10-14

Whole-Epic execution continues on the actual integration branch at baseline
`57fa3c4`, under the same acceptance/privacy/resource contracts. Existing local
source-session no-test/no-commit restrictions below apply to those old sessions,
not this parent-owned current execution. The device-only module/controller is
superseded by `ProviderAgent/account_login.py` and `AccountLoginController(mode)`;
there is no backward alias. Device callers choose `chatgptDeviceCode` explicitly.
Keep the device validator and immutable device instruction projection; share the
same owner-confined current-token/terminal/cancel/completion logic with browser
mode, rather than duplicate or relax it. Wrong-mode input fails the current intent
without exposing instructions or assigning an SDK target. The renamed paired test
is `Tests/Topology/test_account_login.py`, registered as a non-Swift Package exclusion.
The existing Story1.11 continuation defines the exact five-file union and current
parent verification: 24 pure tests PASS, retaining all 17 prior device regressions.
No SDK wait/start, RPC fields, auth/cost/cleanup proof or connection activation is
invented; this component is not the missing complete product login implementation.

## Status and authority

Issue#14 / `issue/14-story-1-12`; planning base `b1ef1d85116f56ac9b4fdbedd101c918591ff1e6`. Local source-order-only instruction/intent slice authorized by the human's independent Story 1.12 session instruction at base `45acff8`; runtime activation remains BLOCKED, P1=false, P2=false, P3=false, StoryDone=false. No capability/auth/UI/gate certification. This session must not commit or execute verification; parent owns Spec/source commit sequencing and gates.

Caller approval provenance: PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`, https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Whole-Epic authority permits this unchanged-scope own-branch Spec commit without repeated SHA questions; stale design labels do not supersede it. No live credentials/paid calls/remote/distribution/permission repair authorization follows.

Architect41 read exactly canonical ROOT epics.md:689–717, own SOLUTION-DESIGN, Story1.9 Spec, ProviderRequest/contract.json and PaperLensApp.swift. Root-only epics not copied. SDK/CLI-bin0.160.0 is caller pin provenance, not public capability proof. Existing Main and sdkImported/cliInitialized labels are topology only.

## Official device-code and connection lifecycle

- Agent executes through admitted packaged official SDK/runtime only. No generic OAuth, chatgptAuthTokens, private APIs, system Python/CLI, arbitrary SDK JSON, host credentials or user CODEX_HOME fallback.
- Explicit start reserves fresh attempt/staged slot under shared Story1.11 lifecycle; admitted handshake precedes auth. Exact methods/fields belong to finalized Story1.9, not invented here.
- Display only SDK-validated current code/procedure, waiting state and Cancel. Exact URL/code/size/expiry shapes require public SDK evidence first. Waiting is NOT connected.
- Use publicly evidenced bounded wait/poll only. No invented interval, blind network retries, restart of expired authorization or prototype-budget extension for human waiting.
- Actual auth completion triggers smallest actual authenticated v1 connectionTest using that staged connection. Code receipt/browser/auth completion, identity/model lists and SDK startup are insufficient.
- Preserve Provider-neutral inner probe: empty input/source, prompt `Reply exactly PAPERLENS_OK.`, typed exact `{text:"PAPERLENS_OK"}` with matching version/requestID/operation; outputTokens64/outputBytes12, probeDeadlineMs10000, streams0. No Paper/arbitrary prompt/cached or fabricated sentinel.
- Only current matching probe and finalized RPC typed usable outcome permits Application promotion. Outer usable schema UNKNOWN, not invented from this inner result. Application alone applies SQLite current-selector CAS/config generation; immutable slot identities/generations, no file/directory selection authority.
- Auth/probe failure, expiry/refusal/network/timeout/cancel, unsafe zone, stale result or CAS conflict never promote; preserve last-good and leased configuration. Explicit Retry/path switch invalidates UI intent and reserves new identities. Duplicate/late/wrong-attempt/slot/generation cannot finish newer flow.
- Cancellation selects one terminal and requests underlying cessation/cleanup. accepted ACK is not closure/absence; unknown/failed cleanup retains affected barrier. No local-cancel claim of remote revocation.
- Safe closed terminal reason categories and explicit Retry/path change; raw SDK exceptions forbidden. Clear displayed prior instructions/code on terminal/replacement. Never auto-replay ambiguous auth/probe on reconnect/startup.

## Private state and recovery

Reuse Story1.11: Agent-only zone, Main never mounts/reads SDK credentials; Agent never accesses Main SQLite/API-key/PDF/cache. Directory0700/file0600 and per-descendant backup exclusion verified after SDK writes/auth and startup. Unsafe verification blocks test/promotion; owned removal only, no permission repair/fallback store. Failed removal retains barrier, not false absent. Last-good active/leased slot is preserved.

Startup follows sole committed selector, validates selected complete slot and cleans abandoned stages/attempt temporary state through Agent ownership. No old waiting-flow resume or late completion. Old slots retire only after actual leases terminate; old calls cannot publish to new generation.

Protocol-only stdout; admitted safe stderr/crash projection only. Codes/tokens/URLs/state, secret argv/environment/raw streams/request/response/documents are not diagnostics. Persistent state limited to permitted auth/config/package metadata; Paper-linked SDK request/EvidenceBundle/result stays attempt-scoped and actually purged on terminal/cancel/startup. No Keychain/encryption redesign or new accepted-limit disclosure/consent. Do not make false confidentiality/erasure claims.

## Unresolved prerequisites and exact conditional scope

Actual P1/P2/P3 remain missing; local purge103/GRDB17/pure13+31+18 are not SDK/Main/physical proof. Story1.9 final wire authority and Story1.11 official-SDK/private-slot implementation remain absent.

Parent static follow-up in controlled installed SDK source/metadata declares0.160.0 and observes public account_login_start/cancel and routed login notifications/wait. Generated `chatgptDeviceCode` params use that type; response has loginId/userCode/verificationUrl, with NO expiry/interval/byte bounds. Completion has success and optional loginId/error; cancel response is status canceled/notFound, NOT closure/absence. These are SDK source shapes, never invented outer RPC fields, authenticated instruction validation or actual login proof.

SDK login/global/pending queues are unbounded and login wait has no timeout argument. start inherits then overlays environment; defaults accept command/file-change approvals. close can wait2s plus two0.5s joins and kill without follow-up wait: not admitted cumulative300ms owned cleanup/reaping proof. Public bounded wait/expiry/refusal semantics, auth paths, authenticated generation, actual resource controls and cancellation/shutdown effects remain UNKNOWN. Do not bypass with private API, change prototype budgets or fabricate expiry from host time. Source inspection performed no SDK import/init/auth/network.

Independent reviewer47 CLEAR/COMMENT on five-file static source consistency only; metadata/version not independently reviewed. Shared source identity/parent metadata evidence belongs to Issue13 evidence/1-11/sdk-source-inspection.json, not authenticated device-code evidence or a gate pass. Timeouts are source arguments, not measured/fixed waits or total-duration bounds.

Pin units/clock basis/expiry comparison/cumulative wait and cleanup after public evidence. Host wall clock is not authenticated expiry proof;120000ms generation ceiling cannot enlarge10000ms probe/current RPC. Final CAS/storage/leases belong to their owners. No guessed SDK fields/paths/endpoints/constants.

The human's exact owned source slice supersedes the old conditional file list: `ProviderAgent/device_login.py`, `Tests/Topology/test_device_login.py`, and this Spec only. Implement pure structural instruction validation, current intent invalidation, correlated auth-completion classification, and cancel-status validation; no SDK import, execution, wait, persistence, browser operation, RPC schema, or connection success. Parent integrates activation through existing Agent/lifecycle/RPC owners after their contracts are admitted; no native callsites are edited here.

### Bounded public-source implementation contract

Controlled packaged `openai_codex` metadata declares 0.160.0. Static reinspection of `client.py:441–463,763–779` and `generated/v2_all.py:492–501,2241–2247,2327–2346,6612–6621,6753–6757` matches the committed evidence SHA256 for both files. No SDK was imported or executed. Device start is exactly `account_login_start({"type":"chatgptDeviceCode"})`; response-model projection is `response.root.model_dump(mode="json", by_alias=True)` with type/loginId/userCode/verificationUrl. Completion projection has success and optional loginId/error/onboardingEntrypoint (the latter is null or `life_sciences`). Cancel is exactly `account_login_cancel(login_id)` with status `canceled` or `notFound`.

The local validator rejects unknown fields, wrong types, empty/control-containing instruction strings, and non-HTTPS/credential-bearing/malformed URLs. These are conservative local presentation checks, not SDK-specified code formatting, endpoint authentication, expiry, size policy, or permission to launch a browser. No endpoint allowlist, timer, polling interval, or copied budget is added. Parent must apply admitted transport byte bounds before decoding and trusted SDK provenance before presentation. Instruction objects omit sensitive fields from repr; errors contain only closed local categories.

One controller is confined to the owner's serialized event context. `replace_intent()` returns a fresh opaque process-local token and clears old instructions; all receive/cancel/fail operations require that exact current token. Neither token nor local state is an RPC or storage identity. Parent must bind it to the shared immutable attempt/slot/configuration lineage and invalidate it on path changes, cleanup barriers, and startup. Correlated success transitions only to `authCompleted`, clears display, and returns a one-time probe handoff signal, never usable/connected. Missing/wrong loginId cannot advance. Raw completion errors are never retained. Cancel/fail chooses one terminal and clears display; SDK cancel ACK validation cannot change this state or prove cleanup.

Parent must register every SDK-returned loginId with the actual lifecycle owner before delivering the start projection, including late responses for canceled/replaced pending starts. Ignored stale results are not closure. Parent cancels those owned late loginIds and retains cleanup barriers until genuine cessation/absence. `cancel()` selects local intent cancellation only; `login_id` remains available to target the official SDK cancel call. No dummy transport/cleanup/connectionTest implementation exists here.

Activation prerequisites remain precise: public bounded login notification delivery/expiry and owned shutdown/reaping within existing policy; admitted staged-slot lifecycle plus shared RPC lineage and authenticated connectionTest handoff; trusted URL presentation and bounded payload admission. SDK `wait_for_login_completed(login_id)` has no timeout parameter and is not called. Parent must not activate the local helper as an independently working login flow. Auth-completion handoff must run the actual shared connectionTest and Application CAS, not set usable from this module.

Authored tests are synthetic pure-source cases for closed-field/type/URL validation, replacement/stale/duplicate/missing-login correlation, cancellation before and after auth, display clearing, and cancel ACK not implying cleanup. They are not run in this session per explicit human restriction. Parent owns tests, integrated native gates, formatter, independent review, and exact local commits; no StoryDone or P1/P2/P3 claim follows.

Equal Provider choice/Settings reconnection/explicit Continue→actual Library is separately gated; no placeholder Library navigation or FR-002 completion claim.

## Required observable verification

Actual SDK instructions→auth→exactly one real correlated probe→current CAS; code/auth-only never promotes. Public-evidenced expiry just-before/at/after and refusal/network/probe failures; safe reasons/no blind replay/last-good preserved. Cancel before/after auth/probe, duplicate/late responses, rapid Retry/path switch, wrong lineage/CAS conflict: one terminal/no revival, accepted ACK cannot clear cleanup barrier.

Actual unsafe root/file/descendant/backup failures, abandoned-stage restart, selected-slot preservation, lost process/missing cleanup ACK/old lease; genuine owned closure/absence. Malformed/oversized instructions/results, unknown fields, SDK output/secret contamination and unsupported polling fail closed without budget relaxation or fake Library.

Architect41 COMMENT on planning, product BLOCK. No writes/tests/gates/formatter/build/GUI/network/SDK/auth/credentials/commits performed by proposal. Parent planning/source/whitespace checks do not certify behavior. Done requires actual gates, exact public interfaces and real native+Agent auth/cleanup/race evidence with independent review.
