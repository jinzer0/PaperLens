---
type: architecture-freshness-review
scope: PaperLens v1 external technology freshness and unresolved compatibility claims
architecture_inputs:
  - ../ARCHITECTURE-SPINE.md
  - ../SOLUTION-DESIGN.md
product_approval: 'APPROVED: PRODUCT @ 3bb2edf6a8d3d7f4942dd439325136b6fcb50456'
reviewed: 2026-08-28
---

# Freshness Review - PaperLens v1

## Verdict

**PASS FOR ARCHITECTURE TRUTHFULNESS; NOT IMPLEMENTATION-READY.** The revised AD-1 through AD-14 correctly distinguish current source availability from unproven integration. It does not claim an exact system SQLite build, per-directory sandbox enforcement, a compatible Codex SDK/CLI pair, or a signed/notarized compound bundle before evidence exists.

P-1 and P-2 are safe blocking gates. P-1 owns executable topology, sandbox/entitlement negative-access, and Agent marker-content purge proof before the Provider Agent, PDFium XPC, and packaging Build Specs. P-2 owns exact toolchain/runtime/dependency locks, a supported dual-CPU runtime matrix, SQLite provenance, FTS5 capability, and packaged Agent marker-content purge proof before helper, CI, persistence, or public-packaging units split. P-1 may use disposable prototype inputs, but those inputs are not release locks or compatibility claims; P-2 must ratify the exact immutable artifacts before affected work separates.

No source refresh was needed: the named source versions and official API/package evidence are unchanged since the 2026-08-28 audit. No named technology is currently `stale/unsupported`; all remaining material concerns are explicitly `unverifiable` or `compatibility-risk` until the gates pass.

## Classification

| Classification | Meaning in this review |
| --- | --- |
| `verified-current` | An official release, maintained documentation, or upstream source resolves the named technology or API on 2026-08-28. |
| `unverifiable` | The architecture deliberately has not selected an exact artifact, entitlement set, or packaged behavior. |
| `compatibility-risk` | Components exist individually, but their required interaction in a PaperLens artifact is not proven. |
| `stale/unsupported` | An official source identifies a named item as unsupported or superseded. No item received this classification. |

## Evidence And Compatibility Matrix

