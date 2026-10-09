# Story 1.15 Build Spec — Native Reader and durable last-read

## Authority and admission

Issue#17 / issue/17-story-1-15, base119a28aa9cc941b2bf88851228a67c0bfec88f5a. PRODUCT5eac3bb9424ad893eca7d63bc319b71f580838ed; ARCHITECTURE1195c92227cc628e325f5ff24d70cc93639bf7a9; Whole-Epic https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229. Own Spec before source; no repeated unchanged-scope SHA approval. Authority does not pass gates or permit live/paid/credential/remote/distribution.

Architect44 inspected exactly ROOT epics.md:783–814, own SOLUTION-DESIGN,1.13 Spec, ProviderRequest/contract.json and PaperLensApp.swift. Root-only excerpt not copied. Planning ONLY, not implementation-ready; actual1.14 stored-Paper/deletion owner absent, product BLOCKED, StoryDone=false. P1/P2/P3/P6 unproved.1.13 parallel policy not product proof; local14dd7b3/c93e873 not Main/SDK/persistence. Current Main is topology prototype.

## Native Reader and durable position

Open Reader accepts Paper identity through Application: current active ownership/generation and committed immutable PDF reference, never arbitrary path/file presence. Native PDFKit in UI process provides page navigation/zoom/search/text selection on original PDF. Never rewrite content/fonts/file for app styling. Page/zoom/selection ephemeral feature-local; no framework types in Domain and no Provider request/context injection.

Search states distinguish searching/matches/no results. No-text/image-only PDF stays readable/navigable/zoomable; no fabricated selectable text/OCR/parse/render fallback. Invalid/missing/unreadable PDF gives truthful typed failure, no pretend-open or scan/repair.

Application alone saves/restores durable last-read tied to Paper UUID/generation/PDF/current Reader ownership. SHA alone not lifecycle identity. Validate position against admitted PDF; new active Paper starts normally at first page; stale/invalid restoration yields typed outcome, no silent clamp/rebind/reconstructed Paper.

Guarded persistence, not UI memory/UserDefaults authority. Leaving resolves current save or reports failure; return/restart restores latest committed state with fresh active admission. No renewed prior-process callback/ownership. Order saves so delayed earlier position/replaced Reader/revoked generation cannot overwrite newer accepted state. Save update-only, never Paper-creating upsert.

## Delete and timing boundaries

Deletion revokes entry/restore/save through shared Paper owner; deleting/failed-deletion/deleted cannot open, ordinary Reader Retry cannot reactivate. Revalidate after async load and before presentation/restoration; close/discard rejected candidate, reject late save. Open Reader observes revoke/stops PDF access/discards search/selection callbacks. Public read-access/close coordination UNKNOWN, must pin before source.

Last-read participates in Paper deletion; no row/file/cache/position resurrection. Reimport creates different identity. No FS/callback/blocking submit/drain under short state arbitration. Reader read access is NOT writer permit; existing real producers still retain writer/publication/drain/synchronous-cleanup rules, no new cache/publication authority.

Actual1.14 is functional prerequisite; actual P6 separately gates timing finalization. blankCapture remains FAIL. NO finalized timing Build Spec/probe/completion API/threshold now. After actual P6, amend same Spec with its one automatic instrumentation-started navigation-or-zoom profile and main-thread expected-visible-update signal. Preserve ImportAcceptedAt→FirstInteractivePageAt; document open/control-enabled/manual action/user think time/raster/offscreen pixels cannot be visible witness. Unresolved P6 permits neither fake instrumentation nor fallback renderer.

## UNKNOWNs and conditional ≤5-file phase

Stored PDF/input APIs, read-position encoding/storage, Reader public APIs/layout and actual source/test paths UNKNOWN. No full schema/new pure-policy/memory-only surrogate or future-feature scaffolds. Reader does not depend on parsing/Translation/Chat/Brief/Highlight/Note.

After actual1.14/applicable persistence, name exact existing owners in bounded same-Spec amendment: Application Paper/Reader use cases; sole persistence narrow position operations/migration; real PDFKit Reader; Library Open Reader/return composition; actual paired storage/native integration tests. Responsibility slots not existing files or permission to omit required wiring/tests. Map admitted complete slice before source, not topology substitution/helper/CI split.

## Required observable verification

