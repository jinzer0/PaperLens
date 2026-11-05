---
name: PaperLens disclosure-scope adversarial closure review
type: architecture-adversarial-review
date: 2026-09-01
product_authority: 'APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456'
architecture_baseline: 'APPROVED: ARCHITECTURE @ f5d488e8ff16b99ba201578e201a11d809b3f054'
candidate_status: unapproved
verdict: PASS
---

# Disclosure-Scope Amendment Adversarial Closure Review

## Verdict

**PASS.** H-01 is closed. The amended authority now normatively prohibits
introducing AD-4/AD-11 accepted limits into onboarding, Settings, deletion UI,
user-facing documentation, release material, consent, notices, or any other
user-facing disclosure surface. It separately says the false-claim constraint
does not authorize or require a disclosure surface. A documentation or release
unit can no longer add the prior voluntary `Security and Data Boundaries` surface
while obeying the authority. `ARCHITECTURE-SPINE.md:76`,
`ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:149`,
`ARCHITECTURE-SPINE.md:234`.

M-01 is correctly deferred, not open: the UX workspace remains paused until the
candidate has a new explicit architecture approval, after which it must append a
superseding authority entry before resuming and must not add an accepted-limit
disclosure surface. `.memlog.md:75`, `.memlog.md:77`.

This closes the disclosure-scope review only. The candidate remains unapproved;
existing P-1..P-6 gates remain independent implementation/release blockers.

## H-01 Retest: Literal Incompatible-Unit Counterexamples

| Independent unit | Former literal construction | Current-rule result |
| --- | --- | --- |
| Documentation | Publish a truthful public `Security and Data Boundaries` page listing plaintext-at-rest, non-revocable Provider requests, and non-forensic deletion. | **Noncompliant.** The page introduces accepted limits into user-facing documentation, expressly prohibited by AD-4, AD-11, and the shared convention. `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:149`. |
| Release | Require that same page in a release checklist while retaining arm64/x86_64 parity, signing, and license material. | **Noncompliant.** Release material is named in the prohibition; AD-13's required AGPL notices and public setup material do not authorize accepted-limit copy. `ARCHITECTURE-SPINE.md:130`, `ARCHITECTURE-SPINE.md:149`. |
| Provider | Add an inline onboarding explanation or acknowledgement because a true security fact should be disclosed. | **Noncompliant.** Onboarding and consent are named prohibited surfaces, and FR-003 already excludes a separate transfer notice and consent gate. `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:149`, `prd.md:145`. |
| UX | Add the accepted limits to Settings or deletion confirmation/progress/result/error copy while retaining normal Provider and deletion states. | **Noncompliant.** Those surfaces are expressly prohibited; required Provider status and deletion outcomes are distinct. `ARCHITECTURE-SPINE.md:118`, `SOLUTION-DESIGN.md:44`, `SOLUTION-DESIGN.md:248`. |

No literally compliant documentation, release, Provider, or UX unit can now
require or add the formerly voluntary disclosure while another omits it. The
incompatible-unit divergence is closed.

## Preserved Mandatory Boundaries

| Boundary | Adversarial retest | Result |
| --- | --- | --- |
| Internal facts and controls | Treat disclosure absence as permission to remove `0700`/`0600`, backup exclusion/reverification, fail-closed cleanup, redaction, or Agent purge. | **Blocked.** Those controls remain mandatory independently of disclosure. `ARCHITECTURE-SPINE.md:76`, `SOLUTION-DESIGN.md:275`, `SOLUTION-DESIGN.md:284`. |
| Truthful claims | Avoid the disclosure surface by claiming containment, security, revocability, or forensic erasure. | **Blocked.** The false-claim rule remains mandatory but does not supply an exception to the surface prohibition. `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:149`. |
| Deletion visibility | Omit success/failure/progress/retry because deletion limits cannot appear in the UI. | **Blocked.** Observable deletion semantics, terminal success, retry for `deleting/failed`, and no re-entry/retry for deleting/deleted Paper remain required. `prd.md:272`, `prd.md:277`, `ARCHITECTURE-SPINE.md:118`, `SOLUTION-DESIGN.md:248`. |
| Deletion safety | Publish a stale result, report success before purge/absence, or remove a reusable Template while keeping accepted limits internal. | **Blocked.** AD-6/AD-10/AD-11 keep publication, fence, purge, tombstone, and absence checks mandatory; AD-14 preserves Templates while cascading Paper snapshots/results. `ARCHITECTURE-SPINE.md:88`, `ARCHITECTURE-SPINE.md:112`, `ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:136`. |
| Provider and release topology | Relax Agent isolation, invent an unproved containment claim, or weaken release integrity because the limits are internal. | **Blocked.** AD-2, AD-13, P-1, and P-2 remain unchanged and their proof gates remain blocking. `ARCHITECTURE-SPINE.md:64`, `ARCHITECTURE-SPINE.md:130`, `ARCHITECTURE-SPINE.md:221`, `ARCHITECTURE-SPINE.md:222`. |

## M-01 Deferral Retest

The existing UX memlog correctly preserves its old-architecture blocker and does
not resume against an unapproved candidate. `../../../ux-designs/ux-PaperLens-2026-08-29/.memlog.md:37`.
The amended architecture explicitly requires the following sequence:

1. Commit the candidate and obtain a new explicit `APPROVED: ARCHITECTURE @
   <new-sha>`; prior approval does not authorize UX changes. `.memlog.md:75`,
   `ARCHITECTURE-SPINE.md:35`.
2. Only then append a superseding UX authority entry and resume UX work.
   `.memlog.md:77`.
3. The superseding entry and resumed UX must retain Provider status plus
   deletion success/failure/retry/non-reentry behavior without introducing an
   accepted-limit disclosure surface. `.memlog.md:74`, `.memlog.md:77`,
   `SOLUTION-DESIGN.md:248`.

That sequence neither treats the candidate as approved nor creates an exception
for a disclosure surface.

## Product And AD Compatibility

| Authority | Result |
| --- | --- |
| Product | **PASS.** The prohibition preserves FR-003's no-notice/no-consent boundary and does not alter FR-030/FR-031 deletion behavior or FR-035 setup/license documentation. `prd.md:145`, `prd.md:272`, `prd.md:277`, `prd.md:299`. |
| AD-2 | **PASS.** ProviderRPC and Agent isolation remain intact; no remedy grants native access to Agent storage. `ARCHITECTURE-SPINE.md:64`. |
| AD-4 | **PASS.** Internal facts, private-storage controls, residual-risk truth, and false-claim prohibition remain intact. `ARCHITECTURE-SPINE.md:76`. |
| AD-6 / AD-10 | **PASS.** Writer/publication permits, SQLite visibility, fencing, and stale-output rejection remain intact. `ARCHITECTURE-SPINE.md:88`, `ARCHITECTURE-SPINE.md:112`. |
| AD-11 / AD-14 | **PASS.** Terminal deletion behavior and Template preservation remain mandatory. `ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:136`. |
| AD-13 | **PASS.** Direct dual-artifact release, required setup/license material, and release integrity remain unchanged. `ARCHITECTURE-SPINE.md:130`. |

## Findings

### Critical

None.

### High

None. H-01 is closed by the normative surface prohibition.

### Medium

None. M-01 is correctly deferred behind explicit architecture approval and a
subsequent superseding UX authority append.

### Low

None.

## Remaining Blocking Findings

None from this closure review. Governance approval of the candidate and the
already-defined P-1..P-6 gates remain prerequisites, not unresolved
disclosure-scope findings.
