# Build Spec — Story 1.5: Packaged DB / FTS5 matrix

## Current explicit human cancellation — Apple Silicon only

User instruction “1,2 제안 승인, intel 빌드 계획 자체를 완전히 폐끼” cancels
Intel/x86_64 build/package/cross-preparation and physical Intel cells, including
the proposed VM alternative. Baseline51e2603. Current required matrix is exactly
minimum/arm64 and current/arm64: two actual independently bound executions, one
arm64 artifact, ten Agent lifecycle rows across the existing five events. All
other DB/isolation/privacy/owner/signature/runtime requirements remain unchanged.
Following four-cell/two-CPU historical wording and Intel continuation/failure
remain audit evidence, not active work or passing results. No retry, temporary
write grant, SDK/authentication, cost, remote/release or protected trial permission.

Issue #8 · own branch `issue/8-story-1-5`.
Approval: https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229 covers in-scope local Spec→implementation→parent tests/review→evidence commits without repeated SHA approval. Commit this Spec on its own branch before implementation. Product `5eac3bb9424ad893eca7d63bc319b71f580838ed`; architecture `1195c92227cc628e325f5ff24d70cc93639bf7a9`. No remote/distribution/environment gate authorization implied.

## Authority and scope

Canonical epics.md489–517 requires actual packaged GRDB open/ordered migration, FTS5 create/query/delete and failure-reopen at four OS×CPU cells. SOLUTION-DESIGN AD6/13/P2 requires one DatabaseQueue, one ordered registry, transactional failure and SQLite visibility authority. scripts/topology/package.py binds acquisition/inventory but its local_packaging_only/not_performed/storyDone:false is not DB execution proof.

Gate-verification only, never normal startup or a second product persistence owner. `local_grdb_probe` is explicitly selected through the isolated parent-only driver below. Actual Main integration remains a separate blocked conditional slice, not implemented by that driver. No Library/product schema, P5 downgrade/corruption policy, PDFium/Provider DB access, cache reconstruction, alternate/mock/Python SQLite driver. Product persistence/helper/CI/public packaging remains P2-blocked.

The1.4 candidate GRDB7.11.1/commit b83108d10f42680d78f23fe4d4d80fc88dab3212 is source identity only. Native implementation requires actual pinned materialization and inspection of public APIs/system-SQLite integration, transaction/registry semantics, safe SQLite error codes and queue close/reopen lifecycle. Unknown APIs are not invented. No native stub while GRDB absent.

Exactly four base cells: minimum15.0/current26.7.1×arm64/x86_64. Current build25G241 is host observation, not packaged execution. Exact minimum build remains unpinned. Intel/Rosetta dynamic execution is unavailable/unapproved, not PASS. Code/artifact/source hashes alone cannot authenticate a submitted OS/CPU/native/packaged label.

## Sequenced implementation files

First complete offline contract precursor: `scripts/topology/verify_packaged_db.py` and `Tests/Topology/test_packaged_db.py`. Pure bounded bytes/typed expected-owner input; no sqlite import, subprocess, network, runtime collection or promotion. It validates supplied record conformance/bindings, never authenticates execution.

Native authored-file budget is at most three: `PaperLensApp/App/PackagedDBProbe.swift`, `PaperLensApp/App/TopologyFixtures.swift`, `Tests/Topology/PackagedDBProbeTests.swift`. Fixture edits only add reusable descriptor/local-DB ownership support; existing Main/home/group selection and canary behavior remain unchanged. No root Package.swift, Xcode/project/app-entry wiring, CI, dependencies.json or package.py edits. Commit this amended existing Spec on Issue8 before native edits; concurrent root HEAD remains unchanged.