## 2026-10-09 exact local implementation phase

Latest explicit source-order instruction admits these five files only: this Spec,
`PaperLensApp/Features/Reader/NativeReaderView.swift`,
`PaperLensApp/Application/ReaderSession.swift`,
`PaperLensApp/Infrastructure/ProductDatabase+Reader.swift`, and
`Tests/Product/ReaderSessionTests.swift`. The seeded 1.14 ProductDatabase and
LocalLibraryLifecycle are read-only; their ready Paper UUID, UUID generation and
committed `papers/<UUID>/document.pdf` reference are admission authority. SHA is
not lifecycle identity. Infrastructure uses only adapterRead/adapterWrite and
registerReaderMigrations for the parent's existing sole migrator. Last-read lives
in Paper columns, writes are update-only, and ownership token plus ordered sequence
prevent a replaced Reader or delayed save from overwriting current state. A SQL
trigger removes positions/ownership when identity/reference/status is revoked.

Application exposes a main-actor read-lease provider and lease protocol. Missing
binding blocks open. The parent implements actual shared acquisition, synchronous
revocation notification, access validation and deletion drain; notification must
discard PDFKit documents/search/selection before close releases the lifetime lease.
Ready identity is revalidated after document validation and before claim/presentation,
and each save checks ready identity plus durable session/sequence independently of
the lease. The Reader uses original PDFKit documents, bounded page and zoom controls,
native selection, explicit searching/matches/no-results and typed open/save/restore
failures. Leaving saves before releasing access; failed saves remain visible.

Synthetic real-DB tests cover admission, save/reopen, same-digest synthetic rows with distinct
Paper identities, reversed sequence, replacement, revocation and invalid restoration;
pure navigation tests cover bounds. No tests/builds/gates/formatters/renderer trials
run in this worker. Source review is not runtime or physical proof. Parent owns
migration registration, lifecycle lease/revoke/drain, Library/Main composition and
focused execution. Native visible rendering, keyboard/accessibility interaction,
physical deletion, actual identical-byte documents and runtime restart remain unexecuted evidence boundaries.
P6 instrumentation/timing remains unimplemented and unexposed; StoryDone remains
false until genuine parent integration/runtime evidence and separately P6 completion.

Real stored multipage PDF Open/navigation both bounds/zoom/search matches/no-results/selection, unchanged bytes/fonts/content. No-text stays readable; corrupt/unreadable/missing fails. Real position save/return/restart, two independent Papers with identical bytes retain separate positions; failed save truthfully retains last committed.

Barrier deletion versus load/open/restore/save in both orders, stale generation/replaced Reader/duplicate-reversed callback: no presentation or update that recreates revoked identity. Actual keyboard/accessibility naming/focus/navigation/zoom/search/selection/no-results. Raster/policy assertions alone not durable restart/visible rendering/physical deletion evidence.

Architect44 COMMENT/WATCH, exact five-source read-only proposal; no writes/tests/gates/formatter/build/GUI/SDK/auth/network/credentials/commits. Done needs actual owners/functionality and separately genuine P6 timing, parent focused evidence/independent review. Planning passes no product/gate.

## Captured Reader close uncertainty correction (2026-10-10)

Concrete current source issue: LibraryReadLeaseRegistry records closureUnknown after
checked close failure but finishClose admits that same entry again via close/read unwind
or deletion retry. A failed close may already have released its numeric descriptor;
retry must not affect a descriptor reused by an unrelated owner. Quarantine uncertain
entries at the single physical-effect admission guard. Keep captured handle/snapshot/debt,
deny new reads and keep drain failing; do not manufacture closure or silently clear debt.
Known pending close requests may still complete once opening/active reads actually cease.
Exact source/test scope: LibraryReadLeaseProvider.swift, LibraryReadLeaseTests.swift and
this Spec; parent updates the existing aggregation receipt, runs owned fixture checks
and compiles the current native source, obtains a narrow independent integrity review
and locally commits. No external PDF, helper/renderer/SDK trial, permission repair,
private API, runtime gate renewal, remote operation or Story promotion is authorized.
Regressions cover repeated close/delete-retry/read-unwind after uncertainty and an actual
test-owned numeric FD reused for another read-only file: no second close effect, live
unrelated descriptor and original data preserved, original registry debt retained.
