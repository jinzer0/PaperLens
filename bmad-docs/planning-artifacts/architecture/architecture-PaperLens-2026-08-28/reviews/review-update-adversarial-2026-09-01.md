---
name: PaperLens disclosure-scope amendment adversarial review
type: architecture-adversarial-review
date: 2026-09-01
product_authority: 'APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456'
architecture_baseline: 'APPROVED: ARCHITECTURE @ f5d488e8ff16b99ba201578e201a11d809b3f054'
candidate_status: unapproved
verdict: CONCERNS
---

# Disclosure-Scope Amendment Adversarial Review

## Verdict

**CONCERNS.** The amendment preserves the internal security, deletion, and
truthfulness invariants: a literally compliant Provider, deletion, or security
unit cannot remove controls, hide product-required deletion state, or make a
false security/deletion claim. It does not yet prove the requested absence of
all user-facing accepted-limit disclosure surfaces. The new convention says
the facts create no disclosure *requirement*, rather than prohibiting a unit
from independently adding a true, voluntary disclosure surface.

This is a candidate-architecture review only. It is not architecture approval,
implementation approval, or permission to resume the blocked UX work.

## Method And Oracle

- Test: build independent Provider, UX, deletion, security, documentation, and
  release units that obey every amended Rule literally, then maximize divergence
  at disclosure, deletion visibility, controls, and public claims.
- The accepted facts are internal: no Keychain or separate at-rest encryption,
  plaintext API-key material in the private zone, already-sent Provider requests
  not revocable locally, and no forensic erasure of APFS/existing backups.
  `.memlog.md:71`, `.memlog.md:72`.
- Product still forbids a separate transfer notice, mandatory checkbox, and
  consent gate; requires observable complete/incomplete deletion with retry; and
  requires public Provider setup and license information. `prd.md:145`,
  `prd.md:272`, `prd.md:277`, `prd.md:299`.

## Independently Built Unit Test

| Unit | Literally compliant construction | Hostile divergence attempt | Result |
| --- | --- | --- | --- |
| Provider | Show only supported Provider choices, connection status, real-request success/failure, and retry. Keep Agent state behind ProviderRPC and avoid an accepted-limit surface. `ARCHITECTURE-SPINE.md:64`, `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:82`. | Require an onboarding warning or acknowledgement because plaintext-at-rest risk must be disclosed. That derives a user-facing disclosure requirement from an accepted limit, violating the amended convention and FR-003. `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:149`, `prd.md:145`. | **PASS.** A mandatory Provider disclosure is noncompliant. |
| UX | Omit accepted-limit copy from onboarding, Settings, deletion confirmation/progress/result/error, while showing Provider status and the product-required deletion success, incomplete/failed state, retry, and no-re-entry outcome. `SOLUTION-DESIGN.md:44`, `SOLUTION-DESIGN.md:248`. | Treat “internal” as permission to remove deletion progress or failure/retry from the UI. That violates FR-030/FR-031 and the terminal-success boundary. `prd.md:272`, `prd.md:277`, `ARCHITECTURE-SPINE.md:118`. | **PASS.** Disclosure removal cannot remove deletion visibility. |
| Deletion | Revoke permits, cancel/drain work, purge Agent state, verify absence, cascade Paper-owned data, retain the tombstone, and report success only after the terminal criteria; do not describe non-revocability or backup erasure in the UI. `ARCHITECTURE-SPINE.md:88`, `ARCHITECTURE-SPINE.md:112`, `ARCHITECTURE-SPINE.md:118`. | Report deletion success before purge/absence, expose a retry for deleting/deleted data, or let a stale result reappear because those controls are internal. | **PASS.** AD-6, AD-10, and AD-11 make each variant text-noncompliant; AD-14 still preserves reusable Templates while deleting Paper snapshots/results. `ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:136`. |
| Security | Enforce private-root/file modes, backup exclusion and re-verification, fail closed on verification failure, redact diagnostics, and retain the stated residual risks internally. `ARCHITECTURE-SPINE.md:76`, `SOLUTION-DESIGN.md:275`. | Remove a control because no user disclosure is required, or claim containment/security/forensic erasure without proof. | **PASS.** The amendment retains the controls and expressly forbids false privacy, security, containment, revocability, and forensic-erasure claims. `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:149`. |
| Documentation | Publish only the Provider setup and license material required for release, with no accepted-limit disclosure and no contradictory claims. `prd.md:299`, `prd.md:302`, `ARCHITECTURE-SPINE.md:130`. | Add a voluntary public `Security and Data Boundaries` page that accurately lists plaintext-at-rest, non-revocable request, and non-forensic-erasure limits. The team can say its release checklist, rather than the accepted facts themselves, requires the page. It adds no consent gate and makes no false claim. | **CONCERN H-01.** The current wording prohibits a disclosure *requirement caused by the facts*, but does not literally prohibit this public surface. `ARCHITECTURE-SPINE.md:76`, `ARCHITECTURE-SPINE.md:118`, `ARCHITECTURE-SPINE.md:149`, `ARCHITECTURE-SPINE.md:234`. |
| Release | Ship two parity-checked artifacts with public setup/license content, no unproved containment claim, and no accepted-limit surface. `ARCHITECTURE-SPINE.md:130`, `SOLUTION-DESIGN.md:298`, `SOLUTION-DESIGN.md:300`. | Adopt the same voluntary documentation page as a release-readiness requirement, while UX omits it. The page does not alter the artifacts' contracts, licenses, signing, or claims. | **CONCERN H-01.** AD-13 fixes artifact parity and required notices, but not the absence of optional accepted-limit copy in public release material. |

