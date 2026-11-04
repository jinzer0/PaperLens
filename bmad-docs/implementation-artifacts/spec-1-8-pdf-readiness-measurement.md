---
title: 'Story 1.8 — PDFKit readiness의 공통 probe와 증거 경계'
status: precursor-ready; visible-completion-blocked
story: '1.8'
issue: 'https://github.com/jinzer0/PaperLens/issues/10'
branch: issue/10-story-1-8
parent_epic: 'https://github.com/jinzer0/PaperLens/issues/3'
approval_record: 'https://github.com/jinzer0/PaperLens/issues/3#issuecomment-6049004229'
product_baseline: 5eac3bb9424ad893eca7d63bc319b71f580838ed
architecture_baseline: 1195c92227cc628e325f5ff24d70cc93639bf7a9
---

## Canonical intent / explicit proof gap

Canonical epics.md1.8(574–602), SOLUTION-DESIGN AD12/P6 및 committed1.7 공통 limits를 소비한다. 한 공통 automatic **zoom-v1** probe만 고정한다. Navigation fallback, source/CPU별 probe 변경은 금지한다.

이번 local precursor는 실제 public PDFKit/AppKit raster verifier 및 timing/profile/disposition state다. cacheDisplay는 **offscreen drawing**의 증거이지 compositor presentation/on-screen interaction의 증거가 아니다. 그 결과로 FirstInteractivePageAt/P6 PASS를 만들지 않는다. 실제 visible completion witness는 unresolved이며, 실제1.1 두CPU 구조와 four-source OS×CPU proof 없이 canonical Story1.8/P6/후속 Import·Reader timing split은 계속 blocked다. Prototype를 Reader 기능 완료로 표시하지 않는다.

## Named events / clock

ImportAcceptedAt은 Application이 source/type·folder/default·duplicate decision·local security scope를 확정한 validated intent를 Paper/Job identity와 함께 수락한 뒤, download/copy 전에 기록한다. Writer/publication permit의 기존 경계를 유지한다.

OpenReader intent를 acceptance 전에 queue하고 즉시 자동 presentation한다. 나중의 manual OpenReader를 기다리는 run은 noncomparable이며 추정 think time을 빼지 않는다. Command/presentation latency는 포함하고 사용자 choice/think time과 AI Job은 제외한다. AI를 기다리거나 artificial pause를 넣지 않는다.

FirstInteractivePageAt은 동일 attempt/probe/generation에서 예상 PDF-view의 **qualified visible update**가 main thread에서 완료됐다는 관측 후에만 기록한다. Document open/control enable/scale-change/CATransaction completion/timer로 대체하지 않는다. Local raster precursor의 RasterVerifiedAt과 분리한다. Same monotonic clock/attempt의 end-start만 비교하고 negative/reversed/stale/cross-attempt/missing event는 invalid 또는 missing이다. Wall-clock display timestamp는 증거가 아니다.

## Fixed public raster probe

- First page/CropBox/rotation0/single-page display/no page breaks/autoScales false. Viewport300×240 points, backing scale1 또는2만 지원. Fit scale 뒤 정확히1.25배 zoom 한 번; viewport/probe 변경이면 새 비교 set.
- CoreGraphics/CoreText로 unencrypted text PDF를 memory에 생성한다. CropBox320×240 points, 흰 바탕, 독립된 red/green/blue8×8 point fiducials를 x80/150/220,y100에 두고 읽을 수 있는 고정 synthetic text를 추가한다. 실제 사용자 PDF/디스크 문서/SDK는 읽지 않는다. Generated PDF≤65536 bytes, raster≤4194304 bytes.
- @MainActor에서 PDFKit layout/display와 public bitmapImageRepForCachingDisplay/cacheDisplay를 사용한다. Baseline pixel geometry부터 검증하고 zoom 뒤 실제 capture의 fiducial identity/width/pair distances가1.25배 예상치인지 검증한다. Tolerance는 backing pixels2. Blank/wrong-size/old-scale/wrong-color image를 통과시키지 않는다. PDFView.convert는 expectation의 위치만 보조하고 그 값 자체를 rendering proof로 쓰지 않는다.
- Capture가 synchronous return하고 pixel 검사를 통과한 경우에만 rasterVerified observation을 반환한다. Bounded main-run-loop observation이며 취소/generation mismatch/deadline 종료는 성공이 아니다. Private subview/API/screenshots/ScreenCapture/TCC 변경 금지. Unsupported/empty capture는 명시적 failure, fallback 없다.
- RasterVerifiedAt은 FirstInteractivePageAt을 채우지 않는다. Visible witness가 확립되지 않으면 missingCompletion과 block을 유지한다. 공개 API의 adequate on-screen witness를 만들어냈다고 주장하지 않는다.