| Claim | Freshness | What the sources establish | What remains deliberately unproven | Gate and action |
| --- | --- | --- | --- | --- |
| Swift 6.3.3 and macOS 15+ | `verified-current` | The [Swift 6.3.3 release](https://github.com/swiftlang/swift/releases/tag/swift-6.3.3-RELEASE) and [Swift macOS install page](https://www.swift.org/install/macos/) establish the toolchain. Apple's [Xcode matrix](https://developer.apple.com/support/xcode) lists Swift 6.3 and a macOS 11-26.5 deployment range; Apple's [Sequoia support list](https://support.apple.com/en-us/120282) includes Apple-silicon and Intel Macs. | The precise Xcode/SDK build used by the release artifact. | P-2 records the exact Xcode/SDK before CI, persistence, helper, or packaging work splits. |
| GRDB.swift 7.11.1 | `verified-current` | The official [v7.11.1 release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) is current. Its [tagged README](https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md) supports macOS 10.15+, Swift 6.1+, Xcode 16.3+, and SQLite 3.20.0+. | The exact Xcode/system-SQLite combination in each PaperLens artifact. | P-2 locks provenance; AD-6's one `DatabaseQueue` remains a design decision, not a source-proven release result. |
| System SQLite and FTS5 | `verified-current` for FTS5; `unverifiable` per artifact | [SQLite FTS5 documentation](https://www.sqlite.org/fts5.html) establishes FTS5 as an SQLite feature. GRDB's standard installation uses target-OS SQLite. | No exact SQLite version, compile flag, or identical arm64/x86_64 SQLite build is asserted. An FTS API surface is not a claim that a final artifact can create/search/delete FTS5 tables. | P-2 requires per-artifact SQLite provenance and a packaged `create/query/delete` FTS5 capability smoke. Do not substitute an inferred compile option or an assumed exact system SQLite version. |
| Codex 0.150.1 and official Python SDK | `verified-current` for availability; `unverifiable` exact pair | OpenAI's [0.150.1 release](https://github.com/openai/codex/releases/tag/rust-v0.150.1) exists. Official [SDK documentation](https://developers.openai.com/codex/sdk/) names `openai-codex`, requires Python 3.10+, and says published SDK builds carry a pinned CLI runtime. The tagged [Python project file](https://github.com/openai/codex/blob/rust-v0.150.1/sdk/python/pyproject.toml) declares `openai-codex-cli-bin==0.147.0`. | `0.150.1` is not a demonstrated Python SDK/CLI compatibility contract; no exact SDK/runtime/CLI artifacts or hashes are yet selected. | P-2 blocks the exact pair and lock. The different source pins are risk evidence, not proof of incompatibility. |
| Python SDK browser/device-code login and state home | `verified-current` for API capability; `compatibility-risk` for the Agent | The tagged [Python SDK README](https://github.com/openai/codex/blob/rust-v0.150.1/sdk/python/README.md) documents browser and device-code login. OpenAI documents [`CODEX_HOME`](https://developers.openai.com/codex/environment-variables) as state for config, auth, logs, sessions, skills, and package metadata; [authentication documentation](https://developers.openai.com/codex/auth/) documents file-backed credential storage. | A private `CODEX_HOME` is not proof of a system-enforced per-directory sandbox, exclusive Agent access, Paper-content absence after a terminal flow, clean deletion, or a working packaged login flow. | P-1 must prove the separate Agent identity, entitlement/launch configuration, no app-container or app-group sharing, negative file/network access, and Agent marker-content absence/purge. P-2 repeats that proof in the selected packaged runtime matrix. |
| PDFium pin `ad5bc13610718aefe737bd9b2f1b258d08e39428` | `verified-current` as a source revision; `compatibility-risk` as a component | The official [PDFium commit log](https://pdfium.googlesource.com/pdfium/+log/ad5bc13610718aefe737bd9b2f1b258d08e39428?format=JSON) resolves the pin dated 2026-08-27. | The commit is not a macOS packaged-component release, and does not prove no-network XPC containment, arm64/x86_64 builds, PDFKit geometry agreement, or notarized redistribution. | P-1 proves XPC topology and negative access; P-2 freezes PDFium dependencies/hashes before the affected units split. |
| Developer ID signing, notarization, and separate artifacts | `verified-current` for the Apple path; `compatibility-risk` for PaperLens | Apple documents [Developer ID distribution](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), and correctly signed [nested code](https://developer.apple.com/library/archive/technotes/tn2206/_index.html). | No source proves that the Main App, PDFium XPC, Provider Agent, Python runtime, Codex runtime, and all nested code are simultaneously sandbox-valid, hardened, signed, notarized, and Gatekeeper-launchable in either artifact or across the required OS/CPU matrix. | P-1 proves the topology and negative access; P-2 locks inputs and proves the selected matrix. AD-13 then requires independent arm64/x86_64 inventory, inside-out signing, notarization, stapling, validation, and clean-machine Gatekeeper smoke. |

## Architecture-Affecting Findings

1. **High - the Codex helper remains compatibility-risk, not a release baseline.** The 0.150.1 source tag's Python project pins a 0.147.0 CLI runtime. AD-2/AD-13 now truthfully leave the exact SDK/runtime/CLI selection, hashes, and dual-CPU runtime matrix unresolved. **Action:** preserve P-2 before helper, CI, persistence, or packaging units split.
2. **High - Agent and XPC isolation are intended topology, not an asserted sandbox fact.** `CODEX_HOME` is broad mutable state, and no official source proves PaperLens' proposed identity, entitlement, launch, resource-handle configuration, or Paper-content purge. **Action:** preserve P-1's signed dual-artifact negative file/network and marker-content tests; do not express their result as a per-directory filesystem guarantee.
3. **Medium - system SQLite truth is correctly scoped.** AD-13 permits OS-specific SQLite variation and requires actual artifact provenance, DB-open/migration, and FTS5 capability behavior on every selected matrix point. **Action:** retain P-2's `create/query/delete` smoke instead of claiming an exact SQLite version or compile configuration.
4. **Medium - PDFium and compound notarization remain prototype outcomes.** The source pin and Apple's distribution path exist, but neither establishes the no-network XPC/geometry contract, required Agent cleanup behavior, or the full signed compound bundle across the required OS/CPU matrix. **Action:** retain P-1 topology proof and P-2 dependency lock/matrix evidence before PDFium and packaging work split.

## Gate Review

| Gate | Verdict | Truthful boundary |
| --- | --- | --- |
| P-1 execution topology | **Safe and blocking** | Proves the intended Main App, PDFium XPC, and Provider Agent topology in signed/notarized arm64 and x86_64 artifacts. The test must demonstrate negative file/network access, no container/app-group sharing, and Agent marker-content absence/purge across terminal, restart, replacement, and deletion flows; it must not be described as a pre-proven per-directory sandbox policy. |
| P-2 release lock | **Safe and blocking** | Freezes exact Xcode/SDK, Python SDK/runtime/CLI, PDFium dependencies/hashes, and a runtime matrix covering minimum macOS 15 plus current supported builds on both CPU artifacts. Every selected point records SQLite provenance and proves DB open/migration, FTS5 `create/query/delete`, and packaged Agent marker-content absence/purge before helper, CI, persistence, or public-packaging units split. |
| P-1 plus P-2 ordering | **Safe with the stated distinction** | P-1 may use provisional prototype inputs to test topology. Those inputs cannot be promoted as exact release locks or used to split affected units. P-2 is the ratification boundary. |

## Sources

All URLs were accessed on **2026-08-28**. No evidence changed in this rerun.

| Source | URL |
| --- | --- |
| Swift 6.3.3 release | https://github.com/swiftlang/swift/releases/tag/swift-6.3.3-RELEASE |
| Swift macOS installation | https://www.swift.org/install/macos/ |
| Apple Xcode support matrix | https://developer.apple.com/support/xcode |
| macOS 15 hardware support | https://support.apple.com/en-us/120282 |
| GRDB.swift v7.11.1 release | https://github.com/groue/GRDB.swift/releases/tag/v7.11.1 |
| GRDB.swift v7.11.1 README | https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md |
| SQLite FTS5 | https://www.sqlite.org/fts5.html |
| OpenAI Codex 0.150.1 release | https://github.com/openai/codex/releases/tag/rust-v0.150.1 |
| OpenAI Codex SDK | https://developers.openai.com/codex/sdk/ |
| OpenAI Codex authentication | https://developers.openai.com/codex/auth/ |
| OpenAI Codex environment variables | https://developers.openai.com/codex/environment-variables |
| OpenAI Python SDK README at 0.150.1 | https://github.com/openai/codex/blob/rust-v0.150.1/sdk/python/README.md |
| OpenAI Python SDK dependency declaration at 0.150.1 | https://github.com/openai/codex/blob/rust-v0.150.1/sdk/python/pyproject.toml |
| PDFium commit log | https://pdfium.googlesource.com/pdfium/+log/ad5bc13610718aefe737bd9b2f1b258d08e39428?format=JSON |
| Apple Developer ID certificates | https://developer.apple.com/help/account/certificates/create-developer-id-certificates/ |
| Apple notarization | https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution |
| Apple nested code signing | https://developer.apple.com/library/archive/technotes/tn2206/_index.html |
