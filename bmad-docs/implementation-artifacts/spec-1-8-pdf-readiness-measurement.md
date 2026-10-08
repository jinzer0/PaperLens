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
