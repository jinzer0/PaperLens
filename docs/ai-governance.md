# AI Development Governance

## Purpose and precedence

PaperLens uses BMAD Method with selected Hyper-Waterfall principles.
BMAD owns requirements, scope, architecture/design and acceptance criteria;
Hyper-Waterfall contributes execution state, durable context handoffs and
verification Evidence. These principles do not establish a separate runtime engine.
Use existing canonical artifacts rather than duplicate plans or approval procedures.

`docs/ai-governance.md` is the canonical repository approval policy. AGENTS,
repository Build overrides and Issue/PR templates apply it without adding routine
implementation or Stage approvals. Higher-priority system/developer instructions,
platform Tool Permissions and explicit task restrictions remain binding. Repository
policy cannot bypass an incompatible global/bundled workflow or grant unavailable
access; report that limitation rather than claim it was overridden.

## Core principles

1. Humans decide product direction and actual risky decisions; agents execute within scope.
2. A clear execution request grants scoped routine authority, not unlimited permission.
3. Risk depends on impact, reversibility, security, data integrity and external effects,
   not file count, code volume, Stage labels or ordinary Spec SHA changes.
4. Checkpoints record state and Evidence; approval gates require a specific human decision.
5. Silence, ambiguous comments, agent-generated text and unrelated previous approvals
   never supply approval. Record actual human instructions without inventing approvals.
6. GitHub Issues and Git artifacts are durable memory. Distill intent and Evidence;
   chat history alone is not the source of truth.
7. Preserve approved product/architecture/acceptance baselines, scope and explicit limits.

## Risk-based execution authority

Classify each decision/action before crossing its boundary. A LOW-labelled task can
contain a HIGH action; harmless work across many files is not automatically HIGH.

### LOW — Autonomous execution

Examples: typos/documentation, harmless UI styling/layout, localized refactoring,
ordinary bugs, tests and code analysis within the requested scope.

Execute immediately with proportionate permitted verification and report the result.
No separate plan, implementation or Stage approval is required. This is not permission
for unsolicited unrelated cleanup. An informational or analysis-only request remains
read-only; a plan-only/review-only request does not authorize implementation.

### MEDIUM — Scope-based delegation

Examples: normal feature additions/extensions, modules and multi-file refactoring
within the existing approved architecture and contracts.

A clear implementation request itself authorizes in-scope investigation, planning,
implementation, permitted tests/static analysis, review, corrective fixes, Evidence
and safe Stage transitions. Do not ask to approve the same scope or each Spec SHA
again. Clarify only consequential missing requirements that cannot be resolved from
existing facts. Record the real request and boundaries, not a fabricated
`APPROVED: IMPLEMENTATION` token. Explicit no-test/no-commit/no-remote limits still apply.

### HIGH — Explicit human decision

Examples: material architecture changes, security/authentication/authorization policy,
breaking API/contracts, destructive data operations or migrations, production deploys,
major external effects, significant cost/security risk, and material scope expansion.

Before the affected risky decision/action, present its minimum proposal, impact,
target/environment and relevant artifact/diff; obtain explicit approval for that
boundary and permitted operations. Stop only that action. Continue independently safe,
authorized analysis, planning, tests and other work. A refusal means do not execute it.
An unchanged already-approved decision does not require another approval at every
follow-up Stage; a new risk or target cannot inherit unrelated consent.

## Checkpoints, workflow sizing and escalation

Choose only useful Stages based on complexity, dependencies and risk. No fixed minimum
Stage count and no formal Planning/Reviewing/Reporting ritual for a typo. BMAD planning
and review remain proportional; both methods reference one task/spec and Evidence trail.
Context Persistence does not require approval gates.

Within scope, execute ready implementation directly; use investigation and planning
only for unresolved decisions. Apply necessary verification, review and corrections,
record results, and proceed to the next ready change without a fixed serial ritual.
Plan completion, readiness, Stage start/end/transition, tests, ordinary code edits,
verification records and status/documentation updates are non-blocking checkpoints.
Record the next slice, result, remaining risks/permissions and blockers; do not wait
for a human response just because a checkpoint was reached.

