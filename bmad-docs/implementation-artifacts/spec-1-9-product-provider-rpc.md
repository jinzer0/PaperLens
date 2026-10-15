# Story 1.9 Build Spec — Product ProviderRPC

## Current human-approved product admission

Actual instruction: “1,2 제안 승인, intel 빌드 계획 자체를 완전히 폐끼”.
Baseline51e2603; this approves the proposed product-only protocol and Agent-only
private-state policy, and cancels Intel building outright. No generated approval
SHA/token, actual authentication, paid call, remote operation, release or exhausted
trial renewal follows. Earlier NOT ADMITTED shared-policy labels below are
historical and superseded for these two decisions, not SDK runtime proof.

One contract.json owns both diagnostic and product schemas. Product endpoints use
product.hello with exact major2/minor0/capabilities[product-v1]; topology hello is
diagnostic-only and never a product downgrade. Frame/body/depth/keys/arrays/queues,
max10s requests and zero streams stay fixed. Add maxAuthURLBytes4096 solely for
the browser authUrl in an exact product.loginStart result; ordinary strings and
keys stay256 bytes, including device verificationUrl and userCode. No truncation,
alternate transport or globally enlarged string allowance. Wrong-path/malformed
large URL is rejected before delivery. URLs require HTTPS, nonempty host, no
credentials/control/whitespace/backslash; actual trusted SDK provenance remains
an owner obligation, not URL parsing proof.

Closed minimum methods and fields (all objects reject unknown/missing keys):
- product.hello: exact version/capabilities above in params and result.
- product.loginStart params: stageID, intentID (fresh UUIDv4), expectedSelector,
  mode(browser|device), model(nonempty ordinary string). Result echoes stageID/
  intentID plus instructions: browser {mode:browser,authUrl}; device
  {mode:device,userCode,verificationUrl}. SDK loginId stays Agent-private.
- product.loginObserve params: stageID,intentID. Result echoes both and state
  pending|authenticated|failed|cancelled|timeout|exited. This bounded wait is not
  a stream or usable connection. Renew only the observation for the current
  intent, never replay login/probe/model generation; no new poll interval/expiry.
- product.connectionTest params: stageID,intentID,expectedSelector. Result echoes
  those plus state:usable,text:PAPERLENS_OK. Only real authenticated fixed inner
  ProviderRequest probe can produce that result; schema validation alone cannot.
- product.loginCancel params: stageID,intentID. Result echoes both plus accepted
  boolean. Acceptance selects cancel, not producer/FD closure or cleanup.
- product.stageRetire params: stageID,intentID,cleanupID. Result echoes all plus
  state:clean|unknown,stopped,closed,absent; clean requires every proof boolean true.
- product.startupCleanup params: cleanupID,expectedSelector. Result echoes both
  plus state:clean|unknown,stopped,closed,absent; clean requires all three true.
- product.paperPurge params: cleanupID,paperID,generation,correlationID. Result
  echoes all plus state:clean|unknown,stopped,closed,absent; clean requires all true.

expectedSelector is the exact durable kind/slotID/generation/model snapshot, not
a second store: null kind and slotID together, or known provider kind with UUIDv4
slotID; generation0..Int64.max (selected requires>=1); model null or ordinary
nonempty string. Connection generation remains distinct from Paper generation,
which keeps the existing positive bounded definition. Native current-intent/CAS
and real owner correlation are required even for structurally valid wire data.

Agent owns app-defined stages/<UUID>,configs/<UUID>,attempts/<UUID>,quarantine/<UUID>
under its sandbox application-support Provider/v1 root; Main never mounts it.
This prescribes app namespaces, not guessed SDK filenames/auth export or copied
CODEX_HOME. Protected creation0700/0600, descendant backup exclusion, immutable
ownership, startup validation/no abandoned promotion and no permission repair
remain. Persistent auth/config metadata excludes Paper bytes. SDK-created state
requires public supported containment proof; unsupported controls fail closed.
Unknown retirement stays quarantined with retained ownership, not moved/deleted
while producers remain; old active/leased configs survive failed candidates.

First implementation union: contract.json, Python and Swift ProviderRPC validators,
paired existing Python/Swift topology contract tests. This establishes callable
typed wire and narrowly scoped URL bounds; not SDK dispatch/auth/purge success.
No production fake auth, store, sentinel echo or cleanup ACK may be synthesized.

Parent verification: shared exact eight-method schemas and Python/Swift validation
are implemented; 549 offline union, 32 native ProviderRequest, 24 native RPC and
496 fresh-process Product cases PASS. Actual unsigned arm64 Main/nested-XPC build
PASS. This is wire/source/fixture proof only, not producer dispatch, authenticated
probe, Agent private-root enforcement, CAS activation or actual purge/closure.
Live/cost/credential/protected-trial/signed/privacy acceptance remains unproven.
Scoped independent review's combining-mark authority parity defect was reproduced
by a failing native regression, corrected with UTF-8 syntax scanning and verified
in paired browser/device cases. Final follow-up CLEAR/APPROVE, no remaining scoped
findings; this does not substitute for the final executor QA/acceptance cohort.

### Native existing-Agent backup enforcement continuation