The parent alone exclusively creates mode0700 `.build/topology/story-1-5-local-driver-<fresh-lowercase-UUIDv4>` as a generated test artifact, not a fourth authored source file. Its tools6.4/macOS15/Swift6 manifest uses a local `.package(path:)` dependency on ROOT `.build/topology/grdb-source-only-cfc8c4b8-0ebb-4728-9575-5db33532443b/grdb-source/src` and `.product(name: "GRDB", package: "src")`; the path basename src is the actual dependency identity, not manifest display name GRDB or an obsolete acquisition-directory name. Validate actual GRDB manifest/product/system-SQLite declarations first. A PackagedDBProbe target contains byte-identical copies of the two app Swift files; its test target contains unchanged PackagedDBProbeTests.swift bytes. No network resolution, generated alternative implementation, fake-origin flags or root-package mutation. Independently bind Spec/source/GRDB/materialization/generated-manifest/original-and-copied-source/executed-binary code identities. Driver paths are not durable exports. Build and the watchdog-bounded test launch are separate operations. No Main ownership, packaged execution, product persistence or CI proof is inferred.

## Real-GRDB behavior

Owner context is immutable per invocation. For local_grdb_probe, parent-controlled test setup outside the probe exclusively creates mode0700 `.build/topology/local-grdb-probe-<runID>` with fresh canonical lowercase UUIDv4, current real UID matching effective UID and empty ACL. Retain approved worktree/topology-parent/run descriptors and independently record device/inode/UID identities, exact run entry, owner/run/attempt and fixed DB basename `db.sqlite`. Expected identities are obtained before passing them to the probe, not derived from its newly opened path/report. This is a CODE-artifact namespace, not Main's container or account-home substitute. No fake bundle/profile, environment/argv home override, temporary-home fallback or user documents.

Validate retained descriptors against independent identity, validRunID, private mode/ACL and descriptor-relative matches; traverse pathname components without following symlinks and verify the pathname still names the retained namespace. Revalidate before mutation, phase results, reopen and cleanup. Reuse existing privateDirectory/privateFile/emptyACL/matches/removeOwned/traversal contracts where applicable, not canary byte checking or automatic canary deinit cleanup. GRDB opens by pathname: descriptor checks do not make SQLite open descriptor-relative or prevent hostile same-UID replacement between checks. No arbitrary same-UID/path-stability/container-isolation proof is claimed.

Test setup reserves empty `db.sqlite` using openat O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, mode0600, current UID, regular single-link/empty-ACL checks and independently recorded inode/device. Close that reservation file descriptor before GRDB opens; retain directory descriptors, not an extra DB-file FD that can interfere with SQLite locking. Existing DB/sidecars, symlink/hardlink/mode/ACL/UID/identity conflicts fail without adoption/reseed/deletion. Only fixed db.sqlite-journal/db.sqlite-wal/db.sqlite-shm can be tracked; record each first appearance under the continuously validated exclusive namespace. Unknown/unrecorded entries are never adopted at cleanup.

Actual packaged_db_fts5 still requires real Main bundle/TopologyIdentity.container(Main), OS-account metadata and actual sandbox-container match, separately verified signing/packaging/execution. Local descriptors cannot satisfy it. One active on-disk DatabaseQueue globally; serialize tests. No pool, second inspector connection, memory DB, backup or temporary-copy API. Preserve eraseDatabaseOnSchemaChange=false and do not call hasSchemaChanges, which may open a comparison queue. Drain/throwing close before any replacement queue.

Register exactly two migrations in order: probe_base_v1 creates empty probe_base(id INTEGER PRIMARY KEY) and explicitly sets probe-owned PRAGMA user_version=1 last; probe_fts_v2 creates probe_fts USING fts5(sentence), parameter-binds four fixed rows and explicitly sets user_version=2 last. Each version write is inside that migration transaction, not an assumed GRDB convention. Cross-check actual schema and public committed registry. Fresh version0/empty registry advances through M1/version1 then M2/version2. A fresh fixture may migrate(upTo:M1) then full migrate; successful reopen only uses full migrate, never an already-exceeded earlier target.

Fixed corpus rowIDs1–4: `orbit alpha.`, `beta gamma.`, `orbit delta.`, `epsilon zeta.`. Bound MATCH `orbit` returns exactly ordered [1,3]. Delete four rows in an explicit queue transaction and verify zero rows/MATCH results. Close/reopen same successful inode, full migrate, verify version2/same two committed IDs/empty baseline/retained FTS schema/zero rows and matches: no rerun, duplication or repopulation. Existing row/sentence/query bounds remain.

