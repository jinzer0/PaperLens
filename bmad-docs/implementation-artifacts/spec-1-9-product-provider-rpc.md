# Story 1.9 Build Spec — Product ProviderRPC

## Status and authority

- Work unit: Story1.9 / Issue#11 / `issue/11-story-1-9`; planning checkpoint based on `51492b8b0b3b454d741d16eef8019ed45ed7d67b`.
- Product implementation BLOCKED; P1=false, P2=false, P3=false, StoryDone=false. This is not an implementation-ready final method specification.
- Supplied approval provenance: PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`, https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Existing Whole-Epic authority permits in-scope own-branch Spec commits; it neither passes gates nor authorizes remote operations, credentials, paid requests or consumed-trial retries.
- Canonical Story: root `bmad-docs/planning-artifacts/epics.md:603–630`. The worktree copy is absent; that is not a requirements gap. Architect37 inspected this exact root excerpt, assigned SOLUTION-DESIGN, contract.json, agent.py and governance only. Stale draft prose does not override current approvals.

## Ownership and scope

### Existing decoder boundary repair under renewed batch authority

The human renewed Story1.1–1.26 implementation/verification authority and explicitly required independent worktree parallelism. Repair the already implemented fixed-v1 decoder, not invent product dispatch: successful EOF formerly permitted feed to reopen the stream in both languages; Python non-bytes input formerly raised before the poison handler and retained partial state. Successful EOF now rejects every subsequent feed while repeated successful finish remains idempotent; invalid dynamic input permanently poisons and clears retained framing state. Preserve contract.json, envelope/field/limit/error authority and atomic malformed-batch rejection.

Exact files: Contracts/ProviderRPC/ProviderRPC.swift, Contracts/ProviderRPC/provider_rpc.py, Tests/Topology/ProviderRPCTests.swift and Tests/Topology/test_provider_rpc.py. Parent verified the combined snapshot with 21 Python wire tests plus five separately registered-synthetic Agent tests, and 20 selected Swift RPC tests; no renderer/SDK/live/control/collector execution. Independent ParallelBoundaryReview approved this RPC delta while blocking a different Agent change; exclude that blocked Agent delta from this workunit. Byte-identical approved RPC files are integrated here without rerunning unchanged tests. This repair does not provide actual product RPC/Main/SDK owners or pass P1/P2/P3 or Story Done.

Fix one native/Agent wire authority before product implementations diverge. Application owns durable state, filesystem publication, input/Paper/config generations and result selection. Agent does not own Main filesystem/SQLite state or native API-key slots. Agent-private authentication/config metadata is distinct from Paper-linked content, which remains verified attempt-scoped temporary state.

Authentication execution, usable-connection decisions, slots, Onboarding/Settings and Paper Chat are Stories1.10–1.12/later work, not delivered here. Their future wire boundary must nevertheless be specified before product dispatch. Existing topology, local Job contracts and synthetic/native tests are precursors, not admission evidence.

## Single authority and unchanged prototype limits

`Contracts/ProviderRPC/contract.json` remains the sole schema authority. Consumers reject parallel method tables and arbitrary SDK JSON passthrough. Frames are 32-bit big-endian byte length plus strict UTF-8 JSON; reject length before allocation, malformed/truncated frames, duplicate/unknown fields, invalid types and out-of-bound values before dispatch. An untrustworthy correlation closes rather than fabricating a typed success.

Current prototype limits, verified from JSON: body65536/frame65540 bytes; depth8; object keys16; arrays32; strings256 UTF-8 bytes; timeout1…10000ms; handshake5000ms; outstanding4 (ordinary3/cancel1); queue4 frames/262160 bytes;256 requests/connection; streams0. Existing Main10s/Worker2s/observer230s/target-minus5s/control12s-or75s/batch100s/reserve1s/cumulative owned cleanup≤300ms remain unchanged. Separate waits are not proof of an aggregate deadline. Product payload/auth/stream incompatibility is blocked, never a silent prototype-limit enlargement.

Retain request `{kind,id,method,timeoutMs,params}`, result `{kind,id,result}`, error `{kind,id,code}` envelopes until an admitted replacement is explicitly pinned. Current typed codes: versionMismatch/handshakeRequired/unknownMethod/invalidParams/busy/cancelled/timeout/unavailable/internal. Raw exception text is not an error code.

## Required product behavior

- Handshake precedes work; safely correlated major mismatch fails and closes. Pin exact product major/minor/capabilities and supported field/method compatibility table. No implicit downgrade, advertised-capability certification or topology fallback.
- Non-reused wire ID selects exactly one terminal across success/failure/cancel/timeout/exit. Paper work binds Paper generation and operation correlation. Retry/reconnect cannot reuse an old identity. Late/duplicate/wrong-method/wrong-generation replies cannot publish results or complete another request.
- `cancel` has its own ID and targetID. `{accepted:boolean}` means cancellation selection only, not stopped producers, closed handles or absent content, and cannot create a second target terminal.
- Separate correlated cleanup ACK requires actual revocation, observed underlying producer/FD closure, validated ownership/generation and scoped absence. Timeout/process loss/missing or failed ACK retains failure/publication barriers. Old ACK cannot release a newer barrier. No caller-selected path sweep or Main-data deletion.
- stdout is protocol-only; SDK output contamination fails. stderr/crash output is RAM-only or closed safe projection: no raw secret/request/response/document/path/exception logging.
- Fixed executable plus exact validated environment allowlist; no arbitrary inherited environment, secret argv, workspace selector or SDK JSON. Prototype HOME/CODEX_HOME checks do not authorize a product authentication home.

## Missing decisions — do not invent implementations

1. Public pinned SDK signatures/effects for browser/device-code authentication, completion/failure/cancel, authenticated v1 dispatch/results, request cancellation and bounded shutdown/reaping. Existing import/start/initialize/private `_proc` access is not that proof.
2. Product version/capability table and exact closed auth/request/attempt-cleanup/startup-cleanup/Paper-purge names/fields/results/errors. Fixture runID and true absent/drained assertions are not assumed SDK product fields or authenticity.
3. Actual P3 common Application/Provider/Import/PDF allowlists and item/byte/token/chunk/stream decisions. Story1.7 fixed-v1 contract/parity is useful, not runtime certification. Preserve EvidenceBundle order/content; no adapter truncation/reranking or larger client authority.
4. Approved Agent-private state layout, descendant permission/backup-exclusion rules, exact environment/output projection and actual SDK-content closure/purge mechanism.
5. Actual P1 isolation evidence and P2 exact release lock, two CPU artifacts/four physical minimum/current OS executions, packaged DB/FTS and twenty Agent event cases. Local GRDB17, synthetic purge103 and supplied-frame conformance do not substitute.

## Conditional bounded delivery after admission

Parent must resolve those decisions, amend/commit this same Spec with exact schemas and obtain required actual gate evidence before product source edits. No repeated per-revision approval is inferred necessary for unchanged Whole-Epic scope; a material scope change still follows governance.

- Authority/paired-validation slice: `Contracts/ProviderRPC/contract.json`, `Contracts/ProviderRPC/ProviderRPC.swift`, `Contracts/ProviderRPC/provider_rpc.py`, `Tests/Topology/ProviderRPCTests.swift`, `Tests/Topology/test_provider_rpc.py` (five exact files).
- SDK endpoint/lifecycle slice after the finished authority: `ProviderAgent/agent.py`, `Tests/Topology/test_agent.py` (two exact files). Do not leave directly affected Python/native tests on obsolete methods. Further discovered callsites require a named bounded amendment, not broad editing.
- Remove superseded topology dispatch/capability/obsolete prototype execution paths at admitted replacement; preserve historical evidence, not compatibility aliases, mock fallbacks or stubs. No product persistence/helper/CI split or root GRDB wiring in this planning checkpoint.

## Verification and completion

Parent verifies shared framing/schema vectors; fragmented/coalesced/zero/oversized/truncated frames; UTF-8/duplicate/extra-key/type violations; all numeric/string/queue/stream boundaries plus one-over; pre-handshake/major/minor/capability pairings; duplicate IDs; late/stale replies; terminal races; cancellation selection versus actual cleanup; startup/repeated purge/missing ACK; reserved cancel lane; environment/output/privacy refusal. Then pinned actual SDK effects and required packaged runtime evidence, followed by independent protocol/privacy/lifecycle review and scoped local evidence commits.

No tests, gates, SDK/auth/network/GUI/signing or implementation ran for this Spec. Architect37 provided read-only proposal, COMMENT on planning; parent corrected the conditional slices to include both directly affected language test suites and replaced ambiguous “Story1.7 certification” wording with local contract/parity.

Done requires actual prerequisite passes, exact final admitted schema, paired observable validation, SDK-backed cancellation/cleanup, obsolete-path removal and independent review. This planning commit alone satisfies none of those feature/gate claims.