After7f512d7, enforce approved privacy on the real exclusively created Agent
runtime namespace before Python/SDK spawn. Reuse TopologyOwnedFixtures and its
actual retained descriptor/device/inode/parent identity, not a synthetic auth
store, new owner registry or guessed SDK home. Exact union: existing
PaperLensApp/App/TopologyFixtures.swift, ProviderAgent/main.swift, Package.swift,
new Tests/Product/AgentPrivateBackupTests.swift and this Spec.

Bounded public-API experiment, private .build UUID fixtures only: setting
Foundation backup metadata through /dev/fd failed and did not mark the actual
directory; ordinary and public file-reference URLs each succeeded and actual
directory reads confirmed exclusion. No Foundation interposition, SDK import,
real auth, external temporary-write grant or protected renderer/collector trial.
Use a public file-reference URL captured for the newly owned empty namespace,
retain actual descriptor and validate current named/descriptor identity and0700
ownership before/after metadata operations. Refuse replacement/symlink/wrong mode,
never repair permissions or reuse an existing namespace. One preparation attempt;
failure cannot be renewed by later mode repair. Read-only backup validation must
not reapply missing metadata. Bridge fails before spawning on missing proof.

Tests use only exclusively created .build fixtures and actual Foundation metadata;
cover successful marking, read-only detection of removed exclusion, sticky failed
preparation, and replacement/symlink/mode refusal preserving unrelated markers.
The directory exclusion covers its contents for backup, but does not authenticate
SDK descendant modes, no-Paper persistence, producer cessation, purge or P1/P3/P6.
No renderer/native collector/SDK trial is admitted or renewed by this slice.

Scoped independent review18 found HIGH/P1: the captured reference and actual
descriptor were not joined; an ancestor swap during capture could mark a different
directory and return success. A real capture-time regression reproduced three
failures before correction. Public Foundation descriptor identity reads through
/dev/fd were then demonstrated: non-null opaque file+volume identifiers matched
the retained directory and rejected another directory on the same volume. Only
the metadata setter on /dev/fd is unsupported; identity reads are supported here.
No private identifier decoding or another textual path check is used as proof.

The intermediate preparation compared both public opaque identifiers via NSObject
equality and required directory types and actual descriptor/named identity before
metadata mutation and afterward. Missing/unsupported identity failed closed.
The capture regression supplies a genuinely unrelated moved-directory reference;
its grouped eight-case PASS was not final fresh-process union proof. The later
isolated union exposed a real preparation-lifetime failure described below;
earlier7/503/build receipts do not certify the corrected implementation.

### Next real SDK native-owner contract — scoped source admission

Historical pre-isolation continuation was NOT verified: the 504-case isolated
union had 503 PASS/1 FAIL; subsequent eight-case runs retained the removal failure.
Public setxattr/fremovexattr debugger observations (artifact520) establish a
deferred same-process Spotlight-queue writer from the earlier Foundation setter,
not a setter in hasBackupExclusion or a demonstrated URL-cache defect. Opaque
FD-xattr snapshots and ctime exposed actual later reapplication. Architect18 then
BLOCK/REQUEST CHANGES superseded its intermediate approval for that revision.
No quiet-period wait, private queue drain or timestamp latch proves completion.

Bounded corrective amendment: reuse the already packaged Python interpreter and
agent.py in a closed metadata-only entry, without importing/starting the SDK.
The native owner supplies actual retained directory/parent descriptors as child
FD3/FD4, the captured public file-reference URI and run UUID, and an exact clean
environment. The child revalidates directory ownership and public opaque FD/URL
identity, performs the public CFURL setter and exits. Native actual waitpid plus
checked local descriptor closes must precede bound parent readback/admission.
This contains the observed in-process deferred writer; delegated external writer
authority still requires assessment and is not certified by waitpid. Preserve
one absolute <=300ms native retirement deadline and permanent actual-owner debt.
No new binary, entitlement, private API, SDK transport or live SDK execution is
admitted. The existing interpreter's sandbox/inherit-only signing profile is
reused; the separate same-ProviderAgent broker target was subsequently withdrawn
after signing inspection, with the supported replacement detailed below.
Source union amendment adds existing ProviderAgent/agent.py and
PaperLensApp/Application/OwnedChildRetirement.swift plus their focused tests;
existing project target membership is updated only where required. A controlled
host-Python metadata fixture is not packaged/signed/P1/P3/P6 or SDK acceptance.

Current corrected metadata slice uses a retained public CF reference and CFEqual
on opaque file+volume identifiers. The parent never invokes the metadata setter.
The helper's actual zero-status reap and eight checked local descriptor closes
precede fresh bound readback. Unknown ownership additionally holds an identity-
bound namespace mutation lease: cleanup, create, links, write-check and the
bridge's raw directory unlinking are denied. Only selected on-time clean releases
the lease; late completion or fixture physical teardown cannot discharge debt.
The failed initial expired-owner fixture did not satisfy namespace preconditions;
it now uses the existing owned repository .build fixture convention, without
relaxing production directory validation.

Parent proof: nine fresh-process metadata cases, eight native-owner cases and the
complete 506-case isolated Product union PASS (artifact556); 562 offline tests
PASS (artifact559; earlier547); actual unsigned arm64 Main/nested-XPC build and project plist
lint PASS (artifact558). Physical removal uses the observed newly added attribute
name without interpreting its format; all FD-xattr bytes and ctime stay unchanged
during validation and repeated preparation refuses. A real held child verifies
unknown cleanup refusal, preserved original entry and permanent lease/debt.
Architect18 final scoped CLEAR/APPROVE resolves both local writer and unknown-
cleanup findings. Retained warnings include unhandled generated bytecode, weak
variable diagnostics, unnecessary await and AppIntents extraction; none suppressed.
This is not delegated-writer absence, signed isolation, actual SDK dispatch/auth,
content absence/purge, hard-real-time proof, P1/P3/P6 or Story/goal completion.

