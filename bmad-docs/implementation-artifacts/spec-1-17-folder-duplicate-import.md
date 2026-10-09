# Story 1.17 Build Spec — Folder arrangement and duplicate local import

## Exact product implementation phase (latest explicit source-order instruction)

This phase supersedes the historical planning-only admission below. Exactly five files:
this Spec; `PaperLensApp/Application/FolderImportService.swift`;
`PaperLensApp/Infrastructure/ProductDatabase+Folders.swift`;
`PaperLensApp/Features/Library/ImportConfirmationView.swift`;
`Tests/Product/FolderImportTests.swift`. Implement durable flat folder create/rename/delete,
ready-Paper placement, bounded security-scoped SHA256 recognition, and native confirmation.
Nil destination explicitly means Unfiled; deleting a folder unfiles its placements without
touching PDF ownership. Metadata not extracted is unavailable; filename is labelled as such.
No bookmark, Paper, Job, stage or retained handle exists before Continue. Intent is single-use.
Continue rehashes before admission; existing importer must compare the copied digest again
before publication and validate/assign destination in its sole publication transaction.
Parent owns that narrow existing-owner change, migration registration and Library wiring.
Register `registerFolderMigrations(in:)` in the existing migrator, never a second startup owner.
Source-only implementation and regression tests are authored; all tests/gates/builds/formatters,
commits/remotes and `.gjc` workflows are skipped by explicit instruction. No runtime PASS claimed.

## Authority and admission

Issue#19 / issue/19-story-1-17, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source; no repeated unchanged-scope SHA approval, no gate/live/paid/credential/remote/distribution permission inferred.

Architect46 read exactly ROOT epics.md:851–886, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift. Root-only excerpt not copied. Planning ONLY, not implementation-ready. Actual1.14 local Library/import and1.15 Reader absent; product BLOCKED, StoryDone=false. P1/P2/P3/P6 unproved; blankCapture FAIL.1.13 parallel precursor not runtime accepted. Local14dd7b3/c93e873 do not prove SDK/Main/durable physical product. Historical repaired findings not reopened.

## Folder, confirmation and independent ownership

Durable folder creation/move/Paper placement through Application and sole SQLite visibility authority survives re-entry/restart. Logical move does not relocate/replace immutable PDF. Failure preserves prior placement; validate destination/current active Paper, no silent substituted default.

Reuse actual1.14 recognition/input owner. Sheet shows only recognized facts with provenance, actual selected folder/default and possible duplicate status. Filename label is not extracted title; absent/unextracted metadata stays unavailable. Opening/changing/cancelling sheet creates no Paper/Import Job/owned stage, no hidden deferred import/bookmark. Cancel releases temporary input through owner.

Available title/URL/identifier/PDF content hash can signal possible duplicate. Distinguish unevaluated signal from evaluated-no-match, never claim uniqueness from incomplete metadata. Duplicate warning never authorizes overwrite, physical sharing or automatic coalescing.

Explicit Continue revalidates source/destination and consumes confirmation intent once, reserves fresh Paper UUID/generation and Job lineage before mutation. Duplicate delivery of one command adds at most its accepted import; independent confirmations of equal bytes produce separate UUIDs and independently owned immutable physical files, never hardlinks/symlinks/blob-refcount alias. Other Paper unchanged.

After Continue remain Library; ready active Paper offers explicit Open Reader only with actual Reader. No auto navigation or wait for future parsing. URL import/tags/search/filter/folder rename-delete-hierarchy/full schema/future UI/stubs/fallback adapters excluded.

## Recovery and deletion

Reuse1.13 current Job/attempt/fence/correlation/input/Paper/epoch/permit guards and explicit applicable config. Writer permit precedes owned access through close/cleanup; closed validated stage acquires distinct publication permit through rename/guarded commit or synchronous cleanup. State short reservation/decision only, effects/drain/DB/callbacks outside.

Delete revokes new work/permits, drains admitted writers/publishers and removes only targeted UUID/generation namespace/records, never hash-selected scope. Same-content survivor PDF/records remain after restart. Move serializes against current placement/deletion. Unknown closure/cross-store failure retains cleanup debt, not success/absence.

Restart restores committed folders/placements; old running→failed/interrupted, no fence renewal/replay. Unconfirmed sheet never becomes import. Explicit Retry uses fresh lineage/current prerequisites and preserves prior usable results. Late Retry/restart/delete completion cannot publish or change another Paper. No alternate recovery/storage or startup-only failed-guard cleanup.

## UNKNOWNs and conditional ≤5-file phase

Actual folder/default/confirmation APIs, metadata availability/duplicate queries, placement transaction/input versions UNKNOWN. Resolve against accepted1.14/1.15; no invented Inbox/preferences/parallel selector/new folder filesystem namespace/Provider fields/schema/migration registry.

After exact same-Spec amendment name≤3source+2test files: real Library UI; Application confirmation/duplicate/placement commands; sole persistence narrow operations; actual command/transaction tests; real relaunch/physical import-delete tests. Ownership slots not speculative paths or scaffolds. Required wiring fits named bounded phase, otherwise stays blocked.

## Required proof, not executed

Create/move/revisit/restart persists; commit failure/invalid destination/move-delete race preserves truthful state. Before Continue/Cancel/restart-open-sheet no Paper/Job/copy. Each available duplicate signal independently tested, unknown facts honest. Concurrent same-content confirmations yield equal bytes but distinct physical identities/UUIDs and zero existing mutation; repeated same intent adds once.

