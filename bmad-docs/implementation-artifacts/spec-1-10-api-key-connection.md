# Story 1.10 Build Spec — Native API-Key Connection

## User-authorized exclusive slot ownership — 2026-11-07

The user authorized exclusive coordination for API-key replacement and cleanup.
One cooperating store owner holds a nonblocking directory `flock` for its lifetime;
outstanding consumer leases and probes retain that ownership through teardown.
Reads do not repeatedly acquire a global lock. Root replacement or a competing
owner fails closed.

Newly created slots carry a durable record bound to the root and slot inode.
After exclusive acquisition, startup reconciliation may remove only recorded
prior-owner slots that are not protected by the durable selector or current owner.
Do not reinterpret an unmarked, copied, malformed or mismatched file as an orphan.
Selection changes still use the sole durable CAS; a key held by a live consumer
cannot be removed before actual termination releases its lease.

Actual API-key validation is explicitly skipped by user instruction. One bounded
dummy-key request returned HTTP 401 / `invalid_api_key`; that proves negative
authentication transport only, not connection eligibility or model enforcement.

## Current shared Provider routing contract — 2026-10-14

Whole-Epic G002 continues at integration baseline `a7de6d6`. The existing sole
providerConfig row stored slot/generation/model but no Provider discriminator;
native routing could not distinguish a future Codex selection with the same UUID
and model from a native key. Implement the already-required equal-provider/single-
selector foundation, without inventing SDK wire fields or authenticated activation.

ProviderKind is exactly openAIAPIKey or codexChatGPT. ProviderConfiguration requires
explicit optional kind; inactive slot requires nil kind, selected slot requires a
known kind. Metadata identifies routing, never credential location, SDK capability,
probe success or eligibility. No implicit runtime native default or second selector.
The DB CAS requires explicit replacementKind and compares the entire expected
kind/slot/model/generation; all directly affected callers must supply it. One atomic
commit increments generation, including kind-only changes. Native adapters require
openAIAPIKey plus exact model before reading a selected key or granting references.
The opaque slot/generation token remains usable for a deliberate cross-provider CAS;
that token alone does not authorize native credential reads. Existing leased keys
remain owned until termination and cannot publish after any changed selector.

Forward migration providerSelectorKindV1 adds providerConfig.kind and frozen
extractionAttempt.configKind. All pre-change selected metadata was native-only;
label those known historical selected rows once without changing UUID/model/generation.
Inactive rows stay nil. Current reads refuse unknown or inconsistent pairs; no schema
fallback, compatibility alias or provider inference from directory/slot names.
Frozen extraction reservations, guarded reads/publication and retry state preserve
their original kind independently of the current selector. Retry reads current kind
in the same DB snapshot and rejects role drift, including drift without a generation
bump; failed-context kind is never inferred from today's selector.

Core source union: Infrastructure/ProductDatabase.swift, DatabaseAPIKeySelector.swift,
ProductDatabase+Extraction.swift and Application/ParsingRecoveryCoordinator.swift.
Paired behavior is in ProductCompositionTests, ExtractionRevisionTests and
ParsingRecoveryCoordinatorTests. Direct required-argument fixture updates additionally
touch LocalLibraryLifecycleTests, MainPDFiumParsingCompositionTests,
PDFiumExtractionProducerTests, PDFiumExtractionResourceOwnerTests,
LibrarySummaryServiceTests and ProductWorkspaceTests. This existing Spec records the
whole union; no extra plan, fake SDK slot store or backend activation is created.

Focused native verification: 37 cases PASS across routing/composition/extraction/retry.
Tests use private metadata/keys only: cross-role same UUID/model refusal, held-lease
retention, cross-role CAS, kind/slot pair denial, full-snapshot CAS/ABA, forward schema
preservation of native/inactive/frozen state, no runtime default and no stale parsing
publication/retry. None executes the SDK or claims genuine Codex authentication.
Independent data-integrity review and full current-bundle verification are parent-
owned before delivery; SDK/RPC/private-stage/real-probe/CAS integration remains open.

Parent actual isolated native verification of the current bundle: 489 Product
cases PASS, zero failures/errors or skip promotion. Report:
`.build/isolated-product-94C0CBD3-5FE6-4930-A061-4985C0CB9742.json`.
Read-only ProviderRoutingIntegrityReview (`agent://2-ProviderRoutingIntegrityReview`)
returns CLEAR/APPROVE with no findings for the four core routing/persistence/recovery
files and this Spec. It confirms full transactional CAS, no native default, forward
native-only data labeling, separate frozen/current kind and no metadata-derived SDK
activation. Native lease-owner implementation and full tests were parent-verified,
not independently inspected in that five-file review. This is advisory risk review,
not a boundary-cohort receipt, runtime gate or Story/Epic completion. Build warnings
in unchanged extraction/UI/weak-reference code remain disclosed and were not suppressed.