Non-executing controlled SDK0.160.0 client.py:193–302 exposes public
CodexConfig.launch_args_override, which supplies Popen argv directly. This is a
supported way for the official SDK to launch a fixed native broker over its same
stdio transport; it exposes no process factory/PID. Override bypasses normal
config_overrides argument construction and checkout-capability setup. No SDK
import/start/init/auth/network or existing-home access was performed to find it.
Read-only architect19 WATCH/COMMENT identifies a real bounded startup-only slice,
not a delivery/QA/privacy verdict or a new policy approval request.

The unchanged ProviderAgent self-execution target is WITHDRAWN. Architect19's
fresh entitlement inspection establishes that this independently sandboxed XPC
binary has app-sandbox+network.client, not the inherit-only helper signature.
Early-main role selection cannot fix sandbox reinitialization. No signed failure
was executed or invented, and no new binary/entitlement decision is inferred.

Use the already packaged inherit-only Python interpreter and existing agent.py
as the fixed broker target: launch_args_override=(packagedPython, '-I', '-B',
existingAgentScript, '--native-broker'). Public SDK start passes the whole tuple
to its existing Popen/stdio transport. Package CHILD_RIGHTS already signs the
interpreter and CLI with app-sandbox+inherit only. Architect19 WATCH/COMMENT
supports this source-level seam; --native-broker remains UNIMPLEMENTED. No new
binary, entitlement, selector store, alternate RPC backend, SDK private _proc
access, monkeypatch or automatic SDK close. Fresh native-owned SDK worker uses an exact
replacement environment; it strongly retains its public SDK client after start.
Native owns its worker PID/raw pipes/waitpid. SDK Popen closes other inherited
FDs: use an owned0700 namespace AF_UNIX rendezvous, not an assumed pass_fds hook.
Native must bind broker identity using kernel peer UID/PID and unique/parent
process identities matched to its actual captured worker; payload PIDs/UUIDs alone
never authorize signals, reaping or cleanup. Missing/denied identity fails closed.

Broker launches only the packaged CLI with fixed app-server/--listen/stdio://
arguments and exact rebuilt environment, initially suspended. Register and check
EVFILT_PROC NOTE_FORK|NOTE_EXIT while it cannot execute, then resume. Any fork,
registration gap/error, missing observation or ambiguous identity is permanently
unknown; no tracking descendants, PID sweeps or killpg. SDK sys/event.h explicitly
marks NOTE_TRACK/NOTE_TRACKERR/NOTE_CHILD unsupported since10.5, not an available
atomic descendant tracker. A fork-free observed path is eligible for actual native
resource retirement; not every path is forced unknown by construction.

Reuse/factor existing operation/independent-terminal/lifetime-root machinery in
OwnedChildRetirement, not the fixture API or a competing owner. Relay SDK stdio
unchanged within existing byte/frame/queue/time bounds; private lifecycle control
is not a new SDK RPC implementation. Startup-only means no SDK initialization,
login, connectionTest, Paper input or usable/product-clean response. Unsolicited
startup traffic cannot feed an unbounded SDK router backlog. No per-layer budget
reset, new timeout, SDK close2s/.5s grace or stdout diagnostics.

Retirement revokes once and shares one absolute monotonic deadline (cumulative
<=300ms): broker observes CLI exit, actually waitpids it, checks its local closes,
then emits correlated native-resource record and exits. Worker actually waitpids
the kernel-authenticated broker child while retaining SDK client; ECHILD is
unknown, never inferred success. Worker then exits without another SDK call.
Native actually waitpids worker and checks all its local pipe/listener/control
closes before internal native-boundary clean. Reaping proves kernel teardown of
process-private handles, not individually checked SDK FileObject closes. Any
fork/stall/partial start/close/wait/deadline uncertainty retains actual owners,
FDs, lanes and namespace forever with admission debt; uncertain broker/worker
must remain alive to retain their real roots. No _exit/facade loss/late clean or
replacement releases debt. Native-resource clean is not absent=true, scoped
SDK-content absence, stageRetire/startupCleanup/paperPurge or P1/P3/P6/StoryDone.

Bounded source union: OwnedChildRetirement.swift, ProviderAgent/main.swift,
new ProviderAgent/sdk_worker.py, Package.swift, project.pbxproj, topology/build.sh,
topology/package.py, OwnedChildRetirementTests.swift, new
Tests/Topology/test_sdk_broker.py and existing test_package.py. Registration-only
changes where needed; name any necessary bounded amendment before expansion.
No product contract/validator changes. Parent must check fixed-interpreter bundled
entry/signing/inherited-sandbox seams before any actual SDK execution; failure
does not authorize a new helper, signature workaround or entitlement. Native
controlled fixtures supplement, never replace real SDK/signed acceptance.

