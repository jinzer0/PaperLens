# PRD Quality Review — PaperLens

## Overall verdict

The current PaperLens PRD is adequate for final structure/prose polish and downstream UX, Architecture, and story creation. The prior high findings are closed: UJ coverage references now match the renumbered FRs, Architecture acceptance gates are explicit in PRD §10.1 and addendum §2, the dangling CM-004 reference is gone, A-003 roundtrips inline and in the Assumptions Index, and public-v1 license finalization is release-blocking. Remaining issues are polish-level or medium-risk clarity gaps, not critical/high blockers.

## Decision-readiness — adequate

The core decisions are visible and usable. PRD §4.1 states that all feature groups are launch-blocking and that the risk is accepted; §10 repeats the one-developer constraint; R-007 names the schedule/quality risk; CM-002 prevents feature-count completion from masking failure of the end-to-end loop. Per instruction, this is treated as an accepted scope trade-off rather than a missing prioritization defect.

The prior Architecture-gate blocker is closed. PRD §10.1 defines Provider secret, Evidence Anchor, 30-second test, deletion/Local App Data via addendum, Job recovery, and Provider connection gates as pass/fail handoff conditions rather than passive notes. Addendum §2 mirrors these gates with impacted PRD IDs, so Architecture has actionable decision boundaries before implementation starts.

### Findings
- **medium** Delivery sequencing remains implicit despite all groups being launch-blocking (§4.1, §10.1, R-007, CM-002) — The accepted breadth is clear, but story creation would benefit from a non-prioritizing dependency sequence so integration risk is managed without reopening scope. *Fix:* Add a short story-slicing note after §4.1 or in §10.1: Provider/Import/Reader first, then Job recovery, Evidence Anchor, Paper Chat/Brief, Library/delete, Release Packaging.

## Substance over theater — strong

The document's structure is earned by the product. The Glossary supports real domain extraction, four user journeys cover the product's meaningful UX surfaces, FR consequences are directly testable, and release metrics map to the product loop rather than generic usage theater. The public open-source dimension is now concrete through FR-035, FR-036, SM-006, O-001, and addendum §8.

NFRs remain product-specific: PDF-visible speed, AI accuracy claims, Evidence Anchor connection, Local App Data, deletion, Provider transfer, and OS keychain non-use. The addendum appropriately holds implementation candidates and architecture notes outside the PRD body without becoming a second requirements source.

### Findings
- **low** Some canonical terms still mix English Glossary terms and Korean descriptive phrasing (§3, §4-§14) — This is unlikely to confuse humans, but downstream extraction will be cleaner if product terms such as `Translation`, `Brief`, `Paper`, `Provider`, and `Local App Data` are used consistently when they refer to defined product concepts. *Fix:* During prose polish, preserve Korean readability while standardizing defined domain nouns to their Glossary form.

## Strategic coherence — adequate

The thesis is coherent: `read -> evidence -> organize -> revisit -> compound`, implemented as a fast AI Reader connected to an accumulating AI Library (§1). The required feature groups serve that loop: Onboarding enables AI functions, Import/Reader creates first value, Translation and Paper Chat support understanding and evidence, Brief and Library preserve work, Job recovery protects continuity, and Release Packaging makes the product publicly usable.

Success metrics now validate the thesis. SM-001 through SM-006 test first-run setup, Reader entry, Evidence Anchor behavior, parsing failure recovery, Library revisit, deletion, and public packaging. CM-001 through CM-003 also guard against speed, feature-count, and AI fluency masking evidence or loop failure.

### Findings
- **medium** Counter-metrics omit a direct Provider-transparency counterweight (§11 Counter-Metrics, R-004, NFR-010) — The dangling CM-004 reference is fixed, but R-004's user-expectation risk no longer has a counter-metric equivalent. *Fix:* Optional before finalization: add a CM that says Provider onboarding speed or reduced consent friction must not obscure the external data transfer premise.

## Done-ness clarity — adequate

The prior critical blocker is closed. FR-001 through FR-036 each include testable consequences, and many are acceptance-ready as written: FR-001 gates first-run entry, FR-010 verifies last-read restoration, FR-017/FR-024 verify Evidence Anchor hover/clickback, FR-030/FR-031 verify deletion and deletion failure behavior, and FR-035/SM-006 verify public-v1 packaging.

The prior Evidence Anchor high blocker is also closed at PRD level. Evidence Anchor is defined in §3 as PDF page, extracted sentence identifier, and visible highlight; FR-017 and FR-024 specify hover/click behavior; SM-002 verifies the end-to-end clickback; addendum §4 gives Architecture the remaining technical contract questions without weakening the product boundary.

