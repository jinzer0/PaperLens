---
name: PaperLens architecture disclosure amendment freshness review
type: architecture-freshness-review
date: 2026-09-01
architecture_baseline: 'APPROVED: ARCHITECTURE @ f5d488e8ff16b99ba201578e201a11d809b3f054'
candidate_status: unapproved
scope: disclosure-only amendment versus f5d488e
verdict: PASS
---

# Freshness / Reality Check - Disclosure Amendment

## Verdict

**PASS.** The 2026-09-01 amendment changes only the user-facing disclosure
scope of the accepted AD-4/AD-11 limits. It neither adds nor changes a
technology, version, deployment, sandbox, signing, notarization, or
compatibility claim. The retained claims are no less truthful than the approved
`f5d488e` baseline, and P-1/P-2 remain explicit, unpassed blockers rather than
evidence of a completed implementation or release.

This is a reality-check result for the candidate wording only. It does not make
the candidate architecture-approved, implementation-approved, or release-ready.

## Amendment Boundary

The word-level diff from `f5d488e` changes only the `updated` dates and
disclosure wording in AD-4, AD-11, the accepted-limit convention, the Deferred
list, and corresponding companion text. It does not touch:

- the stack labels in [ARCHITECTURE-SPINE.md](../ARCHITECTURE-SPINE.md#L151)
  for Swift 6.3.3, GRDB.swift 7.11.1, Codex 0.150.1, the PDFium commit, or
  macOS 15+;
- the Provider Agent, PDFium XPC, App Sandbox, hardened-runtime, Developer ID,
  nested-code, notarization, and Gatekeeper requirements in
  [AD-2](../ARCHITECTURE-SPINE.md#L60),
  [AD-7](../ARCHITECTURE-SPINE.md#L90), and
  [AD-13](../ARCHITECTURE-SPINE.md#L126); or
- the exact blocking boundaries in [P-1 and P-2](../ARCHITECTURE-SPINE.md#L215).

The approved-baseline review already assessed those unchanged claims on
2026-08-28 in [review-freshness.md](review-freshness.md#L30). Its prior source
evidence is still applicable because the candidate carries forward the same
identifiers and expressly leaves exact compatibility, entitlement, signing, and
release-lock facts unproven.

## PASS / CONCERNS / FAIL

| Assessment | Result | Evidence |
| --- | --- | --- |
| Amendment changes a technology or version claim | **PASS** | No such diff exists. The unchanged stack remains at [ARCHITECTURE-SPINE.md:151-161](../ARCHITECTURE-SPINE.md#L151). |
| Swift 6.3.3 and macOS 15+ remain truthful labels | **PASS** | The [Swift 6.3.3 release](https://github.com/swiftlang/swift/releases/tag/swift-6.3.3-RELEASE) remains resolvable, and Apple's current [Xcode support matrix](https://developer.apple.com/support/xcode) still lists Swift 6.3 toolchains and a macOS deployment range including 15+. Exact Xcode/SDK selection remains P-2 work. |
| GRDB.swift 7.11.1 remains truthful | **PASS** | The official [v7.11.1 release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) remains resolvable. The amendment does not turn the version into a proven per-artifact system-SQLite or FTS5 claim. |
| Codex 0.150.1 remains correctly bounded | **PASS** | The official [0.150.1 release](https://github.com/openai/codex/releases/tag/rust-v0.150.1) remains resolvable. Current [Codex SDK documentation](https://developers.openai.com/codex/sdk/) still identifies the Python SDK, Python 3.10+, and a pinned CLI runtime dependency. The candidate continues to call 0.150.1 a compatibility target, not a selected compatible SDK/CLI release lock. |
| PDFium commit remains a source pin, not a packaged-component result | **PASS** | The official [PDFium log](https://pdfium.googlesource.com/pdfium/+log/ad5bc13610718aefe737bd9b2f1b258d08e39428?format=JSON) resolves the retained commit. No amendment wording upgrades it to proof of macOS packaging, XPC isolation, geometry agreement, or dual-architecture support. |
| Sandbox, signing, notarization, and Gatekeeper claims remain reality-bound | **PASS** | Apple still documents [notarization prerequisites](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md), including Developer ID signing and hardened runtime, and [nested-code signing and Gatekeeper verification](https://developer.apple.com/library/archive/technotes/tn2206/_index.html). The architecture frames these as required evidence, not achieved PaperLens behavior. |
| P-1/P-2 prevent unproven claims | **PASS** | [P-1](../ARCHITECTURE-SPINE.md#L221) still blocks signed/notarized dual-artifact topology, sandbox/entitlement negative-access, and cleanup proof. [P-2](../ARCHITECTURE-SPINE.md#L222) still blocks exact toolchain/runtime/SDK/CLI/PDFium locks, hashes, and the macOS/CPU matrix. Neither is marked passed. |
| Freshness risk introduced by the disclosure-only amendment | **CONCERNS: none** | The amendment has no technology-claim delta. Existing prototype and compatibility risk remains contained by unchanged P-1/P-2. |
| Unsupported, superseded, or falsely proven claim introduced | **FAIL: none** | No source or diff evidence reclassifies a retained label as unsupported, and the candidate does not claim completion of any open gate. |

## Tiered Findings

| Tier | Finding | Disposition |
| --- | --- | --- |
| Critical | None. | No amended claim bypasses a safety, packaging, or compatibility gate. |
| High | None introduced. | P-1/P-2 remain unpassed high-risk evidence gates, not architecture facts claimed as complete. |
| Medium | None. | No version, source pin, deployment target, or source classification changed. |
| Low | None. | The amendment's only freshness-relevant effect is preserving the prior evidence boundary. |
| Informational | Current-source spot checks were accessed on 2026-09-01; the complete 2026-08-28 evidence matrix remains valid for unchanged claims. | Re-run the full compatibility review only if a stack label, source pin, platform target, packaging topology, or gate wording changes. |

## Source Record

The following official/current sources were checked on **2026-09-01**. They
establish source availability or platform requirements only; none proves the
unbuilt PaperLens compound artifact.

- [Swift 6.3.3 release](https://github.com/swiftlang/swift/releases/tag/swift-6.3.3-RELEASE)
- [Apple Xcode SDK and system requirements](https://developer.apple.com/support/xcode)
- [GRDB.swift v7.11.1 release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)
- [OpenAI Codex 0.150.1 release](https://github.com/openai/codex/releases/tag/rust-v0.150.1)
- [OpenAI Codex SDK documentation](https://developers.openai.com/codex/sdk/)
- [PDFium commit log](https://pdfium.googlesource.com/pdfium/+log/ad5bc13610718aefe737bd9b2f1b258d08e39428?format=JSON)
- [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md)
- [Apple TN2206 code-signing and nested-code guidance](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

The fuller source-to-claim classification and its 2026-08-28 access record are
retained in [review-freshness.md](review-freshness.md#L30). This review relies
on that unchanged evidence where the current amendment has no relevant claim
delta, and records the 2026-09-01 source checks above to confirm that no new
reality contradiction was introduced.
