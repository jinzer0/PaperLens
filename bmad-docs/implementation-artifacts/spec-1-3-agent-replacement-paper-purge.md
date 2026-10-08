# Build Spec — Story 1.3: Agent replacement / Paper purge

Issue #6 · task branch `issue/6-story-1-3` · local baseline `68b8f41`.
Whole-Epic approval: https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Product `5eac3bb9424ad893eca7d63bc319b71f580838ed`; architecture `1195c92227cc628e325f5ff24d70cc93639bf7a9`. Spec must be committed on its own branch before implementation. No repeated SHA approval within approved scope; no remote/distribution approval implied.

## Scope and authoritative requirements

Canonical epics.md Story1.3 (430–459), SOLUTION-DESIGN §§5.1,6.5,10–11: replacement startup absence, deletion cancel/purge, late-result rejection, retry and two-CPU P1 aggregation. This slice supplies real synthetic filesystem Paper purge and named fresh-instance recovery, not a complete product deletion saga. Actual SDK/process-tree/installed-app lifecycle and packaged P1 remain separate mandatory proof.

## Ownership and closed producer scope

Existing AttemptFixtures.prepare/terminal/cleanup/recover and RuntimeWorker/Server are reused. Short root flock serializes operations but cannot revoke future writers.

A session coordinator holds the verified root's existing .owner.json descriptor with exclusive nonblocking flock for the entire producer session. Root/receipt inode is stable while held. All synthetic store instances join before scheduling/first access; independent instances/processes need their own exclusive lease and return busy during contention. Existing inspected store writers also need this flock before mutation. This is not control over arbitrary unknown/SDK writers.

Only the coordinator owns/closes/unlocks retained root/owner FDs. Joined stores borrow them without close callbacks or another flock. Reopen the namespace and owner entry after lease acquisition, before mutation and before acknowledgment; compare their inodes with retained FDs. Compare the post-flock receipt self identity with fstat of the LOCKED owner, not merely its own replacement identity. Replacement is unavailable, never adoption/relocking/chmod. A detached old-root absence check proves nothing about the current namespace. Missing namespace requires the ordinary verified fresh-root creation path before lease acquisition; unleased root(False) absence cannot acknowledge purge.

Register each real synthetic prepare producer before scheduling or filesystem access. Its permit lasts through descriptor close and cancellation byte cleanup. Only observed completion removes registration: task cancellation, dictionary removal and invented drained flags are insufficient. Test-injected barriers control timing, not fake writer implementations.

Revocation uses a separate state lock, never awaiting drain under the filesystem operation gate. Atomically arbitrate prepare success against revocation: a terminal selected after revocation is cancelled; a success already selected earlier is not retrospectively late. If a producer capable of touching the scope cannot be registered or excluded, or completion cannot be observed, refuse acknowledgment.

## Typed boundary and ordering

Add only topology.paperPurge to sole ProviderRPC JSON authority. Params exactly {runID:uuid,paperID:uuid,generation:generation,correlationID:uuid}; result exactly {absent:true,drained:true}, with true-only fields. EnvelopeID correlates the response; correlationID identifies the purge operation, not one attempt filter. Preserve framing, limits, handshake, deadlines and safe errors.

Scope: named run/Paper, all owned attempt correlations at generations ≤ deletion fence. Any matching owned/registered generation above fence fails invalidParams before mutation. Application aggregates all relevant run scopes; one ack does not cover another run.

Under the state lock validate the registered identity/fence census and reserve bounded state → revoke every-generation admission and request producer stop WITHOUT waiting for/holding the filesystem gate → observe underlying writers and operation-local FDs become unable to write → under the operation gate validate ENTIRE named-run ownership and persisted/registered generations BEFORE FIRST unlink → validated cancellation/attempt cleanup → reopened ownership and marker/receipt absence → acknowledge. Registration survives writer quiescence until validated cleanup completes. Cancellation of the request wrapper is not underlying producer closure.

Stale RAM fence rejects before stop. A higher persisted generation discovered after quiescence rejects before any unlink, retains revocation/unresolved ownership and does not claim success. Failed whole-run validation similarly forbids cancellation-cleanup unlink; no partial/unreceipted ownership repair. A stopped producer may leave unresolved bytes and a failed purge, never a fabricated drained acknowledgment. Drain waiting cannot hold the gate needed by that producer's close path.

