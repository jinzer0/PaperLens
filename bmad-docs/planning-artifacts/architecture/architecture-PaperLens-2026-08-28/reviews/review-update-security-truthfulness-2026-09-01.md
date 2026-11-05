---
name: PaperLens disclosure-scope security truthfulness review
type: architecture-security-review
date: 2026-09-01
product_authority: 'APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456'
architecture_baseline: 'APPROVED: ARCHITECTURE @ f5d488e8ff16b99ba201578e201a11d809b3f054'
candidate_status: unapproved
verdict: PASS
---

# Security Truthfulness Review - 2026-09-01

## Scope

This review examines the uncommitted disclosure-scope amendment in `.memlog.md`,
`ARCHITECTURE-SPINE.md`, and `SOLUTION-DESIGN.md`. It verifies that removing
accepted-limit disclosure mandates neither weakens an existing control nor
authorizes a false privacy, security, containment, revocability, deletion, or
forensic-erasure claim. It is an architecture-review result, not implementation
evidence, implementation approval, or a new security policy.

## Verdict

**PASS.** The candidate removes only the requirement to surface accepted limits
to users. The retained architecture continues to state the no-Keychain and
plaintext-at-rest boundary, security controls, Provider Agent isolation and
purge, PDFKit residual risk, non-revocable external calls, and non-forensic
APFS/external-backup boundary. It also expressly forbids the false claims that
those limits could otherwise enable.

This pass is conditioned on the existing evidence gates remaining blocking:
P-1/P-2 must still prove packaged isolation and Agent cleanup, P-3 must still
pin request/import limits, and P-4 must still decide diagnostic handling. None
is represented as completed by this amendment.

## PASS / CONCERNS / FAIL

