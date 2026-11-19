//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Metal
import XCTest

class PageCurlGeometryTests: XCTestCase {
    private func request(
        preference: PageTransition = .curl,
        animated: Bool = true,
        reduceMotion: Bool = false,
        scrolls: Bool = false,
        voiceOverRunning: Bool = false,
        resourceDistance: Int? = nil
    ) -> PageTransitionPolicy.Request {
        PageTransitionPolicy.Request(
            preference: preference,
            animated: animated,
            reduceMotion: reduceMotion,
            scrolls: scrolls,
            voiceOverRunning: voiceOverRunning,
            resourceDistance: resourceDistance,
            overrideRaw: nil
        )
    }

    func testProgressClampsAndEaseInOutIsFlatAtTheEnds() {
        XCTAssertEqual(PageCurlGeometry.clampProgress(-0.4), 0)
        XCTAssertEqual(PageCurlGeometry.clampProgress(0), 0)
        XCTAssertEqual(PageCurlGeometry.clampProgress(0.4), 0.4)
        XCTAssertEqual(PageCurlGeometry.clampProgress(1), 1)
        XCTAssertEqual(PageCurlGeometry.clampProgress(3), 1)
        XCTAssertEqual(PageCurlGeometry.clampProgress(.nan), 0)
        XCTAssertEqual(PageCurlGeometry.clampProgress(.infinity), 0)

        XCTAssertEqual(PageCurlGeometry.easeInOut(0), 0)
        XCTAssertEqual(PageCurlGeometry.easeInOut(1), 1)
        XCTAssertEqual(PageCurlGeometry.easeInOut(0.5), 0.5)
        // Slower than linear at the start, so the leaf does not jump.
        XCTAssertLessThan(PageCurlGeometry.easeInOut(0.2), 0.2)
        XCTAssertGreaterThan(PageCurlGeometry.easeInOut(0.8), 0.8)
        XCTAssertEqual(PageCurlGeometry.tapDuration, 0.38, accuracy: 0.0001)
    }