Implemented bounded resource layer: ProviderAgent/broker.py and
Tests/Topology/test_sdk_broker.py implement and exercise the real Darwin CLI
resource owner before dependent SDK-worker/control integration. Production launch
selects only the existing sibling MacOS/codex with fixed app-server --listen
stdio:// arguments; no caller-selected executable or shell. Public posix_spawn
starts it suspended; checked kqueue NOTE_FORK/NOTE_EXIT registration precedes
SIGCONT. Actual captured child/pipe/kqueue/cwd resources survive every uncertainty;
only actual reap, checked closes and an on-time deadline check support a scoped
retirement record. This layer does not make blocking Python/C calls bounded:
the independent native terminal remains mandatory for the integrated owner.
Controlled fresh-process true/cat/fork-and-reap programs prove kernel behavior,
not actual SDK/CLI execution, descendant absence or signed acceptance. The module
is not a replacement SDK transport or a new product selector/admission store.
--native-broker and the SDK worker remain unimplemented until integrated; no
unused module is represented as a callable product connection flow.

Architect23 resolves the next native running interval without another owner:
extend the existing Core/Roots and consume its stdin-write/stdout-read into the
existing OwnedPipeAgentRPCChannel exactly once. AgentConnectionLifecycle binds
that same channel. A separate startup deadline does not start/reset cleanup;
first revoke fences IO and fixes one absolute <=300ms cleanup deadline returned
unchanged by later revocations. Capture the actual channel before fallible setup,
reserve handoff against cleanup, quiesce IO before checked closes, and read actual
same-instance closure state rather than accepting cleanup booleans. Unknown keeps
Core/channel/namespace/FDs/lanes and metadata lease permanently rooted. This slice
adds OwnedPipeAgentRPCChannel.swift, AgentConnectionLifecycle.swift and
OwnedPipeAgentRPCChannelTests.swift to the existing native-owner/test source union.
Only real running true/cat fixtures are integrated now: no missing-worker launch
stub, production routing switch or claim of SDK/Broker/content retirement.

Execution deviation: worker22 reports reading a public CPython source URL to
check select's exported flags despite the offline instruction. This was not an
SDK/Provider request or an auth trial, but is not reported as zero network use.
The parent instructed all remaining workers to use local SDK headers/repository
sources only; no further public fetch is authorized. The parent receipt does not
contain that URL or proof of transmitted request contents.

Parent verified this scoped source union: 568 offline Python tests (artifact580),
15 native-owner and 11 actual-channel isolated cases, and the complete 514-case
fresh-process Product union (artifact602). The final unsigned arm64 Release Main
and all three nested XPC targets built successfully, plist lint and diffcheck
passed (artifact603). Existing nine metadata cases remain included, with no
backup-exclusion, mutation-lease or physical no-repair assertion weakened.

Preserved failures drove actual corrections: missing environment forwarding and
suspended spawn EBADF were fixed; the raw kqueue is created after captured spawn
and registered before resume. Darwin's initial suspended wait status is observed
as 0x7f (WIFSTOPPED, WSTOPSIG zero), not presumed SIGSTOP. CLI cleanup uses one
UInt64 absolute monotonic-nanosecond deadline, polls queued fork/exit events before
retirement effects and never retries uncertain closes. Physical registration
failure and fork uncertainty remain permanently unknown; injected EINTR is labeled
an injected return/errno, not an actual OS interruption.

The initial native 13/14 run crashed on the startup timer's inherited MainActor
executor check. Its explicitly @Sendable handler fixes the independent terminal
lane without moving effects under a lock. Source review then found two passing-
suite omissions: replaceable public observers suppressed lifecycle acknowledgement,
and clean retirement could discard a pending startup result. Strengthened tests
reproduced both failures (native14/15 and channel10/11, artifact601). The actual
channel now has a protected single lifecycle binding; duplicate binding refuses
before endpoint effects, and external observer replacement cannot remove closure
acknowledgement. First revocation consumes the pending startup failure exactly
once independently of retirement evidence; genuine clean retirement stays clean.
The new captured-cat setup regression requires both failed startup and actual
clean reap/six checked closes. Both regressions and the full union pass afterward.

Scoped source reviews25 and26 returned CLEAR/APPROVE for the corrected native
ownership and CLI/packaging layers respectively. They are not the final goal
completion cohort. --native-broker, SDK worker/control/kernel-peer integration,
official authenticated dispatch/probe/CAS and content retirement/purge remain
unfinished engineering. Python effects are not independently bounded until the
native enclosing chain is integrated. No SDK import/start, real authentication,
Provider request, signed acceptance, P1/P3/P6 or Story Done is certified by these
fixtures/builds. G002 and the aggregate objective remain active, not paused.

Next callable slice composes, rather than replaces, those owners: exact
--native-broker dispatch, a separate broker_control.py for authenticated lifecycle
rendezvous/opaque bounded relay, and small observe-pending/unknown operations on
the existing broker.py primitive. Agent and its broker tests are the other worker
targets; parent owns packaging inventory/tests and this existing Spec. This
four-file worker boundary keeps Darwin resource ownership separate from control
and relay without adding another CLI owner, product method or SDK transport.
Use a fixed relative AF_UNIX name in the actual inherited private cwd, never an
overlong container socket path, native global chdir or /dev/fd traversal. Kernel
peer UID/PID/audit token and public token-bound process/BSD parent observations
must establish the actual direct parent; payload PID/UUID does not authorize
effects. A future Native-worker FD5 socketpair/SCM_RIGHTS interface is lifecycle
only; inherited socketpair peer PID is not worker identity proof. No absent SDK
worker launch command or production routing switch is admitted by this slice.
Real fresh parent/true/cat/fork fixtures must prove relay, bounded cumulative
startup traffic, checked closure/reap, one supplied absolute deadline and retained
uncertainty. Broker-local resource records never certify inaccessible SDK
FileObjects, content purge, external writer absence or full initialized dispatch.
Unknown parks actual owned resources; no voluntary exit, retries, new effects or
best-effort write after terminal uncertainty. All SDK imports/execution, Provider
network/authentication and signed acceptance remain unperformed.

