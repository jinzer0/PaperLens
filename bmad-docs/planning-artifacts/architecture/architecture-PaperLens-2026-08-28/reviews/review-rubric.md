# Architecture Spine Reviewer Gate

- Review date: 2026-08-28
- Reviewed workspace: `architecture-PaperLens-2026-08-28`
- Scope: exact current `ARCHITECTURE-SPINE.md`, with `SOLUTION-DESIGN.md`, `.memlog.md`, the approved PRD and addendum, both reconciliation reports, and repository governance as evidence
- Rubric: `.agents/skills/bmad-architecture/references/reviewer-gate.md`

## Verdict

**Tier 3 - PASS**

The current spine is compact, decision-complete at the architectural level, and suitable to govern downstream Build Specs. It preserves the approved product requirements, assigns one owner to each state class and mutation boundary, defines the important failure and recovery contracts, and converts unresolved implementation facts into bounded, owner-assigned gates.

No Critical, High, Medium, or Low good-spine defect remains in the exact current draft. P-1 through P-6 are safe blocking prototypes or release gates, not silent architecture deferrals.

This is a reviewer-gate result only. It is not `APPROVED: ARCHITECTURE`, `APPROVED: IMPLEMENTATION`, or `APPROVED: MERGE` under `docs/ai-governance.md`.

## 1. Evidence And Baseline

The canonical product baseline remains the final PRD and addendum identified by `APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456`. The review did not treat file dates, chat history, `[ADOPTED]` labels, or prior reviewer output as approval evidence.

The exact current architecture evidence is:

- `ARCHITECTURE-SPINE.md:1-387`
- `SOLUTION-DESIGN.md:1-362`
- `.memlog.md:1-62`
- `reviews/reconcile-prd.md:1-40`
- `reviews/reconcile-addendum.md:1-40`

The current spine linter reports zero findings.

## 2. Historical Finding Closure

All previously reported Critical and High findings remain closed in the current text.

| Prior concern | Current closure | Result |
|---|---|---|
| Provider fallback or direct-SQL mutation ambiguity | AD-2 makes `ProviderRPC` the sole App-to-Agent boundary and forbids Swift-side mutation of Agent-owned stores; AD-3 assigns one writer per database | Closed |
| Secret handoff, slot rollback, and active-slot mutation ambiguity | AD-4 defines one-time handoff, Keychain-only persistence, pre-activation health checks, atomic promotion, and immutable `active`/`warming` slots | Closed |
| Paper deletion could race readers, jobs, or Agent residue | AD-11 requires `deleting`, rejection of new work, cancellation, reader/writer closure, durable artifact deletion, Agent purge acknowledgement, catalog mutation, and terminal `deleted` | Closed |
| PDF coordinate or rendering authority was split | AD-5 makes PDFKit page-space canonical and makes rendered pixels authoritative for hit-testing and clipping | Closed |
| Catalog publication could race RAG visibility | AD-6 and AD-10 require a fence-bound publication permit after canonical result commit and before catalog mutation | Closed |
| Import double-add, replacement, and partial-file cleanup were underspecified | AD-7 defines one import state machine, pre-persistence identity, same-source conflict semantics, one temp file, atomic move, and cleanup behavior | Closed |
| Job cancellation, blank cancellation, lease renewal, and restart convergence were incomplete | AD-2, AD-6, and AD-10 define acknowledged Provider cancellation, Job fences, bounded renewals, startup convergence, and new-attempt rules | Closed |
| Provider-side Paper data could become durable residue | AD-2 prohibits durable Paper content, prompts, excerpts, answers, and embeddings in the Agent zone and requires purge acknowledgement plus marker tests | Closed |
| URL import allowed downgrade ambiguity | AD-7 now admits HTTPS only and never follows HTTPS-to-HTTP redirects | Closed |
| Interactive timing could pass through manual think time | AD-12, AD-13, and P-6 require deterministic post-trigger probes with a fixed trigger-to-probe interval | Closed |

The named follow-ups are also closed:

| ID | Required closure | Current evidence | Result |
|---|---|---|---|
| M-R1 | Pin the exact macOS matrix for Python SDK compatibility | P-2 names current macOS 14.6 and macOS 15 runners, with a bounded earliest-supported-runner fallback when current macOS 15 CI is unavailable | Closed |
| L-R1 | Assign an explicit owner for numeric ProviderRPC budgets | P-3 assigns the Application/Agent integration owner and requires numeric timeout, retry, in-flight, payload, and ping thresholds before Agent split | Closed |
| L-R2 | State whether staged environments may mutate after activation | AD-4 and the companion slot lifecycle prohibit package or configuration mutation in `active` and `warming`; package installation is restricted to `staging` | Closed |

## 3. Good-Spine Rubric

### 3.1 Scale And Resilience

**Pass.** AD-1 defines Paper-local ownership and per-Paper writer serialization. AD-3 isolates catalog, Paper, and Agent stores. AD-6, AD-8, AD-9, and AD-10 bound concurrent work through fences, backpressure, bounded queues, coalescing, and explicit Job states. AD-12 converts performance expectations into measurable gates rather than architectural promises.

The architecture avoids premature distributed-system machinery while retaining the invariants needed for a local-first single-user application.

### 3.2 Failure And Recovery

**Pass.** Failure behavior is explicit at every irreversible boundary:

