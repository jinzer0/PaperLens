# AI Development Governance

## Purpose

This repository uses a human-governed AI development workflow based on
BMAD Method with selected Hyper-Waterfall governance principles.

BMAD defines how product and software work is explored, planned,
architected, implemented, reviewed, and improved.

GitHub and Git preserve task state, approvals, implementation history,
and verification evidence.

AI performs execution and repository operations.
Humans retain decision ownership.

## Core Principles

1. AI owns execution and routine GitHub operations.
2. Humans own product direction, scope, architecture, priority, and release decisions.
3. GitHub Issues and Git artifacts are persistent project memory.
4. Chat history is temporary context and is never the source of truth.
5. Silence is never approval.
6. Approval must never be inferred.
7. Materially changed approved artifacts require re-approval.
8. AI must not silently expand approved scope.

## Agent Authority

The agent may:

- create and update GitHub Issues
- create Milestones and labels
- create branches and worktrees
- commit changes
- push branches
- create and update Pull Requests
- run tests and verification
- perform code review
- record explicit human approvals
- merge a Pull Request after explicit human merge approval
- close completed Issues
- delete merged task branches
- update BMAD sprint status and project artifacts

The agent must not:

- originate a human approval
- infer approval from silence
- interpret previous approval as approval of changed scope
- implement materially unapproved scope
- silently change approved architectural decisions
- merge a Pull Request without explicit human approval
- reuse merge approval after the PR HEAD has changed

## Work Units

For non-trivial source changes, prefer:

1 BMAD Story
= 1 GitHub Issue
= 1 task branch
= 1 Pull Request

A fresh AI session is preferred for implementation when practical,
but session boundaries are not themselves project memory.

## Branch Naming

Planning:

planning/<release>

Governance or repository maintenance:

chore/<slug>

Story implementation:

issue/<issue-number>-<slug>

Examples:

planning/v0.1
chore/ai-governance-bootstrap
issue/12-document-indexing

## Approval Model

Product, Architecture, and Merge approvals reference immutable Git commits.
Scope and Implementation approvals normally reference immutable Git commits,
but may use the explicit whole-Story approval below.

The approved document itself does not contain its own approval SHA.

### Product Approval

Format:

APPROVED: PRODUCT @ <commit-sha>

This approves the Product Brief / PRD baseline identified in the approval record.

### Scope Approval

Format:

APPROVED: SCOPE @ <commit-sha>

This approves the relevant BMAD SPEC.

### Architecture Approval

Format:

APPROVED: ARCHITECTURE @ <commit-sha>

This approves the architecture artifact at that revision.

### Implementation Approval

Format:

APPROVED: IMPLEMENTATION @ <commit-sha>

This approves the Story's BMAD Build Spec / implementation plan.

Implementation must not begin without this approval for non-trivial work.

### Whole-Story Approval

A human may explicitly approve an entire identified Story rather than each
diagnostic proposal or implementation-spec revision. This grants Scope and
Implementation approval for local work needed to meet that Story's existing
acceptance criteria, including bounded investigation, spec updates, implementation,
tests, and local evidence commits. The human does not need to supply a commit SHA.

Record the Story ID, governing Issue, baseline Spec path and current commit,
the explicit human instruction, and the retained execution restrictions on the
governing Issue. The baseline commit is an audit reference, not a requirement
for another human approval of each in-scope revision.

This approval does not authorize another Story, changed acceptance criteria,
material architecture changes, relaxed privacy or safety boundaries, or remote
operations. Explicit per-run limits and execution prohibitions remain in force;
whole-Story approval alone does not renew an exhausted single-run allowance.
Such changes require separate explicit human approval.

In-scope follow-up specs must still be written and committed before implementation,
but do not require another Scope or Implementation approval. Evidence and unresolved
limitations must remain truthful; approval is not proof of a passing Story.

### Merge Approval

Format:

APPROVED: MERGE @ <pull-request-head-sha>

The agent may execute the actual merge after receiving this explicit approval.

If the PR HEAD changes afterward, the approval is stale and new approval is required.

## Approval Provenance

The agent may write an approval record to GitHub on behalf of the human,
but only after receiving an explicit human approval.

Valid human signals include clear statements such as:

- approve
- approved
- proceed
- continue with this plan
- merge approved

Ambiguous comments, silence, previous approvals, or agent-generated text
must not be treated as approval.

Recommended GitHub record:

APPROVAL RECORD

Type: <PRODUCT | SCOPE | ARCHITECTURE | IMPLEMENTATION | MERGE>
Artifact: <path or PR>
Commit: <sha>
Decision: APPROVED
Supersedes: <old-sha if applicable>

Recorded by agent from explicit human approval.

## Scope Changes

During implementation, the agent may discover missing requirements,
better alternatives, or unexpected constraints.

The agent must not silently incorporate material changes.

Under Whole-Story Approval, in-scope follow-up changes use an updated, committed
Spec and the existing Story approval. Changes outside that approval's boundaries
follow the re-approval sequence below.

Instead:

1. stop before implementing the changed scope
2. explain the discovered issue
3. propose the minimum required change
4. update the relevant artifact
5. commit the new artifact
6. show the diff and new commit SHA
7. request human re-approval
8. continue only after approval

Small implementation details that do not change observable behavior,
contracts, architecture, acceptance criteria, or approved scope
do not require re-approval.

## Risk Levels

### LOW

Examples:

- localized UI fixes
- small bug fixes
- internal refactoring with no contract change

Workflow:

Issue
→ Build plan
→ Human implementation approval
→ Implementation
→ Verification
→ PR
→ Human merge approval

### MEDIUM

Examples:

- normal product features
- new API endpoints
- meaningful domain changes

Workflow:

Issue
→ Build plan
→ Human implementation approval
→ Implementation
→ BMAD review
→ Additional code review when useful
→ PR
→ Human merge approval

### HIGH

Examples:

- authentication or authorization
- database migrations
- billing
- security boundaries
- public API compatibility
- cross-service contracts
- major architecture changes
- destructive data operations

High-risk tasks may use Stage Gates.

Example:

Approved plan
→ Stage 1
→ verification
→ human checkpoint
→ Stage 2
→ verification
→ human checkpoint
→ final PR
→ human merge approval

Stage Gates are optional for LOW and MEDIUM risk work.

## Verification

A Pull Request must distinguish:

- automated verification
- manual/scenario verification
- CI/remote verification
- verification limitations
- remaining risks

Passing tests are evidence, not permission to merge.

## Completion

After explicit merge approval, the agent may:

1. merge the Pull Request
2. confirm merge success
3. close the governing Issue
4. update parent Epic / sprint status
5. remove merged task branches where appropriate
6. recommend the next ready Story

## Project Memory

Important decisions must survive the AI session.

Persist them in the appropriate place:

Product intent → PRD
Scope → SPEC
Technical decisions → Architecture
Task intent → GitHub Issue
Approval → GitHub Issue / PR
Implementation → commits
Verification → PR
Lessons → retrospective / project context

Do not preserve raw conversation merely for completeness.
Distill decisions and evidence instead.
