# Story 1.12 Build Spec — Device-code Connection

## Status and authority

Issue#14 / `issue/14-story-1-12`; planning base `b1ef1d85116f56ac9b4fdbedd101c918591ff1e6`. Planning ONLY, product implementation BLOCKED, P1=false, P2=false, P3=false, StoryDone=false. No capability/auth/UI/gate certification.

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

Actual P1/P2/P3 remain missing; local purge103/GRDB17/pure13+31+18 are not SDK/Main/physical proof. Story1.9 final wire authority and Story1.11 official-SDK/private-slot implementation remain absent. Public signatures/effects for start/completion/refusal/wait/poll/expiry/cancel/bounded shutdown/reap, auth paths and authenticated generation are UNKNOWN.

Pin units/clock basis/expiry comparison/cumulative wait and cleanup after public evidence. Host wall clock is not authenticated expiry proof;120000ms generation ceiling cannot enlarge10000ms probe/current RPC. Final CAS/storage/leases belong to their owners. No guessed SDK fields/paths/endpoints/constants.

Conditional Agent slice after gates and exact Spec amendment: `ProviderAgent/agent.py`, `Tests/Topology/test_agent.py` only. Native candidate `PaperLensApp/App/PaperLensApp.swift` requires actual lifecycle owner and paired tests located/named in an amended slice of at most five exact files. Not implementation-ready; no future guessed Application files, new RPC schemas, helper/persistence/CI split or UI stubs. Name required callsites/wiring before edits, remove superseded prototype without fallback aliases.

Equal Provider choice/Settings reconnection/explicit Continue→actual Library is separately gated; no placeholder Library navigation or FR-002 completion claim.

## Required observable verification

Actual SDK instructions→auth→exactly one real correlated probe→current CAS; code/auth-only never promotes. Public-evidenced expiry just-before/at/after and refusal/network/probe failures; safe reasons/no blind replay/last-good preserved. Cancel before/after auth/probe, duplicate/late responses, rapid Retry/path switch, wrong lineage/CAS conflict: one terminal/no revival, accepted ACK cannot clear cleanup barrier.

Actual unsafe root/file/descendant/backup failures, abandoned-stage restart, selected-slot preservation, lost process/missing cleanup ACK/old lease; genuine owned closure/absence. Malformed/oversized instructions/results, unknown fields, SDK output/secret contamination and unsupported polling fail closed without budget relaxation or fake Library.

Architect41 COMMENT on planning, product BLOCK. No writes/tests/gates/formatter/build/GUI/network/SDK/auth/credentials/commits performed by proposal. Parent planning/source/whitespace checks do not certify behavior. Done requires actual gates, exact public interfaces and real native+Agent auth/cleanup/race evidence with independent review.