## Incompatible-Unit Result

The Provider/UX/deletion/security units converge when they derive behavior from
the amended ADs: no accepted-limit UI surface, mandatory internal controls, and
mandatory observable deletion semantics. The documentation/release construction
above remains a literal counterexample: it can add a truthful public surface
without asserting that AD-4 or AD-11 requires it. A separate UX unit that omits
the surface and a release unit that requires it can therefore diverge while each
follows the candidate's stated Rules.

The existing UX workspace also still records the superseded premise that removing
all such disclosure conflicts with the architecture and pauses UX discovery.
`../../../ux-designs/ux-PaperLens-2026-08-29/.memlog.md:37`. It is correct to
remain paused while this candidate is unapproved, but it becomes a propagation
hazard after approval.

## Compatibility Check

| Authority | Adversarial result |
| --- | --- |
| AD-2 | **PASS.** No remedy grants the native app Agent-zone access, relaxes ProviderRPC, or turns unproved Agent isolation into a claim. `ARCHITECTURE-SPINE.md:64`. |
| AD-4 | **PASS.** Controls and residual facts remain mandatory; the concern is only that disclosure absence is weaker than the stated outcome. `ARCHITECTURE-SPINE.md:76`. |
| AD-6 | **PASS.** The remedy leaves Application-owned writer/publication permits, SQLite visibility, cleanup, and no-resurrection intact. `ARCHITECTURE-SPINE.md:88`. |
| AD-10 | **PASS.** Fenced attempts and guarded publication still prevent stale output from becoming visible. `ARCHITECTURE-SPINE.md:112`. |
| AD-11 | **PASS.** Observable success/failure/retry and terminal deletion criteria remain mandatory even though the accepted limits stay off user-facing surfaces. `ARCHITECTURE-SPINE.md:118`. |
| AD-13 | **PASS.** The release remedy preserves required arm64/x86_64 parity, signing, provenance, AGPL notices, and public setup material. `ARCHITECTURE-SPINE.md:130`. |
| AD-14 | **PASS.** Paper deletion continues to remove snapshots/results while retaining reusable Templates. `ARCHITECTURE-SPINE.md:136`. |
| Product | **PASS.** Prohibiting accepted-limit surfaces would not add a product capability or contradict FR-003's no-notice/no-consent rule, while it preserves FR-030/FR-031 and FR-035. `prd.md:145`, `prd.md:272`, `prd.md:277`, `prd.md:299`. |

## Findings By Tier

### Critical

None.

### High

**H-01 -- The disclosure convention does not require user-facing accepted-limit
surfaces to be absent.** `ARCHITECTURE-SPINE.md:76`,
`ARCHITECTURE-SPINE.md:118`, and `ARCHITECTURE-SPINE.md:149` say only that the
facts create no disclosure *requirement*. A documentation or release unit can
independently add a true voluntary surface, producing the prohibited divergence
without weakening a control or making a false claim.

**Remediation:** after the candidate receives the required architecture change
process, make the convention normative: accepted AD-4/AD-11 limits must not be
introduced into onboarding, Settings, deletion UI, product documentation, or
release material as user-facing disclosure surfaces. State that the false-claim
rule constrains claims but does not authorize or require a disclosure surface.

### Medium

**M-01 -- The UX memlog retains the superseded disclosure blocker.** The draft UX
workspace still says the architecture requires these limits not be hidden and
pauses discovery. `../../../ux-designs/ux-PaperLens-2026-08-29/.memlog.md:37`.
This is not a compliant descendant of the candidate and must not drive resumed
UX work after adoption.

**Remediation:** only after a new explicit architecture approval, rebase the UX
authority record and replace the blocker with the amended boundary: no
accepted-limit surface, but required Provider status and deletion
success/failure/retry/non-reentry behavior remain.

### Low

None.

## PASS / CONCERNS / FAIL Summary

| Status | Result |
| --- | --- |
| PASS | Internal facts, permissions, backup exclusion, redaction, Agent purge, deletion revocation/drain, tombstone, non-resurrection, Template preservation, and truthful-claim constraints remain mandatory. |
| CONCERNS | H-01 leaves a literal optional-docs/release disclosure surface; M-01 preserves a stale UX blocker. |
| FAIL | None. No compliant unit can remove deletion visibility, weaken the stated controls, or falsely claim security/deletion guarantees. |

## Required Remediation Order

1. Close H-01 in the architecture convention without changing the product's
   capabilities, deletion behavior, or control boundaries.
2. Complete the required amendment governance process before using the candidate
   as UX authority. `.memlog.md:75`.
3. After approval, close M-01 by rebasing the UX workspace; do not add a
   disclosure, notice, or consent surface while doing so.