### Change-based execution and review

The unit of verification and review is the actual change and its risk, not each
Stage, command, evidence sentence or status update.

- Reuse established approvals, constraints and findings while their scope, authority
  and relevant inputs remain unchanged. Reassess only the changed boundary or a new
  concrete defect; do not restart a whole safety/admission audit.
- Finish and integrate existing work before expanding concurrent implementation.
  The parent executor owns one explicit integration branch/worktree, shared DB/RPC
  contracts and app composition. Use an existing integration target where possible.
  Parallelize only bounded independent changes whose ownership, integration target
  and affected verification are known; do not create another lane for the same
  unfinished Story. Preserve each Story's work unit and acceptance attribution.
- Batch related changes for parent verification. Routine LOW/MEDIUM changes use
  focused tests and the implementing agent's diff review; a separate reviewer is
  not a mandatory lifecycle step. Use independent review for HIGH decisions,
  load-bearing shared-contract/concurrency/data-integrity changes, or an explicit
  task requirement. One review may cover multiple Stories with per-Story findings.
  After a fix, rerun affected checks, including relevant integration checks when
  shared behavior changes, not unrelated passed gates.
- Record evidence with actual results. Editorial corrections and status updates do
  not require a separate review cycle; changed authority, safety meaning or acceptance
  claims require assessment of that specific change.
- Apply a blocker only to the action and dependents it actually prevents. Signing,
  authentication or external-environment gates do not stop independent permitted
  implementation. Never turn partial verification into Story completion.

Do not schedule an investigation, delegation, review or rerun without a concrete
unresolved question, changed relevant input, demonstrated failure or required gate.
State that trigger and a bounded exit condition; otherwise execute the next ready
change using existing findings. Stage/session changes, elapsed time and editorial
updates alone are not triggers. Reuse test evidence for unchanged code, dependencies,
configuration and environment; invalidate only evidence affected by a real change.
Do not create new checklists, audits or evidence-only work to occupy a blocked lane.

These execution defaults do not weaken acceptance criteria, required independent review,
privacy, Tool Permissions, exhausted trial limits, or HIGH/remote/Merge/Release gates.

### Integration, progress and worktree closure

Use the existing Epic execution Spec and actual integration HEAD as the cross-session
entry point, not an old root checkout or another session's goal receipt. Never copy
or forge runtime state, receipts or source hashes. Historical phase plans do not add
perpetual precommit or serial-review gates; protected acceptance restrictions remain.

Progress means observable behavior integrated and verified at the integration target,
not the number of branches, plans, reviews or evidence edits. Report local implementation,
synthetic checks, packaged checks and external acceptance separately. Preserve existing
results unless relevant inputs changed; do not label a Story done from source presence.

When worktree cleanup is explicitly requested, first inventory committed and uncommitted
changes, including untracked source and local records. Preserve unique commits with
durable local refs and unique uncommitted work with a verified recoverable snapshot before
removing any worktree. Integrate useful changes and resolve duplicates by behavior and
tests, not timestamps. A preservation archive is not proof that a feature was integrated.
Do not delete a live worker's checkout or remove the active integration target. Keep a
source-to-integration disposition and verification result in the existing Epic record.
Remote refs and unrelated user work remain outside local cleanup authority.

A failed permitted test leads to bounded diagnosis, correction and reverification
without separate approval. Never weaken acceptance tests or suppress warnings to pass.
Escalate repeated failures without a viable in-scope remedy, real dependencies/access
blockers, requirements conflicts, new protected decisions or material scope changes.
Human silence must not stop independent safe work, but is never approval for a blocked
risky action. No fixed retry budget is invented here: actual per-run limits govern.

## Safety and operation boundaries

- Preserve data/privacy/security, platform Tool Permissions and explicit task prohibitions.
  Workflow authority and Codex/Claude Code/GJC tool permissions are separate layers.