Preserve other Papers/runs. Unknown entries, symlinks, hardlinks, swapped inodes, unsafe modes and contradictory receipts fail without adoption, chmod repair or broad sweep. Missing owned entries allow retryable absence. absent&&drained proves registered cleanup and synthetic absence under retained lease. Revocation lasts while coordinator lives. No permanent non-resurrection after lease release, SDK residue absence, DB cascade, remote erasure or user deletion-complete claim. Application owns durable tombstones, cross-session fencing and dispatch exclusion; Agent gets no second durable Paper deletion ledger.

## Bounds, retry and failure

Keep32 attempts/run,64 directory entries,4096-byte receipts. Coordinator RAM caps256 correlation records and256 revoked run/Paper scopes. Reserve before mutation, busy for new admission at capacity; never evict revocations/consumed identities. Existing same-identity retries remain possible at capacity.

Fresh envelopeID, same purge identity reruns validation/drain/absence, not cached success. Reusing purge correlation for changed params or an attempt is invalidParams. Lease/capacity busy; identity/stale fence invalidParams; unsafe ownership/unknown producer/IO unavailable; deadline timeout; cancel cancelled. Failure/lost response retains revocation and unresolved ownership. No success while writer may still write.

## Fresh-instance recovery

After old session closure, fresh Server/coordinator acquires ownership and invokes existing topology.attemptRecover(runID) for explicitly named prior runs before admitting them. Independently inspect absence; no replacement alias RPC, discovery/adoption of unnamed runs or reuse of prior attempt identities. Unknown live writer prevents recovery acknowledgment. This does not prove installed-app replacement or permanent protection against later recreation.

Session close first blocks admission and requests stop, then observes ALL underlying producers and operation-local FDs close before releasing the lease. Empty pending, gathering request tasks or overwriting Server is insufficient. Failed/unknown closure retains ownership rather than releasing it to a fresh instance. Fresh named recovery requires observed prior lease release and exclusive reacquisition. Test helpers must explicitly close old sessions or explicitly join their coordinator; those are different proofs.

## Implementation and verification

Proposed bounded targets: ProviderAgent/agent.py, Contracts/ProviderRPC/contract.json, Tests/Topology/test_agent.py, Tests/Topology/test_provider_rpc.py, Tests/Topology/ProviderRPCTests.swift. Inspect native generic schema support for true-only result fields; if absent, sequence a separate patch to Contracts/ProviderRPC/ProviderRPC.swift rather than duplicate policy. No product DB/UI/SDK/permission changes. Parent alone runs tests/build/format/whitespace and commits.

Required real-tempfs tests: two correlations/generations purge; otherPaper/run survives; independently reopened absence and repeat retry. UUID/bool-generation/extra/stale-fence/reused-correlation and foreign/mode/inode/symlink/hardlink failures preserve data. Unlink/fsync/deadline/cancel/lostresponse/failed-drain/capacity retain failure/fences; retry converges only after actual cleanup.

Barrier races before write, after marker and before terminal: no acknowledgment until actual close/cleanup, no post-revocation success/recreated marker; cancelling an async task does not drain its underlying writer. Shared coordinator revokes all joined stores; independent instances/processes contend. After lease release, demonstrate possible recreation explicitly outside prior acknowledgment. Fresh named recovery refuses foreign/unresolved-writer state.

Actual authenticated SDK success/failure cleanup, restart, installation replacement, Paper deletion and two-CPU signed topology/negative-access/notary/Gatekeeper evidence remain required P1 proof. Synthetic passes do not promote P1/P2. Native x86 dynamic execution and remote actions remain unapproved. Safe durable evidence excludes raw PID/path/log/timestamp/content; source/evidence commits stay local.

## Static design assessment

Architect13 read-only proposal: WATCH / COMMENT. Producer exclusion/drain is a prerequisite, not a proven existing property. Retained lease provides bounded session proof without duplicating Application durable deletion authority. No tests or implementation review performed by architect.
