# Build Spec — Story 1.5: Packaged DB / FTS5 matrix

Issue #8 · own branch `issue/8-story-1-5`.
Approval: https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229 covers in-scope local Spec→implementation→parent tests/review→evidence commits without repeated SHA approval. Commit this Spec on its own branch before implementation. Product `5eac3bb9424ad893eca7d63bc319b71f580838ed`; architecture `1195c92227cc628e325f5ff24d70cc93639bf7a9`. No remote/distribution/environment gate authorization implied.

## Authority and scope

Canonical epics.md489–517 requires actual packaged GRDB open/ordered migration, FTS5 create/query/delete and failure-reopen at four OS×CPU cells. SOLUTION-DESIGN AD6/13/P2 requires one DatabaseQueue, one ordered registry, transactional failure and SQLite visibility authority. scripts/topology/package.py binds acquisition/inventory but its local_packaging_only/not_performed/storyDone:false is not DB execution proof.

Gate-verification only, explicitly selected in actual main app, never normal startup or a second product persistence owner. No Library/product schema, P5 downgrade/corruption policy, PDFium/Provider DB access, cache reconstruction, alternate/mock/Python SQLite driver. Product persistence/helper/CI/public packaging remains P2-blocked.

The1.4 candidate GRDB7.11.1/commit b83108d10f42680d78f23fe4d4d80fc88dab3212 is source identity only. Native implementation requires actual pinned materialization and inspection of public APIs/system-SQLite integration, transaction/registry semantics, safe SQLite error codes and queue close/reopen lifecycle. Unknown APIs are not invented. No native stub while GRDB absent.

Exactly four base cells: minimum15.0/current26.7.1×arm64/x86_64. Current build25G241 is host observation, not packaged execution. Exact minimum build remains unpinned. Intel/Rosetta dynamic execution is unavailable/unapproved, not PASS. Code/artifact/source hashes alone cannot authenticate a submitted OS/CPU/native/packaged label.

## Sequenced implementation files

First complete offline contract precursor: `scripts/topology/verify_packaged_db.py` and `Tests/Topology/test_packaged_db.py`. Pure bounded bytes/typed expected-owner input; no sqlite import, subprocess, network, runtime collection or promotion. It validates supplied record conformance/bindings, never authenticates execution.

Conditional native slice: `PaperLensApp/App/PackagedDBProbe.swift`, `PaperLensApp/App/TopologyFixtures.swift`, `Tests/Topology/PackagedDBProbeTests.swift`. Inspect real GRDB/fixture/target wiring before editing. Dependency/project integration outside these five files requires a separately bounded revised slice, not hidden edits to the evolving1.7Package.swift. No dependencies.json/package.py changes in this slice. Parent alone runs gates/formatter/build/commits.

## Real-GRDB behavior

Validate owner/run and approved fixture namespace before DB access. Use exclusively owned on-disk synthetic DB under approved root; never choose another DB, inspect user docs or delete foreign/symlink/inode-conflicting state. One active queue/connection, drain/close before reopen.

Two fixed migrations: baseline schema, then FTS5 schema. Each atomically commits its changes and probe completion/version. Earlier completed migrations may remain if a later step fails, but no partial failing step. Maintain probe schema version inside the same transaction; cross-check real schema and committed registry, not cached state or an assumed GRDB user_version convention.

Parameter-bound fixed synthetic corpus: create FTS5, insert/query exact expected IDs, delete, zero matches. Reopen same successful DB; verify schema/registry/deletion and no duplicate migration. Inject real SQL failures after schema/data or FTS changes but before completion; assert failing-step table/shadow/data/version rollback and preservation of earlier committed state.

Reopen the same failed DB without deletion/reseeding/cache rebuild. Integrity inspection sees last committed state; unchanged failing startup remains blocked, never normal ready publication. Retry cannot erase failure history or promote a cell. Cleanup only owned DB/sidecars after all handles drained; failure/timeout leaves blocked unresolved ownership, no deletion of a live DB.

## Loaded SQLite provenance / privacy

Observe version/sourceID/compile options from the SAME GRDB connection and bind its actually used SQLite symbols to the loaded Apple system image/dyld cache and OS build. Headers, load commands, a /usr/lib prefix or a different loaded image are insufficient. A missing standalone file for a shared-cache image does not justify bundled SQLite.