Use separate fresh fixtures for success/M1-fault/M2-fault; fault choice is immutable across reopen. Real SQL faults insert baseline id1 then duplicate id1 after M1 schema creation or after M2 FTS creation/first insertion, BEFORE version write. No thrown Swift fault sentinel/mock. M1 rollback leaves version0/no probe objects/no applied IDs; an empty GRDB registry infrastructure table may remain because it precedes per-migration transactions. M2 rollback preserves M1/version1/empty baseline/only M1 ID, with no FTS/shadow objects/rows/version2. Inspect actual state after rollback and same-inode reopen. Unchanged full migrate still fails, never normal ready publication or erasure/reseed/cache rebuild.

Reopen the same failed DB without deletion/reseeding/cache rebuild. Integrity inspection sees last committed state; unchanged failing startup remains blocked, never normal ready publication. Retry cannot erase failure history or promote a cell. Cleanup only owned DB/sidecars after all handles drained; failure/timeout leaves blocked unresolved ownership, no deletion of a live DB.

Stop admission, observe EVERY admitted operation completion, call throwing DatabaseQueue.close outside database closures and observe successful return before releasing/opening a replacement. interrupt is cancellation request, not drain. Keep≤30s launch watchdog and separately bounded reopen; local queue reopen is not app relaunch. Timeout/close throw/unobserved completion stays blocked, no replacement queue or live-file deletion. Only afterward descriptor-relative cleanup can remove individually recorded DB/sidecars with current identity/type/UID/mode/ACL/link checks and matching empty run directory. No recursion, unknown entry unlink or deinit proof; cleanup failure preserves original failure and adds cleanup_failed.

## Loaded SQLite provenance / privacy

Observe version/sourceID/compile options from the SAME GRDB connection and bind its actually used SQLite symbols to the loaded Apple system image/dyld cache and OS build. Headers, load commands, a /usr/lib prefix or a different loaded image are insufficient. A missing standalone file for a shared-cache image does not justify bundled SQLite.

This inspected local slice does not establish public symbol/image/signature/shared-cache attestation. Record sqlite_origin_unverified, not a stub Apple classification/private API/certification. Actual SQL/FTS/rollback/reopen observations may be retained independently while provenance remains blocked; local behavior success is not an authenticated cell PASS. storyDone:false/p2Passed:false remain. Do not skip actual SQL tests because image proof is missing or suppress missing image proof because SQL passes.

Raw addresses, paths, sourceID timestamp prefix, SQL/data/error text, logs, durations, argv/environment remain RAM. Durable provenance exports approved bounded Apple-system classification/code-image identity and SQLite source-code identity suffix, not raw timestamp-containing sourceID or DB/content hashes. These code/artifact identities are not general authorization for raw hashes. Compile options are observed fully within bounds, exported only as≤16 preapproved facts; overflow is blocked, not truncated proof.1.4 consumer schema must share this timestamp-free projection; incompatible full sourceID formats require source repair, not fallback.

## Evidence ownership / closed contract

Separate `packaged-db-fts5-evidence-v1`; do not add ad-hoc fields to packager's closed manifest. Immutable expected bindings supplied independently by parent: Issue/Spec/source/lock/GRDB-source/acquisition/package/final-artifact identities. Per-cell expected OS/version/build/artifactCPU/nativehardware/processCPU/untranslated state and contentless owner/run/attempt IDs. Close/reopen phases share same owner fixture/lineage. Reused host receipts, another DB/artifact/cell, changed CPU labels or copied attempt identities cannot supply missing proof.

Approved SOLUTION-DESIGN section9 defines TWO release artifacts: arm64 and x86_64. Minimum/current OS cells of the SAME CPU must bind the SAME actual artifact identity; the two CPU artifact identities must differ. Four distinct artifact hashes are not required and would contradict that baseline. Each of the FOUR executions still requires distinct attempt, lineage and receipt identities and independently bound OS/build/CPU observations. Sharing code bytes within a CPU is not copying execution evidence; cross-CPU artifact substitution and cross-cell receipt reuse remain invalid. Do not salt/rename identical artifacts to fabricate uniqueness.

