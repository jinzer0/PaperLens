# Deletion Integrity Preservation Review

- Review date: 2026-09-01
- Scope: the uncommitted disclosure-scope amendment in [`.memlog.md`](../.memlog.md), [`ARCHITECTURE-SPINE.md`](../ARCHITECTURE-SPINE.md), and [`SOLUTION-DESIGN.md`](../SOLUTION-DESIGN.md), tested against the final product deletion contract.
- Question: whether making AD-4/AD-11 accepted limits internal-only removed any deletion data-integrity invariant or required product-visible deletion behavior.

## Verdict

**PASS.** The amendment changes only the disclosure scope of accepted limits. It preserves the AD-6 writer/publication permit boundary, AD-10 fenced publication and stale-result rejection, AD-11 cancellation/deletion saga, and AD-14 Template ownership. It also explicitly preserves confirmation, progress, success/failure, retry, and no-reentry semantics without requiring forensic APFS/external-backup erasure or external Provider erasure.

## PASS / CONCERNS / FAIL

| Assessment | Result | Evidence |
| --- | --- | --- |
| Amendment boundary | **PASS** | The amendment is constrained to disclosure scope and expressly retains deletion purge, cancellation, permit revocation/drain, tombstone, non-resurrection, and product-visible deletion behavior. [`.memlog.md:70`](../.memlog.md#L70) [`.memlog.md:73-74`](../.memlog.md#L73) |
| AD-6 writer and publication permits | **PASS** | Every Paper-scoped filesystem producer must hold a Paper UUID/generation writer permit before its first access through close or cancellation cleanup. The distinct publication permit is held through guarded commit or synchronous cleanup; tombstones prohibit final rename and SQLite remains the visibility authority. [`ARCHITECTURE-SPINE.md:88`](../ARCHITECTURE-SPINE.md#L88) [`SOLUTION-DESIGN.md:220-222`](../SOLUTION-DESIGN.md#L220) |
| AD-10 cancellation fencing and stale results | **PASS** | Immutable attempts/fences and a guarded transaction require a current running attempt, input/config/Paper generation before publication. Stale output changes no state, result, or cache visibility; prior-process attempts become `failed/interrupted` without fence renewal. [`ARCHITECTURE-SPINE.md:112`](../ARCHITECTURE-SPINE.md#L112) [`SOLUTION-DESIGN.md:216-218`](../SOLUTION-DESIGN.md#L216) |
| AD-11 cancellation, drain, Agent purge, and terminal absence | **PASS** | Deletion atomically revokes the active predicate, generation, leases, and new writer/publication permits, cancels queued correlations, drains writers/publishers, then requires Agent purge acknowledgment/verification, PDF/cache absence, and terminal cascade. [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:234-248`](../SOLUTION-DESIGN.md#L234) |
| Retry and terminal-state separation | **PASS** | Pending/running attempts become non-retryable `failed/paperDeleting`; no retry or re-entry is exposed for deleting/deleted Papers. Only an incomplete `deleting/failed` saga is retried, and it cannot report terminal success before the required purge and absence checks. [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:246-248`](../SOLUTION-DESIGN.md#L246) |
| Tombstone and non-resurrection | **PASS** | The terminal transaction leaves a durable, contentless tombstone; import, recovery, and cache scan cannot reactivate its identity, and a later import receives a new Paper UUID. [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:248`](../SOLUTION-DESIGN.md#L248) |
| Template preservation | **PASS** | Reusable Templates are Paper-independent immutable aggregates. Deletion cascades the Paper-bound snapshot/results, but not the Template aggregate/version. [`ARCHITECTURE-SPINE.md:136`](../ARCHITECTURE-SPINE.md#L136) [`SOLUTION-DESIGN.md:252-254`](../SOLUTION-DESIGN.md#L252) |
| Product-visible deletion behavior | **PASS** | The product still requires deletion confirmation, complete removal/no re-entry after restart, Template preservation, and visible incomplete-failure plus retry behavior. [`prd.md:272-280`](../../../prds/prd-PaperLens-2026-08-27/prd.md#L272) [`prd.md:351`](../../../prds/prd-PaperLens-2026-08-27/prd.md#L351) The solution design retains success/failure, retry for `deleting/failed`, and no retry/re-entry for deleting/deleted Papers. [`SOLUTION-DESIGN.md:234`](../SOLUTION-DESIGN.md#L234) [`SOLUTION-DESIGN.md:243-248`](../SOLUTION-DESIGN.md#L243) |
| Accepted-limit disclosure removal | **PASS** | Already-sent external-request non-revocability and APFS/external-backup limits need not appear in deletion confirmation, progress, result, or error UI. That exemption is explicitly paired with retained observable success/failure, retry, and no-reentry behavior. [`SOLUTION-DESIGN.md:248`](../SOLUTION-DESIGN.md#L248) |
| Required forensic or external erasure | **CONCERNS: none** | The contract correctly does not promise APFS snapshot/external-backup forensic erasure or external Provider erasure. Those limits do not weaken local cancellation, purge, absence, terminal-cascade, or truthfulness requirements. [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:248`](../SOLUTION-DESIGN.md#L248) |
| Deleted integrity invariant or observable deletion outcome | **FAIL: none** | The diff adds disclosure-boundary text and does not remove the deletion saga or product contract. [`.memlog.md:70-75`](../.memlog.md#L70) [`ARCHITECTURE-SPINE.md:88,112,118,136`](../ARCHITECTURE-SPINE.md#L88) [`SOLUTION-DESIGN.md:246-254`](../SOLUTION-DESIGN.md#L246) |

## Race And Failure Matrix

| Race or failure | Required outcome | Preserved evidence |
| --- | --- | --- |
| Delete begins before a producer obtains a writer or publication permit | Revocation prevents new Paper-scoped filesystem access and final rename; no new result can become visible. | [`ARCHITECTURE-SPINE.md:88`](../ARCHITECTURE-SPINE.md#L88) [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) |
| Revocation wins while a writer is active | The writer returns only typed `cancelled`/`stale`, removes its bytes, then releases its permit; its output never publishes. | [`ARCHITECTURE-SPINE.md:88`](../ARCHITECTURE-SPINE.md#L88) [`SOLUTION-DESIGN.md:220`](../SOLUTION-DESIGN.md#L220) [`SOLUTION-DESIGN.md:246`](../SOLUTION-DESIGN.md#L246) |
| Delete races a publisher that already holds its permit | Deletion drains the publisher before namespace removal/terminal absence; a failed guarded DB commit synchronously removes the final artifact. | [`ARCHITECTURE-SPINE.md:88`](../ARCHITECTURE-SPINE.md#L88) [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:222`](../SOLUTION-DESIGN.md#L222) |
| Late worker, Agent, or previous-process attempt returns | Attempt/fence/input/config/Paper-generation predicates reject the stale result; it cannot alter state, result, cache, or the current usable pointer. | [`ARCHITECTURE-SPINE.md:112`](../ARCHITECTURE-SPINE.md#L112) [`SOLUTION-DESIGN.md:216-218`](../SOLUTION-DESIGN.md#L216) |
| Delete races Job claim or Provider dispatch | The start transaction revokes the active predicate/generation/leases/permits, cancels queued correlation IDs, and prohibits subsequent Provider dispatch. | [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:235-246`](../SOLUTION-DESIGN.md#L235) |
| Already-sent Provider response arrives after cancellation | The external request is not retractable, but its response neither publishes nor enters diagnostics; no durable Paper-linked Agent content may be recreated after purge. | [`ARCHITECTURE-SPINE.md:64`](../ARCHITECTURE-SPINE.md#L64) [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:184`](../SOLUTION-DESIGN.md#L184) [`SOLUTION-DESIGN.md:246-248`](../SOLUTION-DESIGN.md#L246) |
| Agent is unavailable or purge fails | Terminal success is blocked. The Paper remains `deleting/failed`, and the same idempotent saga is retryable without broad native-app access to the Agent filesystem. | [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:248`](../SOLUTION-DESIGN.md#L248) |
| Failure during namespace removal or terminal cascade | The saga remains recoverable rather than reporting partial deletion as success; terminal success requires the terminal DB cascade and durable tombstone. | [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`prd.md:277-280`](../../../prds/prd-PaperLens-2026-08-27/prd.md#L277) |
| Restart, cache scan, recovery, or same-content reimport after terminal deletion | Filesystem/cache state never reconstructs the Paper; the tombstone identity stays inactive and a later import uses a new UUID. | [`ARCHITECTURE-SPINE.md:88`](../ARCHITECTURE-SPINE.md#L88) [`ARCHITECTURE-SPINE.md:118`](../ARCHITECTURE-SPINE.md#L118) [`SOLUTION-DESIGN.md:222`](../SOLUTION-DESIGN.md#L222) [`SOLUTION-DESIGN.md:248`](../SOLUTION-DESIGN.md#L248) |
| Template edit or Brief regeneration overlaps deletion | Paper-owned snapshots/results cascade, while the independent Template aggregate/version survives; a stale regeneration cannot move the current Brief. | [`ARCHITECTURE-SPINE.md:112`](../ARCHITECTURE-SPINE.md#L112) [`ARCHITECTURE-SPINE.md:136`](../ARCHITECTURE-SPINE.md#L136) [`SOLUTION-DESIGN.md:252-254`](../SOLUTION-DESIGN.md#L252) |

## Tiered Findings

| Tier | Finding | Remediation |
| --- | --- | --- |
| Critical | None. | None. |
| High | None. | None. |
| Medium | None. | None. |
| Low | None. | None. |
| Verification obligation | The architectural invariants are preserved, but the existing P-1/P-2 and deletion/Job Build Spec gates still require marker-content purge, cancellation, permit-drain, absence, tombstone, and fault/race proof before implementation is cleared. | Keep those gates blocking; exercise the race matrix without adding accepted-limit disclosure, forensic erasure, or external Provider-erasure requirements. [`ARCHITECTURE-SPINE.md:221-222`](../ARCHITECTURE-SPINE.md#L221) [`SOLUTION-DESIGN.md:318-320`](../SOLUTION-DESIGN.md#L318) |

## Remediation

No amendment remediation is needed. Future Build Specs and UX must preserve the complete local deletion contract: confirmation; progress; success or visible incomplete/failure; retry only for `deleting/failed`; no retry or re-entry once deleting/deleted; cancellation; writer/publication revocation and drain; Agent purge acknowledgment/verification; terminal absence; contentless tombstone; stale-result fencing; Template preservation; and no resurrection. Do not introduce an accepted-limit disclosure requirement, forensic-erasure promise, or external Provider-erasure requirement. [`SOLUTION-DESIGN.md:234-248`](../SOLUTION-DESIGN.md#L234) [`SOLUTION-DESIGN.md:252-254`](../SOLUTION-DESIGN.md#L252)
