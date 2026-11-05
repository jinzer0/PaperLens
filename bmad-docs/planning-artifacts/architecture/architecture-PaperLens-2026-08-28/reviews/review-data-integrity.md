# Data Integrity, Concurrency, Durable Job, Revision, and Deletion Review

## Verdict

**PASS — the exact current draft closes DI-01 through DI-06 and the three newly explicit race boundaries at architecture-invariant altitude.**

The draft now fixes one durable/side-effect authority, one publication winner, cross-store visibility and rollback, startup handling of prior-process running attempts, extraction/FTS activation, credential selection, immutable Template/Brief provenance, deletion publication drain, Agent-owned Paper-state purge, and durable tombstone behavior. No Tier 1 or Tier 2 data-integrity/concurrency finding remains.

This PASS is a review of the current draft, not `APPROVED: ARCHITECTURE`, implementation approval, or proof that the blocking prototypes and fault-injection suites already pass.

## Baseline and review method

- Product baseline: final PRD and addendum approved at `APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456`.
- Exact architecture reviewed: current [ARCHITECTURE-SPINE.md](../ARCHITECTURE-SPINE.md) AD-1..AD-14 and current [SOLUTION-DESIGN.md](../SOLUTION-DESIGN.md).
- Decision provenance reviewed: current [memlog](../.memlog.md).
- Retested surfaces: DI-01..DI-06, publication permit/revocation/drain, startup running-attempt reconciliation, and Provider Agent purge as a deletion dependency.

The sufficiency test is whether independently built units could choose incompatible winners, visibility boundaries, restart outcomes, revision identities, active credentials, current Briefs, or deletion completion conditions while claiming compliance. Full table design, lock implementation, scheduler algorithm, filesystem primitive, and RPC payload remain Build Spec detail when the architecture already fixes the invariant they must realize.

## Current closure summary

| Surface | Current invariant | Result |
| --- | --- | --- |
| DI-01 fences/result publication | AD-10 fixes immutable attempts/fences, transactional claim, durable dispatch intent, guarded atomic result/state/current-pointer publication, stale rejection, and prior-result preservation. | **CLOSED** |
| DI-02 cross-store visibility | AD-6 fixes staging, validation, Paper generation publication permit, guarded DB commit or synchronous cleanup, SQLite-only visibility, and startup reconciliation/scavenging. | **CLOSED** |
| DI-03 extraction/FTS revision | AD-7 fixes inactive immutable sentence/geometry/FTS construction, one-transaction activation, pinned retrieval, and referenced-old-revision retention. | **CLOSED** |
| DI-04 staged credential selector | AD-4/AD-5 fix never-reused slot identity/config generation, real staged test, SQLite sole selector, serialized CAS promotion, retirement, and stale-generation rejection. | **CLOSED** |
| DI-05 Template/current Brief | AD-14 fixes immutable Template versions, transactional value-copy snapshot+Job, snapshot-only payload, complete result provenance, and current fenced regeneration winner. | **CLOSED** |
| DI-06 deletion/tombstone | AD-11 fixes predicate/generation/lease/permit revocation, publisher drain, Agent purge dependency, local absence, terminal cascade+tombstone, retryable failure, and no identity reconstruction. | **CLOSED** |
| Startup prior-process running attempts | AD-10 fixes one reconciliation transaction to `failed/interrupted`, preserves prior usable result, forbids old-fence resume/renew, and restricts normal claims to `pending`. | **CLOSED** |
| Agent Paper-state deletion dependency | AD-2/AD-11 make Paper-linked Agent state attempt-keyed and non-diagnostic, require terminal/cancel/startup purge, and block deletion success until purge acknowledgment/verification. | **CLOSED** |

## Explicit validation of new boundaries

### Publication permit, synchronous rollback, and deletion drain

AD-6 now requires an Application-owned Paper UUID/generation publication permit immediately before final rename. The publisher holds that permit through either the guarded SQLite commit or synchronous removal after a failed guard. AD-11's deletion-start transaction revokes new permits together with the active predicate, generation, and leases; deletion drains existing publishers before checking file/cache absence and forbids final rename after tombstone.

This closes the previous late-artifact race:

1. A publisher that has not obtained a permit loses to deletion and cannot rename.
2. A publisher already holding a permit finishes its guarded commit or cleanup before deletion's drain completes.
3. If deletion made the Paper/generation inactive, the publisher's DB guard fails and the same operation removes the renamed artifact before releasing the permit.
4. Only after all such publishers drain can deletion establish filesystem absence and perform the terminal database cascade/tombstone.
5. A process crash after rename but before DB reference still leaves an invisible unreferenced object; startup scavenging or the deleting saga removes it, and filesystem presence never reconstructs a Paper.