    func testRadiusClosesAtTheEndsAndTiltFollowsTheFinger() {
        XCTAssertEqual(PageCurlGeometry.cylinderRadius(progress: 0, span: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.cylinderRadius(progress: 1, span: 1), 0, accuracy: 0.0001)
        let mid = PageCurlGeometry.cylinderRadius(progress: 0.5, span: 1)
        XCTAssertEqual(mid, PageCurlGeometry.peakRadius, accuracy: 0.0001)
        // Wide enough to read as paper. A thin band was 0.07.
        XCTAssertGreaterThanOrEqual(PageCurlGeometry.peakRadius, 0.09)
        XCTAssertLessThanOrEqual(PageCurlGeometry.peakRadius, 0.14)
        // A narrow leaf does not grow a cylinder wider than itself.
        let narrow = PageCurlGeometry.cylinderRadius(progress: 0.5, span: 0.1)
        XCTAssertLessThanOrEqual(narrow, 0.1 * 0.45 + 0.0001)

        // A tap lifts the bottom corner. A finger at mid-page stays vertical.
        let tapTilt = PageCurlGeometry.tiltRadians(touchY: PageCurlGeometry.tapTouchY)
        XCTAssertGreaterThan(tapTilt, 0.25)
        XCTAssertLessThan(tapTilt, PageCurlGeometry.maxTilt)
        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: 0), -PageCurlGeometry.maxTilt, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: 1), PageCurlGeometry.maxTilt, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: -2), -PageCurlGeometry.maxTilt, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: 4), PageCurlGeometry.maxTilt, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: .nan), 0)
    }

    func testSpineResolutionForOnePageTwoPageAndTheFold() {
        XCTAssertEqual(PageCurlGeometry.resolveSpine(renderedColumns: 1, rtl: false, divisionNormalizedX: nil), .leading)
        XCTAssertEqual(PageCurlGeometry.resolveSpine(renderedColumns: 0, rtl: false, divisionNormalizedX: nil), .leading)
        XCTAssertEqual(PageCurlGeometry.resolveSpine(renderedColumns: 1, rtl: true, divisionNormalizedX: nil), .trailing)
        // A fold x must not slice a one-column page.
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 1, rtl: false, divisionNormalizedX: 0.47),
            .leading
        )
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: false, divisionNormalizedX: nil),
            .center(normalizedX: 0.5)
        )
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: true, divisionNormalizedX: nil),
            .center(normalizedX: 0.5)
        )
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: false, divisionNormalizedX: 0.47),
            .center(normalizedX: 0.47)
        )
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: false, divisionNormalizedX: 0.50),
            .center(normalizedX: 0.5)
        )
        // Outside the band the fold is clamped, not used raw.
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: false, divisionNormalizedX: 0.1),
            .center(normalizedX: 0.35)
        )
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: true, divisionNormalizedX: 0.9),
            .center(normalizedX: 0.65)
        )
        XCTAssertEqual(
            PageCurlGeometry.resolveSpine(renderedColumns: 2, rtl: false, divisionNormalizedX: .nan),
            .center(normalizedX: 0.5)
        )
    }

    func testAnimationSpineKeepsTheBindingOnTheWayBack() {
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: false, forward: true, divisionNormalizedX: nil),
            .leading
        )
        // A backward one-page turn uncurls from the same spine. It does not
        // peel the current page off the opposite edge.
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: false, forward: false, divisionNormalizedX: nil),
            .leading
        )
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: true, forward: true, divisionNormalizedX: nil),
            .trailing
        )
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: true, forward: false, divisionNormalizedX: nil),
            .trailing
        )
        XCTAssertTrue(PageCurlGeometry.playsReversed(renderedColumns: 1, forward: false))
        XCTAssertFalse(PageCurlGeometry.playsReversed(renderedColumns: 1, forward: true))
        XCTAssertFalse(PageCurlGeometry.playsReversed(renderedColumns: 2, forward: false))
        XCTAssertFalse(PageCurlGeometry.playsReversed(renderedColumns: 0, forward: true))
        XCTAssertTrue(PageCurlGeometry.playsReversed(renderedColumns: 0, forward: false))
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 2, rtl: false, forward: false, divisionNormalizedX: 0.47),
            .center(normalizedX: 0.47)
        )
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 2, rtl: true, forward: true, divisionNormalizedX: nil),
            .center(normalizedX: 0.5)
        )

        let centre = PageCurlSpine.center(normalizedX: 0.5)
        XCTAssertEqual(PageCurlGeometry.peelSign(spine: .leading, rtl: false, forward: true), 1)
        XCTAssertEqual(PageCurlGeometry.peelSign(spine: .trailing, rtl: true, forward: true), -1)
        XCTAssertEqual(PageCurlGeometry.peelSign(spine: centre, rtl: false, forward: true), 1)
        XCTAssertEqual(PageCurlGeometry.peelSign(spine: centre, rtl: false, forward: false), -1)
        XCTAssertEqual(PageCurlGeometry.peelSign(spine: centre, rtl: true, forward: true), -1)
        XCTAssertEqual(PageCurlGeometry.peelSign(spine: centre, rtl: true, forward: false), 1)

        XCTAssertEqual(PageCurlGeometry.span(spine: .leading, peelSign: 1), 1)
        XCTAssertEqual(PageCurlGeometry.span(spine: .trailing, peelSign: -1), 1)
        XCTAssertEqual(PageCurlGeometry.span(spine: centre, peelSign: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            PageCurlGeometry.span(spine: .center(normalizedX: 0.47), peelSign: 1),
            0.53,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PageCurlGeometry.span(spine: .center(normalizedX: 0.47), peelSign: -1),
            0.47,
            accuracy: 0.0001
        )
    }

    func testDowngradeRules() {
        XCTAssertEqual(PageCurlGeometry.rendered(request(animated: false)), .none)
        XCTAssertEqual(PageCurlGeometry.rendered(request(reduceMotion: true)), .none)
        XCTAssertEqual(PageCurlGeometry.rendered(request(scrolls: true)), .none)
        XCTAssertEqual(PageCurlGeometry.rendered(request(voiceOverRunning: true)), .none)
        XCTAssertEqual(PageCurlGeometry.rendered(request(preference: .none)), .none)
        XCTAssertEqual(PageCurlGeometry.rendered(request()), .curl)
        XCTAssertEqual(PageCurlGeometry.rendered(request(resourceDistance: nil)), .curl)
        XCTAssertEqual(PageCurlGeometry.rendered(request(resourceDistance: 1)), .curl)
        XCTAssertEqual(PageCurlGeometry.rendered(request(resourceDistance: 2)), .fade)
        XCTAssertEqual(PageCurlGeometry.rendered(request(resourceDistance: 5)), .fade)
        XCTAssertEqual(PageCurlGeometry.rendered(request(preference: .slide, resourceDistance: 4)), .slide)
        XCTAssertEqual(PageCurlGeometry.rendered(request(preference: .fade)), .fade)
        // A jump still fades when the other gates have already forced none.
        XCTAssertEqual(PageCurlGeometry.rendered(request(animated: false, resourceDistance: 3)), .none)
    }

    func testBacksidePaperFollowsTheTheme() {
        let oled = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0, g: 0, b: 0))
        XCTAssertGreaterThan(oled.r, 0.05)
        XCTAssertLessThan(oled.r, 0.10)
        XCTAssertEqual(oled.mix, PageCurlGeometry.backsideMix, accuracy: 0.0001)
        XCTAssertLessThan(oled.specular, 0.2)

        // Light is white, slightly greyed. Warming it produced a beige leaf.
        let light = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(light.mix, PageCurlGeometry.backsideMix, accuracy: 0.0001)
        XCTAssertEqual(light.r, 0.96, accuracy: 0.001)
        XCTAssertEqual(light.g, light.r, accuracy: 0.001)
        XCTAssertEqual(light.b, light.r, accuracy: 0.001)

        let sepiaBackground = PageCurlRGB(r: 0.984, g: 0.941, b: 0.851)
        let sepia = PageCurlGeometry.backsidePaper(background: sepiaBackground)
        XCTAssertEqual(sepia.mix, PageCurlGeometry.backsideMix, accuracy: 0.0001)
        XCTAssertEqual(sepia.r, sepiaBackground.r * 0.92, accuracy: 0.001)
        XCTAssertEqual(sepia.g, sepiaBackground.g * 0.92, accuracy: 0.001)
        XCTAssertEqual(sepia.b, sepiaBackground.b * 0.92, accuracy: 0.001)
        XCTAssertGreaterThan(sepia.r, sepia.b)

        let dark = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0.12, g: 0.12, b: 0.13))
        XCTAssertEqual(dark.r, 0.20, accuracy: 0.001)
        XCTAssertEqual(dark.g, 0.20, accuracy: 0.001)
        XCTAssertEqual(dark.b, 0.22, accuracy: 0.001)

        // The dark branch is 0.06 <= luminance < 0.28. Just inside both ends.
        let darkFloor = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0.07, g: 0.07, b: 0.07))
        XCTAssertEqual(darkFloor.r, 0.20, accuracy: 0.001)
        XCTAssertEqual(darkFloor.b, 0.22, accuracy: 0.001)
        let darkCeil = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0.27, g: 0.27, b: 0.27))
        XCTAssertEqual(darkCeil.r, 0.20, accuracy: 0.001)
        let aboveDark = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0.30, g: 0.30, b: 0.30))
        XCTAssertEqual(aboveDark.r, 0.30 * 0.96, accuracy: 0.001)
    }

    func testTiltedFoldDoesNotPopACorner() {
        // Portrait phone, tap at the bottom corner. The old fold (`span * (1 - progress)`)
        // put ~32% of the bottom edge on the incoming page at progress 0.002.
        let aspect = 390.0 / 844.0
        let tilt = PageCurlGeometry.tiltRadians(touchY: PageCurlGeometry.tapTouchY)
        let span: CGFloat = 1
        let overhang = PageCurlGeometry.tiltOverhang(tilt: tilt, aspect: aspect)
        XCTAssertGreaterThan(overhang, 0.25)

        func popped(progress: CGFloat, atBottom: Bool) -> CGFloat {
            let radius = PageCurlGeometry.cylinderRadius(progress: progress, span: span)
            let fold = PageCurlGeometry.foldCenter(
                progress: progress,
                span: span,
                overhang: overhang,
                curlWidth: radius * 2,
                far: 0
            )
            let line = PageCurlGeometry.foldLine(
                fold: fold,
                tilt: tilt,
                normalizedY: atBottom ? 1 : 0,
                aspect: aspect
            )
            if atBottom {
                return max(0, span - line)
            }
            return max(0, line)
        }

        XCTAssertEqual(popped(progress: 0, atBottom: true), 0, accuracy: 0.0001)
        XCTAssertLessThan(popped(progress: 0.002, atBottom: true), 0.02)
        XCTAssertEqual(popped(progress: 1, atBottom: false), 0, accuracy: 0.0001)
        XCTAssertLessThan(popped(progress: 0.998, atBottom: false), 0.02)
    }

    func testTwoPageFoldCrossesTheFarHalf() {
        let span: CGFloat = 0.5
        let midRadius = PageCurlGeometry.cylinderRadius(progress: 0.5, span: span)
        let mid = PageCurlGeometry.foldCenter(
            progress: 0.5,
            span: span,
            overhang: 0,
            curlWidth: midRadius * 2,
            far: PageCurlGeometry.farSpan(twoPage: true, span: span)
        )
        // Halfway, the fold has crossed the spine. The far half is not frozen.
        XCTAssertLessThan(mid, 0)

        let endRadius = PageCurlGeometry.cylinderRadius(progress: 0.998, span: span)
        let end = PageCurlGeometry.foldCenter(
            progress: 0.998,
            span: span,
            overhang: 0,
            curlWidth: endRadius * 2,
            far: 0.5
        )
        XCTAssertLessThan(end, -0.4)
        XCTAssertEqual(PageCurlGeometry.farSpan(twoPage: false, span: 1), 0)
    }

    func testUsedColumnCountFollowsTheWidthsThatFit() {
        // 2 × 400pt columns do not fit in 800pt with a gap. CSS still says 2.
        XCTAssertEqual(
            PageCurlGeometry.usedColumnCount(cssColumnCount: 2, columnWidth: 400, columnGap: 20, innerWidth: 800),
            1
        )
        XCTAssertEqual(
            PageCurlGeometry.usedColumnCount(cssColumnCount: 2, columnWidth: 300, columnGap: 20, innerWidth: 800),
            2
        )
        // `column-width: auto` does not parse. Trust the CSS count.
        XCTAssertEqual(
            PageCurlGeometry.usedColumnCount(cssColumnCount: 2, columnWidth: 0, columnGap: 0, innerWidth: 800),
            2
        )
        XCTAssertEqual(
            PageCurlGeometry.usedColumnCount(cssColumnCount: 1, columnWidth: 100, columnGap: 0, innerWidth: 800),
            1
        )
        XCTAssertEqual(
            PageCurlGeometry.usedColumnCount(cssColumnCount: 2, columnWidth: .nan, columnGap: 10, innerWidth: 800),
            2
        )

        let probe: [NSNumber] = [2, 400, 20, 800]
        XCTAssertEqual(PageCurlGeometry.usedColumnCount(parsing: probe), 1)
        XCTAssertEqual(PageCurlGeometry.usedColumnCount(parsing: NSNumber(value: 2)), 2)
        XCTAssertEqual(PageCurlGeometry.usedColumnCount(parsing: nil), 1)
        XCTAssertEqual(PageCurlGeometry.usedColumnCount(parsing: "nope"), 1)
    }

    func testSnapshotFailureDoesNotCurlTheOutgoingPage() {
        XCTAssertEqual(PageCurlGeometry.captureRoute(webViewCount: 1, snapshotSucceeded: true), .webSnapshot)
        XCTAssertEqual(PageCurlGeometry.captureRoute(webViewCount: 1, snapshotSucceeded: false), .failed)
        XCTAssertEqual(PageCurlGeometry.captureRoute(webViewCount: 0, snapshotSucceeded: false), .hierarchy)
        XCTAssertEqual(PageCurlGeometry.captureRoute(webViewCount: 2, snapshotSucceeded: true), .hierarchy)
        XCTAssertEqual(PageCurlGeometry.incomingReveal(snapshotSucceeded: true), .cylinder)
        XCTAssertEqual(PageCurlGeometry.incomingReveal(snapshotSucceeded: false), .crossfade)
    }

    func testUniformStrideMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<PageCurlUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<PageCurlUniforms>.size, 64)
    }

    func testCurlShaderCompiles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        do {
            let library = try device.makeLibrary(source: PageCurlShader.source, options: nil)
            XCTAssertNotNil(library.makeFunction(name: "curlVertex"))
            XCTAssertNotNil(library.makeFunction(name: "curlFragment"))
        } catch {
            XCTFail("Metal curl shader failed to compile: \(error)")
        }
    }
}