Required phases: DB open; actual before/after schema version; ordered migration identities; FTS create/query/delete/reopened absence; injected failure phase; rollback/failure-reopen; loaded SQLite projection; drained cleanup. Build inputs, runtime observations and package references are distinct.

Scopes exactly local_contract_only/local_grdb_probe/packaged_db_fts5. Offline output only conformance/blocked, never authenticated packaged-cell PASS. Local success keeps storyDone:false and p2Passed:false. Even actual four-cell DB completion does not complete P2 without1.6Agent's five events/P1 and independent parent reconciliation. Fresh owner-launched bound packaged execution is mandatory; well-formed JSON/hash binding is not authenticity.

## Bounds and safe errors

Verification-only: one active queue, two migrations,≤4synthetic rows/returned IDs,≤256UTF8bytes/sentence,≤64bytes bound query. Evidence≤16384bytes/cell,≤65536bytes/set, depth≤8,≤32phase records/cell. Reject unknown/duplicate keys, wrong scalar types, missing/conflicting bindings and oversized arrays/values before any success publication.

Compile-option RAM inspection≤256entries×256bytes, export≤16allowlisted facts. Watchdog≤30seconds/launch; close/reopen separate bounded launch. Actual API interruption/drain must be verified; a timeout does not prove safe close or authorize live-file deletion.

Fixed phase + reason enums: grdb_unavailable/binding_mismatch/db_open_failed/migration_failed/fts_unavailable/fts_failed/rollback_failed/reopen_failed/sqlite_origin_unverified/provenance_overflow/timeout/cleanup_failed/unexpected_failure. Approved numeric SQLite primary/extended codes only if safely available; no exception strings. Unknown remains blocked, not alternate-driver success/empty DB/fake fallback.

## Parent tests / acceptance evidence

Offline: all closed-key/type/depth/UTF8/duplicate/byte/phase bounds; trusted expected binding mismatch; stale lock/source/artifact/owner/attempt; copied/crosspoint evidence; missing/order/contradictory migration/FTS/rollback/reopen/cleanup; unknown runtime provenance; raw timestamp/path/SQL/log rejection; deterministic safe projection; synthetic complete fixture never promotion.

Real-GRDB local tests after materialization: transaction fault rollback, preserved earlier schema, failing-reopen no ready publication, successful reopen no duplicate migration, real FTS5 lifecycle, cleanup/drain failures. They are local probe evidence, not packaged matrix.

Add real queued-operation barrier tests: no cleanup/replacement while completion/close pending, interrupt/cancel alone not drain; release actual operation and observe throwing close. Test reused namespace/wrong independent descriptor/dev/inode/UID/run, symlink/hardlink/mode/ACL/replacement/foreign-sidecar preservation. No fake close result/drain flags; unexercised API branches remain unverified. Same-connection complete bounded options remain RAM; export ONLY existing approved timestamp-free source suffix/≤16 compile facts, never first16/truncated proof or a new allowlist. Inspect materialized argument-binding/typed-fetch/error-code/manifest declarations before using their exact APIs.

Canonical AC1–3 require these actual behaviors at every packaged cell, Xcode/SDK/systemSQLite provenance and no mock/host substitution. AC4 requires truthful failures/unverified cells and continued P2/product-split blocking. Parent focused+union tests/independent review/evidence/local commit; no push/PR/notary/stapler/spctl/usercredentials/permissions/Intel/Rosetta implied.

## Static proposal assessment

Architect16 inspected only epics/SOLUTION-DESIGN/dependencies baseline/package.py; no GRDB API, current native wiring, implementation or test execution. Parent removed its obsolete repeated-SHA-approval wording and speculative additional matrix cells. This is a useful offline precursor specification, not packaged/runtime proof or SDK/materialization assertion.