## Source / environment profile

Local unit fixtures는 arxivAbstract/arxivPDF/httpsPDF/localPDF의 in-memory scripted metadata와 동일 generated text PDF를 사용한다. 이는 classification/event plumbing이지 실제 HTTP/security scope/transport proof가 아니다. Production Import/Provider/parser/DB를 구현하지 않는다.

URL/admission/resources는1.7 single contract를 소비한다. 별도 production validators/numeric policy를 복제하지 않는다. arXiv abs는 pinned host/ID grammar의 local abs→pdf mapping, 모든 redirects HTTPS/no userinfo; terminal200/application-pdf/identity/%PDF-; redirects5/headerBytes32768/headerCount64/body104857600/readBuffer65536/idle10000ms/total120000ms. Native1.7 ABI가 완성되기 전에는 연동하지 않는다.

실제 source trial에는 accessible arXiv abstract/PDF URL, general HTTPS fixture 및 local copy의 exact identity/profile/first-page oracle, cold/warm/cache state/viewport/backing scale와 ordinary unshaped network class가 필요하다. Generated geometric oracle을 unrelated 실제 paper에 적용하지 않는다. Actual fixture/oracle/network cells는 미확정이며 실제source proof를 fabricate하지 않는다. No login/OCR/encryption/AI work.

## Outcome / disposition / safe evidence

Outcomes: rasterVerified/qualifiedVisibleUpdate/missingCompletion/wrongUpdate/cancelled/invalidMeasurement/changedProbe/noncomparable. Missing/stale/negative observation에는 successful duration이 없다. 서로 다른 probe/profile/semantics의 samples를 합치지 않는다.

30000ms는 arXiv soft target이지 timeout/hard release fail이 아니다. 한 comparable exceedance는 review,2개 이상은 repeated, unusable output/resource/deadline/completion failure는 severe다. Repeated/severe에는 owner/cause/affected cells/action/retest 또는 explicit measured-risk disposition이 필요하고 missing evidence를 waiver로 바꾸지 않는다. GeneralHTTPS/local은 별도 baselines이지 새30s 제품 약속이 아니다.

Raw timestamps/durations/pixels/PDF/text/URLs/paths/input hashes/streams/exceptions는 RAM에만 둔다. P4 이전 새 logging/export system을 만들지 않는다. Durable test evidence는 code/profile/probe version, bounded source/CPU/OS/toolchain identity, outcome, durationBand(within-soft-target/over-soft-target/not-observed), geometryBand(within-tolerance/outside-tolerance/not-observed), disposition의 closed projection만. Source raw values·timing numbers로 기존 privacy limit을 완화하지 않는다.

## Exact local implementation and verification boundary

Committed Spec 후 implementation targets4개: Contracts/PDFReadiness/PDFReadiness.swift, Contracts/PDFReadiness/PDFKitReadinessProbe.swift, Tests/PDFReadiness/PDFReadinessTests.swift, Package.swift. Dedicated local library/test target만, 제품 Reader/Import 연결 없음. Existing files/wiring를 먼저 확인하고1.7 stable native types를 소비한다.

Pure tests: fixed probe/profile/all4sources, event ordering/cancellation/generation/changed profile, missing first-interactive, dispositions(한soft exceedance가release fail이아님), safe projection, expected/blank/oldscale/wrong-size geometry. Native precursor는 real generated PDF +main-thread PDFKit zoom/cacheDisplay +actual pixels를 검증한다. Fake render callback/scale notification은 증거가 아니다.

Native operation은 exact approved Xcode27.0/27A266a Swift6.4 arm64, fresh exclusive UUID scratch, generated in-memory inputs, no window/no network/no external documents를 대상으로 부모가 bounded test 실행한다. Local in-scope operation의 committed Spec과 현재 일괄 실행 승인으로 반복 승인 질문 없이 수행한다. 이 범위 밖 visible GUI/live HTTPS는 precise artifact/fixtures/action/count/budget/qualified witness/safe evidence를 명세한 뒤 해당 safety boundary를 충족해야 하며 현재 precursor 승인으로 임의 실행하지 않는다. Intel/Rosetta 실행 면제를 PASS로 만들지 않는다.

