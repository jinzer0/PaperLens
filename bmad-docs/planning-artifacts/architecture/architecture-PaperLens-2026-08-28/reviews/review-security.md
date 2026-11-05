# Security and Privacy Boundary Review

## Verdict

**PASS for the architecture security/privacy boundary review.** The current AD-1..AD-14 draft resolves the prior HTTP-import and Provider Agent Paper-state blockers. It establishes an explicit HTTPS-only Paper-import boundary with no ATS cleartext exception, and it prevents durable Agent retention of Paper request/response/content while requiring Agent-owned, acknowledged or verified, idempotent Paper-state purge before deletion can succeed.

This is an architecture verdict only. P-1 through P-4 remain mandatory evidence gates; they do not constitute completed implementation security work or implementation approval.

## Scope and Decision Constraints

- **Product baseline:** `APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456`.
- **Reviewed:** the current [architecture spine](../ARCHITECTURE-SPINE.md) AD-1..AD-14 and [solution design](../SOLUTION-DESIGN.md).
- **Disposition meanings:** `defer` is safe only behind its named blocking proof gate; `ignore` is an explicit accepted product-risk boundary, not a defect.
- **Out of scope by design:** Keychain or separate at-rest encryption, PDFKit process containment, cloud security, transfer-consent UX, external Provider forensic erasure, and APFS/existing-backup forensic erasure.

## Top Remaining Findings

None. No `autofix` or `discuss` finding remains in the current architecture draft.

## Explicit Boundary Retest

| Boundary | Current evidence | Retest result |
| --- | --- | --- |
| HTTPS-only Paper import and ATS | AD-7 and Solution Design 5.3 permit only `https` for arXiv and general PDF URLs, prohibit ATS cleartext exceptions for Paper URLs, revalidate each redirect as HTTPS, reject embedded credentials, and apply URL/resource/type checks before durable copy or parser dispatch. This aligns with Apple's guidance to avoid ATS exceptions for insecure connections ([Preventing Insecure Network Connections](https://developer.apple.com/documentation/security/preventing-insecure-network-connections.md)). | **Pass.** The prior cleartext HTTP substitution path is closed. |
| Agent Paper-state non-persistence and purge | AD-2 permits the separate Agent zone to durably retain only Provider auth/config/package metadata. It prohibits durable Paper request/response, `EvidenceBundle`, generated result, and document-content retention. SDK-required Paper-linked temporary state is attempt-scoped, Paper UUID/generation/correlation keyed, excluded from diagnostics, and idempotently purged after terminal/cancel and at startup. AD-11 requires Paper-keyed purge acknowledgment or verification before deletion succeeds; failure remains retryable `deleting/failed` without granting broad Agent-filesystem access to the native app. P-1/P-2 require Agent-zone marker-content absence/purge after success, failure, restart, replacement, and Paper deletion. | **Pass, gated by P-1/P-2.** The prior locally controlled Agent-state deletion gap is closed in the architecture; the gate must prove the contract in both packaged artifacts. |

## SEC-01 Through SEC-09 Retest