Architect33 inspected only this existing Spec, root TopologyFixtures.swift/Package.swift and materialized DatabaseQueue.swift/DatabaseMigrator.swift. Public throwing close/interrupt/serialized access and transactional register/migrate/appliedIdentifiers/appliedMigrations exist. Binding/fetch/error-code/GRDB manifest/image APIs were outside that inspection and require actual declarations before implementation. Three local ownership/wiring/provenance ambiguities are resolved by this committed amendment, not by invented runtime proof. Parent alone implements/runs gates after committing it.

## Current materialized-input reconciliation — parent local driver only

Independent81 read exactly this Spec, existing probe/fixture/test sources and the actual
materialized GRDB manifest. Its sole MEDIUM was the obsolete dependency identity above.
Correcting that instruction admits the already specified driver, not another GRDB preparation
retry or app/helper execution. Actual imports need only GRDB/system GRDBSQLite; evolved
TopologyFixtures has no ProviderRequest import and unrelated Bundle.main resource paths
are not called by this probe. No numeric-contract copy/new target or fake-origin flag needed.
Keep SPI_BUILDER absent so the manifest's conditional remote documentation plugin is absent.
Generated driver resides under the integration .build/topology so unchanged #filePath
upward discovery finds this actual committed Spec. Root Package/Xcode/startup remain untouched.
Parent retains compiler and XCTest stdout/stderr only in RAM; no raw logs, xcresult/JUnit
or tool artifacts containing absolute source/runtime paths, SQL, sourceID timestamps or
durations. Export safe test identities/status/reasons/approved numeric codes and code hashes
only. Build separately; single nonparallel actual test launch has original <=30s watchdog.
Timeout/kill is blocked unresolved ownership, never successful drain/cleanup or fixture
deletion permission. Actual SQL success still sqlite_origin_unverified/P2false/Storyfalse.

### Parent actual local SQL test proof

Committedb06050c inputs produced a byte-identical isolated driver against independently
checked clean pinned GRDBb83108/source treeff52b3c. Build succeeded; parent's legacy SwiftPM
bundle-location assertion then failed BEFORE runtime. Actual Xcode-backed test bundle was
inspected; no rebuild, execution replay or safety relaxation. One separate actual XCTest
launch under30s watchdog returned0; all17 expected named methods passed, zero failures,
safe projectionartifact1058. Three nested suite count lines are not three launches.
This exercises actual migrations/FTS lifecycle/M1–M2 SQL fault rollback/same-inode failing
and successful reopen, queued-operation/interrupt-not-drain/throwing-close barriers and
namespace/UID/device/inode/mode/ACL/foreign-sidecar preservation. Same-connection diagnostic
values stay RAM; their tested bounds do not classify the loaded image.
Original/copied code SHA identities: probe4ed56f9ba79425c0749ca98ff24241858136916fa03e03d75f0d4cf1818e1a92;
fixturee07462f4809099215496c4ac01f1f02199887acf4a4fe859a722de646a55878f;
tests2f5118cd1c1d82894ea0867fd8887ff560bc30eda2b15e73e985ecdc8e621732.
Generated manifest5bce7b02b43459c354ef492c90c3025f61633ff0887f0efbd93e4eaa085dce77;
actual launched arm64 test code757fb893a831fb1200bc44058a571179f9532d44f8a07c1098e5f83962f5ae2c.
Independent81 SOURCE-ONLY RECONCILIATION CLEAR / APPROVE: stale identity resolved; the
supplied safe receipt matches all17 source test methods, no further mismatch. This review
does not independently recompute hashes or witness runtime; parent performed those checks.
Parent persisted no raw compiler/XCTest logs, sourceID timestamps, SQL or runtime paths/
durations; driver paths are not exported. RootPackage/Xcode/startup and all three actual
probe sources remained unchanged; current305/native-z product proof is reused, not rerun.
No app/helper/renderer/SDK/auth/paid/remote/protected trial ran. sqlite_origin_unverified,
packagedCellPassed=false/P2false/Storyfalse/canonical0of26 remain unchanged.

## Current WholeEpic continuation — G003 explicit native artifact CPU