Parents own tests/formatter/whitespace/review/evidence/local commit. Static architect proposal was read-only; no tests/GUI/network/PDFKit trial was performed by that review. Actual four-source ×twoCPU ×minimum15/currentOS visible completion proof remains unresolved. This precursor alone never closes Story1.8/P6 or unlocks downstream timing builds.

## Reviewed local integration boundary

Story1.9–1.26 own-branch planning checkpoints and accepted Story1.13 pure/registered-synthetic code may be locally integrated without product admission. `JobRecoveryPolicyTests.swift` remains an independent isolated-driver suite, not ProviderRPCTests; Package.swift must explicitly exclude it from the RPC test directory. No new root recovery target, dependency, Xcode product wiring, helper/CI or Provider operation is admitted. Parent verifies unchanged root Python/native contracts and the separately compiled recovery suite; the consumed failed renderer is not rerun or converted to PASS. Epic map/sprint may record only actual checkpoints, retaining all26notDone and undefined1.27.

## Allocation-only destination audit — not a renderer retry

Readonly review72은 current custom `alphaNonpremultiplied` destination과 public failable `NSGraphicsContext(bitmapImageRep:)`의 compatibility를 credible-but-unproven hypothesis로 분류했다. Apple의 NSGraphicsContext initializer 문서는 nil failure와 single-plane requirement를 정의하며, archived Quartz Supported Pixel Formats table은 direct RGB32bpp/8bpc premultipliedFirst/Last 및 noneSkipFirst/Last를 나열한다. 이 표는 AppKit의 변환 가능성을 배제하거나 historical blankCapture의 원인을 증명하지 않는다. Production capture/format/scanner/threshold/oracle는 이 조사에서 변경하지 않는다.

- Own branch `issue/10-story-1-8`에서 이 same-Spec amendment를 test source보다 먼저 commit한다. 정확한 source target은 existing `Tests/PDFReadiness/PDFReadinessTests.swift` 하나다. Explicit AppKit import와 `testCurrentCaptureRGBAContextAllocationAtBothBackings`, `testPremultipliedRGBAContextAllocationAtBothBackings`만 추가한다. Package/production source/dependency/product wiring는 그대로다.
- Finite scope는 current straight-alpha tuple와 otherwise-identical premultiplied comparison을 backing1/2에서 각각 한 번씩, 총4 cases다. 각 case는 scoped autorelease pool에서 NSBitmapImageRep 한 개와 성공한 representation당 public NSGraphicsContext initializer 한 번만 사용하며 sequentially release한다. 실패를 재시도하거나 nil/non-nil을 모두 unconditional PASS로 처리하지 않는다. Representation 및 context의 실제 allocation availability를 assert하고 한 case의 non-throwing 실패가 다른 backing 관측을 막지 않게 한다.
- Exact tuple은 viewport300×240 points, pixels300×240 또는600×480, deviceRGB/8bits/four samples/alpha/single plane/32bpp/row width×4다. Current bitmapFormat은 alphaNonpremultiplied, comparison만 empty flags다. Actual representation dimensions/stride/component/sample/alpha/planarity/color space/format을 context 전후 확인한다. Returned public context layout/alpha/byte-order 및 storage alias/nonalias는 mapping 관측이지 pixel conversion/drawing proof가 아니다. Pointer 값은 RAM에만 둔다.
- NSApplication/NSView/PDFView/PDFDocument/Fixture/generatedPDF/renderer callback/window/cacheDisplay/draw/CGImage/separate CGContext/NSGraphicsContext.current/pixel read·write/array copy/network/SDK/user document/permission 변경은 실행하지 않는다. Raster4194304 cap과 다른 fixed limits는 그대로이며 nonalias/context 내부 overhead를 zero-copy나 measured RSS proof로 부르지 않는다.
- 부모는 approved Xcode27.0/27A266a Swift6.4 native arm64에서 exclusive UUID scratch로 위 두 named tests만 한 번 선택하고 outer30초 watchdog 및 owned loader exit/reap을 확인한다. Raw framework diagnostics/timing/pointers는 RAM에만 보관한다. 기존 evidence에는 code/toolchain identity, four closed case outcomes, typed layout classifications, executed test/failure count, watchdog/reap 및 scope만 기록한다. Context unavailable이면 그 test failure를 그대로 기록하며 기대값/format/threshold를 바꿔 green으로 만들지 않는다.
- 양 tuple가 available이면 이 initializer의 silent-nil hypothesis를 해당 environment/backing에서 기각할 수 있을 뿐 actual cacheDisplay mapping이나 renderer 성공은 미검증이다. Current unavailable/comparison available이면 tuple-specific allocator 실패이며 renderer root cause나 format replacement 권한이 아니다. Any production capability guard는 필요한 exact semantic/source/test amendment를 별도로 먼저 commit하고 검증한다. Historical blankCaptureFAILED, consumed renderer/control/live SDK trial 상태, qualified visible witness 없음과 actual P1/P2/P3/P6/Story completion false를 유지한다.