**Disposition: SUFFICIENT ARCHITECTURE INVARIANT.** The permit's actor/lock implementation, lock ordering, filesystem durability calls, atomic rename primitive, and crash-fault harness belong in the shared Job/cross-store Build Spec. That Build Spec must avoid waiting for permit drain while holding a database transaction needed by a current publisher, but the exact deadlock-free mechanism need not be fixed in the spine.

### Startup reconciliation of persisted `running` attempts

AD-10 now states that startup never resumes or renews a prior-process attempt or fence. One startup transaction maps every persisted `running` attempt to `failed/interrupted` and preserves the prior usable-result pointer. Only `pending` Jobs are normally claimable. Any re-execution receives a new attempt/fence under one Application-owned Job-class recovery policy pinned before Job Build Specs split. An ambiguous external dispatch always waits for explicit user Retry.

The outcome is deterministic for all prior-process states:

- `running` with no external dispatch: becomes failed/interrupted; any automatic re-execution allowed by the common class policy uses a new fence.
- `running` with durable external dispatch intent: becomes failed/interrupted; ambiguous billable work is not automatically retried.
- `running` regeneration with an older usable result: becomes failed/interrupted while the older current-usable pointer remains.
- late local worker or Agent output from the old process/fence: fails attempt/fence/config/input/Paper-generation publication predicates.
- `pending`: remains the only ordinary claim source and receives a fresh immutable attempt/fence.

**Disposition: SUFFICIENT ARCHITECTURE INVARIANT.** The per-Job-class recovery policy must be one shared Application contract before feature Job Build Specs diverge. Which non-ambiguous Job classes auto-create a new attempt, UI copy, scheduling, lease intervals, and SQL representation remain Build Spec details.

### Provider Agent purge as a deletion dependency

AD-2 limits durable Agent-zone state to Provider auth/config/package metadata. Any SDK-required Paper-linked session, log, or temporary state is attempt-scoped, keyed by Paper UUID/generation/correlation, excluded from diagnostics, and purged after terminal/cancel and on startup. ProviderRPC is the sole lifecycle and purge acknowledgment/verification boundary; the native app receives no broad Agent-filesystem access.

AD-11 makes purge a deletion prerequisite rather than best-effort cleanup. Deletion cancels known correlations and requests an Agent-owned Paper-state purge. Terminal success is forbidden until acknowledgment/verification is received. Purge failure leaves the Paper `deleting/failed` and retries the same idempotent saga. A request already sent externally cannot be revoked, but its response cannot publish or enter diagnostics; AD-2's no-durable-Paper-content and terminal/cancel purge rules prevent it from becoming retained local Paper state. P-1/P-2 marker-content tests cover success, failure, restart, app replacement, and Paper deletion on both CPU artifacts/runtime matrix points.

**Disposition: SUFFICIENT ARCHITECTURE INVARIANT WITH BLOCKING PROOF.** Exact purge RPC fields, Agent-local retirement/drain primitive, SDK cleanup adapter, acknowledgment proof, and marker harness are shared ProviderRPC/P-1/P-2 details. A conforming purge acknowledgment must mean the keyed correlations are locally retired and no Paper-linked writer can recreate retained state after acknowledgment; a mere request receipt is not sufficient under AD-2/AD-11.

## DI-01..DI-06 detailed retest

### DI-01 — Fenced Job and result publication

AD-10 selects one attempt winner with immutable attempt ID, never-reused fence/lease, transactional `pending → running` claim, immutable input/config/Paper generations, and one atomic result/success/current-pointer commit. Renewal cannot change or reuse ownership. Stale completion changes neither state, result, nor cache visibility. Failed/interrupted work does not clear the prior usable pointer. Durable dispatch intent before the external call plus explicit-only retry for ambiguous work avoids an impossible exactly-once external-execution promise.

**Result: CLOSED.** CAS SQL, fence encoding, lease duration, heartbeat, scheduler, and backoff are implementation details.

### DI-02 — File/cache/database publication

AD-1 keeps side-effect winner authority in Application. AD-6 makes staged output non-readable, validates identity/size/hash, uses the publication permit through DB commit or cleanup, and makes SQLite the only visibility authority. Referenced-missing artifacts become typed failure; unrelated unreferenced artifacts are scavenged; filesystem state never creates a Paper. Paper caches use Paper UUID/generation, and AD-7 gives every duplicate import a separately owned PDF copy rather than shared-blob/refcount ambiguity.

**Result: CLOSED.** Path layout, rename/fsync sequence, permit primitive, scavenger cadence, and deletion barrier mechanics remain Build Spec details.

### DI-03 — Active extraction revision and FTS