- Do not access actual user documents, credentials or existing CODEX_HOME, make
  unapproved paid requests, relax safety/permissions or blindly repeat exhausted trials.
  A fix, Spec update, Stage or new session never renews a consumed single-run allowance;
  renewal requires separate specific human authorization.
- Local analysis, edits, branches/worktrees, commits, tests and review require the
  applicable task/tool authority. A planning-only or no-commit task stays limited.
- Push, GitHub writes (Issues, Milestones, labels, PRs, approval records, closure and
  remote cleanup) require explicit applicable human instruction and access. Local
  authority, task completion and a passing test do not imply remote permission.
- Merge requires approval for the current PR HEAD. Release/distribution/production
  and other protected external/cost/data operations have their own target-specific
  permissions; Merge does not authorize them.
- Preserve unrelated user work; never broadly stage, revert, stash, delete or switch
  branches in a way that damages it. Report local pending synchronization honestly
  when remote operations are not authorized or possible.

## Work units and context

For non-trivial source changes retain traceability to the existing BMAD Story,
Issue, branch and planned PR, and use the existing Build Spec. Routine in-scope fixes
and follow-ups do not require a new Spec, separate pre-implementation Spec commit,
Issue, branch or PR. Record necessary Spec deltas and results with the implementation
commit. Establish a Spec before new substantive work lacking a usable contract;
material acceptance/architecture changes still follow their HIGH approval boundary.
Link existing task artifacts; remote synchronization is not a local execution gate.
A trivial LOW correction needs only proportionate intent/diff/verification Evidence,
not a new Epic/Story or mandatory full workflow. An unavailable remote Issue is a
synchronization prerequisite, not permission to create it remotely.

Branch conventions: `planning/<release>`, `chore/<slug>` for governance/maintenance,
`issue/<issue-number>-<slug>` for Stories. Choose a safe task branch/worktree under
actual authority; naming conventions alone do not justify switching a dirty worktree.
A fresh session can help, but session boundaries are not project memory or new authority.

## Decision records

Distinguish an **Execution Authority Record** from an **Approval Record**.
For non-trivial work, record task/Story/range and Issue or local artifact reference,
actual human request/reference, impact-based risk rationale, scope/acceptance and
permitted operations, baseline Spec/current commit, retained limits/trial status,
necessary HIGH decisions and actual verification/limitations. Keep trivial records
small; no extra human confirmation or supplied SHA is needed for routine authority.
Do not store raw chat, secrets or documents just for provenance. Publish to GitHub
only when remote publication is authorized; otherwise preserve a local pending record.

For an actual human decision use the relevant existing format:

- `APPROVED: PRODUCT @ <commit-sha>` — identified product baseline.
- `APPROVED: SCOPE @ <commit-sha>` — protected scope decision/BMAD SPEC.
- `APPROVED: ARCHITECTURE @ <commit-sha>` — identified architecture decision.
- `APPROVED: IMPLEMENTATION @ <commit-sha>` — a specifically approved risky
  implementation decision/plan; not a mandatory LOW/MEDIUM token.
- `APPROVED: MERGE @ <pull-request-head-sha>` — current PR HEAD only.

Product/architecture/commit-bound decisions reference immutable artifacts. The approved
document does not contain its own approval SHA. Whole-Story/range provenance below
can identify routine scope authority without a human-supplied SHA.

Approval records contain type, decision, artifact/target, immutable reference when
applicable, permitted operations, actual human instruction/reference, retained limits
and superseded decision if any. The agent may record a real approval but never originate
one. A risk dropdown, completed form, vague “continue” or reviewer verdict is not
permission for a HIGH action. Clear scoped execution requests are routine authority,
not silence-based inference. Changed approved targets invalidate target-bound approval;
ordinary in-scope evidence/Spec edits do not invalidate routine scope authority.

### Whole-Story Approval

