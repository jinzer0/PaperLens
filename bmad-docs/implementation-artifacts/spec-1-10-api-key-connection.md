# Story 1.10 Build Spec — Native API-Key Connection

## Status and authority

Issue#12 / `issue/12-story-1-10`, base `b1ef1d85116f56ac9b4fdbedd101c918591ff1e6`. Planning checkpoint ONLY, not implementation-ready: P1=false, P2=false, P3=false, StoryDone=false, product implementation BLOCKED. Story1.9 final product RPC and real connection/selector implementation do not exist.

Supplied approval provenance: PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`, https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Whole-Epic authority permits this own-branch planning commit without repeated unchanged-scope SHA approval; actual gates and material-scope governance still apply. No credentials, paid request, remote, signing/distribution or permission-repair authorization follows.

Architect39 inspected exactly canonical ROOT epics.md:631–659, own SOLUTION-DESIGN, Story1.9 Spec, ProviderRequest contract.json, and PaperLensApp.swift. Root-only epics was not copied. Stale draft approval labels do not supersede approved baselines. Main entry remains a topology prototype, not an authentication UI.

## Native lifecycle and sole authority

Application owns connection state, commands and winner selection. Native adapter returns typed results/errors, never selects Provider or writes SQLite. SQLite is the sole active selector/config-generation authority; Settings/preferences/directory names are not a second selector.

- Create never-reused staged slot/version and fresh probe attempt, capturing expected active selector/config generation. Key edits or explicit Retry invalidate prior intent and mint new identities; staging leaves the active connection unchanged.
- Verify backup exclusion, ownership and directory0700/file0600 throughout the private subtree before probe/promotion, after writes and at startup. Unsafe/unverifiable state blocks; no silent permission repair or adoption of conflicting paths.
- No Keychain/additional at-rest encryption. Keys only in controlled native RAM/private secret files; never SQLite/journals, ordinary settings, argv/environment, logs or diagnostics. Selector metadata is non-secret.
- Fixed shared connectionTest: schemaVersion1, fresh requestID, operation connectionTest, empty input; result preserves version/request/operation and exact `{text:"PAPERLENS_OK"}`. Prompt `Reply exactly PAPERLENS_OK.`; no trimming/normalization/extra fields/correlation mismatch. Inspected probe bounds: deadline10000ms, inputCharge2048, outputTokens64, outputBytes12, controlReserve1024, streams0. These are policy, not actual P3/model/auth certification.
- ONLY staged-key actual authenticated minimal v1 generation with a current correlated typed result makes the candidate eligible. Identity/model-list calls, cached/locally echoed sentinel and certified flags are not success. A native path must not fabricate Agent authentication/RPC methods.
- First-run failure remains full-window key entry with closed redacted reason/explicit Retry; no app entry. Failed replacement preserves existing safe active connection and availability.
- After real usability and final storage validation, serialized CAS commits tested complete slot and fresh config generation against expected selector/generation in one SQLite transaction. Competing promotion, stale intent, changed key, permission failure or failed commit cannot activate/report success.
- Retain old slot until selector commit AND every old-slot in-flight lease terminates. New work uses new config generation; old-generation calls may finish but cannot publish. Cancel acceptance/timeout does not prove drain.
- Startup follows committed SQLite selector, validates its complete slot and removes only owned abandoned/unselected retired stages after actual no-live-reference proof. No directory-derived selection, ambiguous probe replay or silent fallback. Unsafe selected state blocks without rewriting selector.
- Failed owned-stage removal retains safe failure/barrier; never claim absent if ownership/closure/removal is unresolved. A winning selector is not modified by cleanup of a losing candidate.

## Missing admission decisions

Actual P1/P2/P3 and exact Story1.9 methods/bounds remain missing. Pin CAS/storage schema, generation allocation, single migration/DB authority, lease and crash cleanup before code. Endpoint/model/tokenizer/profile, native transport/auth mapping, Provider parsing, safe result/error types and cancellation/termination effects are unresolved. `usable` is a conceptual eligibility outcome, not an invented shared-contract field.

Exact slot path/layout, protected creation/backup verification APIs, registry/project/test wiring and authorized live credentials/request budget also remain unresolved. This Spec invents no endpoint, model, filesystem home or API parameter. Local GRDB17/purge103/native parity are not actual connection, Main packaging or physical matrix evidence.

## Conditional bounded slices after gates and exact Spec amendment

A: proposed `PaperLensApp/Application/ProviderConnection.swift`, `PaperLensApp/Infrastructure/NativeAPIKeyAdapter.swift`, `PaperLensApp/Infrastructure/APIKeySlotStore.swift`, `PaperLensApp/Infrastructure/ProviderConfigurationStore.swift`, `Tests/Topology/APIKeyConnectionTests.swift` (five files). These are conditional proposed additions, not existing modules or stub delivery. Use existing sole DB/migration authority, not a second persistence owner.

B: `PaperLensApp/App/PaperLensApp.swift`, proposed `Tests/Topology/APIKeyOnboardingTests.swift` (two files), only after actual flow exists. Required discovered callsites/registry/package/project wiring must be named in a bounded amended slice before edits; no hidden wiring or duplicated schema.

No SDK browser/device-code, final dual-provider UI, fake Library entry, limited-mode bypass or accepted-limit consent. FR-001–004 remain incomplete beyond this scope.

## Required observable verification

Separate authorized live staged-key generation evidence from deterministic tests. Reject identity/model-only success, synthetic sentinel, wrong/duplicate operation/ID, malformed/extra fields, suffixed sentinel, timeout/provider/transport failure, and each bound plus one-over. Safe projected outcomes only, no raw key/body retention.

Race two candidates from one baseline: at most one CAS; failed authentication/permissions/CAS/commit preserves last good. Deliver late success after edit/Retry/cancel/timeout/another promotion: no stale activation/publication. Crash around stage write/probe/eligibility/commit/retirement; restart follows SQLite and never auto-replays ambiguous dispatch. Hold old-slot work across promotion; prove actual drain before retirement. Refuse wrong modes/UID/symlink/replaced inode/unsafe descendant/missing backup exclusion and cleanup failure without foreign deletion/repair. Verify initial full-window failure versus replacement availability and SQLite-derived UI selection.

Architect39: read-only proposal, COMMENT, no source defect asserted where product code is absent. No edits/tests/gates/build/GUI/auth/SDK/network/credential/paid-request execution for this Spec. Done needs exact admitted decisions, actual gates, real authenticated usable response, CAS/privacy/crash/lifecycle/UI verification and independent reviews; planning commit passes none.