- Import uses attempt-scoped temporary files and atomic finalization.
- Jobs use durable states, leases, fencing tokens, bounded renewal, and startup convergence.
- Provider cancellation waits for acknowledgement and purges attempt-scoped state.
- Catalog publication is gated by canonical result commit and fence validation.
- Environment updates use staged slots, health checks, atomic activation, and rollback.
- Paper deletion is a terminal, restart-safe workflow rather than a best-effort cascade.

### 3.3 Understandability And Decision Density

**Pass.** AD-1 through AD-14 each state one governing decision, its invariant, and its consequence. The companion supplies protocol and state-machine detail without replacing the spine. Build Spec work can derive ownership, mutation order, cancellation, recovery, and gate placement without inventing a competing architecture.

### 3.4 Constraint Adherence

**Pass.** The current draft preserves the approved product baseline:

- local-first Paper ownership and deletion semantics;
- SwiftUI/PDFKit native interaction;
- arXiv and general PDF URL import;
- local SQLite-backed state;
- explicit user-controlled AI behavior;
- direct CLI and SDK use rather than an unapproved broker service;
- App Sandbox, Keychain, and hardened-runtime constraints;
- performance requirements represented as measurable gates.

HTTPS-only generic URL import is an architecture-level transport safety boundary, not a domain restriction: arbitrary non-arXiv HTTPS PDF sources remain supported, and the approved baseline does not require insecure HTTP transport.

### 3.5 Contradiction Detection

**Pass.** No unresolved contradiction remains between the current spine, companion, approved product baseline, addendum, and governance policy.

The product reconciliation report still uses the older phrase `HTTP(S)` and older line counts. The exact current review independently checked AD-7's HTTPS-only rule against the approved requirements; the stale wording is evidence-maintenance drift, not a spine contradiction or an authorization to edit the reconciliation artifact in this scoped task.

### 3.6 Testability

**Pass.** The architecture exposes deterministic acceptance surfaces for:

- importer identity, replacement, redirect, partial-file, and cleanup behavior;
- ProviderRPC method, cancellation, retention, and cross-OS compatibility contracts;
- Job fencing, renewal, restart, and stale-result rejection;
- deletion ordering and Agent purge acknowledgement;
- slot activation and rollback;
- OCR/RAG and timing gates;
- catalog publication ordering and ghost-result prevention.

Each unresolved empirical fact has a named owner, deadline, fixture or marker expectation, and blocking consequence.

### 3.7 Version And Dependency Plausibility

**Pass.** The selected stack is coherent with the deployment target and architecture boundaries. The spine records verified references for macOS 14.6, Xcode 16.4, Swift 6.1.2, PDFKit/Vision, GRDB 7.7.1, Python 3.12, Pydantic 2.12.5, and Codex SDK 0.1.0. P-1 and P-2 correctly prevent the least-certain SDK and packaging facts from becoming implementation assumptions.

## 4. Decision And Dimension Coverage

AD-1 through AD-14 cover the required spine surfaces:

| Surface | Governing decisions |
|---|---|
| Paper ownership and lifecycle | AD-1, AD-11 |
| App/Agent boundary and privacy | AD-2, AD-3 |
| Secrets and environment lifecycle | AD-4 |
| PDF rendering and coordinates | AD-5 |
| Background work, publication, and recovery | AD-6, AD-8, AD-9, AD-10 |
| Import semantics | AD-7 |
| Performance and measurement | AD-12, AD-13 |
| Testing and acceptance | AD-14 |

The owned-dimensions table assigns one owner to Security, Data Ownership, Failure Semantics, Compatibility, Scalability, and Deployment/Recovery. No required dimension is left ownerless.

## 5. Prototype And Open-Item Safety

| Item | Why it is safe | Result |
|---|---|---|
| P-1 | Blocks implementation until the ProviderRPC spike proves lifecycle, cancellation, helper-process, retention, and SDK surface contracts | Safe blocking prototype |
| P-2 | Blocks implementation until the exact macOS 14.6/15 matrix proves slot execution, path handling, cleanup, and no Paper-data retention | Safe blocking prototype |
| P-3 | Blocks the Agent split until the integration owner commits numeric protocol and flow-control limits | Safe blocking gate |
| P-4 | Blocks semantic-RAG implementation until OCR/embedding fixtures prove the quality threshold | Safe blocking prototype |
| P-5 | Blocks model-enabled release until supported models and release gates are approved and tested | Safe release gate |
| P-6 | Blocks timing instrumentation until a deterministic trigger, probe, interval, fixture, and threshold are fixed | Safe measurement gate |

The Deferred section contains UI wording and preference-policy choices only. Those items do not alter ownership, mutation order, security boundaries, failure semantics, or downstream implementation safety.

## 6. Remaining Findings

No remaining Critical, High, Medium, or Low architecture findings.

Non-blocking process observation: refresh `reviews/reconcile-prd.md` in a separately authorized artifact-maintenance step so its `HTTP(S)` wording and line counts describe the exact current spine. This does not change the reviewer-gate verdict.

## 7. Final Gate

**PASS - Tier 3.** The exact current AD-1 through AD-14 draft satisfies the good-spine rubric and is ready for human architecture review. Subsequent implementation still requires the repository's governed Story/Issue/branch/PR work unit, a committed Build Spec, and explicit `APPROVED: IMPLEMENTATION` for that Build Spec SHA.
