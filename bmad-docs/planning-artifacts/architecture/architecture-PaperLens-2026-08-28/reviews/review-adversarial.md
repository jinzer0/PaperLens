# Adversarial Incompatible-Unit Re-Review

## Verdict

**PASS — no remaining incompatible-unit seam found.** The exact current draft closes N-01 without reopening R-01..R-03 or former F-01..F-14. Two independently built units cannot now choose incompatible Paper-scoped writer, publication, deletion, restart, timing, identity, wire, evidence, migration, or release semantics while complying with every Rule and blocking gate literally.

This verdict reviews convergence, not implementation proof or governance approval. The architecture remains `draft`; `[ADOPTED]` and `[ASSUMPTION]` retain their documented meanings, P-1..P-6 still require their named evidence or decisions, and only an explicit `APPROVED: ARCHITECTURE @ <commit-sha>` can approve the artifact.

## Basis and method

- Reviewed [ARCHITECTURE-SPINE.md](../ARCHITECTURE-SPINE.md) AD-1..AD-14, [SOLUTION-DESIGN.md](../SOLUTION-DESIGN.md), [the memlog](../.memlog.md), N-01, prior R-01..R-03, and former F-01..F-14.
- Product baseline remains `APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456`.
- Test: construct two independently implemented units that obey every current Rule and blocking gate literally but maximize disagreement at a shared state, wire, identity, publication, lifecycle, measurement, or release seam.
- A prototype/open item counts as safe deferral only when it has an owner, required evidence or decision, and a before-boundary that prevents affected units from splitting. Feasibility failure must have explicit routing where it can invalidate the selected topology.
- Exact schemas, RPC fields, numeric limits, algorithms, actor/lock/filesystem primitives, worker counts, migration SQL, and QA fixture values remain lower-level detail only where one shared authority and a pre-split or pre-release gate prevent local variants.

## N-01 writer-permit regression

| Required invariant | Exact current authority | Hostile retest | Result |
| --- | --- | --- | --- |
| Every Paper-scoped producer needs a writer permit before first filesystem access through close/cancellation cleanup | AD-6; Solution Design 4, 6.1, 6.4, 7, 10, 11 | AD-6 covers **all** Paper-scoped filesystem producers and explicitly names import download/copy plus cache/artifact staging. The Application-owned Paper UUID/generation writer permit is required before first filesystem access and remains held through final close or cancellation cleanup. The responsibility matrix independently forbids import adapters from accessing Paper-scoped storage before the permit. A producer that opens or writes first and acquires later is text-noncompliant. | **Closed.** |
| Deletion revokes and drains writers and distinct later publication permits before namespace removal/absence | AD-6, AD-11; Solution Design 6.4–6.5, 7, 10, 11 | Writer and publication permits are distinct phases. Deletion-start atomically revokes new writer/publication permits with active predicate, generation, and leases, dispatches cancellation, drains **all** existing writers and publishers, and only then removes Paper PDF/cache namespaces and checks terminal absence. Final rename after revocation/tombstone is forbidden. A unit that checks absence while either permit class is live is text-noncompliant. | **Closed.** |
| Revoked writers remove bytes before permit release | AD-6, AD-11; Solution Design 6.1, 6.4–6.5, 10 | A revoked producer may return only typed `cancelled`/`stale` output and must remove its bytes before releasing the writer permit. Deletion cannot complete its writer drain while that permit remains held. A producer that releases first, leaves bytes, or returns a publication candidate is text-noncompliant. | **Closed.** |

### Inter-phase hostile race

A writer may close a valid stage and release its writer permit before attempting to acquire the distinct publication permit. If deletion wins in that interval, it revokes publication, drains the already-finished writer, removes the Paper UUID/generation PDF or cache namespace containing the stage, and then checks absence. The producer cannot reacquire publication authority or perform final rename. A global Paper stage outside those owned namespaces would conflict with the storage matrix and Paper UUID/generation cache identity. The writer-to-publication handoff therefore does not reopen N-01 or R-02.

Provider Agent Paper-linked temporary state remains a separate sandbox-zone lifecycle under AD-2/AD-11 and ProviderRPC purge acknowledgment/verification. P-1/P-2 marker-content evidence covers success, failure, restart, replacement, and deletion without granting the native app broad Agent-filesystem access; the main-container writer permit does not weaken or replace that boundary.

## R-01..R-03 regression

