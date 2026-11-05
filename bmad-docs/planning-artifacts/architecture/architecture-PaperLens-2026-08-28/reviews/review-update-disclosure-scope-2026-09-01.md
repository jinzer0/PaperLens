# Disclosure-Scope Amendment Review

- Review date: 2026-09-01
- Scope: the current `.memlog.md`, `ARCHITECTURE-SPINE.md`, and `SOLUTION-DESIGN.md` in this workspace, including the uncommitted 2026-09-01 disclosure-scope amendment.
- Question: whether every mandate to disclose the accepted AD-4/AD-11 limits to users was removed without removing the internal facts, controls, product-visible deletion behavior, or truthful-claim boundaries.

## Verdict

**PASS.** The amended architecture removes user-facing disclosure mandates for the accepted no-Keychain/plaintext-at-rest, already-sent external-request, and APFS/existing-backup non-forensic-erasure limits. It explicitly retains those limits as internal architecture/review facts, retains their controls and observable deletion behavior, and still forbids contradictory privacy, security, containment, revocability, forensic-erasure, and deletion claims.

## PASS / CONCERNS / FAIL

| Assessment | Result | Evidence |
| --- | --- | --- |
| AD-4 accepted-limit disclosure mandate removed | **PASS** | `ARCHITECTURE-SPINE.md:76` makes the limit internal and says it creates no onboarding, Settings, deletion UI, consent, notice, documentation, or other user-facing disclosure requirement. |
| AD-11 accepted-limit disclosure mandate removed | **PASS** | `ARCHITECTURE-SPINE.md:118` applies the same boundary to already-sent requests and APFS/external-backup limits. |
| Separate transfer notice or consent gate absent | **PASS** | `.memlog.md:46`, `ARCHITECTURE-SPINE.md:234`, and `SOLUTION-DESIGN.md:44` keep a separate data-transfer notice and mandatory consent gate outside v1. |
| Deletion UI does not have to disclose accepted limits | **PASS** | `SOLUTION-DESIGN.md:248` excludes the non-revocability and APFS/backup limits from deletion confirmation, progress, result, and error UI while retaining visible deletion outcomes. |
| Internal facts and controls retained | **PASS** | `.memlog.md:72-74`, `ARCHITECTURE-SPINE.md:76,118`, and `SOLUTION-DESIGN.md:246,275-284` retain the facts, sandboxing, permissions, backup exclusion, redaction, purge, cancellation, revocation/drain, tombstone, and non-resurrection rules. |
| Truthful-claim boundary retained | **PASS** | `.memlog.md:73`, `ARCHITECTURE-SPINE.md:76,118,149`, and `SOLUTION-DESIGN.md:44,284` continue to prohibit contradictory false claims. |
| Contradictory user-facing disclosure requirement | **CONCERNS: none** | No scanned clause requires presenting an AD-4/AD-11 accepted limit to a user. |
| Removed internal control or truth boundary | **FAIL: none** | The amendment adds a disclosure-scope boundary; it does not delete the underlying facts, controls, or claim constraints. |

## Exhaustive Surface Scan

The table covers every current occurrence relevant to onboarding, Settings, deletion UI, consent, notice(s), documentation, disclosure, `hide`/`숨기`, accepted limits, false claims, and transfer boundaries in the three in-scope authorities. Internal architecture/review documentation is intentionally retained; it is not a user-facing product disclosure merely because it records a limit.

| Surface | Current clauses | Audit result |
| --- | --- | --- |
| Onboarding and Settings | `.memlog.md:71`; `ARCHITECTURE-SPINE.md:76,118,149`; `SOLUTION-DESIGN.md:44` | Each says the accepted limits create no onboarding or Settings requirement. |
| Deletion UI | `.memlog.md:71,74`; `ARCHITECTURE-SPINE.md:76,118,149`; `SOLUTION-DESIGN.md:44,248` | No accepted-limit disclosure is required in deletion UI. Confirmation, progress, incomplete/failed state, retry, terminal success, and non-reentry remain required product behavior. |
| Consent and transfer notice | `.memlog.md:46,71`; `ARCHITECTURE-SPINE.md:76,118,149,234`; `SOLUTION-DESIGN.md:44,369` | A separate data-transfer notice and mandatory consent gate are explicit v1 non-goals; no replacement gate appears. |
| Notice(s) | `ARCHITECTURE-SPINE.md:76,118,149,234`; `SOLUTION-DESIGN.md:44` | All accepted-limit notice references deny a user-facing requirement. `ARCHITECTURE-SPINE.md:130` requires AGPL notices only; that licensing obligation is unrelated to the accepted limits and is not a contradiction. |
| Documentation | `.memlog.md:71`; `ARCHITECTURE-SPINE.md:76,118,149`; `SOLUTION-DESIGN.md:44` | No user-facing documentation disclosure is mandated. The retained memlog, spine, and solution-design facts are internal architecture/review documentation, which the amendment expressly permits. |
| Disclosure | `ARCHITECTURE-SPINE.md:69,149,234`; `SOLUTION-DESIGN.md:369` | `ARCHITECTURE-SPINE.md:69` concerns Provider-operation consistency, not a user disclosure surface. The remaining occurrences make accepted-limit disclosure a non-goal. |
| `hide` / `숨기` | No current match in the three in-scope authorities | The prior instruction not to hide the limits has been removed; no concealment requirement was introduced. The governing boundary is absence of a mandatory user-facing surface, not removal of internal facts. |
| Accepted limits | `.memlog.md:71-73`; `ARCHITECTURE-SPINE.md:76,118,149`; `SOLUTION-DESIGN.md:273-284,369` | The plaintext-at-rest, non-revocable external-request, and non-forensic-erasure facts remain internally documented and explicitly do not create user-facing disclosure work. |
| False claims | `.memlog.md:73`; `ARCHITECTURE-SPINE.md:76,118,149`; `SOLUTION-DESIGN.md:44,284,369` | Truthful non-contradictory claims remain mandatory without converting the internal facts into a disclosure mandate. |

## Retention Check

| Retained item | Evidence |
| --- | --- |
| No Keychain or separate at-rest encryption; API key plaintext-at-rest in the controlled private zone | `.memlog.md:72`; `ARCHITECTURE-SPINE.md:76`; `SOLUTION-DESIGN.md:266,275,279` |
| Already-sent Provider requests cannot be revoked; their responses cannot publish or enter diagnostics | `.memlog.md:72`; `ARCHITECTURE-SPINE.md:118`; `SOLUTION-DESIGN.md:246,248,281` |
| APFS snapshots and existing external backups are not forensically erased | `.memlog.md:72`; `ARCHITECTURE-SPINE.md:118`; `SOLUTION-DESIGN.md:248,282` |
| Protection and deletion controls remain mandatory | `.memlog.md:73`; `ARCHITECTURE-SPINE.md:64,76,88,118`; `SOLUTION-DESIGN.md:246,248,275,284` |
| Product-visible deletion behavior remains mandatory | `.memlog.md:74`; `ARCHITECTURE-SPINE.md:118`; `SOLUTION-DESIGN.md:243,246,248` |

## Findings By Severity

| Severity | Finding | Remediation |
| --- | --- | --- |
| Critical | None. | None. |
| High | None. | None. |
| Medium | None. | None. |
| Low | None. | None. |

## Remediation

No remediation is needed. Keep future Build Specs and UX work aligned with this boundary: do not introduce an accepted-limit disclosure surface, separate transfer notice, or consent gate solely for these internal facts; do retain the stated controls, product-visible deletion outcomes, and prohibition on contradictory claims.