Callable broker layer now implemented with real fresh-process parent/child
fixtures, not an SDK client mock. Kernel UID/PID/audit-token/public BSD parent
checks authenticate both directions; the separate real grandchild case refuses
before CLI creation. Relative rendezvous works in a private cwd whose absolute
path exceeds104 bytes. Actual fixture grandparent/worker/broker SCM_RIGHTS handoff
preserves the worker's sole waitpid responsibility; no Native worker command is
added. Split/NUL bytes relay unchanged, CLI stderr is bounded discard, and both
directions enforce65540-byte LF/partial records plus four cumulative records and
262160 cumulative bytes, never reset by draining. Only the six closed environment
keys reach the existing fixed CLI owner.

Parent preserved the initial45-test run's ten failures (artifact616): Darwin
socket permission bits change0140666 to0140000 when the peer exits while device/
inode/filetype stay fixed. Checked socket closure now uses those stable identity
fields, without dropping full mode checks for directories or the namespace socket
entry. A closed peer query fails with fixed unavailable identity, never a weaker
fallback. The real wrong-parent fixture holds the grandchild until actual kernel
ancestry rejection, then permits its independent parent refusal; it does not
pretend a disappeared peer still supplied ancestry evidence.

Review29 found gaps despite the first576 offline/514 Product passes. Real direct
authenticated-child helper cases plus a non-echoing stdin consumer reproduced ten
failures (artifact628): uncertain close retries, descriptor effects after failed
wait/unknown, changed/malformed/expired cleanup deadlines, and input records whose
rejection was previously masked by cat's output. The shared close helper now
enforces terminal state before effects, selects unknown itself on any failure,
retains actual close results and forbids a different deadline once D is latched.
Shared opaque record counting admits neither a fifth input record nor a split
65541-byte record. These are actual source corrections, not relaxed assertions.

An additional gated real pre-hello revoke exposed the stale startup bound after
receiving the first cleanup D (artifact631). Pending hello delivery now adopts
only that already-latched D and rechecks it before writing; the cleanup deadline
never changes. The fixture proves preLaunchRetired with zero factory invocations,
actual exit0/reap and checked role retirement. The initial omitted zero-count test
case also failed (artifact632) and is preserved. Final complete offline union:
578 PASS (artifact633, including47 focused broker/package tests). Complete514
fresh-process Product, actual unsigned arm64 Main/all three XPC Release build,
plist and diffcheck PASS (artifact630); Native source remains unchanged635765d.
The local public-C self-socketpair probe established32-byte audit token/136-byte
BSD snapshot and token-bound lookup/accessor exports, not sandbox or ancestry
acceptance; the separate actual role fixtures establish only unsandboxed parentage.
EINTR/ECHILD/clock/partial-I/O fault injections stay explicitly labeled injections.
SDK worker, initialized dispatch, Native enclosing integration and authenticated
product probe/CAS/purge remain unfinished, not human-only blockers or Story Done.
Final review29 inspected the corrected five-file source boundary and returned
CLEAR/APPROVE with no residual finding. This is scoped role acceptance, not the
aggregate goal's terminal completion cohort or external acceptance.

Source slice (contract30, implemented below): callable exact
`--official-sdk-worker`, genuine lazy CodexClient/config/generated-model calls,
explicit product-mode existing Server (no topology fixture construction), actual
worker-owned rendezvous/SCM_RIGHTS and retained blocking SDK jobs. No Native
production launch is added before this real worker and same-Core control support
exist. Native forwards authenticated dispatching and first revoke D on FD5;
worker never competes for broker control reads and SDK.close never competes for
broker waitpid. FD3/4 meanings are unchanged. HOME=cwd=N, CODEX_HOME=N/codex,
TMPDIR=N/tmp: reuse the actual owned namespace, not a new home/store/FD6.

Explicit private dispatch/dispatching phase may end the startup timer and raise
only the lifetime record allowance from4 to256; startup totals remain retained.
Both direction cumulative byte totals stay<=262160 FOR THE WHOLE SESSION, never
reset; individual records<=65540 and pending slots<=4 including partial/scratch.
This finite-ingress guard replaces the first contract30 suggestion of unrestricted
ongoing relay, which would not bound SDK router ingress. Pending closed records
use backpressure, no read-and-drop fifth record; control/revoke retain priority.
Exhaustion requests sessionLimit, never retry/replacement or a larger allowance.
Actual owned-scope retirement requests use private revokeNeeded(scopeRetire)
before terminal uncertainty; no new notifications/descriptor effects after unknown.
Real SDK imports/authentication/Provider calls remain unperformed and unauthorized;
offline scripted public-contract objects must never be called real SDK evidence.
SDKFileObject/queue/content purge remains unproved, requiring permanent retained
unknown rather than a fake clean result, namespace deletion or voluntary exit.

