---
name: PaperLens amended architecture rubric review
type: architecture-rubric-review
review_date: 2026-09-01
reviewed_workspace: architecture-PaperLens-2026-08-28
product_authority: 'APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456'
architecture_baseline: 'APPROVED: ARCHITECTURE @ f5d488e8ff16b99ba201578e201a11d809b3f054'
candidate_status: unapproved
verdict: PASS
---

# Amended Architecture Rubric Review - 2026-09-01

## Verdict

**PASS.** Against the BMad good-spine checklist, the candidate remains a decision-complete, enforceable initiative-level spine. The 2026-09-01 diff changes only the accepted-limit disclosure boundary: it removes no AD identity, binding, prevention, control, product-visible deletion behavior, gate, capability, or Deferred safeguard.

This is a rubric result, not an approval. The current approved architecture remains `f5d488e8ff16b99ba201578e201a11d809b3f054` until the amended candidate is locally committed and receives an explicit `APPROVED: ARCHITECTURE @ <new-sha>` record. [`.memlog.md:70-75`](../.memlog.md#L70-L75) [ARCHITECTURE-SPINE.md:31-35](../ARCHITECTURE-SPINE.md#L31-L35)

## Evidence And Review Method

- Reviewed the current [`.memlog.md`](../.memlog.md), [spine](../ARCHITECTURE-SPINE.md), [solution design](../SOLUTION-DESIGN.md), approved [PRD](../../../prds/prd-PaperLens-2026-08-27/prd.md), approved [addendum](../../../prds/prd-PaperLens-2026-08-27/addendum.md), and the BMad [good-spine checklist](../../../../../.agents/skills/bmad-architecture/references/reviewer-gate.md#L5-L13).
- Compared the candidate directly with `f5d488e8ff16b99ba201578e201a11d809b3f054`. The only substantive candidate edits are the disclosure boundary in AD-4 and AD-11, its shared convention/Deferred statement, matching solution-design wording, and six append-only memlog entries. The AD headings, P-1..P-6 rows, and all other governing text are unchanged.
- The unchanged stack remains within the prior freshness review's verified-current or explicitly gate-bounded classifications; the amendment introduces no technology, dependency, or compatibility claim. [ARCHITECTURE-SPINE.md:151-161](../ARCHITECTURE-SPINE.md#L151-L161) [review-freshness.md:13-19](review-freshness.md#L13-L19) [review-freshness.md:32-40](review-freshness.md#L32-L40)

## PASS / CONCERNS / FAIL

| Assessment | Result | Evidence |
| --- | --- | --- |
| Amendment scope is minimal | **PASS** | The memlog limits the amendment to disclosure scope and explicitly preserves product capability, ownership, security, and deletion controls. [`.memlog.md:70-74`](../.memlog.md#L70-L74) |
| Internal accepted-limit facts and controls remain | **PASS** | AD-4 retains no-Keychain/plaintext storage, private permissions, backup exclusion, verification, cleanup, and false-claim prohibition; AD-11 retains cancellation, drain, purge, terminal absence, cascade, tombstone, and non-resurrection. [ARCHITECTURE-SPINE.md:72-76](../ARCHITECTURE-SPINE.md#L72-L76) [ARCHITECTURE-SPINE.md:114-118](../ARCHITECTURE-SPINE.md#L114-L118) |
| Product-visible deletion remains | **PASS** | FR-030/FR-031 require complete non-reentry, visible incomplete/failure states, retry, and no resurrection; the companion retains the same success/failure/retry/no-reentry contract. [prd.md:272-280](../../../prds/prd-PaperLens-2026-08-27/prd.md#L272-L280) [SOLUTION-DESIGN.md:243-248](../SOLUTION-DESIGN.md#L243-L248) |
| Disclosure removal remains compatible with product | **PASS** | The approved product excludes a separate transfer notice and mandatory consent gate, while retaining the no-Keychain and external-transfer premises for architecture controls. [prd.md:142-145](../../../prds/prd-PaperLens-2026-08-27/prd.md#L142-L145) [prd.md:326-327](../../../prds/prd-PaperLens-2026-08-27/prd.md#L326-L327) [addendum.md:61-66](../../../prds/prd-PaperLens-2026-08-27/addendum.md#L61-L66) |
| AD-1..AD-14, dimensions, Deferred, and P-1..P-6 remain enforceable | **PASS** | The unchanged rules, capability map, bounded deferrals, and stated blocking gates continue to prevent independently built units from selecting incompatible owners, contracts, visibility, recovery, deletion, release, or timing behavior. [ARCHITECTURE-SPINE.md:39-136](../ARCHITECTURE-SPINE.md#L39-L136) [ARCHITECTURE-SPINE.md:198-236](../ARCHITECTURE-SPINE.md#L198-L236) |
| Candidate authority | **CONCERN - governance hold, not a spine defect** | The candidate has not replaced the SHA-addressed architecture approval. [`.memlog.md:75`](../.memlog.md#L75) |
| Weakened dimension, removed product behavior, or unsafe deferral | **FAIL: none** | No such change appears in the candidate diff or current governing text. |

## Tiered Findings

| Tier | Finding | Disposition |
| --- | --- | --- |
| Critical | None. | No remediation. |
| High | None. | No remediation. |
| Medium | None. | No remediation. |
| Low | None. | No remediation. |

### Governance Hold (Not A Tiered Architecture Finding)

The candidate cannot be treated as the approved architecture or as permission for implementation or UX work. This is an authority condition, not a defect in the spine: the memlog explicitly preserves `f5d488e` as the approval baseline until a new committed SHA receives separate approval. [`.memlog.md:70`](../.memlog.md#L70) [`.memlog.md:75`](../.memlog.md#L75)

## AD Enforceability And Stability

Each AD retains explicit `Binds`, `Prevents`, and `Rule` fields, satisfying the checklist's enforceability test. [ARCHITECTURE-SPINE.md:37-43](../ARCHITECTURE-SPINE.md#L37-L43) The amendment adds disclosure scope to AD-4 and AD-11 without changing their protected internal facts or mechanisms.

| AD | Enforceable invariant that remains stable | Evidence |
| --- | --- | --- |
| AD-1 | Application is the single durable-state and side-effect winner; features/workers/adapters cannot independently own SQLite, file lifecycle, or visible success. | [ARCHITECTURE-SPINE.md:39-43](../ARCHITECTURE-SPINE.md#L39-L43) |
| AD-2 | A separately sandboxed Agent and the sole ProviderRPC contract prevent alternate helper access, protocol, retention, and diagnostic paths. | [ARCHITECTURE-SPINE.md:60-64](../ARCHITECTURE-SPINE.md#L60-L64) |
| AD-3 | Application-owned immutable EvidenceBundle and source allowlists prevent Provider-specific retrieval, evidence, or Reader-context behavior. | [ARCHITECTURE-SPINE.md:66-70](../ARCHITECTURE-SPINE.md#L66-L70) |
| AD-4 | The no-Keychain/plaintext risk boundary still fixes storage, permissions, backup exclusion, cleanup, redaction, residual risk, and truthful claims; only a user-facing disclosure mandate is removed. | [ARCHITECTURE-SPINE.md:72-76](../ARCHITECTURE-SPINE.md#L72-L76) |
| AD-5 | Real authenticated activation, immutable slot/config identity, SQLite selection, and CAS promotion prevent false success or stale configuration publication. | [ARCHITECTURE-SPINE.md:78-82](../ARCHITECTURE-SPINE.md#L78-L82) |
| AD-6 | One database owner, permits, staging, guarded publication, visibility authority, migration ordering, and non-reconstruction prevent cross-store divergence. | [ARCHITECTURE-SPINE.md:84-88](../ARCHITECTURE-SPINE.md#L84-L88) |
| AD-7 | Separate Paper and PDF identities, HTTPS-only import validation, bounded XPC extraction, and atomic revision activation prevent inconsistent import or extraction lifecycles. | [ARCHITECTURE-SPINE.md:90-94](../ARCHITECTURE-SPINE.md#L90-L94) |
| AD-8 | One immutable anchor identity, canonical coordinate system, display transform owner, and typed failure states prevent incompatible citations/clickback. | [ARCHITECTURE-SPINE.md:96-100](../ARCHITECTURE-SPINE.md#L96-L100) |
| AD-9 | Page-ordered, bounded-parallel translation tied to canonical revisions prevents queue-order and alignment-result divergence. | [ARCHITECTURE-SPINE.md:102-106](../ARCHITECTURE-SPINE.md#L102-L106) |
| AD-10 | Immutable attempts/fences, guarded atomic publication, startup reconciliation, and explicit retry prevent duplicate winners and recovery drift. | [ARCHITECTURE-SPINE.md:108-112](../ARCHITECTURE-SPINE.md#L108-L112) |
| AD-11 | Deletion still revokes/drains work, purges Agent state, verifies absence, cascades Paper-owned records, preserves Templates, and leaves a tombstone; only disclosure of accepted limits is out of scope. | [ARCHITECTURE-SPINE.md:114-118](../ARCHITECTURE-SPINE.md#L114-L118) |
| AD-12 | Named timing events and one P-6 probe prevent teams from redefining the soft-target interval or treating it as a strict threshold. | [ARCHITECTURE-SPINE.md:120-124](../ARCHITECTURE-SPINE.md#L120-L124) |
| AD-13 | Direct dual-artifact distribution, parity, nested-code integrity, and release-lock conditions prevent release topology drift. | [ARCHITECTURE-SPINE.md:126-130](../ARCHITECTURE-SPINE.md#L126-L130) |
| AD-14 | Immutable Template versions/snapshots and a fenced current-Brief winner prevent provenance and regeneration races. | [ARCHITECTURE-SPINE.md:132-136](../ARCHITECTURE-SPINE.md#L132-L136) |

## Coverage, Dimensions, And Deferred Assessment

The initiative-level capability map traces every functional group, evidence/accuracy, local data/secrets, deletion, Jobs, and packaging to governing ADs. [ARCHITECTURE-SPINE.md:198-213](../ARCHITECTURE-SPINE.md#L198-L213) The companion makes the remaining altitude-owned dimensions explicit: executable topology, ownership, contracts, critical flows, data/upgrade, security, operational release parity, and verification. [SOLUTION-DESIGN.md:46-345](../SOLUTION-DESIGN.md#L46-L345)

No whole dimension is silent. In particular, the operational and environmental envelope is bound by the Provider Agent/XPC topology, direct Developer ID dual-artifact release, supported runtime matrix, sandbox/signing/notarization evidence, local diagnostics policy, and downgrade/corruption policy. [ARCHITECTURE-SPINE.md:60-64](../ARCHITECTURE-SPINE.md#L60-L64) [ARCHITECTURE-SPINE.md:126-130](../ARCHITECTURE-SPINE.md#L126-L130) [ARCHITECTURE-SPINE.md:219-226](../ARCHITECTURE-SPINE.md#L219-L226)

Deferred items cannot let lower-level units diverge. Protocol fields, schema, algorithms, and numeric limits are explicitly assigned to shared Build Specs after P-1..P-3; diagnostic and migration-release choices are assigned to P-4/P-5 rather than to feature teams; out-of-v1 items are prohibitions, not optional alternative implementations. [ARCHITECTURE-SPINE.md:228-236](../ARCHITECTURE-SPINE.md#L228-L236)

## Blocking Gate Retention

P-1..P-6 remain unpassed, blocking, owner-assigned gates. The candidate retains each exact stated boundary: topology proof (P-1), release/toolchain/runtime lock (P-2), shared limits (P-3), diagnostics policy (P-4), downgrade/corruption behavior (P-5), and timing probe/profile/disposition (P-6). [ARCHITECTURE-SPINE.md:215-226](../ARCHITECTURE-SPINE.md#L215-L226) Their unpassed and blocking status is also preserved in the decision history and companion gate table. [`.memlog.md:65-67`](../.memlog.md#L65-L67) [SOLUTION-DESIGN.md:304-326](../SOLUTION-DESIGN.md#L304-L326)

## Exact Remediation

No architecture-text remediation is required. Preserve the following exact boundary in all subsequent Build Specs and UX work:

1. Do not add an accepted-limit disclosure surface, separate transfer notice, or mandatory consent gate solely because the internal AD-4/AD-11 limits are recorded.
2. Do not remove or weaken the no-Keychain/plaintext facts, permissions, backup exclusion, redaction, sandboxing, staged promotion, deletion purge, cancellation, permit revocation/drain, tombstone, non-resurrection, truthful-claim, success/failure, retry, or non-reentry requirements. [`.memlog.md:71-74`](../.memlog.md#L71-L74) [SOLUTION-DESIGN.md:246-248](../SOLUTION-DESIGN.md#L246-L248) [SOLUTION-DESIGN.md:273-284](../SOLUTION-DESIGN.md#L273-L284)
3. Keep `f5d488e8ff16b99ba201578e201a11d809b3f054` as the governing approved architecture until the amended candidate is locally committed and receives explicit `APPROVED: ARCHITECTURE @ <new-sha>`; neither this PASS nor the candidate's `final` label authorizes implementation. [`.memlog.md:75`](../.memlog.md#L75) [ARCHITECTURE-SPINE.md:31-35](../ARCHITECTURE-SPINE.md#L31-L35)