Raw addresses, paths, sourceID timestamp prefix, SQL/data/error text, logs, durations, argv/environment remain RAM. Durable provenance exports approved bounded Apple-system classification/code-image identity and SQLite source-code identity suffix, not raw timestamp-containing sourceID or DB/content hashes. These code/artifact identities are not general authorization for raw hashes. Compile options are observed fully within bounds, exported only as≤16 preapproved facts; overflow is blocked, not truncated proof.1.4 consumer schema must share this timestamp-free projection; incompatible full sourceID formats require source repair, not fallback.

## Evidence ownership / closed contract

Separate `packaged-db-fts5-evidence-v1`; do not add ad-hoc fields to packager's closed manifest. Immutable expected bindings supplied independently by parent: Issue/Spec/source/lock/GRDB-source/acquisition/package/final-artifact identities. Per-cell expected OS/version/build/artifactCPU/nativehardware/processCPU/untranslated state and contentless owner/run/attempt IDs. Close/reopen phases share same owner fixture/lineage. Reused host receipts, another DB/artifact/cell, changed CPU labels or copied attempt identities cannot supply missing proof.

Required phases: DB open; actual before/after schema version; ordered migration identities; FTS create/query/delete/reopened absence; injected failure phase; rollback/failure-reopen; loaded SQLite projection; drained cleanup. Build inputs, runtime observations and package references are distinct.

Scopes exactly local_contract_only/local_grdb_probe/packaged_db_fts5. Offline output only conformance/blocked, never authenticated packaged-cell PASS. Local success keeps storyDone:false and p2Passed:false. Even actual four-cell DB completion does not complete P2 without1.6Agent's five events/P1 and independent parent reconciliation. Fresh owner-launched bound packaged execution is mandatory; well-formed JSON/hash binding is not authenticity.

## Bounds and safe errors

Verification-only: one active queue, two migrations,≤4synthetic rows/returned IDs,≤256UTF8bytes/sentence,≤64bytes bound query. Evidence≤16384bytes/cell,≤65536bytes/set, depth≤8,≤32phase records/cell. Reject unknown/duplicate keys, wrong scalar types, missing/conflicting bindings and oversized arrays/values before any success publication.

Compile-option RAM inspection≤256entries×256bytes, export≤16allowlisted facts. Watchdog≤30seconds/launch; close/reopen separate bounded launch. Actual API interruption/drain must be verified; a timeout does not prove safe close or authorize live-file deletion.

Fixed phase + reason enums: grdb_unavailable/binding_mismatch/db_open_failed/migration_failed/fts_unavailable/fts_failed/rollback_failed/reopen_failed/sqlite_origin_unverified/provenance_overflow/timeout/cleanup_failed/unexpected_failure. Approved numeric SQLite primary/extended codes only if safely available; no exception strings. Unknown remains blocked, not alternate-driver success/empty DB/fake fallback.

## Parent tests / acceptance evidence

Offline: all closed-key/type/depth/UTF8/duplicate/byte/phase bounds; trusted expected binding mismatch; stale lock/source/artifact/owner/attempt; copied/crosspoint evidence; missing/order/contradictory migration/FTS/rollback/reopen/cleanup; unknown runtime provenance; raw timestamp/path/SQL/log rejection; deterministic safe projection; synthetic complete fixture never promotion.

Real-GRDB local tests after materialization: transaction fault rollback, preserved earlier schema, failing-reopen no ready publication, successful reopen no duplicate migration, real FTS5 lifecycle, cleanup/drain failures. They are local probe evidence, not packaged matrix.

Canonical AC1–3 require these actual behaviors at every packaged cell, Xcode/SDK/systemSQLite provenance and no mock/host substitution. AC4 requires truthful failures/unverified cells and continued P2/product-split blocking. Parent focused+union tests/independent review/evidence/local commit; no push/PR/notary/stapler/spctl/usercredentials/permissions/Intel/Rosetta implied.

## Static proposal assessment

Architect16 inspected only epics/SOLUTION-DESIGN/dependencies baseline/package.py; no GRDB API, current native wiring, implementation or test execution. Parent removed its obsolete repeated-SHA-approval wording and speculative additional matrix cells. This is a useful offline precursor specification, not packaged/runtime proof or SDK/materialization assertion.