## Current stored-selector revalidation repair — 2026-10-14

Continue this existing Story on the product integration branch, baseline `9f3aedf`,
under the current full Story1.1–1.26 execution request. A warm NativeAPIKeyConnection
previously retained eligibleForEntry and its old activeSelection when restore failed
for a changed model or invalid selected generation. Continue already performs a fresh
lease/selector check, so this finding is stale eligibility/status, not proof of an
unauthorized actual Library admission. It nevertheless misreports a prior selection
as safely retained after the sole database selector has changed.

Revoke entry eligibility before revalidation. On failure clear only the connection's
validated active snapshot; never alter the database, cancel existing leases, remove
slots or infer cleanup. Existing leased keys remain retained for finishing old work,
and existing live database generation/model checks still reject stale publication.
Successful later validation may admit the actual current stored selection again;
it must not replay a probe. Failed candidate replacement semantics are unchanged:
this repair affects restore, not normal connect failure/last-good retention.

Exact delta: Application/NativeAPIKeyConnection.swift, paired
Tests/Product/ProductCompositionTests.swift and this same Spec. No kind/schema/RPC
expansion, SDK activation, model certification, privacy/resource relaxation or actual
credentials/network/trial is authorized or delivered by this repair.

Private prepopulated-selector regressions reproduce the original failure with four
assertion failures in one case; the repaired failure/recovery checks pass without an
injected successful login/probe. Verify changed model and zero selected generation,
no new admission, held lease/key preservation, stale-result denial, unchanged selected
database/slot data, explicit valid replacement recovery and zero transport calls.
Affected native suites: 13 ProductComposition + 11 APIKeyConnection + 7 ProviderSettings
cases PASS. Real authentication and P1/P2/P3/StoryDone remain unproved.

The current caller-built Product bundle was then exercised by the real isolated
driver: 483 cases PASS, zero failures/errors or skip promotion. Report:
`.build/isolated-product-6C723CFA-0ED1-47B0-8A5D-8B9950B63DE3.json`.
The failing-before-repair case remains observed evidence, not suppressed or relabeled.

## Synchronous native key-edit intent boundary

Source scope: Features/Onboarding/APIKeyConnectionView.swift and this Spec only.
Every changed SecureField value must synchronously call the existing Application
invalidateCandidate() before assigning the new field value. Deferred onChange/render
observation is not the mutation boundary: an edited-away candidate response could
otherwise promote before the owner learns of the edit. Unchanged values do not revoke
intent. Remove the deferred edit observer; keep explicit submit, disappearance clearing
and invalidation, Application arbitration and admitted probe/cleanup retention unchanged.
Preserve an independently safe active selection; this is not blanket connection removal.
No root/controller/storage/credential/profile/network authority or API change. Production
unsupportedProfile remains fail-closed. Tests/test fixes/type/build/native/runtime/gates/
formatters remain deferred; source review/parse/diff cannot establish real authentication
or Story/Epic acceptance.

### Source-only onboarding edit receipt

Governing 1f3ee12 preceded the single-view change. Architect222 identified the source
ordering gap: a suspended candidate A could return and promote after field edit B but
before deferred onChange informed the Application owner. The view now uses a private
Binding: changed values invalidate before assignment, equal values do nothing, and the
deferred observer is removed. Submit/default action and disappearance clearing remain.

