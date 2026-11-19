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

    /// Rows of the posture matrix. A horizontal fold is not a spine. One
    /// rendered column stays an edge curl, which is what an AX size does
    /// when the stylesheet collapses to a single column.
    func testSpineResolveFollowsRenderedColumnsAndAVerticalFold() {
        let viewport = CGRect(x: 0, y: 0, width: 900, height: 600)
        let vertical = PageCurlDivisionSample(
            frame: CGRect(x: 393, y: 0, width: 60, height: 600), isActive: true
        )
        let horizontal = PageCurlDivisionSample(
            frame: CGRect(x: 0, y: 280, width: 900, height: 40), isActive: true
        )
        let inactive = PageCurlDivisionSample(frame: vertical.frame, isActive: false)
        let crease = PageCurlDivisionSample(
            frame: CGRect(x: 420, y: 0, width: 0, height: 600), isActive: true
        )

        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 1, rtl: false, regions: [vertical], viewport: viewport),
            .leading
        )
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 1, rtl: true, regions: [vertical], viewport: viewport),
            .trailing
        )
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 0, rtl: false, regions: [vertical], viewport: viewport),
            .leading
        )
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: false, regions: [], viewport: viewport),
            .center(normalizedX: 0.5)
        )
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: true, regions: [inactive], viewport: viewport),
            .center(normalizedX: 0.5)
        )
        // Tabletop. The fold is ignored, so two columns stay centred and one
        // column stays an edge.
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: false, regions: [horizontal], viewport: viewport),
            .center(normalizedX: 0.5)
        )
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 1, rtl: true, regions: [horizontal], viewport: viewport),
            .trailing
        )

        assertCenter(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: false, regions: [vertical], viewport: viewport),
            423.0 / 900.0
        )
        assertCenter(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: true, regions: [vertical], viewport: viewport),
            423.0 / 900.0
        )
        assertCenter(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: false, regions: [crease], viewport: viewport),
            420.0 / 900.0
        )

        let outside = PageCurlDivisionSample(
            frame: CGRect(x: 1000, y: 0, width: 40, height: 600), isActive: true
        )
        XCTAssertEqual(
            PageCurlSpine.resolve(renderedColumns: 2, rtl: false, regions: [outside], viewport: viewport),
            .center(normalizedX: 0.5)
        )
    }

    func testColumnGapCoversTheCreaseAndAnOffCentreFold() {
        let viewport = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(defaultGap: 0, foldFrame: nil, viewport: viewport),
            0
        )
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(defaultGap: 12, foldFrame: nil, viewport: viewport),
            12
        )
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(
                defaultGap: 0,
                foldFrame: CGRect(x: 426, y: 0, width: 48, height: 600),
                viewport: viewport
            ),
            48
        )
        // Fold at 393...453. A centred gap of 60 still leaves text under the
        // hinge, so the gap widens to 114.
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(
                defaultGap: 0,
                foldFrame: CGRect(x: 393, y: 0, width: 60, height: 600),
                viewport: viewport
            ),
            114
        )
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(
                defaultGap: 20,
                foldFrame: CGRect(x: 445, y: 0, width: 10, height: 600),
                viewport: viewport
            ),
            20
        )
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(
                defaultGap: 20,
                foldFrame: CGRect(x: 430, y: 0, width: 40, height: 600),
                viewport: viewport
            ),
            40
        )
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(
                defaultGap: 8,
                foldFrame: CGRect(x: 450, y: 0, width: 0, height: 600),
                viewport: viewport
            ),
            8
        )
        // A fold that runs to the window edge used to ask for a clearance as
        // wide as the viewport. Cap it so cloned column padding still leaves text.
        let narrow = CGRect(x: 0, y: 0, width: 450, height: 600)
        let edgeFold = CGRect(x: 360, y: 0, width: 80, height: 600)
        XCTAssertEqual(
            PageCurlGeometry.columnGapClearingFold(defaultGap: 0, foldFrame: edgeFold, viewport: narrow),
            450 * PageCurlGeometry.maxFoldClearanceFraction
        )
        XCTAssertEqual(PageCurlGeometry.foldInsetLength(clearance: 114), "57.00000px")
        XCTAssertNil(PageCurlGeometry.foldInsetLength(clearance: 0))
        XCTAssertTrue(PageCurlGeometry.foldInsetRules.contains("box-decoration-break: clone"))
        XCTAssertTrue(PageCurlGeometry.foldInsetRules.contains("column-gap: 0px"))
        XCTAssertTrue(PageCurlGeometry.foldInsetRules.contains("var(--RS__foldInset)"))
    }

    func testActiveVerticalDivisionDropsTabletopInactiveAndTheLoser() {
        let viewport = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertNil(PageCurlGeometry.activeVerticalDivision(
            regions: [PageCurlDivisionSample(
                frame: CGRect(x: 0, y: 280, width: 900, height: 40), isActive: true
            )],
            viewport: viewport
        ))
        XCTAssertNil(PageCurlGeometry.activeVerticalDivision(
            regions: [PageCurlDivisionSample(
                frame: CGRect(x: 430, y: 0, width: 40, height: 600), isActive: false
            )],
            viewport: viewport
        ))
        let narrow = CGRect(x: 430, y: 0, width: 20, height: 600)
        let wide = CGRect(x: 400, y: 0, width: 80, height: 600)
        XCTAssertEqual(
            PageCurlGeometry.activeVerticalDivision(
                regions: [
                    PageCurlDivisionSample(frame: narrow, isActive: true),
                    PageCurlDivisionSample(frame: wide, isActive: true)
                ],
                viewport: viewport
            ),
            wide
        )
        let onTheEdge = PageCurlDivisionSample(
            frame: CGRect(x: 860, y: 0, width: 80, height: 600), isActive: true
        )
        XCTAssertNil(PageCurlGeometry.activeVerticalDivision(regions: [onTheEdge], viewport: viewport))
        XCTAssertNil(PageCurlGeometry.normalizedDivisionX(
            of: CGRect(x: 10, y: 0, width: 10, height: 10),
            in: CGRect(x: 0, y: 0, width: 1, height: 600)
        ))
    }

    private func assertCenter(
        _ spine: PageCurlSpine,
        _ x: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .center = spine else {
            XCTFail("expected a centre spine, got \(spine)", file: file, line: line)
            return
        }
        XCTAssertEqual(spine.normalizedX, x, accuracy: 0.0001, file: file, line: line)
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

    func testTwoPageRollSamplesTheTurningLeaf() {
        let spine: CGFloat = 0.5
        let span: CGFloat = 0.5

        // Still on the near half. The front is the outgoing right page.
        // The back is the incoming left page, not the incoming right page.
        let nearFront = rollSample(progress: 0.25, t: 0.25, spine: spine, span: span)
        XCTAssertEqual(nearFront.region, .rollFront)
        XCTAssertEqual(nearFront.sheet, .outgoing)
        XCTAssertGreaterThan(nearFront.x, spine)

        let nearBack = rollSample(progress: 0.25, t: 0.75, spine: spine, span: span)
        XCTAssertEqual(nearBack.region, .rollBack)
        XCTAssertEqual(nearBack.sheet, .incoming)
        XCTAssertLessThan(nearBack.x, spine)

        // The fold has crossed the spine. Both faces of the roll lay the
        // verso (incoming left) down. They do not peel the static left page
        // or paint the incoming right page on the back.
        let farFront = rollSample(progress: 0.75, t: 0.25, spine: spine, span: span)
        XCTAssertEqual(farFront.region, .rollFront)
        XCTAssertEqual(farFront.sheet, .incoming)
        XCTAssertLessThan(farFront.x, spine)
        XCTAssertGreaterThanOrEqual(farFront.x, 0)

        let farBack = rollSample(progress: 0.75, t: 0.75, spine: spine, span: span)
        XCTAssertEqual(farBack.region, .rollBack)
        XCTAssertEqual(farBack.sheet, .incoming)
        XCTAssertLessThan(farBack.x, spine)
        XCTAssertGreaterThanOrEqual(farBack.x, 0)

        let staticLeft = PageCurlGeometry.spreadSample(
            uvX: 0, uvY: 0.5, progress: 0.75,
            spineX: spine, peelSign: 1, span: span,
            twoPage: true, realVerso: true, tilt: 0, aspect: 1
        )
        XCTAssertEqual(staticLeft.region, .flatOutgoing)
        XCTAssertEqual(staticLeft.sheet, .outgoing)

        let revealedRight = PageCurlGeometry.spreadSample(
            uvX: 0.9, uvY: 0.5, progress: 0.75,
            spineX: spine, peelSign: 1, span: span,
            twoPage: true, realVerso: true, tilt: 0, aspect: 1
        )
        XCTAssertEqual(revealedRight.region, .flatIncoming)
        XCTAssertEqual(revealedRight.sheet, .incoming)
        XCTAssertGreaterThan(revealedRight.x, spine)
    }

    func testAsymmetricVersoStaysInsideTheFarHalf() {
        let span: CGFloat = 0.53
        let spine: CGFloat = 0.47
        let along = PageCurlGeometry.versoAlong(orig: 0.50, span: span, twoPage: true)
        let x = spine + along
        XCTAssertGreaterThanOrEqual(x, 0)
        XCTAssertLessThan(x, spine)
        // Unscaled `-orig` would land past the left edge.
        XCTAssertLessThan(spine - 0.50, 0)
    }

    func testReversedTiltFlipsTheCorner() {
        let bottom = PageCurlGeometry.tiltRadians(touchY: 0.9)
        XCTAssertGreaterThan(bottom, 0)
        XCTAssertEqual(PageCurlGeometry.displayedTilt(touchY: 0.9, reversed: false), bottom, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.displayedTilt(touchY: 0.9, reversed: true), -bottom, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.displayedTilt(touchY: 0.5, reversed: true), 0, accuracy: 0.0001)
    }

    func testColumnCorrectionScrollsToTheAbsoluteTarget() {
        // Three points short of the column. Another page-width would skip one.
        XCTAssertEqual(PageCurlGeometry.curlColumnCorrection(offset: 780, target: 783), 3, accuracy: 0.001)
        XCTAssertEqual(PageCurlGeometry.curlColumnCorrection(offset: 781.5, target: 783), 0, accuracy: 0.001)
        // Snapped all the way back to the start. One page, toward the target.
        XCTAssertEqual(PageCurlGeometry.curlColumnCorrection(offset: 393, target: 783), 390, accuracy: 0.001)
        // Already past the target. Come back, do not add another page.
        XCTAssertEqual(PageCurlGeometry.curlColumnCorrection(offset: 1170, target: 783), -387, accuracy: 0.001)
    }

    func testShaderLaysTheVersoOnceTheFoldCrosses() {
        let source = PageCurlShader.source
        XCTAssertTrue(source.contains("u.twoPage > 0.5 && orig < 0.0"))
        XCTAssertTrue(source.contains("versoAlong"))
        XCTAssertTrue(source.contains("PageCurlGeometry.spreadSample"))
    }

    private func rollSample(
        progress: CGFloat,
        t: CGFloat,
        spine: CGFloat,
        span: CGFloat
    ) -> PageCurlGeometry.SpreadSample {
        let radius = PageCurlGeometry.cylinderRadius(progress: progress, span: span)
        let fold = PageCurlGeometry.foldCenter(
            progress: progress,
            span: span,
            overhang: 0,
            curlWidth: radius * 2,
            far: PageCurlGeometry.farSpan(twoPage: true, span: span)
        )
        let along = fold + t * radius * 2
        return PageCurlGeometry.spreadSample(
            uvX: spine + along,
            uvY: 0.5,
            progress: progress,
            spineX: spine,
            peelSign: 1,
            span: span,
            twoPage: true,
            realVerso: true,
            tilt: 0,
            aspect: 1
        )
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