### Official worker and finite relay source checkpoint — 2026-10-15

The source delta over265384178165ad40e9404c9fe47b5fbc3a6ca3e7 adds
sdk_worker.py, exact --official-sdk-worker entry and explicit product Server;
packaging includes byte-identical worker/control resources and import-purity
checks. Package.swift excludes both Python broker/worker test modules from the
Swift test target. These are genuine lazy public SDK calls, not SDK execution:
no openai_codex import/start/initialize/authentication or Provider request ran.

Actual login/cancel/thread/turn objects, late IDs/results/exceptions, blocked jobs,
notification readers, loop and namespace remain rooted. Wire cancellation never
releases blocked SDK-job debt. Exact-stage admission gates ordinary SDK work;
loop-side acceptance revalidates the same stage and retirement fence before
publishing instructions/usable or committing probe validation. Only an admitted
ordinary job's actual stage receives its wire-terminal invalidation; unstarted,
unbound/hello/observe/unowned-paper requests cannot stale an unrelated stage.
SDK-thread timeout checks refuse work without selecting loop-owned terminals.
The hello-created global reader remains session-scoped; login/probe readers are
stage-bound. Unsupported paper scopes fail closed before bookkeeping or account
retirement; no paper registry/absence record is invented. Matched stage/startup
retirement asks for actual Native D and never fabricates whole-SDK cleanup proof.

Review34 initially blocked stale successful publication, stale ordinary SDK
admission and unowned paper retirement (F1–F3). Corrections added scripted
interleavings, then re-review found F4: binding the global reader to the cancelled
stage could select unknown before reserved cancellation. The global reader's
stage argument was removed; its new real scripted-thread interleaving holds the
reserved cancellation, returns a global notice after stage cancellation, observes
the second global read without unknown, then verifies actual cancellation runs.
Final review34 inspected this correction and returned scoped CLEAR/APPROVE with
F1–F4 resolved and no residual finding; this is not the terminal goal cohort.
These are scripted public-contract objects, not a fake installed SDK or runtime
authentication evidence. Review33's bounded-burst follow-up is CLEAR/APPROVE:
control/watch priority occurs each at-most256-byte burst and payload write, not
every byte and not a Python wall-clock/preemption guarantee.

Historical affected194 gate failed two physical-role observation deadlines plus
an injection's missing errno import (artifact649). Import fixed; removing redundant
per-byte priority polling preserved real five-second assertions, resource/watch
checks, reservations and counters. Affected194 then passed (654), corrected208
passed (665), full622 passed (668), and the final F4-corrected full offline union
passed623 in22.364s (673). Asyncio slow-task diagnostics remain visible. Fresh
Product514/0 failures/0 errors passed (670), report
.build/isolated-product-sdk-worker-4B96AE2B-87AB-4FB5-A408-1219B267CD98.json;
unsigned arm64 Main/all three XPC Release build passed (raw671). Those native
gates preceded the final worker-only F4 correction; Native/agent source remained
unchanged. Failed/intermediate evidence is retained rather than relabelled passed.

Public Swift ancillary-macro import failure648 is resolved as an implementation
input, not a production bridge: direct public sys/socket.h/arm/_param.h align32,
cmsghdr size and CMSG_LEN/SPACE translations compiled and actually transferred a
/dev/null descriptor with sendmsg/recvmsg, matching fstat identity and four checked
closes (.build/public-swift-ancillary.swift). Header12/dataOffset12/len16/space16
are observed self-ABI values, not invented offsets or signed-child acceptance.
The Native same-Core WorkerLaunch/control/SCM production route is still absent;
source authentication/probe does not activate Settings, serialized selector CAS,
reconnection or dependent purge. SDK FileObjects/internal queues/content closure,
P1/P3/P6, signed/minimum/current OS acceptance and Story/goal completion remain
unproved. G002 and aggregate stay active; implementable engineering is not paused.

## Historical minimal SDK/product proposal — initially NOT ADMITTED, 2026-10-14

At this earlier checkpoint integration source was5f08cc2. This existing Spec, not
a new plan, records the precise next dependency after explicit sole-Provider kind,
atomic CAS, frozen extraction/retry routing, real pipe transport and shared browser/
device presentation state. Actual unsigned arm64/macOS15 Main/XPC build and private
tests do not settle product RPC or authenticated SDK admission. There is no global
human-only blocker: independent artifact work and public containment engineering
continue under current authority. No SDK is invoked by this proposal.

### Fixed semantics — preserve without a new approval loop

- contract.json remains the only wire authority. Keep closed validation, existing
  envelopes, safe errors, sizes/queues/deadlines and zero streams. Existing
  1/1/topology-v1 identity is not product capability; no compatibility downgrade,
  SDK JSON passthrough or borrowed topology-home authority.
- Browser/device modes are explicit, with their evidenced closed instruction
  projections and one current intent. Only trusted bounded minimal instructions
  reach the intentional login surface. Missing/wrong/late/duplicate identity never
  certifies auth; every returned late SDK loginId remains owned for cleanup.
- Bind a never-reused stage to expected selector/configuration, current intent and
  generation. Preserve last-good and actual leases during candidate work. Only
  the Application serialized SQLite CAS winner activates. Metadata kind, auth
  completion, slot names or token existence are not usable-connection authority.