| Prior finding | Exact current authority | Hostile retest | Result |
| --- | --- | --- | --- |
| R-01 Restart recovery | AD-10; Solution Design 6.4, 10, 11 | Startup transactionally maps every prior-process `running` attempt to `failed/interrupted`, preserves the prior usable result, never resumes or renews the old fence, normally claims only `pending` Jobs, and uses one Application-pinned Job-class recovery policy. Ambiguous external dispatch still requires explicit user Retry. | **Closed.** |
| R-02 Publication after deletion | AD-6, AD-11; Solution Design 6.4–6.5 | Paper-scoped writes require a writer permit; final rename requires the distinct later publication permit held through guarded DB commit or synchronous cleanup. Deletion revokes and drains both phases before namespace removal/absence, and revoked writers or failed DB guards synchronously remove their bytes. | **Closed, including the former N-01 pre-publication variant.** |
| R-03 Timing stimulus ambiguity | AD-12, P-6; Solution Design 6.1, 10, 11 | Instrumentation starts the deterministic readiness probe immediately after first-page presentation without user input. P-6 pins exactly one navigation-or-zoom probe and completion signal across every source and both CPU artifacts before timing Build Specs split. | **Closed.** |

## Former F-01..F-14 retest

| Former finding | Revised authority | Hostile retest | Result |
| --- | --- | --- | --- |
| F-01 State and side-effect authority | AD-1, AD-6, responsibility matrix | Application alone commands durable state and filesystem effects. Feature-local ephemeral state stays local; workers/adapters return typed output, cannot mutate SQLite, and cannot decide success visibility. Writer/publication permits now also make effect lifetime Application-owned. | **Closed.** |
| F-02 ProviderRPC interoperability | AD-2, `Contracts/ProviderRPC`, P-3 | Framing, endian, JSON, handshake, correlation, one terminal response, typed errors, cancellation, bounds, method allowlist, process streams, and major mismatch are common. One pre-split contract pins exact fields and numbers. | **Closed.** |
| F-03 Agent isolation truthfulness | AD-2, AD-13, P-1/P-2 | Signed/notarized dual-architecture topology, no sharing, negative file/network checks, nested inventory, Gatekeeper launch, and Agent marker-content tests block convention-only containment claims. Infeasibility routes to PRODUCT correction. | **Closed conditionally by valid blocking prototypes.** |
| F-04 Activation and staged slots | AD-4, AD-5 | Activation requires the smallest real authenticated v1 generation request. Immutable slot/config generations, SQLite sole selection, serialized CAS, old-active retirement, startup cleanup, and permission/backup fail-closed checks reject local variants. | **Closed.** |
| F-05 Paper/content identity | AD-7, AD-8 | Paper UUID is lifecycle identity; SHA-256 is content identity and duplicate-warning key. A continued duplicate import receives a new UUID and separately owned immutable copy. | **Closed.** |
| F-06 Anchor geometry | AD-8, `Contracts/EvidenceAnchor` | CropBox, PDF points, lower-left origin, axes, quad order, rotation metadata, normalization owner, display-transform owner, and one pre-split tolerance authority are fixed. | **Closed.** |
| F-07 Extraction/FTS publication | AD-6, AD-7 | PDFium returns a typed batch and cannot own DB/FTS/cache. One inactive immutable revision becomes active transactionally; retrieval pins one revision and referenced old revisions survive. | **Closed.** |
| F-08 EvidenceBundle authority | AD-3, `Contracts/ProviderRequest`, P-3 | Application owns ordered immutable evidence and insufficiency. Adapters cannot add, remove, reorder, rerank, truncate, or reinterpret it; one pre-split contract owns source allowlists and budgets. | **Closed.** |
| F-09 Job fencing and recovery | AD-10 | Stable Job identity, immutable attempts/fences, transactional claim, durable dispatch intent, guarded publication, prior-result preservation, startup reconciliation, and one recovery-policy authority converge. | **Closed, including R-01.** |
| F-10 Deletion/tombstone | AD-6, AD-10, AD-11 | Predicate/generation/lease/permit revocation, writer and publisher drain, revoked-writer byte cleanup, Provider cancellation, Agent purge, namespace absence, terminal cascade, durable tombstone, and no reactivation converge. | **Closed, including R-02 and N-01.** |
| F-11 Template snapshots | AD-14 | Immutable Template versions, value-copied Paper snapshots, fenced regeneration ordering, snapshot-only payload/provenance, and Paper-independent Template retention reject live-FK and out-of-order winner variants. | **Closed.** |
| F-12 Named timing events | AD-12, P-6 | Start prerequisites, instrumentation-owned probe, one pre-split probe selection, completion semantics, exclusions, source coverage, CPU parity, and soft-target disposition converge. | **Closed, including R-03.** |
| F-13 Artifact parity | AD-13, P-1/P-2 | Both artifacts share source, locks, contracts, migrations, extraction contract, entitlements policy, smoke corpus/results, nested inventory, signing/notary/Gatekeeper evidence, and runtime-matrix checks. | **Closed conditionally by valid blocking prototypes.** |
| F-14 Migrations/operations | AD-6, AD-13, P-4/P-5 | One persistence-owned ordered registry and transactional forward migration are fixed. Manual replacement, no updater, and no telemetry are fixed; diagnostics and downgrade/corruption have named owners and pre-publication blockers. | **Closed by invariant plus bounded release-plan gates.** |

