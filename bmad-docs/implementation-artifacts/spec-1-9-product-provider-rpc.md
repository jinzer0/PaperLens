# Story 1.9 Build Spec — Product ProviderRPC

## Status and authority

- Work unit: Story1.9 / Issue#11 / `issue/11-story-1-9`; planning checkpoint based on `51492b8b0b3b454d741d16eef8019ed45ed7d67b`.
- Product implementation BLOCKED; P1=false, P2=false, P3=false, StoryDone=false. This is not an implementation-ready final method specification.
- Supplied approval provenance: PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`, https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Existing Whole-Epic authority permits in-scope own-branch Spec commits; it neither passes gates nor authorizes remote operations, credentials, paid requests or consumed-trial retries.
- Canonical Story: root `bmad-docs/planning-artifacts/epics.md:603–630`. The worktree copy is absent; that is not a requirements gap. Architect37 inspected this exact root excerpt, assigned SOLUTION-DESIGN, contract.json, agent.py and governance only. Stale draft prose does not override current approvals.

## Ownership and scope

### Human-assigned Main-side fixed-v1 source slice (2026-10-10)

The current independent-session instruction assigns exactly
`PaperLensApp/Adapters/AgentRPCConnection.swift`,
`PaperLensApp/Application/AgentConnectionLifecycle.swift`,
`Tests/Product/AgentRPCConnectionTests.swift`, and this Spec. This is a
source-order-only dispatcher phase over the existing finalized fixed-v1 contract
and actual Agent `accept`/`serve` implementation, not admission of new product
methods. The parent owns integration, gates, formatting and commits; this session
does not run tests/builds, execute a helper/SDK, or change the wire authority.

The dispatcher owns one bounded session, exact hello 1/1/topology-v1 identity,
contract-validated requests and correlated terminals, ordinary/reserved cancel
lanes, non-reused UUIDs, bounded outbound queue, aggregate monotonic deadlines,
atomic supplied-batch terminal validation, fail-closed timeout/poison, and drain.
Unknown product login/auth/chat/usable methods are refused locally. Existing
topology methods remain contract operations, not product admission or permission
to execute controls. No product auth/usable/purge schema is invented.

`AgentRPCChannel.write/read/requestClose` is the exact integration seam for the
parent's actual XPC/process adapter. Main has one reader, serialized writer and
deadline timer; only observed EOF or actual external channel invalidation marks
transport closure. A requested close, thrown IO, accepted cancel or wire terminal
does not establish producer shutdown, process reaping, scoped absence or job
cleanup. Parent must supply an adapter whose close revokes IO and unblocks pending
reads/writes, plus bounded process reaping and its independent observed evidence.

Parent must register both production files and the test in Package.swift and
native targets, then run the integrated tests/build and independent review. The
authored supplied-frame tests cover handshake/refusal, fragmentation, duplicate/
unknown/unsent correlations, wrong-method atomic batch rejection, reserved cancel,
cancel selection versus closure, timeout/late reply, drain/EOF, truncated EOF,
version mismatch and lifetime request exhaustion. None ran in this session.

This layer does not publish Paper results or persist Job state. Required future
Paper callsites must use the existing GRDB queue and JobRecoveryPolicy arbitration;
no second store or synthetic closure attestation is introduced. Authenticated
product dispatch still requires the exact missing product methods and SDK effects
listed below. Existing P1/P2/P3 and StoryDone blockers remain unchanged.

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

## Actual owned native pipe transport — bounded local admission

Architect67 admits one source-only transport slice independent of the missing SDK/product
dispatch decisions above. Implement the existing AgentRPCChannel with genuine exclusive
Main-owned stdout-read/stdin-write FIFO FileHandles; do not start a process, SDK, helper,
app or network peer. No product protocol/method/capability or authentication is invented.
Fixed-v1 ProviderRPC remains the sole framing/queue/deadline authority: maximum body65536
and frame65540 bytes. This admits transport, not product endpoint activation or Story Done.

Before effects, require both fstat/F_GETFL checks: distinct descriptors and FIFO identities,
read exactly O_RDONLY, write exactly O_WRONLY; refuse files/dirs/sockets/O_RDWR/invalid
and paired FIFO aliases. Exclusive transfer is a caller ownership obligation: public
inspection cannot prove absence of arbitrary external dup aliases/users/handlers/closers.
After preflight capture ownership through setup failures. Preserve existing flags, set
and verify O_NONBLOCK, set/verify writer F_SETNOSIGPIPE/F_GETNOSIGPIPE using public macOS
sys/fcntl.h73/74 before any write. No global signal handler, socket or guessed fallback.

One serial native execution lane, one pending read and one pending write; reject same-
direction overlaps instead of queuing. Bound retained frame/read chunk by existing
authority; handle short I/O/EINTR/EAGAIN through readiness, not blocking Foundation I/O
or new guessed wait bounds. Aggregate timeouts remain with AgentConnectionLifecycle.

requestClose synchronously revokes/unblocks; cancel readiness sources and recheck stale
callbacks. Join source cancellation and syscall quiescence before checked FileHandle.close
once per endpoint. Retain separate closed/unknown outcomes and actual handle/owner debt
strongly on uncertainty, with no retry, destructor proof or numeric-FD closure inference.
Peer read-zero initiates duplex shutdown; read returns nil/closure callback only after
both physical closes succeed. Debt throws, never reports closed. Lifecycle native factory
binds the genuine duplex outcome before I/O; only both-closed calls transportDidClose.
Existing decoder.finish and reader/writer loop joins remain unchanged. Local endpoint
closure proves no SDK termination/reaping/authentication/scoped-content purge.

Exact worker scope: new Adapters/OwnedPipeAgentRPCChannel.swift, existing
Application/AgentConnectionLifecycle.swift, new Tests/Product/OwnedPipeAgentRPCChannelTests.swift,
and this Spec. Parent owns Package/native registration, permitted local-Pipe verification,
independent review/evidence/local commit. No authority/AgentRPCConnection/SDK changes.
Local owned-FD tests cover validation, bounded/short/backpressured I/O, overlaps, revocation,
EOF versus duplex closure, real EPIPE survival after verified no-SIGPIPE, and unknown-close
retention/no retry. Test-only injected close failure is not physical closure proof. If FIFO
no-SIGPIPE setup/readback or EPIPE safety fails, refuse; do not broaden privileges.
Existing product/renderer/live/collector trials remain unrenewed; no remote/release action
or privacy/profile/Story acceptance follows from transport source or owned-pipe tests.

### Source authoring handoff (not verification evidence)

Authored exactly the four admitted files: `Adapters/OwnedPipeAgentRPCChannel.swift`,
`Application/AgentConnectionLifecycle.swift`, `Tests/Product/OwnedPipeAgentRPCChannelTests.swift`,
and this existing Spec. Public channel API is `init(readStdout:writeStdin:)`,
`write(_:) async throws`, `read() async throws -> Data?`, `requestClose()`,
`closureOutcome`, and `observeClosure(_:)`. Typed endpoint outcomes are pending/closed/unknown;
only `ClosureOutcome.bothClosed` authorizes the lifecycle callback. Factory
`AgentConnectionLifecycle.ownedPipe(readStdout:writeStdin:)` constructs the actual channel,
constructs the lifecycle, then installs a weak callback before return; `start()` remains explicit.
Lifecycle factory failure requests checked native cleanup rather than abandoning captured handles.

The MainActor owner captures genuine FileHandles after preflight, keeps a process-lifetime
strong retention root until genuine both-closed, and retains unknown ownership debt with
no retry. Dispatch readiness sources are one-shot, activated before cancellation; queued
event callbacks recheck generation and per-source tokens, and observed cancellation handlers
join all outstanding sources before checked endpoint closes. Native synchronous nonblocking
syscalls share the MainActor lane; active syscall count must also be zero. EINTR/short-write
work yields after sixteen attempts (a fairness quantum, not a deadline or wait bound).
Operation UUIDs prevent late cancellation callbacks from revoking a subsequent operation.
Frame retention and read allocation use public ProviderRPC.maxFrameBytes65540, not a new limit.

Authored owned-Pipe tests cover paired alias/wrong access mode/ambient/invalid refusal,
ordinary file/directory/socket/O_RDWR FIFO refusal, preserved flags and verified writer
no-SIGPIPE, one-over frame refusal, partial reads, actual EAGAIN backpressure with ordered
maximum-frame delivery, same-direction busy, pending read/write revocation and cancellation,
EOF awaiting physical duplex closure, real EPIPE host survival, unknown-close actual-handle
retention after facade drop/no retry, EOF debt throwing instead of nil, and lifecycle hello/
EOF decoder finish including truncation. Tests use explicit bounded XCTest expectations;
manual fixture debt cleanup is not runtime ACK. A lifecycle state waiter is cooperatively
cancelled/joined after the bounded expectation, not CPU/time certification.

Parent must register Package/native targets and perform source/type/native compilation,
focused owned-FD tests plus existing lifecycle/contract union, independent review, evidence
and local commit. Worker ran no tests/builds/gates/lint/formatters/processes/SDK/network,
and these authored cases are not pass evidence. Public FIFO no-SIGPIPE setup/readback and
actual EPIPE safety remain required parent checks. This channel closes local endpoints only:
actual producer Process ownership, SDK dispatch/authentication, cancellation/purge/reaping,
P1/P2/P3, private/live/renderer/trial boundaries and Story Done remain separate and unproved.

### Observed anonymous-pipe peer identity correction

Parent focused owned-FD run artifact958 executed10 tests with2 assertions failing:
paired endpoints of one anonymous macOS Pipe were not rejected and preflight changed
the read flag. Existing fstat device/inode comparison is not sufficient to recognize
the two peer endpoints on this OS. Preserve the failed output and the paired-alias/
unchanged-flags assertions; do not weaken the requirement to make tests pass.

Before ownership/setup effects, use public libproc.h proc_pidfdinfo(getpid(), fd,
PROC_PIDFDPIPEINFO, ...) for these actual self-owned descriptors, requiring exact
pipe_fdinfo result size and nonzero pipe_handle/pipe_peerhandle. Refuse same handles
or either handle matching the other's peer handle, in addition to existing type/mode/
descriptor checks. Unavailable/partial/ambiguous observation refuses before effects;
no fstat-only fallback. Do not dereference, persist, expose or log opaque kernel handles.
Public sys/proc_info.h600–610/786–787 and libproc.h97 provide this bounded self-FD API;
no SDK private property, foreign-process query, new privilege or environment change is
admitted. Named/unsupported FIFO identity may refuse rather than broaden transport.
Actual EPIPE/no-SIGPIPE survival already passed in artifact958 but is not Story/P1/P3
proof. Source scope remains the exact existing channel and owned-Pipe tests; API and
fixed wire authority stay unchanged. Parent repeats only changed-source verification.

### Parent actual owned-pipe verification

Ten focused actual local-Pipe tests passed after the peer-identity correction (artifact959),
including per-FD no-SIGPIPE readback and real EPIPE survival, bounded/backpressured IO,
revocation, EOF versus duplex cleanup, retained unknown-close FD and lifecycle decoder
closure. Prior10/two alias assertions (artifact958) remain preserved, not suppressed.
The same exact implementation passed 271 Product tests (zero failures, artifact962).
Fresh unsigned native Release arm64/macOS15 compiled in native-r (artifact963); only
new build member55 was appended to the unchanged original Main source phase order.

Independent review69 returned SOURCE-ONLY CLEAR / APPROVE. Five-source-file binary
delta against correctionSpec5557fd3:
cbf334aa9a7f1ba95b303fed8305574ad9cf7993fd1e048d634ea7c6446a124a.
Existing dispatcher and fixed schema remain byte-identical; no SDK/app/helper producer,
credentials, remote peer or protected trial ran. Actual local duplex endpoint closure
does not establish SDK termination/reaping, authentication or content purge. Sandbox
P1/P2/P3/product protocol and Story/Epic acceptance remain unproved and false.