- Fixed inner connectionTest: empty input, prompt Reply exactly PAPERLENS_OK.,
  exact text PAPERLENS_OK and unchanged version/request/operation. Actual
  authenticated output only; no local sentinel, simulated usable stage or replay.
- One eventual terminal across usable/failure/cancel/timeout/exit. Cancel selection
  is not cessation. Separately correlated cleanup must prove revocation, producer/
  FD closure, correct ownership/generation and scoped absence. Missing/stale/failed
  proof retains affected barriers and old/new leased state.
- Agent exclusively owns auth/config; persistent metadata excludes Paper content.
  Required Paper bytes are attempt-scoped. Protected creation, directory0700/
  file0600, descendant backup exclusion, no permission repair or abandoned-stage
  promotion, protocol-only stdout and closed safe diagnostics remain mandatory.

### Two HIGH shared choices requiring concrete owner input

1. Settle the product handshake/version/capability and closed carrier/call
   boundaries for current browser/device instructions and the eventual terminal:
   exact names/fields/results/safe errors, immutable stage/expected configuration/
   current-intent correlation and independently correlated cleanup ACK. Settle
   instruction delivery within existing timeout/size/zero-stream policy; do not
   infer notifications, poll intervals, expiry or streams. Unrelated final Paper
   Chat fields need not block settlement of this minimum.
2. Settle complete Agent-only auth/stage/lease/attempt layout, selected versus
   abandoned startup policy and exact permitted environment/output projection.
   Include ownership/backup validation for SDK-created descendants and how auth/
   session/log state stays separate from Paper attempt content. No guessed SDK
   paths, borrowed topology homes, privacy waiver or enlarged resource budgets.

Owners may pin these choices or explicitly delegate bounded settlement. Ordinary
public process/filesystem/serialization mechanics do not need per-edit approvals.
No exact new wire name, path, constant, authorization or SDK effect is invented here.

### Public supervisor feasibility remains autonomous engineering

The strongest candidate is an independently owned public worker, not client._proc
or the topology RuntimeProbe. Establish exclusive launch/stdio ownership and
partial-start/descendant handling; exact environment replacement before SDK import;
denied unexpected command/file effects; bounds for all internal queues/pending login
storage, not just four outer frames; revoke/unblock/join/reap/checked-close ordering
under the unchanged aggregate budget; retained uncertainty debt; and generation-
checked scoped absence that cannot erase newer/leased stages.

Neither a process group, cancellation, EOF, cancel ACK nor SDK close return proves
the whole boundary. Current evidence also does not prove supervision impossible;
the SDK's2s wait timeout is not necessarily a mandatory2s delay. Approval cannot
make unsupported SDK effects supported. Do not repeat unchanged source-fact audits.

No executable process slice is admitted by the old pipe-only phase. Parent must
first pin a trusted no-SDK/no-network/no-credential fixture executable identity,
exact arguments/environment/working-directory/stdio, exclusive descendant policy,
existing deadline/cleanup applicability, observable termination/debt assertions
and exact source/test union. That is bounded source admission, not automatically
a new HIGH decision or permission to enlarge budgets. It must create a real owned
process and measured local failure proof, not an inactive fake SDK/slot owner.

Architect4 NextSDKBoundaryDecision is BLOCK/COMMENT for this successor only.
It explicitly leaves independent Epic implementation and this public-boundary
feasibility resolvable. After minimal policy settlement, the existing five-file
authority/parity slice below is the real source successor, followed separately by
the actual SDK owner. No goal/Story/P1/P2/P3/FR-002 completion follows from this text.

## Status and authority

### Withdrawn direct-child implementation admission: public deadline conflict

The Whole-Epic parent proposed an independent public ownership slice, not SDK
dispatch or shared product/privacy policy. Proposed union: ProviderAgent/owned_child.py,
Tests/Topology/test_owned_child.py, Package.swift Python-test exclusion, and this
existing Spec. Capture exclusively owned actual subprocess.Popen plus its actual
pipe FileObjects; constructor does not launch anything or accept a synthetic peer.
No Popen means no process ownership claim. Direct child only: no descendant, SDK
content absence, remote cancellation, auth or product cleanup ACK is inferred.

The tests launch only existing trusted system /usr/bin/true and /bin/cat, explicit
argument arrays, shell=false, stdin/stdout/stderr owned PIPEs, close_fds=true,
an exact environment with PATH=/usr/bin:/bin:/usr/sbin:/sbin and LANG/LC_ALL=C,
and a fresh private temporary working directory. No helper/SDK/app/network/document
or credential path is launched. Constructor and retirement use public Popen PID,
poll/terminate/kill/wait and actual file.close, never SDK _proc or a new slot store.
These host utilities are private process fixtures, never packaged SDK fallback.

Caller supplies its existing absolute monotonic cleanup deadline; no new duration,
polling interval, resource limit or grace period. Select revoke once; no reads or
writes by this owner. Observe wait/reaping and each captured physical pipe close
before success. Deadline/termination/wait/close uncertainty retains the actual owner
and handles in a process-lifetime strong root with no blind close/reap retry or
destructor inference. Constructor/setup/partial capture must not silently abandon
transferred ownership. Redacted typed state only; no argv/environment/path/raw output.