## Typed destination preflight — explicit precursor eligibility

This section records the prior eb8808c/81dd7cc eligibility phase and its unchanged historical verification. The new phase below supersedes only its future production straight-alpha/test-only-comparison restriction; it does not reinterpret the failed allocator audit or grant a renderer retry.

## Chosen production destination and canonical-alpha eligibility

Readonly84 at e836cf72 inspected exactly this Spec, production probe, readiness state/scanner, tests and governance. Its conditional in-scope assessment identifies a genuine nonpainting source phase, not raster/visible verification: premultiplication can change threshold classification when alpha250–254, so raw comparison promotion is refused. Under existing Whole-Epic approval choose fixed premultiplied storage plus a stricter canonical-alpha capture admission. Every counted pixel must have alpha255, where RGB has the same numerical meaning as the prior canonical scanner. Reject any alpha250–254 before scan as unsupportedCapture; retain alpha below250 as ignored by the unchanged scanner. Disclose that real capture may fail this new precondition. Do not unpremultiply, rewrite RGB, enlarge tolerances or relax pixel meaning/limits.

- Commit this same Spec on own `issue/10-story-1-8` BEFORE code. Exact implementation targets are only `Contracts/PDFReadiness/PDFKitReadinessProbe.swift` and `Tests/PDFReadiness/PDFReadinessTests.swift`; ReadinessPixels/state/contract, Package, product wiring and dependencies are unchanged.
- Extract the existing destination constructor into internal `allocateCaptureBitmap(backing: ReadinessBacking) throws -> NSBitmapImageRep` on the existing MainActor enum. Fixed viewport300×240, backing1/2, deviceRGB/8bpc/4samples/alpha/nonplanar/32bpp/row width×4, empty bitmap flags. Validate actual dimensions/stride/alpha/color-space/exact flags/data availability before and after exactly one existing real scoped context preflight; return only bitmap, never context/current state. Production capture uses this constructor after the existing natural-representation plus destination/copy budget check; no alternate allocator/fallback. Validate the same layout again after cacheDisplay.
- Add pure internal `requireCanonicalScannerAlpha(_ rgba: [UInt8]) throws -> Void`: reject empty/malformed/non-four-byte-aligned/over-cap buffers and alpha250–254, without copying/mutating bytes, drawing, context calls or new numeric limits. Reuse the existing bounded capture RGBA copy, call this guard BEFORE unchanged ReadinessPixels.scan. Blank alpha below250 still reaches existing blankCapture handling. View/coordinate/geometry/zoom/oracle/scanner/threshold/PDF65536/raster4194304 limits remain unchanged; post-cache layout/actual alpha are UNVERIFIED without a separately authorized renderer trial.
- Replace only the obsolete comparison-only positive test with one exercising the actual production constructor at both backings; retain a clearly named straight-alpha negative preflight regression and historical method identities in evidence. No duplicated positive constructor/context probe. Assert actual metadata and data availability; no NSApplication/View/PDF/document/draw/cacheDisplay/currentContext/CGImage/native pixel read/write. Pure array tests cover every partial-alpha250–254, accepted255, ignored0/249, malformed/over-cap buffer and unchanged full-alpha geometry/zoom at both backings. Guard acceptance is not scan success: ignored-only arrays must still fail blankCapture. No always-accept/always-throw/no-op guard can satisfy paired tests.
- Parent performs one formatter pass over changed Swift files and diff check; fresh exclusive UUID native build using approved arm64 Swift6.4 environment, isolated byte-identical sources/caches/config/security/scratch/modules/tmp and account-metadata Home. Select the two allocation/preflight tests once each (one actual bitmap/context per backing/case), new pure alpha tests and existing13 nonrenderer regressions plus request31/RPC18; each suite once, positive XCTest summaries, 30s outer watchdog and owned loader reap. Do not select original failed allocator/renderer tests or renew live/SDK/control/GUI/PDF drawing trials. Parent Python focused/union verification only if directly affected; unchanged Python uses prior416/34 evidence with source identity rather than a claimed new run.
- Obtain independent source review before local code/evidence commit; preserve all old evidence keys, allocator fe18834 FAILED and renderer ea270b54 blankCaptureFAILED. Fresh micro can prove ONLY production allocation/preflight and pure alpha admission in its measured environment, not actual cacheDisplay layout/alpha/raster/root cause/visible callback/cross-OS-CPU/RSS/framework retention. Actual P1/P2/P3/P6, FirstInteractivePageAt and all Story completion remain unproved. No ordinary approval here renews exhausted renderer/control allowances.