An explicit human instruction for an identified whole Story grants routine local
lifecycle authority within its existing acceptance criteria. This is an application
of the common policy, not an exception requiring every later Spec SHA approval.
Record Story ID, governing Issue, baseline Spec/current commit, actual instruction
and retained limits; the baseline commit is an audit reference. Routine in-scope Spec
updates may accompany the implementation commit, without a separate precommit or
Scope/Implementation approval. Passing Evidence and truthful limitations remain necessary.

It does not authorize another Story, changed acceptance criteria, material architecture
changes, privacy/safety relaxation, remote operations or exhausted allowance renewal.
Seek specific approval for the changed boundary, not for all safe remaining work.

### Explicit Story-Range Execution

An explicit instruction to plan, implement and verify an identified Story range
applies scoped authority to every existing Story in that range. Record the instruction
and range on the governing Epic and link each Story Issue when remote writes are
permitted; otherwise record pending synchronization locally. Preserve per-Story
traceability, reuse existing Specs/work units, and apply change-based verification
and risk-triggered independent review. Do not require a new pre-implementation Spec
commit for routine follow-ups. Do not reduce the instruction
to the active Story or repeatedly ask for in-scope approval.

Continue dependency-ready Stories despite an environment-only blocker elsewhere.
Missing Story definitions are requirements gaps, not permission to invent acceptance
criteria. Track local, synthetic, packaged and external verification separately.
Bounded verification follows each committed Spec and actual remaining allowances.
User-assisted login, paid real requests and unavailable hardware remain blocked until
necessary inputs/permissions exist; no blind historical retry, data/credential access,
permission relaxation, product/architecture scope change, remote action or distribution
is implied by the range instruction.

## Scope changes

In-scope implementation details, fixes, Spec and Evidence updates continue under the
same authority. Stage changes and SHA churn are not standalone reapproval triggers.
For material changes to scope/acceptance/product/architecture/security/auth/contracts
or protected privacy/permission boundaries:

1. stop the affected action before crossing the new boundary
2. explain the finding and minimum proposal, target, impact and tradeoffs
3. update the relevant existing artifact and commit it when permitted
4. present the meaningful diff and immutable reference when applicable
5. obtain the specific human decision and record its actual provenance
6. resume only the approved action; keep independent safe work moving

Do not use a routine feature request to rewrite an approved baseline silently.

## Merge, Release and completion

`APPROVED: MERGE @ <pull-request-head-sha>` authorizes that actual Merge.
Recheck HEAD immediately before Merge; any HEAD change makes that approval stale.
Tests, implementation approval and review are Evidence, not Merge permission.

Explicit instructions to integrate into a named local branch authorize that local
integration after verification and source/target HEAD and worktree checks, not a PR
merge, push or release. Record the actual instruction; never invent approval tokens.

Release/deploy approval identifies the current revision/artifact/version, destination,
environment and permitted operations. A changed target invalidates it. Merge alone
is not Release, production, destructive-data, paid-request or remote-cleanup authority.
After an authorized Merge, confirm success and close/update Issues, sprint/Epic status
and merged branches only within applicable operation authority. Never touch unrelated
work. Local completion can be reported without forcing a PR, Merge or Release stage.

## Verification and project memory

Retain proportionate required tests, BMAD review and independent review where applicable.
Evidence distinguishes automated, manual/scenario, CI/remote, skipped/blocked/not-applicable
checks, limitations and remaining risks. Do not report a source-only/text walkthrough
as runtime, product, external or hardware proof. Policy/config changes need relevant
syntax and semantic checks, not unrelated product suites or unsafe trials to fill a form.

Persist product intent in PRD, scope in SPEC, technical decisions in Architecture,
task intent/authority in Issue or linked local artifacts, implementation in permitted
commits, verification in existing Evidence/PR records, lessons in retrospective/context.
Use the `APPROVED: PRODUCT` record to select the canonical final PRD/addendum, not
filename dates. Product Brief remains discovery/history and does not overwrite the
approved final PRD or itself grant implementation authority. Record concise decisions
and next work rather than duplicate documents or raw conversation.