Delete either duplicate while survivor open/importing; survivor PDF/records/placement intact after relaunch. Copy/close/rename/DB failure and crash around accepted intent/publication never false ready. Hold actual writer/publisher barriers with revoke/Retry/restart and late completions: drain before removal, synchronous cleanup before release, no resurrection/cross-Paper deletion. Ready explicit Reader only, pending/failed/deleting cannot open; no automatic navigation/parsing dependency.

Architect46 COMMENT/WATCH, exact five-source read-only proposal; no tests/gates/formatter/build/GUI/SDK/auth/network/credentials/user docs/commits. Done requires real accepted owners/durable physical tests, parent gates and independent review; planning commits certify no product/gate.

## Selected-source read ownership correction

At current verified integration fe7ea93, FolderImportService.hashSelectedSource defers
import resource lease.close and security-scope stop unconditionally. If checked input
FileHandle.close throws producerClosureUnknown, the actual descriptor is not retained
and the importer capacity is released despite unproved physical closure. This is a
concrete still-executable source defect, separate from missing Agent purge/SDK gates.
Also regular/symlink URL attributes checked before Foundation opening do not pin the
opened object's type; replacing it with a FIFO/symlink can precede a blocking/wrong open.

Keep the same actual import pool/budget and temporary read-only recognition semantics.
Use public nonblocking O_RDONLY/O_NOFOLLOW/O_CLOEXEC opening followed by actual fstat
regular-file/type/size and pinned identity checks against observed source facts before
reading. No arbitrary-source fallback, permission repair, new selector or second counter.
Capture real FileHandle/resource lease/security-scope ownership before read effects.
Checked close is attempted once; only known physical close releases its lease/scope.
Unknown close retains actual handle/lease/scope strongly beyond thrown prepare/facade
loss, denies further capacity, returns producerClosureUnknown and creates no confirmation,
Paper/Job/stage. No ARC, FD-number probe, blind retry or error masking is closure evidence.
Normal failure/cancellation with known close releases genuinely and preserves its cause.

Exact worker scope: FolderImportService.swift, existing FolderImportTests.swift and this
Spec. Production close uses actual FileHandle.close; a required internal test injection
may throw while retaining the real descriptor, never default-success. Read-only internal
debt inspection may expose actual retained fixture ownership for explicit test teardown;
manual fixture cleanup/lease release must not change runtime unknown state or claim ACK.
Tests use owned synthetic files/FIFOs/symlinks only, no user document or SDK/runtime trial.
Parent owns focused/union/native verification, independent retention review/evidence/local
commit. Current291 tests1001/native-w1002 remain prior baseline, not correction evidence.
Story/privacy/P1/P2/P3/renderer/trial/remote boundaries remain unchanged and unproved.

Implementation handoff (aa39aab Spec before code): Darwin admission uses lstat of the
selected URL, O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK open, and fstat of the actual
descriptor. Both observations must be regular files with identical device/inode;
actual positive size within pdfBytes is pinned for final read-count comparison.
URL content type remains recognition evidence, never physical admission authority.
A lock-protected static root captures the real handle, actual import lease and original
security-scope flag before fstat/read/close effects. Locks arbitrate ownership only;
no filesystem, scope, budget, read or close effect runs under them. Known checked close
removes the root after lease/scope release; unknown remains retained indefinitely.
Internal required close injection receives the actual FileHandle; optional beforeOpen
hook only permits owned-fixture substitution between observation and real open.
Read-only unknown ownership inspection exposes the actual handle/lease and scope facts
for manual fixture teardown, not runtime repair, retry, closure evidence or ACK.
Tests authored, NOT RUN by the worker: normal hash/release, retained real FD after facade
loss with actual capacity denial/no intent or durable effects, typed signature failure,
size admission, symlink/FIFO/directory and regular-to-FIFO/symlink/regular replacement.
Parent owns all verification/build/review/commit; prior baseline is unchanged evidence.
Parent concurred not to add beforeRead hooks or racing fixture writers just to inject
read/budget errors. Their original catch/preserve-cause path remains source-reviewable;
those runtime failure branches remain explicitly unverified by the authored tests.

Parent verification:13 focused tests passed (artifact1005), including5 new actual owned
source/FD/retention cases. Full Product union296 passed, zero failures (artifact1007).
Fresh unsigned native Release arm64/macOS15 compiled in native-x (artifact1010).
Independent review75 SOURCE-ONLY CLEAR / APPROVE. Two-source binary delta vsaa39aab:
c45ea42346e98a3e5b37595b2d6f02992a5d38da4938f83cbdfce27344ce3052.
Preserve1003 inaccessible private error initializer and1004 incorrect cap-one test
assumption. Public error fields and actual contract-derived capacity saturation repaired
the tests; shared pool caps/nonblocking admission remain unchanged. Unknown debt consumes
its actual slot, not a guessed blanket prohibition of all remaining contract capacity.
Manual owned-fixture physical cleanup precedes lease/scope teardown but does not alter
runtime unknown state or fabricate ACK. Granted user security scope and deterministic
read/body-budget error branches remain runtime-unverified. No actual user PDFs, helper/
SDK/app/renderer/paid/remote/trial renewal ran; Story/P1/P2/P3/hard bounds remain unproved.