Independent223 completed on resume after an initial failed job with no retained report;
final verdict OKAY — SOURCECLEAR. It checked existing intent replacement before task
cancellation/publication, post-suspension intent checks before response validation/CAS,
fresh subsequent submit, safe active-selection retention and admitted cleanup/debt guards.
Root/connection/storage APIs and unsupportedProfile enforcement are unchanged. Parent
frontend parse/diff passed (artifact://3513); no credentials, requests or runtime executed.
Tests/test fixes/type/build/native/authentication/profile/Story gates remain deferred.
This is source delivery only; StoryDone=false and canonical acceptance 0/26 remain.

## Status and authority

Issue#12 / `issue/12-story-1-10`, source baseline `367eafd` in canonical worktree `.build/topology/story-1-10-f47b0f87-869e-42a1-b50a-7c409f3a2b0d`. The new explicit human source-execution directive authorizes development of the actual native source vertical below, independently of missing runtime acceptance. Owners are TO DEVELOP, not human prerequisites. P1=false, P2=false, P3=false, StoryDone=false remain truthful; source creation is not gate acceptance. Story1.9 final product RPC remains outside this native lane.

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

## Source-execution order amendment and bounded implementation

The prior planning-only clauses “product implementation BLOCKED”, “Pin ... before code”, and “Conditional bounded slices after gates” imposed an order prerequisite on missing owner implementations. This amendment replaces only that order: implement native source and an explicit narrow persistence dependency first; parent binds the finished actual DB API and verifies the union afterward. It does not weaken actual authenticated probe, sole SQLite selector, privacy, profile certification or runtime acceptance. The inspected architecture does not forbid this native source step. No fictional Story1.9 RPC is introduced.

Exactly five mutable files in this lane:

1. This same Spec.
2. `PaperLensApp/Application/NativeAPIKeyConnection.swift`: Application winner/intent/lease state, typed nonsecret DB dependency, explicit OpenAI configuration and actual Foundation URLSession generation transport.
3. `PaperLensApp/Infrastructure/APIKeySlotStore.swift`: owned private plaintext UUID slot files, no Keychain/encryption or secret DB owner.
4. `PaperLensApp/Features/Onboarding/APIKeyConnectionView.swift`: functional secure key entry/connect/retry/cancel and actual observable state, no local Library-entry flag.
5. `Tests/Product/APIKeyConnectionTests.swift`: isolated deterministic transport/owned temporary storage regressions. Product module name is `PaperLensProduct`; parent owns target/dependency/project/Main wiring and test execution.

### Finished persistence and lifecycle interface

`@MainActor APIKeySelectorPersistence` exposes synchronous throwing `currentSelection() -> APIKeySelection?` and `compareAndSwap(expected: APIKeySelection?, slotID: UUID) -> APIKeySelection?`. `APIKeySelection` has only UUID `slotID` and positive Int64 `configGeneration`. DB owner performs comparison, fresh monotonic generation allocation and durable commit in one real transaction; nil means conflict. There is no in-memory/default selector implementation in delivered product source. An absent binding returns `persistenceUnavailable` before staging or dispatch. A malformed/ambiguous receipt blocks and retains the possible winning secret. The parent binds an adapter after the DB contract is finished; no database/migration edits in this lane.

`NativeAPIKeyConnection(configuration:slots:persistence:transport:authority:)` is the single Application connection owner. `connect(key:)`, `invalidateCandidate()` (every edit), explicit retry via connect, and `cancel()` mint/invalidate intent. A response must be current, shared-contract-correlated, exact-sentinel and network-generation evidence before final storage validation and synchronous CAS. Cancellation acceptance does not remove an in-flight stage: removal follows the actual probe function's termination. Active replacement failure keeps the previously safe selector. Failed storage/cleanup creates a sticky barrier and revokes entry eligibility.

`acquireLease()`, `key(for:)`, `mayPublish(_:)` and `releaseAfterTermination(_:)` retain old generation secrets until actual work termination. Old work may read its leased old key after a replacement but cannot publish under the new DB selector. DB-derived `restore()` validates the selected complete slot without replaying any probe or selecting from directory names. Crash-abandoned files of unknown provenance/reference state are retained, not silently erased: no cross-process no-live-reference proof API exists yet. Parent-owned DB/recovery integration must supply that proof before abandoned-stage garbage collection is accepted. A partially written unsafe abandoned file blocks startup, rather than being repaired or hidden. This is a remaining crash-cleanup acceptance item, not a successful cleanup claim.

### Explicit native wire pin (not profile certification)

Transport is Foundation `URLSession`, not an SDK. Pin: `POST https://api.openai.com/v1/chat/completions`, TLS only, bearer authorization in the native request header, fresh `X-Client-Request-Id`, JSON `model` (caller-supplied explicit configuration), shared-authority-rendered `messages`, `max_completion_tokens` from shared connectionTest `outputTokens` (64), `stream:false`, `n:1`. Endpoint changes, empty/oversized/non-ASCII or unsafe model identifiers are rejected before dispatch. No default model is guessed. The returned model must match the caller's explicit model exactly; aliases resolving to a different snapshot require the caller to configure that snapshot, not a hidden fallback.

This is an explicit implementation wire choice; no existing repository native endpoint/profile pin was found. No worker network/documentation/auth request was authorized or performed. Parent must contrast this format with the actual public API and certify applicable endpoint/model enforcement before accepting P3. `NativeOpenAIConfiguration.requireCertifiedEnforcement()` currently returns typed `unsupportedProfile`, always: explicit model configuration never becomes a certified profile. HTTP400/404/422 also map to `unsupportedProfile`; 401/403 to authentication, 429 to rateLimited, other non200 to providerUnavailable. There are no model-list/identity probes, cached/local success, retries, credential helpers or redirect following.

URLSession is ephemeral/cache-free/cookie-free/credential-storage-free. Both resource and request timeout are 10 seconds, with elapsed-deadline checks while reading and on completion; request deadline derives from shared `probeDeadlineMs`. Provider JSON envelope is incrementally bounded at min(16KiB, shared bodyBytes), separately from shared outputBytes12. Task is cancelled on every return/error. Reject nonJSON MIME, duplicate JSON members, excessive shared-authority JSON depth, malformed envelopes, multiple choices, wrong index/model/role/finish reason, refusal/tool/function calls, and nonexact sentinel. Require integer reported usage `completion_tokens` in 1...64 (shared outputTokens); provider-reported usage is an observed response bound, not independently certified tokenizer/enforcement evidence. The actual response-to-task association correlates the native provider response; OpenAI is not falsely claimed to echo shared schemaVersion/requestID/operation. `ProviderRequest.wrapModelResult` plus `validateResult` construct/check that closed shared result under the original authorized request. Safe closed Korean error projections never retain/log raw response/error/key.

Injected `NativeConnectionTestTransport` returns a shared `ValidatedProviderResult` and evidence kind. Explicit `deterministicFixture` evidence cannot promote. URLProtocol tests exercise production wire/parsing and Application CAS under controlled artificial responses; their transport response marker is not independent real authentication evidence or any gate pass. Injection is a trusted test/adapter boundary, not a user-certifiable flag.

### Secure slot contract and native UI

`APIKeySlotStore(directory:)` receives an explicit canonical file URL from parent composition, with an already-owned0700 parent if creating a new root. It creates root0700/files0600 exclusively; checks effective UID, no symlink ancestors/children, root device/inode, file regularity/single hard link/size, pinned file device/inode/content modification stamp, complete private subtree and backup exclusion. Existing permissions are never repaired. Open/openat/O_NOFOLLOW/O_EXCL, descriptor validation, full writes/fsync, verified backup resource values and inode-checked unlink implement actual storage and cleanup. A created inode is pinned before the first write; reads verify an unchanged stamp after descriptor reading, and final promotion re-reads and compares the tested staged key. No Keychain, additional encryption, preferences/env/argv/logs/SQLite secret storage. OS storage/backup behavior still needs parent's actual verification.

`APIKeyConnectionView(connection:)` renders secure field, explicit endpoint/model, paid-request warning, connect/retry/cancel, safe Korean failures, current selector state and verified entry eligibility. It invalidates on edits/disappearance. It has no Library navigation shortcut, browser placeholder or fake Codex button. Parent composes real future Codex browser/device parity separately; FR-001–004 and final dual-provider/onboarding completion remain incomplete.

## Required observable verification

Separate authorized live staged-key generation evidence from deterministic tests. Reject identity/model-only success, synthetic sentinel, wrong/duplicate operation/ID, malformed/extra fields, suffixed sentinel, timeout/provider/transport failure, and each bound plus one-over. Safe projected outcomes only, no raw key/body retention.

Race two candidates from one baseline: at most one CAS; failed authentication/permissions/CAS/commit preserves last good. Deliver late success after edit/Retry/cancel/timeout/another promotion: no stale activation/publication. Crash around stage write/probe/eligibility/commit/retirement; restart follows SQLite and never auto-replays ambiguous dispatch. Hold old-slot work across promotion; prove actual drain before retirement. Refuse wrong modes/UID/symlink/replaced inode/unsafe descendant/missing backup exclusion and cleanup failure without foreign deletion/repair. Verify initial full-window failure versus replacement availability and SQLite-derived UI selection.

Architect39's earlier read-only planning checkpoint is historical, not a source-execution veto under the new human directive. This lane adds native source and deterministic tests only; no tests/gates/builds/formatters/commits/remotes/workflows/network/auth/helpers/credential/paid-request execution was performed. Parent owns actual integration and one union verification. Done still needs actual gates, real authenticated usable response, endpoint/model/profile verification, real SQLite CAS/privacy/crash/lifecycle/UI evidence and independent reviews. Source creation and authored tests pass none automatically.