AD-7 builds sentence, geometry, and revision-tagged FTS rows as one inactive immutable revision, then activates the complete revision in one transaction. The old active revision remains usable until success; each retrieval pins one revision; referenced old revisions survive; only unreferenced revisions are reclaimable. EvidenceBundle, EvidenceAnchor, Translation, and Provider result provenance retain that revision identity. The deletion terminal transaction removes extraction/FTS visibility.

**Result: CLOSED.** FTS schema, completeness marker, active-pointer representation, ranking, query SQL, and cleanup implementation are lower-level details.

### DI-04 — Staged credential selector and replacement

AD-4/AD-5 distinguish immutable, never-reused slot identity/config generation from SDK-managed contents that may mutate only inside the controlled Agent zone. A staged slot must pass the smallest real authenticated v1 request. SQLite is the sole active selector; promotion is serialized expected-selector CAS; the old active remains through commit and in-flight retirement. Startup preserves only the selected complete slot, cleans abandoned stages through the owner/Agent, and does not infer active state from directory names. New work uses current config generation and old-generation output cannot publish.

**Result: CLOSED.** Selector schema, slot layout, retirement lease, Agent cleanup call, and exact capability request remain shared Build Spec/prototype details.

### DI-05 — Immutable Template snapshot and current Brief

AD-14 makes every Template save a new immutable version and moves only the current Template pointer. One Brief command transaction value-copies the selected version, sections, prompts, and generation inputs into a Paper-owned immutable snapshot, assigns the ordered regeneration version, and creates the Job. Provider payload reads only the snapshot. Result provenance records snapshot identity/hash, extraction revision, Provider config/result version, and Paper generation. Only the still-current fenced regeneration can atomically move current Brief; failure and reverse completion preserve the prior usable Brief.

**Result: CLOSED.** Table shape, hash/version encoding, Markdown storage, and pointer SQL remain Build Spec details.

### DI-06 — Deletion, local absence, purge, and tombstone

AD-11 starts by making the active predicate false, advancing Paper generation, revoking leases and new publication permits, then canceling work. Existing publishers drain before absence checks. Pending/running attempts become non-retryable `failed/paperDeleting`; no new dispatch, rename, or retry is allowed. Agent purge acknowledgment/verification, PDF/cache absence, and publisher drain are terminal dependencies. One final DB transaction cascades Paper-owned rows and FTS and leaves a durable contentless v1 tombstone. Failure stays `deleting/failed`; recovery/import/cache scan cannot reactivate the identity; a later import gets a new Paper UUID. Reusable Templates survive while Paper-bound snapshots/results delete.

The guarantee remains correctly non-forensic: it does not promise APFS snapshot, existing external backup, already-transmitted request, or external Provider erasure.

**Result: CLOSED.** Saga checkpoint schema, cancellation transport, purge RPC, filesystem deletion calls, terminal cascade SQL, and tombstone columns remain implementation details.

## Complete crash/race matrix

