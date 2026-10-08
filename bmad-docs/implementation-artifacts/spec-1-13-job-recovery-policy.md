# Story 1.13 Build Spec — Application-owned Job recovery policy

## Authority and admission

Issue#15 / `issue/15-story-1-13`; planning base `51492b8b0b3b454d741d16eef8019ed45ed7d67b`. PRODUCT `5eac3bb9424ad893eca7d63bc319b71f580838ed`, ARCHITECTURE `1195c92227cc628e325f5ff24d70cc93639bf7a9`, Whole-Epic authority https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. No repeated unchanged-scope SHA approval; document approval never passes technical gates.

Canonical requirements: **caller-supplied canonical excerpt**, Story1.13 epics.md:719–750. Architect38 could not read root-only epics in its worktree and reconciled the supplied excerpt with its other four exact sources: SOLUTION-DESIGN.md, ProviderRequest/contract.json, ProviderAgent/agent.py, spec-epic-1-execution.md. Parent subsequently verified the exact root excerpt; it is not copied/staged. Stale design approval prose does not override approved baselines.

Fix one Application-owned policy before the first product Import Job Build Spec: input version, dispatch history, terminal/interruption, explicit Retry, usable-result preservation, fenced publication, writer/publication permits and synchronous cleanup across Import, parsing, Translation, Chat preparation, Chat request, Brief and Library one-line summary. Future Paper/Reader/annotation/Folder implementation and full schema generation are NOT prerequisites.

- Planning now; commit this own-branch Spec BEFORE source.
- Admit a bounded complete pure Application policy and deterministic tests after parent ownership/convention checks. It needs no product persistence, helper/CI or actual P2. Python may compose tests with existing real registered-synthetic writers, never duplicate policy.
- Product integration BLOCKED: P1=false, P2=false, P3=false; actual product RPC, real1.10–12 connections, durable authority and Main class-specific data owners are absent. StoryDone=false; no P6 promotion, blankCapture remains FAIL.
- `14dd7b3` proves registered-synthetic closure/scoped purge, not SDK/Main publisher/permanent post-lease deletion. `c93e873` proves local GRDB, not product persistence/P2. No rerun/promotion of historical gates.

## Single policy and immutable lineage

Application alone owns transition, dispatch/permit admission and winner selection. A framework/SDK/DB/filesystem-free Swift policy consumes typed snapshots/events and returns next snapshot plus admitted commands or typed rejection. Tests use that same implementation. No adapter-local recovery authority.

Stable logical Job identity; each execution has never-reused attempt, fence, correlation and captured immutable input version, plus applicable Paper/config generations and current execution epoch. Reserve all fresh identities before any state/intent/permit/pointer/filesystem mutation; duplicate or rebound lineage rejects atomically. Pending claim consumes one reserved lineage once, never renews an earlier fence. No invented numeric allocator/wraparound/expiry or durability scheme.

- Import/parsing: class-owned immutable source/PDF input and Paper identity/generation; available source/new stage required. Exact source/parser version encoding UNKNOWN; precursor tests opaque typed equality.
- Translation: frozen permitted request/evidence/language, Paper UUID/generation/PDF SHA/extraction revision.
- Chat preparation/request: applicable extraction/history/input version, then bounded session/question/prior turns/evidence. No Reader page/selection/highlight context. Durable preparation/request linkage UNKNOWN.
- Brief/summary: immutable Template snapshot/version/generation inputs or allowed summary language/evidence; never mutate old provenance. Full regeneration/version encoding UNKNOWN.

ProviderRequest remains the sole closed operation/input/result/allowlist/budget authority; do not add Job metadata to its payload. Validate typed result there before Application publication guards. Agent synthetic `generation` is Paper generation, NOT Job fence/epoch; fresh correlation cannot escape revoked run/Paper scope.

## Transitions and dispatch

Persisted states: pending/running/succeeded/failed. `interrupted`/`paperDeleting` are failure reasons, not extra persisted states.

| Event | Required outcome |
| --- | --- |
| Claim | Only current pending with valid unused lineage/current prerequisites CASes to running; competing claims have one winner. Other states produce no dispatch. |
| Startup | Prior-process running becomes failed/interrupted; preserve historical lineage/input/usable result; invalidate authority, never resume/renew old attempt/fence. Other states unchanged; idempotent. Precursor checks supplied snapshots, not fake durable restart. |
| Dispatch | Durable intent/correlation before external send. Once send may have happened, silence does not prove non-dispatch. Precursor checks command/admission order only, no network/durability claim. |
| Failure/cancel/timeout | One terminal, retain dispatch history/previous usable pointer. Transport terminal/response/cancel acceptance is not closure/purge/publication authority. |
| Explicit Retry | Revalidate current class prerequisites, reserve fresh lineage, create pending work. Never relabel old attempt. Never auto-replay ambiguous external dispatch. Pending/running cannot gain second execution. Explicit regeneration must retain prior usable result until new guarded success. |
| Deletion/revocation | Reject claim/Retry/new dispatch/publication; pending/running fail paperDeleting. Ordinary Retry cannot reactivate deletion. Existing deletion-saga retry is separate idempotent work. |

Fresh Retry may capture newly validated inputs/config; historical input/attempt/result stays immutable. Failure, interruption or stale result never moves/retags previous usable pointer. Retention does not fabricate usability under changed inputs; class owner decides.