## AD-1..AD-14 hostile-rule result

| AD | Result |
| --- | --- |
| AD-1 | **Pass.** Durable, ephemeral, mutation, and external-effect authority are singular. |
| AD-2 | **Pass, P-1/P-2-gated.** ProviderRPC, Agent retention/purge, containment, packaging, and negative-access evidence converge. |
| AD-3 | **Pass, P-3-gated.** Provider-neutral operation, EvidenceBundle, insufficiency, ordering, disclosure, and budget authority converge before adapters split. |
| AD-4 | **Pass.** Plaintext scope, descendants, diagnostics, backup, permissions, cleanup, and accepted residual risks are explicit. |
| AD-5 | **Pass.** Real activation, sole selector, immutable generation, CAS, retirement, startup cleanup, and ambiguous-call handling converge. |
| AD-6 | **Pass.** Storage, writer lifetime, staged validation, distinct final publication, DB visibility, cleanup, migration, startup scavenging, and cache identity converge. |
| AD-7 | **Pass, P-1/P-3-gated where stated.** HTTPS import validation, Paper/content identity, process topology, extraction publication, and revision lifetime converge. |
| AD-8 | **Pass.** Anchor identity, citation range, coordinate frame, transform owner, states, and tolerance authority converge. |
| AD-9 | **Pass.** Queue order, navigation independence, canonical input, partial visibility, cache versions, and alignment uncertainty converge. |
| AD-10 | **Pass.** Fencing, publication, restart reconciliation, one pre-split recovery policy, and ambiguous external retry semantics converge. |
| AD-11 | **Pass.** Deletion revokes and drains writer/publication phases before namespace removal/absence, requires revoked-writer byte cleanup, purges Agent state, cascades content, and preserves only the stated limits. |
| AD-12 | **Pass, P-6-gated.** Named events and one instrumentation-owned readiness probe/completion signal converge before timing units split. |
| AD-13 | **Pass, P-1/P-2-gated.** Channel, update boundary, runtime matrix, parity, nested integrity, provenance, licensing, and dual-artifact evidence converge. |
| AD-14 | **Pass.** Template, snapshot, regeneration, result-winner, provenance, and deletion ownership converge. |

## Prototype and open-item truthfulness

| Gate | Hostile result |
| --- | --- |
| P-1 | **Valid blocking prototype.** Named owners, pre-implementation boundary, signed dual-architecture topology, negative access, no sharing, nested inventory, Gatekeeper launch, and Agent marker-content absence/purge are explicit. Failure cannot silently remove the launch-blocking Provider mode. |
| P-2 | **Valid pre-split release gate.** Exact tool/runtime/dependency locks and the OS/CPU matrix must prove DB migration, FTS5, and packaged Agent cleanup before helper/CI/persistence/public-packaging units split. |
| P-3 | **Valid pre-split shared-contract gate.** Application, Provider, and Import/PDF jointly pin operation/source allowlists and numeric Provider/import/parser ceilings before affected implementations split. |
| P-4 | **Valid bounded release-plan decision.** Application/Release own local diagnostic location, retention, export, redaction, and deletion before public packaging; telemetry remains forbidden. |
| P-5 | **Valid bounded release-plan decision.** Persistence/Release own downgrade, incompatible-schema, and corruption fail-closed behavior before a schema-bearing public release. |
| P-6 | **Valid pre-split timing gate.** QA/Architecture pin one automated probe, completion signal, fixtures, source criteria, and exceedance disposition before instrumentation Build Specs split and before the release QA plan. |

## Remaining findings

None. The hostile pass did not find a pair of literally compliant lower-level implementations that can diverge at a boundary the current architecture owns.

## Safe lower-level deferrals

Exact writer/publication actor, lock, and filesystem primitives; ProviderRPC method fields; Agent purge transport details; numeric Provider/import/parser limits; FTS ranking; prompt text; sentence segmentation; geometry algorithm/tolerance value; scheduler/backoff/lease duration; Translation worker count; full schema/migration SQL; diagnostic policy values; downgrade/corruption disposition; runtime lock values; and QA fixture/profile values remain safely deferred. Each has a sole owner and a pre-split or pre-release gate, so lower-level units cannot choose independent semantics without violating the current draft.

## Review result

No architecture wording change is required by this adversarial incompatible-unit review. The next actions are the existing governance approval decision and, if approved, execution of the named P-1..P-6 gates at their documented boundaries.