| Surface | Crash/race point | Required current-draft outcome |
| --- | --- | --- |
| Import | Before Paper/Job transaction | No visible Paper or published artifact. |
| Import | During download/copy/hash | Partial stage is non-readable; startup/deletion scavenges it; Job is failed/interrupted or retryable by policy. |
| Publication | Delete begins before permit acquisition | New permit is revoked; no final rename occurs. |
| Publication | Delete begins while publisher holds permit | Deletion waits for drain; publisher commits valid reference or synchronously removes failed-guard final before release. |
| Publication | Crash after rename, before DB commit | Artifact has no SQLite visibility; startup/deletion scavenges it and never reconstructs Paper. |
| Publication | DB guard fails after rename | Same operation removes final artifact before permit release. |
| Publication | Valid DB commit, then crash before permit release | Referenced artifact remains valid; process-local permit cannot authorize later stale publication. |
| Deletion | Drain completed, then old worker returns | No permit/final rename or DB publication is available to the stale fence/generation. |
| Extraction | Two workers claim one logical Job | Transactional claim/fence chooses one; loser cannot dispatch or publish. |
| Extraction/FTS | Crash during inactive revision build | Existing active revision remains complete and searchable. |
| Extraction/FTS | Query races active switch | Retrieval pins complete old or complete new revision, never mixed rows. |
| Extraction/FTS | Cleanup races pinned reference | Referenced old revision remains; only unreferenced revision is removed. |
| Translation | Page attempts finish out of order | Fixed page order remains; each result is fenced and version/generation-bound. |
| Provider | Crash before durable dispatch intent | External dispatch is forbidden; retry behavior follows class policy with new attempt/fence. |
| Provider | Crash after intent, before known response | Attempt becomes failed/interrupted; ambiguous billable call is not auto-retried. |
| Provider | Response received, crash before guarded commit | Response remains invisible; startup fails old running attempt and preserves prior usable result. |
| Startup | Persisted prior-process `running` attempt | One transaction maps it to failed/interrupted; old fence is never resumed or renewed. |
| Startup | Persisted `running` regeneration with prior result | Prior current-usable pointer remains unchanged. |
| Startup | Persisted `pending` Job | It is the only normal claim source and gets a new immutable attempt/fence. |
| Startup | Old Agent/local worker later returns | Old attempt/fence/config/input/Paper predicates reject publication. |
| Retry | New attempt succeeds before old response | Old response cannot replace the new winner. |
| Result replacement | Regeneration fails | Prior current usable result remains. |
| Result replacement | Two regenerations finish in reverse order | Current logical regeneration plus fence wins, not completion order. |
| Credential | Crash during stage/test | Stage cannot promote; old active remains and stage is deleted/startup-cleaned. |
| Credential | Concurrent promotions | Serialized selector CAS chooses one expected-selector winner. |
| Credential | Crash after selector commit, before old cleanup | Complete new slot stays active; old slot is idempotently retireable and receives no new work. |
| Credential | Old-generation call finishes | Result cannot publish; ambiguous call is not auto-retried. |
| Template | Edit races Brief command | Command captures one immutable value-copy snapshot; payload does not read live Template. |
| Brief | Older regeneration finishes after newer success | Older result cannot move current Brief. |
| Deletion | Delete races claim/dispatch | Start transaction revokes active predicate/generation/leases/permits before cancellation; no subsequent dispatch/retry is valid. |
| Agent purge | Agent unavailable or purge fails | Paper remains deleting/failed; terminal tombstone/success is blocked and saga retries. |
| Agent purge | Already-sent external response arrives after cancel | It cannot publish or enter diagnostics; canceled correlation may not recreate retained Agent Paper state after purge acknowledgment. |
| Agent purge | App/Agent restart with orphan Paper temp | Startup purge removes attempt-keyed state; marker tests verify absence. |
| Deletion | Crash during local PDF/cache removal | Paper remains deleting/failed and same idempotent saga resumes. |
| Deletion | Crash around final cascade/tombstone | Atomic terminal transaction yields recoverable pre-terminal deletion or complete tombstone, never partial success. |
| Deletion | Restart/cache scan/same-PDF reimport | Tombstone identity stays inactive; cache is not recovery authority; reimport uses a new Paper UUID. |

## Invariant versus implementation-detail boundary

The current architecture sufficiently fixes:

- Application as sole durable and side-effect winner authority;
- immutable/non-reused Paper, attempt, fence, config, revision, snapshot, and result identities;
- claim, publication, current-result, and prior-result winner predicates;
- publication permit lifetime, revocation, drain, rollback cleanup, and no-post-tombstone rename;
- startup running-to-failed/interrupted reconciliation and no prior-fence continuation;
- SQLite visibility authority and filesystem non-reconstruction;
- complete extraction/FTS activation and pinned revision use;
- staged credential selector and stale-generation behavior;
- immutable Template snapshot/current Brief behavior;
- Agent Paper-state ownership, purge dependency, and verification boundary;
- deletion local absence, terminal transaction, tombstone, non-reentry, and non-forensic scope.

The following remain correctly deferred, not findings:

- DB tables, columns, indexes, foreign keys, migration SQL, and CAS statement form;
- fence/token encoding, lease duration, heartbeat, scheduler, Job-class policy details, and backoff;
- publication permit actor/lock and lock order implementation, staging paths, fsync/rename calls, and scavenger cadence;
- FTS schema/ranking/completeness representation and revision cleanup query;
- credential selector columns, slot naming, Agent retirement mechanics, and capability-test payload;
- Template/snapshot/result/tombstone schema and hash/version encoding;
- purge RPC fields, Agent-local retirement/drain implementation, marker instrumentation, and exact verification method;
- fault-injection harness and fixtures.

## Remaining findings and verification obligations

**No remaining architecture-level data-integrity or concurrency finding.**

The Job/cross-store gate must prove permit-held rename through commit/cleanup, revocation/drain, crash scavenging, and deadlock-free lock ordering. The startup gate must prove all prior-process running attempts fail atomically without fence reuse or prior-result loss and that each Job class follows the one pre-split recovery policy. The Provider Agent/Deletion gates and P-1/P-2 must prove marker-content absence and no post-ack recreation after success, failure, cancel, restart, app replacement, and Paper deletion on the supported OS/CPU matrix. DI-01..DI-06 fault/race tests remain mandatory.

P-5 downgrade/corruption handling is still a separate release-blocking open item and does not reopen this review.

## Final disposition

**PASS.** Two compliant implementations may differ in schema and algorithm, but the exact current draft no longer permits different publication winners, restart handling, visible extraction revisions, active credential generations, current Briefs, Agent purge completion, or deletion/tombstone outcomes.