## Historical typed destination preflight details

위 diagnostic은 checkpointfe188348a1faf76382edb2d133518595e822cce6에 FAILED로 보존했다. Native78f6aace-f44f-46cc-8869-699b2dfad88d의2 tests/2 assertion failures, sourceSHAa66dda171df6c2d8f1abe71bb9da6a8333078640a002a76e3ca06769cc74cab2, 기존 두 test names와 four outcomes를 바꾸지 않는다. Current straight-alpha 두 backings에서 public initializer nil, premultiplied comparison 두 backings에서 available/requested layout/alias라는 측정만 확인했다. 독립75 WATCH/APPROVE는 truthful failed diagnostic만 검토했고 working raster나 implemented guard를 인증하지 않았다.

- Same-Spec을 own issue10 branch에서 먼저 commit한 뒤 정확히 `Contracts/PDFReadiness/PDFKitReadinessProbe.swift`, `Tests/PDFReadiness/PDFReadinessTests.swift` 두 파일만 수정한다. Local precursor의 **새 explicit eligibility**로 destination이 public NSGraphicsContext initializer를 허용해야 한다. 이는 cacheDisplay 내부의 필수 단계라는 문서 주장이나 renderer repair가 아니라 선택한 fail-closed precondition이다. Production bitmapFormat/byte order/scanner/threshold/oracle/viewport/backing/zoom/budgets/dependencies/product wiring는 그대로다.
- Existing @MainActor enum에 internal `requireBitmapGraphicsContext(for: NSBitmapImageRep) throws -> Void`를 추가한다. Scoped autorelease pool에서 real `NSGraphicsContext(bitmapImageRep:)`를 정확히 한 번 호출하고 nil이면 `ReadinessFailure.unsupportedCapture`를 throw한다. Context/current state를 return/store/set하지 않고 drawing/fallback을 수행하지 않는다. `bitmap.size = view.bounds.size` 직후, pixel zeroing/cacheDisplay 직전에 호출한다. Temporary context는 그 뒤 retain하지 않는다. Existing observe의 unsupportedCapture immediate propagation을 유지한다. 이 guard는 이전 NSApplication/PDFKit setup/display/layout 전체의 선행 gate가 아니다.
- 기존 두 allocator diagnostic methods와 private audit helper를 제거하고 실제 production-helper regressions `testBitmapGraphicsContextPreflightRejectsCurrentTupleAtBothBackings`, `testBitmapGraphicsContextPreflightAcceptsPremultipliedTupleAtBothBackings`로 대체한다. Historical failed availability assertions/run을 PASS로 뒤집는 것이 아니라 위 새 rejection contract의 두 branches를 검증한다. Current tuple은 exact typed failure, comparison tuple은 정상 return을 요구하므로 no-op/always-throw helper는 각각 실패한다. Comparison은 test-only이며 production format fallback이 아니다.
- Four sequential real-allocation cases의 각 pool에서 기존 exact tuple의 bitmap 한 개와 production helper의 실제 initializer 한 번만 사용한다. Requested metadata를 전후 확인하며 별도 context probe/mock/provider/Fixture/PDF/View/Window/generatedPDF/draw/cacheDisplay/CGImage/currentContext/pixel 접근·복사/SDK/network를 실행하지 않는다. Observed availability에 따라 기대값을 동적으로 바꾸지 않는다. 검증 scope는 approved measured native arm64 environment이며 모든 OS/CPU에 대한 API 보장이 아니다.
- 부모가 fresh exclusive UUID native build, 위 두 named helper tests의 single invocation/outer30초 watchdog/owned loader reap 및 별도 기존 non-renderer contract 회귀를 검증한다. Raw diagnostics/timing/pointers는 RAM에만, durable evidence는 source/artifact identity/count/typed outcomes/limitations만 둔다. Agent는 gates/formatter/Git mutations 없이 두 파일만 수정하고 부모가 formatter/독립 리뷰/로컬 evidence commit을 담당한다. 원래 FAILED diagnostic, blankCaptureFAILED, missing qualified visible witness, actual P1/P2/P3/P6/Story completion false를 유지한다. 새 renderer/native-PDF/GUI/SDK/control/live trial은 승인하지 않는다.