### Findings
- **medium** A few consequences remain more judgment-based than pass/fail (FR-007, FR-015, FR-027, FR-034) — Phrases such as “사용자가 이해할 수 있는 형태,” “사용자는 불확실성을 알 수 있다,” and “빠르게 회상할 수 있는 방식” are directionally testable but still leave QA interpretation open. *Fix:* Replace them during polish with observable labels, required states, or minimum displayed fields.

## Scope honesty — strong

Scope is now explicit and honest. §4.1 says every feature group is release-blocking; §4.2 lists non-goals; §10 states the one-developer constraint and accepted risk; §14 separates the only open license item from deferred future candidates; addendum §1 records superseded decisions such as removed Reader context transfer.

Assumption tracking is now mechanically sound. A-001 appears inline in the Glossary and in §13; A-002 appears inline in NFR-002 and in §13; A-003 appears inline in NFR-009 and in §13. The prior public-v1 license boundary is fixed because FR-035, SM-006, and O-001 now require a final open-source license before public v1 distribution.

### Findings
- **low** Addendum §8 uses softer license wording than the PRD release gate (addendum §8, PRD FR-035, SM-006, O-001) — The authoritative PRD is clear that public v1 needs a finalized license, while addendum §8 says users can confirm “license state,” which is less strict. *Fix:* During prose polish, align addendum §8 wording with the PRD by saying public v1 packaging requires the final license.

## Downstream usability — adequate

The prior UJ coverage-reference high finding is closed. UJ-1 now maps to onboarding, import, Reader, Translation, Paper Chat, Brief, Library recording, and Job state FRs it actually describes. UJ-2 maps to Provider setup, parsing failure, disabled AI functions, retry, and Job recovery. UJ-3 maps to Library revisit and deletion. UJ-4 maps to Template and Chat Session management. The coverage is no longer a misleading trace source.

IDs are also downstream-ready. FR-001 through FR-036, UJ-1 through UJ-4, SM-001 through SM-006, CM-001 through CM-003, R-001 through R-008, A-001 through A-003, O-001, and D-001 through D-006 are contiguous and unique. The prior CM-004 dangling reference is closed; R-004 now references only FR-003 and NFR-010. Addendum §2 includes impacted PRD IDs for architecture gates.

### Findings
- **medium** UJ coverage is accurate but not exhaustive for every FR consequence (§5, §7) — The `Covers:` lines now point to appropriate FRs, but they do not prove every consequence under those FRs is exercised by a journey. This is acceptable for a PRD but should not be mistaken for a full acceptance matrix. *Fix:* In story creation, treat UJ `Covers` as scenario coverage and derive detailed acceptance from each FR's `Consequences` bullets.

## Shape fit — adequate

The PRD shape fits a meaningful-UX public macOS product feeding UX, Architecture, and stories: it has named journeys, a Glossary, stable IDs, testable FR consequences, release metrics, counter-metrics, risks, assumptions, open/deferred items, and a technical addendum. It is intentionally heavier than a hobby PRD because it is chain-top and feature-dense.

The all-launch-blocking scope remains a substantial execution risk, but it is a clear user decision and is handled honestly through §4.1, §10, §10.1, R-007, SM-001 through SM-006, and CM-002. The remaining shape issue is not missing content; it is ensuring polish does not dilute the hard gates.

### Findings
- **medium** Structure/prose polish must preserve gate language (§4.1, §10.1, §11, §14) — The document now relies on precise release-blocking and architecture-gate language; softening it during polish would reintroduce ambiguity. *Fix:* During polish, keep “launch-blocking,” “does not start before Architecture records,” “public v1,” and “final license” semantics intact even if phrasing is improved.

## Mechanical notes

- Prior high finding closed: UJ coverage references now align with renumbered FRs in UJ-1 through UJ-4.
- Prior high finding closed: Architecture acceptance gates now exist in PRD §10.1 and addendum §2 with impacted IDs.
- Dangling reference fixed: R-004 no longer references undefined CM-004; CM IDs are CM-001 through CM-003 only.
- A-003 roundtrip fixed: NFR-009 has inline `[ASSUMPTION A-003]`, and §13 defines A-003 with owner and needed-before condition.
- Public-v1 license boundary fixed: FR-035, SM-006, and O-001 require a final license before public v1 distribution.
- ID continuity: FR-001 through FR-036, UJ-1 through UJ-4, SM-001 through SM-006, CM-001 through CM-003, R-001 through R-008, A-001 through A-003, O-001, and D-001 through D-006 are contiguous/unique.
- Glossary: present and broadly consistent; only minor polish-level term casing/language drift remains.
- Assumptions Index: A-001, A-002, and A-003 all roundtrip inline and in §13.