## Publication, permits and cleanup

After typed result validation compare current running state, logical Job/current attempt, fence, immutable input version, Provider config generation, active Paper generation, epoch and permit ownership. Inapplicable generations are explicit, never wildcard. Any mismatch rejects, including late success after restart/Retry/configuration change/deletion.

Product success atomically commits immutable result, succeeded state and usable pointer under guarded persistence. Closed validated stage only. Writer permit covers first Paper filesystem access through final close/cancellation cleanup. Distinct publication permit covers final rename through guarded commit OR synchronous failed-guard cleanup.

Revoke new dispatch/permits; drain already admitted writers/publishers before namespace removal/absence. Revoked writer removes owned bytes before release; failed publication guard synchronously removes final bytes before release. Unknown closure/cleanup failure retains obligation and blocks success/absence. Startup scavenging is NOT a substitute.

State critical section contains reservation/decision/accounting only, no FS, blocking queue submission, DB/transport/cancellation callback/drain wait. Record command under state, execute outside, report exact-lineage completion; revalidate before mutation/publication. Deletion waits outside state and releases producer-required gates. New epoch cannot erase cleanup obligations or admit stale publication.

Every repeated cleanup and namespace-removal invocation also reserves a fresh opaque operation identity before admission; execution/permit identity alone is insufficient across retries. Command/accounting captures that identity and immutable Paper scope; completion must match the currently outstanding invocation and target. Reject stale/duplicate prior completions without changing current obligations. Scope absence to the removed target, never mutable live authority. Failure retains debt; a retry cannot overwrite in-flight accounting. This defines no durable allocator/numeric scheme or new physical executor.

Independent static reviewer48 initially BLOCKED the first source on uncorrelated cleanup retries and namespace-removal scope/completions despite20 pure XCTest PASS. Repair these exact same-scope defects before acceptance and preserve that historical result. Add prior-epoch pending coverage: old/rebound claim and direct Retry reject; explicit cancellation then fresh current-authority Retry/claim works, no automatic send or old-lineage renewal.

Precursor expresses observable permit/cleanup transitions, NOT real Main rename/SQLite transaction/publisher drain. Composed tests use actual existing AttemptSession.register/AttemptFixtures.prepare and marker writer/FD closure, optionally Server.accept, in isolated owned fixtures. `prepared:true` is not authenticated output. cancel.accepted/terminals/task cancellation/attemptTerminal or attemptRecover absent:true do not prove producer drain. Only existing scoped paper_purge `{absent:true,drained:true}` observes registered closure/census/absence; no invented ACK or SDK/product promotion.

## Exact bounded source slice

Parent located no existing Application directory/policy or proposed test; existing Swift XCTest conventions inspected. These are intentional new pure policy/test files, not a parallel implementation or product placeholder.

1. `PaperLensApp/Application/JobRecoveryPolicy.swift`: standalone pure complete policy, no product wiring/schema/framework IO.
2. `Tests/Topology/JobRecoveryPolicyTests.swift`: deterministic tests of same policy, test-only composed runner if necessary.
3. `Tests/Topology/test_agent.py`: only narrow test orchestration with existing real registered-synthetic producer if composition requires it; no second policy/fallback.
4. This Spec: parent-owned admission/proof record.

No ProviderAgent/agent.py, ProviderRequest/ProviderRPC, Package.swift, Xcode project, dependencies/helper/CI changes. Parent-only isolated local test driver may compile byte-identical admitted Swift sources; no root product/test wiring hidden in this slice. Resolve any newly observed ownership conflict before edits, do not widen scope silently.

## Required verification and completion limits

All seven kinds: mixed-state/repeated startup, pending-only competing claims, explicit Retry fresh reservation, duplicate identity/no partial mutation, ambiguous dispatch/no autoreplay, preservation and successful pointer movement once. Independently vary every publication guard, plus combined/reverse-order/duplicate/malformed results.

Deterministic barriers, not sleeps: permit required before access, closed/validated before publish, revocation at acquisition/write/close/rename/commit; failed guard cleanup before release, held publisher blocks removal, unknown closure/cleanup failure cannot become success. These are policy assertions, not physical publisher proof.

Compose narrow new tests with actual marker writer barriers beforeWrite/afterMarker/beforeTerminal: terminal/cancel can precede producer.closed; actual purge waits for producer finally/absence, failed purge cannot complete policy cleanup. Fresh higher-generation recovery versus lower-generation purge must preserve bytes/reject before unlink, no stale publication. Correlation rebinding/closure uncertainty admit neither success nor publication. Do not rerun consumed SDK/control/matrix/readiness trials.

Parent runs focused gates/formatter once, records source revision/counts/failures/warnings and obtains independent review. Architect38 read-only COMMENT/WATCH, no writes/tests/gates/build/GUI/SDK/auth/network/credentials/commits. Pure-policy acceptance is separate from actual product/gate status.

Before product admission, pin exact durable lineage/epoch allocator, dispatch/result crash transaction boundaries, input encodings/cross-store recovery and physical permit executor in relevant real work units. Reuse sole migration/visibility/config selector authorities. Prove actual crash-before/after durable intent/commit/synchronous cleanup, authenticated usable requests and packaged CPU/OS gates. No full schema, future feature stubs, new numeric constants or memory-only durability substitute. This precursor does not complete Story1.13 or durable Jobs/deletion/lifecycle.