WholeEpic G003 continues from integration HEAD `5f08cc2`; this current amendment is
outside the historical Spec/probe evidence above. Exact authored scope:
`scripts/product/prepare-grdb.py`, `Tests/Topology/test_product_grdb.py`, and this
`bmad-docs/implementation-artifacts/spec-1-5-packaged-db-fts5-matrix.md` only.
Pinned public GRDB7.11.1 commit `b83108d10f42680d78f23fe4d4d80fc88dab3212`
is reused from the existing parent-validated source-only PASS receipt at
`../grdb-source-only-cfc8c4b8-0ebb-4728-9575-5db33532443b/grdb-source/source-only.json`;
the builder validates the existing receipt/tree/source inventory and never clones or fetches.

Preparation requires explicit `--arch arm64` or `--arch x86_64`; `prepare`,
`build_arguments`, and `validate_output` require the same explicit artifact CPU.
Invalid/omitted CPU cannot start a build or create an owned output. Native Darwin
arm64 and untranslated execution-host requirements remain unchanged: x86_64 here
means cross-compilation on that host, not actual Intel execution. Xcode receives
one `ARCHS` value with `ONLY_ACTIVE_ARCH=NO`; static verification requires exactly
that thin lipo CPU and its exact `<CPU>-apple-macos.swiftmodule`, with no module
fallback. The successful receipt reports the validated requested artifact CPU.
Unchanged controls include exact Xcode27.0/SDK27.0/Swift6.4/linker27037.1 pins,
macOS15.0 deployment target, controlled environment, deny-network/owned-write
sandbox, fresh output/exclusive logs, unsigned framework, load-command/system-link
and inventory checks, and no runtime execution.

Synthetic tests are authored for both CPUs on the same arm64 host, wrong/fat CPU,
missing/other-CPU module, invalid/injected/omitted CPU at API/CLI boundaries, and
unchanged execution-host restrictions alongside the existing guards. No tests,
builds, gates, formatters, SDK calls or source-receipt mutations are performed by
this delegated edit. Parent owns integration, focused tests, actual fresh thin
framework build and static verification, evidence and commits; no actual new
artifact identity or validation PASS is asserted here.

Architecture P2 still requires TWO actual CPU artifacts and FOUR independently
bound physical OS×CPU executions. Cross-compilation establishes only artifact
preparation, not SDK/auth/runtime/Intel/OS-cell/P2 acceptance. No four fabricated
artifact hashes, physical-cell results, consumed-trial replay or acceptance
promotion is authorized. G003 and the aggregate original three goals remain
incomplete; a missing local cross-compiled dependency is autonomous engineering
work, not evidence that all remaining work is human-only.

### Parent current verification and operation-scoped blocker

Current CPU-builder fixtures: 30 tests PASS, including the subsequently authored
PIFCache permission-failure regression. The regression checks preservation of
inputs/failed namespace and absence of a successful receipt; canned failure bytes
are not actual tool evidence. GRDBArtifactIntegrityReview approves CPU source
routing with no findings; overall WATCH and no artifact/P2 acceptance.

Actual x86_64 preparation failed before compilation with BUILD_FAILED. Preserve
`.build/grdb-x86_64-94CF0DA8-C5FC-4C1B-AAD8-3F3946683233`, complete build logs and
all failed diagnostics. No preparation.json or new validated thin framework exists.
Actual pinned source validation succeeded and the strict toolchain checks reached
the build. Xcode PIFCache workspace save reported Cocoa513/POSIX1 despite owned
destination writes being allowed by the unchanged profile.

Bounded public diagnostics distinguish the operation: direct POSIX exclusive
write in that namespace succeeds; Foundation Data atomic save fails even under
the exact preparation environment including owned TMPDIR. NSTemporaryDirectory
was observed outside the owned root; public itemReplacementDirectory appropriate
for the owned destination also fails513/POSIX1. These isolate temporary/replacement
selection, not a universally unsupported Xcode operation. No supported caller
override was established. No vendor/private interposition, external-temp write
grant, source/home write, weakened sandbox, blind retry or fabricated success is
allowed. A supported containment mechanism or separately scoped preparation-design
decision preserving ownership is required before another actual build.