| Assessment | Result | Evidence |
| --- | --- | --- |
| Disclosure scope is narrowed without removing security facts | **PASS** | The amendment says accepted limits are internal architecture/review facts only and creates no onboarding, Settings, deletion UI, consent, notice, documentation, or other user-facing disclosure requirement. [ARCHITECTURE-SPINE.md:76](../ARCHITECTURE-SPINE.md#L76) [ARCHITECTURE-SPINE.md:118](../ARCHITECTURE-SPINE.md#L118) |
| Product authority permits no accepted-limit disclosure surface | **PASS** | The approved product excludes a separate data-transfer notice, mandatory checkbox, and consent gate; it does not require disclosure of these accepted limits. [prd.md:145](../../../prds/prd-PaperLens-2026-08-27/prd.md#L145) [addendum.md:63](../../../prds/prd-PaperLens-2026-08-27/addendum.md#L63) [addendum.md:64](../../../prds/prd-PaperLens-2026-08-27/addendum.md#L64) |
| Controls and residual-risk limits are still architecture obligations | **PASS** | The amendment records that permissions, backup exclusion, redaction, staged promotion, deletion purge, cancellation, revocation/drain, tombstone, non-resurrection, and no-false-claim constraints remain unchanged. [.memlog.md:72](../.memlog.md#L72) [.memlog.md:73](../.memlog.md#L73) |
| Architecture truthfulness is not overstated as implementation proof | **CONCERNS** | P-1/P-2/P-3/P-4 remain unpassed gates. Their controls are retained and blocking, but executable proof is still required before the affected work or public packaging. [ARCHITECTURE-SPINE.md:221](../ARCHITECTURE-SPINE.md#L221) [ARCHITECTURE-SPINE.md:222](../ARCHITECTURE-SPINE.md#L222) [ARCHITECTURE-SPINE.md:223](../ARCHITECTURE-SPINE.md#L223) |
| Disclosure removal authorizes a weaker control or false claim | **FAIL: none** | The amendment adds explicit non-disclosure scope while preserving control text and false-claim prohibitions. [ARCHITECTURE-SPINE.md:149](../ARCHITECTURE-SPINE.md#L149) [SOLUTION-DESIGN.md:284](../SOLUTION-DESIGN.md#L284) |

## Threat / Control Preservation Matrix

| Threat or accepted limit | Preserved control or factual boundary | Amendment interpretation | Evidence |
| --- | --- | --- | --- |
| API-key exposure without Keychain or separate at-rest encryption | API key remains plaintext only in a private, backup-excluded slot; native adapter only; immutable slot/generation; failed permission or backup verification fails closed, deletes the stage, and cleanup runs at startup. | The limit remains a recorded threat boundary. Removing user disclosure does not convert plaintext storage into a secure-storage claim or relax its controls. | [ARCHITECTURE-SPINE.md:76](../ARCHITECTURE-SPINE.md#L76) [SOLUTION-DESIGN.md:266](../SOLUTION-DESIGN.md#L266) [SOLUTION-DESIGN.md:275](../SOLUTION-DESIGN.md#L275) |
| Same-user access to private secret or Agent-zone data | Private roots/descendants require `0700`; files require `0600`; backup exclusion and permissions are reverified after each write/auth flow, including SDK-created descendants. | The amendment does not remove the verification or fail-closed rule. It only removes a requirement to present the accepted limit to the user. | [ARCHITECTURE-SPINE.md:76](../ARCHITECTURE-SPINE.md#L76) [SOLUTION-DESIGN.md:275](../SOLUTION-DESIGN.md#L275) |
| Sensitive data entering logs, diagnostics, or process streams | Diagnostics use only safe projections and exclude secrets, raw URL, argv/environment, request/response, document content, and raw streams. | No disclosure wording waives redaction. P-4 remains the blocking diagnostic-policy gate. | [ARCHITECTURE-SPINE.md:64](../ARCHITECTURE-SPINE.md#L64) [ARCHITECTURE-SPINE.md:147](../ARCHITECTURE-SPINE.md#L147) [SOLUTION-DESIGN.md:275](../SOLUTION-DESIGN.md#L275) |
| Provider Agent access to app data or durable Paper content | Separate sandbox identity, no app-container/app-group sharing, no broad native access to the Agent zone, and ProviderRPC as the sole boundary; durable Paper content is prohibited in the Agent zone. | The disclosure change cannot be read as reducing isolation or permitting Paper-content retention. | [ARCHITECTURE-SPINE.md:64](../ARCHITECTURE-SPINE.md#L64) [SOLUTION-DESIGN.md:63](../SOLUTION-DESIGN.md#L63) [SOLUTION-DESIGN.md:81](../SOLUTION-DESIGN.md#L81) |
| SDK-required temporary Paper state surviving an operation or deletion | State is attempt-scoped and correlation-keyed, excluded from diagnostics, purged after terminal/cancel/startup, and purge acknowledgement/verification is required before terminal deletion success. | The amendment retains purge as a local control, not a user disclosure or an external-erasure promise. | [ARCHITECTURE-SPINE.md:64](../ARCHITECTURE-SPINE.md#L64) [ARCHITECTURE-SPINE.md:118](../ARCHITECTURE-SPINE.md#L118) [SOLUTION-DESIGN.md:184](../SOLUTION-DESIGN.md#L184) [SOLUTION-DESIGN.md:248](../SOLUTION-DESIGN.md#L248) |
| Hostile PDF compromise reaching the UI process and API-key zone | PDFium extraction remains no-network sandboxed XPC with no DB, Secrets, Caches, or arbitrary-file access; PDFKit's same-process risk remains explicitly accepted. | Removing disclosure does not authorize a PDFKit containment claim. | [ARCHITECTURE-SPINE.md:94](../ARCHITECTURE-SPINE.md#L94) [SOLUTION-DESIGN.md:65](../SOLUTION-DESIGN.md#L65) [SOLUTION-DESIGN.md:280](../SOLUTION-DESIGN.md#L280) |
| Already-sent Provider request cannot be withdrawn | Deletion prevents new dispatch, cancels queued work, prevents the sent request's response from publishing or entering diagnostics, and requires local purge/absence checks before terminal success. | The accepted non-revocability limit stays factual. It does not weaken local cancellation, containment of response visibility, or deletion behavior. | [ARCHITECTURE-SPINE.md:118](../ARCHITECTURE-SPINE.md#L118) [SOLUTION-DESIGN.md:246](../SOLUTION-DESIGN.md#L246) [SOLUTION-DESIGN.md:248](../SOLUTION-DESIGN.md#L248) |
| APFS snapshots and existing external backups are not forensically erased | The architecture continues to decline any forensic-erasure or external-Provider-erasure promise while preserving PaperLens-controlled deletion, tombstone, non-resurrection, and retry semantics. | Absence of a disclosure surface is not an erasure claim and does not change product-visible deletion success/failure behavior. | [ARCHITECTURE-SPINE.md:118](../ARCHITECTURE-SPINE.md#L118) [SOLUTION-DESIGN.md:248](../SOLUTION-DESIGN.md#L248) [SOLUTION-DESIGN.md:282](../SOLUTION-DESIGN.md#L282) |

## False-Claim Analysis

| Claim that remains prohibited | Why the amendment cannot authorize it | Preserved constraint |
| --- | --- | --- |
| Privacy-first or local-first product claim | External Provider transfer remains a product premise, and `local-first` remains an ownership pattern rather than a privacy assertion. No-disclosure scope changes neither premise. | [prd.md:327](../../../prds/prd-PaperLens-2026-08-27/prd.md#L327) [prd.md:333](../../../prds/prd-PaperLens-2026-08-27/prd.md#L333) [ARCHITECTURE-SPINE.md:29](../ARCHITECTURE-SPINE.md#L29) |
| Security or containment claim for plaintext secrets or PDFKit | Same-user malware and UI-process hostile-PDF compromise remain accepted residual risks; the design expressly forbids false privacy, security, and containment claims. | [ARCHITECTURE-SPINE.md:76](../ARCHITECTURE-SPINE.md#L76) [SOLUTION-DESIGN.md:279](../SOLUTION-DESIGN.md#L279) [SOLUTION-DESIGN.md:280](../SOLUTION-DESIGN.md#L280) |
| Claim that Provider calls are revocable after dispatch | The architecture says already-sent calls cannot be retracted. The local response-publication and diagnostic block is not revocation. | [ARCHITECTURE-SPINE.md:118](../ARCHITECTURE-SPINE.md#L118) [SOLUTION-DESIGN.md:246](../SOLUTION-DESIGN.md#L246) [SOLUTION-DESIGN.md:281](../SOLUTION-DESIGN.md#L281) |
| Claim of forensic erasure from APFS, external backups, or external Providers | The candidate keeps these limits unpromised and specifically prohibits false forensic-erasure and deletion claims. | [ARCHITECTURE-SPINE.md:118](../ARCHITECTURE-SPINE.md#L118) [ARCHITECTURE-SPINE.md:149](../ARCHITECTURE-SPINE.md#L149) [SOLUTION-DESIGN.md:282](../SOLUTION-DESIGN.md#L282) |
| Claim that local Paper deletion is weakened because limits are not disclosed | Product-visible success/failure, retry for `deleting/failed`, terminal success criteria, and no re-entry remain required; only accepted-limit UI disclosure is absent. | [.memlog.md:74](../.memlog.md#L74) [SOLUTION-DESIGN.md:243](../SOLUTION-DESIGN.md#L243) [SOLUTION-DESIGN.md:248](../SOLUTION-DESIGN.md#L248) |

## Tiered Findings

### Critical

None.

### High

None.

### Medium

None.

### Low

None.

### Informational

1. The candidate's security truthfulness depends on retaining the explicit
   no-false-claim language alongside the no-disclosure language. Removing the
   former in a later amendment would be a regression even if all controls
   remained unchanged. [ARCHITECTURE-SPINE.md:149](../ARCHITECTURE-SPINE.md#L149)
2. P-1/P-2 marker-content and negative-access proofs, P-3 shared limits, and
   P-4 diagnostic policy remain future evidence obligations, not facts proven
   by this documentation amendment. [SOLUTION-DESIGN.md:310](../SOLUTION-DESIGN.md#L310) [SOLUTION-DESIGN.md:313](../SOLUTION-DESIGN.md#L313) [SOLUTION-DESIGN.md:323](../SOLUTION-DESIGN.md#L323)

## Remediation

No corrective remediation is required for this amendment. Preserve the existing
control and truthfulness clauses in future Build Specs, UX work, release
material, and review updates. Do not add an accepted-limit disclosure surface,
separate transfer notice, or consent gate solely because these internal facts
exist; the approved product does not require one. Before affected implementation
or packaging proceeds, satisfy the already-defined P-1 through P-4 evidence
gates without representing their unproven controls as completed.