Verify actual already-exited child and held pipe child retirement, idempotent
successful observation, one terminal/no callbacks or close retry after unknown,
deadline exhaustion and physical wait/close uncertainty retention after facade loss.
Test fixture manual teardown never certifies production unknown debt. Parent runs
tests/build/risk review only after the conflict below is resolved. The intended
proof would cover local direct-child ownership only, not full SDK descendant/
resource/private-state supervision. No primitive or passing fixture exists.

The proposed executable slice above is BLOCKED, not delivered or admitted for
implementation. ActualDirectChildRetirement found that buffered stdin.close may
flush/block; actual pipe close, poll, terminate and kill lack deadline/cancellation
contracts. wait(timeout=remaining) cannot bound those surrounding synchronous
effects or guarantee return at the supplied absolute deadline. Parent explicitly
ordered implementation stopped and the original deadline unchanged: no deadline-
checked blocking substitute, extra grace or successful retirement claim. Worker
made no source/test/Package changes and launched no fixture. The named files above
are proposal targets only, not present delivered ownership code.

A separately specified deadline-isolated execution mechanism with retained
ownership and late-effect semantics must be admitted and proved, or acceptance
must be explicitly renegotiated by its owner. The latter is not authorized here.
SDK descendant/resource/private-state and actual cleanup remain unproved; neither
this conflict nor a potential mechanism is a blanket Epic source gate.

### Parent successor admission: native deadline-isolated direct child

TerminalBlockerAudit PAUSE-1/ITERATE confirms this mechanical successor is parent-
owned autonomous engineering. Synchronous Popen proposal stays stopped. Exact union:
PaperLensApp/Application/OwnedChildRetirement.swift, Tests/Product/OwnedChildRetirementTests.swift,
Package.swift and PaperLens.xcodeproj/project.pbxproj registration, and this Spec.
Actual public Darwin posix_spawn creates the owned child, never arbitrary PID or
synthetic owner. Only fixture /usr/bin/true or /bin/cat, empty argument list, no
shell; exact PATH=/usr/bin:/bin:/usr/sbin:/sbin, LANG=C, LC_ALL=C; fresh private cwd.
Public close-on-exec-default actions duplicate explicitly owned pipe stdio and
prevent ambient FD inheritance. No SDK/app/helper/network or credentials.

Prepare an independent native operation lane before cleanup starts. Spawn/setup,
each checked raw pipe close and blocking waitpid run only there. The independent
deadline/terminal-selection lane NEVER performs or joins those blocking effects.
Caller supplies the unchanged absolute monotonic deadline; no new timeout, grace,
poll interval, resource constant, queue or retry. One retirement invocation per
immutable actual child identity. On-time clean requires actual waitpid reaping
and every observed physical close, not EOF/signal acceptance or destructors.

For these no-input fixtures, checked stdin closure requests EOF; waitpid observes
actual child reaping, then checked stdout/stderr closure. Check the absolute clock
before every next effect and before success. At expiry/uncertainty select sticky
unknown and retain actual child/handles/operation lane in a process-lifetime strong
root with its admission barrier. Never retry unknown close or admit replacement
against that debt. In-flight operations may finish late but cannot start another
effect after expiry, issue a second terminal, clear debt or affect a newer identity.
Timer scheduling/measurement failure remains failure evidence, not fabricated
hard realtime proof. No potentially blocking call is made bounded by timeout checks.

Parent verifies actual true/cat reaping/checked closes, actual already-exited child,
held real worker with independent deadline expiry, facade-loss root retention,
no late success/replacement, partial-start/close uncertainty and no retry. A private
synchronization gate may hold the genuine operation lane; separate fixture teardown
never discharges production uncertainty or certifies SDK/descendant/content absence.
This primitive is not usable product Provider dispatch or full SDK cleanup and
cannot satisfy Story/P1/P2/P3/P6 acceptance on fixture evidence.

### Native successor parent verification — actual local proof only

The exact five-file native successor union is implemented and registered in the
Swift package and actual Main Xcode target. NativeChildOwnershipIntegrityReview:
CLEAR/APPROVE, no findings, direct true/cat ownership scope only. Parent formatted
the two new Swift files once, rebuilt the caller bundle, then ran all496 Product
cases in fresh native processes:496 PASS, zero failures/errors, including all seven
OwnedChildRetirementTests. Current report:
`.build/isolated-product-native-child-formatted.json`. Actual unsigned arm64 Main/
nested XPC compilation also BUILD SUCCEEDED with automatic resolution disabled.

Observed cases include real waitpid/checked six-FD closes, cat EOF followed by
reaping, true exit observed WNOWAIT, held actual operation lane with independent
deadline expiry/facade loss/no late clean/replacement refusal, partial setup real
pipe retention, actual EBADF close failure and expired-no-effect. Unknown roots
are intentionally never reset; physical fixture teardown is not cleanup evidence.
Dispatch timer/scheduling and untested arbitrary syscall interleavings remain
explicit limitations, not hard realtime/P3 or full SDK shutdown guarantees.

Only trusted fixed fixture utilities are admitted. No product RPC activation,
SDK login/probe, auth/private layout, descendant/content absence/purge, protected
trial, signed OS×CPU proof or acceptance was delivered by this primitive. HIGH
shared product/private-state decisions above and the actual SDK owner remain
unresolved. Terminal critic ITERATE was addressed with genuine autonomous source
work; full original three-goal aggregate remains active and incomplete.

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