| Finding | Current architecture evidence | Retest result |
| --- | --- | --- |
| SEC-01 - untrusted PDF execution | AD-7 confines PDFium to a no-network App-Sandboxed XPC worker with read-only imported-PDF input, resource ceilings, and no DB/secret/cache/arbitrary-file access. P-1 requires negative-access proof. PDFKit remains in the UI process under an explicit accepted hostile-PDF/main-process/API-key residual risk. | **Pass / `ignore` for the accepted PDFKit residual; `defer` to P-1 for PDFium proof.** |
| SEC-02 - helper filesystem scope | AD-2 gives the Provider Agent a separate sandbox identity and private zone, prohibits app-container/app-group sharing, limits access outside its zone, and denies the native app broad Agent-filesystem access. P-1 requires sandbox/entitlement negative-access evidence. | **Pass / `defer` to P-1.** |
| SEC-03 - Provider disclosure envelope | AD-3 makes the Application-owned immutable `EvidenceBundle` and Provider request fields authoritative, forbids raw document/PDF path/process data, bounds prior turns, and assigns shared numeric limits to P-3 before adapters split. | **Pass / `defer` to P-3.** |
| SEC-04 - stdio and diagnostics leakage | AD-2 fixes framed, versioned ProviderRPC; protocol-only stdout; method and environment allowlists; typed errors; safe stderr/crash projection; and prohibits raw exception/request/response/URL/document/secret leakage. AD-4 and P-4 retain the required diagnostic policy gate. | **Pass / `defer` to P-4.** |
| SEC-05 - post-delete Provider dispatch | AD-10/AD-11 record intent/correlation, revoke the active predicate/generation/leases/publication permits before cancellation, prohibit new dispatch/retry/final rename, cancel queued Agent work, and prevent already-sent responses from publishing or entering diagnostics. | **Pass.** Previously transmitted external Provider data remains an accepted limit. |
| SEC-06 - secret lifecycle and backup exclusion | AD-4/AD-5 require immutable, non-reused slots; private-root and descendant `0700`/`0600` permissions; backup exclusion and verification after writes/auth flows; fail-closed cleanup; startup stage cleanup; and serialized activation/retirement. | **Pass.** Plaintext secret storage without Keychain remains an explicit accepted risk. |
| SEC-07 - untrusted URL and local-file import | AD-7 and Solution Design 5.3 enforce HTTPS-only network import with no ATS exception, HTTPS redirect revalidation, credential rejection, response/body/redirect/resource ceilings, PDF type/magic validation before durable copy/parser dispatch, raw-URL diagnostic exclusion, and short-lived local security scope without a persisted bookmark. | **Pass.** |
| SEC-08 - nested-runtime integrity | AD-13 requires per-artifact nested-code inventory, identity/entitlement/hardened-runtime verification, unexpected-code rejection, inside-out signing, sealed-bundle verification, notarization/stapling, Gatekeeper launch, and arm64/x86_64 parity. | **Pass / `defer` to P-1/P-2.** |
| SEC-09 - Provider Agent private-state deletion | AD-2 forbids durable Agent retention of Paper data and requires attempt-keyed terminal/cancel/startup purge. AD-11 makes acknowledged/verified Agent purge a prerequisite for terminal Paper deletion, keeps purge failure retryable, and requires P-1/P-2 marker-content proof across success, failure, restart, replacement, and deletion. | **Pass / `defer` to P-1/P-2.** |

## Prototype Truthfulness and Accepted Limits

| Item | Disposition | Review result |
| --- | --- | --- |
| P-1/P-2 signed topology, runtime compatibility, and Agent cleanup | `defer` | Correctly block Provider Agent/PDFium/package implementation until both CPU artifacts prove isolation, nested-runtime integrity, and marker-content absence/purge across every required lifecycle. |
| P-3 request/import/parser limits | `defer` | Correctly centralizes the numeric disclosure and resource limits before implementation units diverge. |
| P-4 diagnostics location, retention, export, redaction, and deletion | `defer` | Correctly blocks public packaging while preserving AD-2/AD-4 safe-projection requirements and the Agent-state boundary. |
| PDFKit UI-process compromise and possible main API-key exposure | `ignore` | Explicitly accepted in AD-4/AD-7. The draft makes no false containment claim. |
| Plaintext Provider secrets; APFS/existing-backup erasure; data already transmitted to an external Provider | `ignore` | Explicitly accepted residual risks. None waive the local Agent-state, deletion, redaction, or import controls above. |

## Required Follow-Through

1. Preserve the HTTPS-only/no-ATS-exception invariant in the Import Build Spec and its redirect tests.
2. Make P-1/P-2 marker-content testing a release-blocking proof of Agent-state non-persistence and purge across success, failure, restart, replacement, and Paper deletion.
3. Keep P-3/P-4 as blocking evidence gates and do not replace them with assertions of completed controls.
