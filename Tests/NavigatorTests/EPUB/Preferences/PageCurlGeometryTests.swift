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
        // About 25–35 pt on a 402 pt phone mid-turn.
        XCTAssertGreaterThanOrEqual(PageCurlGeometry.peakRadius * 402, 25)
        XCTAssertLessThanOrEqual(PageCurlGeometry.peakRadius * 402, 40)
        // A narrow leaf does not grow a cylinder wider than itself.
        let narrow = PageCurlGeometry.cylinderRadius(progress: 0.5, span: 0.1)
        XCTAssertLessThanOrEqual(narrow, 0.1 * 0.45 + 0.0001)
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

    /// The back is the page's own colour in every theme (black on a black
    /// page), with no OLED lift and no grey card.
    func testBacksidePaperIsThePageColourInEveryTheme() {
        let themes: [(String, PageCurlRGB)] = [
            ("OLED", PageCurlRGB(r: 0, g: 0, b: 0)),
            ("Dark", PageCurlRGB(r: 0.12, g: 0.12, b: 0.13)),
            ("Light", PageCurlRGB(r: 1, g: 1, b: 1)),
            ("Sepia", PageCurlRGB(r: 0.984, g: 0.941, b: 0.851)),
        ]
        for (name, background) in themes {
            let paper = PageCurlGeometry.backsidePaper(background: background)
            XCTAssertEqual(paper.r, background.r, accuracy: 0.0001, name)
            XCTAssertEqual(paper.g, background.g, accuracy: 0.0001, name)
            XCTAssertEqual(paper.b, background.b, accuracy: 0.0001, name)
            XCTAssertEqual(paper.mix, PageCurlGeometry.backsideMix, accuracy: 0.0001, name)
        }
        let odd = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: .nan, g: 1.2, b: -0.1))
        XCTAssertEqual(odd.r, 1)
        XCTAssertEqual(odd.g, 1)
        XCTAssertEqual(odd.b, 0)
    }

    /// The mirrored text shows through at about a quarter: white type on a
    /// black page comes out at 50–80 of 255.
    func testBackShowsTheMirroredTextAtAboutAQuarter() {
        XCTAssertEqual(PageCurlGeometry.backsideMix, 1 - PageCurlGeometry.backGhostStrength, accuracy: 0.0001)
        let paper = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0, g: 0, b: 0))
        // The shader's paperBack: mix(text, paper, mix).
        let whiteType = 1 + (paper.r - 1) * paper.mix
        XCTAssertGreaterThanOrEqual(whiteType * 255, 50)
        XCTAssertLessThanOrEqual(whiteType * 255, 80)
        // Light: black type on white is a light grey, still readable.
        let light = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 1, g: 1, b: 1))
        let blackType = 0 + (light.r - 0) * light.mix
        XCTAssertLessThan(blackType, 0.85)
        XCTAssertGreaterThan(blackType, 0.6)
        XCTAssertTrue(PageCurlShader.source.contains("paperBack(sampleFront(outgoing, paperUV(q, aspect), u), u)"))
    }

    func testGrabAtACornerPeelsDiagonallyAndMidEdgeStaysVertical() {
        let height: CGFloat = 2
        // Mid-edge, straight across: the normal is horizontal, so the fold is vertical.
        let mid = tryGrab(
            p0: CGPoint(x: 1, y: 1),
            p: CGPoint(x: 0.45, y: 1),
            radius: 0.08,
            spineX: 0,
            pageHeight: height
        )
        XCTAssertEqual(mid.normal.y, 0, accuracy: 0.0001)
        XCTAssertEqual(mid.normal.x, -1, accuracy: 0.0001)
        XCTAssertFalse(mid.clamped)

        // Bottom corner, dragged up and in.
        let bottom = tryGrab(
            p0: CGPoint(x: 1, y: height),
            p: CGPoint(x: 0.45, y: 1.2),
            radius: 0.08,
            spineX: 0,
            pageHeight: height
        )
        XCTAssertLessThan(bottom.normal.y, -0.25)

        // Top corner peels the other way.
        let top = tryGrab(
            p0: CGPoint(x: 1, y: 0),
            p: CGPoint(x: 0.45, y: 0.8),
            radius: 0.08,
            spineX: 0,
            pageHeight: height
        )
        XCTAssertGreaterThan(top.normal.y, 0.25)
        XCTAssertGreaterThan(abs(bottom.normal.y - top.normal.y), 0.5)

        // The same grab, then the finger moves up: the fold rotates.
        let low = tryGrab(
            p0: CGPoint(x: 1, y: 1.4),
            p: CGPoint(x: 0.5, y: 1.5),
            radius: 0.05,
            spineX: 0,
            pageHeight: height
        )
        let high = tryGrab(
            p0: CGPoint(x: 1, y: 1.4),
            p: CGPoint(x: 0.5, y: 0.3),
            radius: 0.05,
            spineX: 0,
            pageHeight: height
        )
        XCTAssertGreaterThan(abs(low.normal.y - high.normal.y), 0.4)
    }

    func testFoldAxisIsTheBisectorOffsetByAQuarterTurnOfTheRoll() {
        let p0 = CGPoint(x: 1, y: 1.2)
        let p = CGPoint(x: 0.4, y: 1.2)
        let radius: CGFloat = 0.08
        let fold = tryGrab(p0: p0, p: p, radius: radius, spineX: 0, pageHeight: 2)
        XCTAssertFalse(fold.clamped)
        XCTAssertEqual(fold.point.x, (p0.x + p.x) / 2, accuracy: 0.0001)
        XCTAssertEqual(fold.point.y, (p0.y + p.y) / 2, accuracy: 0.0001)
        XCTAssertEqual(fold.axis.x, fold.point.x + fold.normal.x * radius * .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(fold.axis.y, fold.point.y + fold.normal.y * radius * .pi / 2, accuracy: 0.0001)
        let offset = hypot(fold.axis.x - fold.point.x, fold.axis.y - fold.point.y)
        XCTAssertEqual(offset, radius * .pi / 2, accuracy: 0.0001)
        // The axis sits toward the finger, not back toward the held point.
        let towardFinger = (p.x - p0.x) * fold.normal.x + (p.y - p0.y) * fold.normal.y
        XCTAssertGreaterThan(towardFinger, 0)
        XCTAssertLessThan(fold.axis.x, fold.point.x)
    }

    func testSpineEdgeNeverDetaches() {
        // This drag's unclamped bisector crosses the spine.
        let fold = tryGrab(
            p0: CGPoint(x: 1, y: 2),
            p: CGPoint(x: -0.5, y: 0),
            radius: 0.05,
            spineX: 0,
            pageHeight: 2
        )
        XCTAssertTrue(fold.clamped)
        func signed(_ y: CGFloat) -> CGFloat {
            (0 - fold.point.x) * fold.normal.x + (y - fold.point.y) * fold.normal.y
        }
        XCTAssertGreaterThanOrEqual(signed(0), -0.0001)
        XCTAssertGreaterThanOrEqual(signed(2), -0.0001)

        // Two pages: the centre spine stays attached too.
        let spread = tryGrab(
            p0: CGPoint(x: 1, y: 1.6),
            p: CGPoint(x: 0.1, y: 0.2),
            radius: 0.04,
            spineX: 0.5,
            pageHeight: 2
        )
        func spreadSigned(_ y: CGFloat) -> CGFloat {
            (0.5 - spread.point.x) * spread.normal.x + (y - spread.point.y) * spread.normal.y
        }
        XCTAssertGreaterThanOrEqual(spreadSigned(0), -0.0001)
        XCTAssertGreaterThanOrEqual(spreadSigned(2), -0.0001)
    }

    func testTapPathStartsAtTheLowerCornerAndRises() {
        let flat = PageCurlGeometry.tapGrab(
            progress: 0, spineX: 0, peelSign: 1, span: 1, pageHeight: 2
        )
        XCTAssertEqual(flat.p0.x, 1, accuracy: 0.0001)
        XCTAssertEqual(flat.p0.y, 2, accuracy: 0.0001)
        XCTAssertEqual(flat.p.x, flat.p0.x, accuracy: 0.0001)
        XCTAssertEqual(flat.p.y, flat.p0.y, accuracy: 0.0001)
        XCTAssertNil(PageCurlGeometry.grabFold(
            p0: flat.p0, p: flat.p, radius: 0.05, spineX: 0, pageHeight: 2
        ))

        let mid = PageCurlGeometry.tapGrab(
            progress: 0.5, spineX: 0, peelSign: 1, span: 1, pageHeight: 2
        )
        XCTAssertEqual(mid.p0.x, 1, accuracy: 0.0001)
        XCTAssertEqual(mid.p0.y, 2, accuracy: 0.0001)
        XCTAssertLessThan(mid.p.x, mid.p0.x)
        XCTAssertLessThan(mid.p.y, mid.p0.y)
        let fold = tryGrab(p0: mid.p0, p: mid.p, radius: 0.05, spineX: 0, pageHeight: 2)
        XCTAssertLessThan(fold.normal.y, -0.05)

        // A tiny step does not put the top of the page on the incoming side.
        let barely = PageCurlGeometry.tapGrab(
            progress: 0.002, spineX: 0, peelSign: 1, span: 1, pageHeight: 2
        )
        let top = sample(
            uvX: 0.5, uvY: 0.05, progress: 0.002,
            spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false,
            p0: barely.p0, p: barely.p, radius: 0.01, aspect: 0.5
        )
        XCTAssertEqual(top.region, .flatOutgoing)
    }

    func testRTLGrabMirrorsTheLTRGrab() {
        let ltr = PageCurlGeometry.tapGrab(
            progress: 0.4, spineX: 0, peelSign: 1, span: 1, pageHeight: 2
        )
        let rtl = PageCurlGeometry.tapGrab(
            progress: 0.4, spineX: 1, peelSign: -1, span: 1, pageHeight: 2
        )
        XCTAssertEqual(rtl.p0.x, 0, accuracy: 0.0001)
        XCTAssertEqual(rtl.p0.y, ltr.p0.y, accuracy: 0.0001)
        XCTAssertEqual(rtl.p.x, 1 - ltr.p.x, accuracy: 0.0001)
        XCTAssertEqual(rtl.p.y, ltr.p.y, accuracy: 0.0001)
        let left = tryGrab(p0: ltr.p0, p: ltr.p, radius: 0.05, spineX: 0, pageHeight: 2)
        let right = tryGrab(p0: rtl.p0, p: rtl.p, radius: 0.05, spineX: 1, pageHeight: 2)
        XCTAssertEqual(right.normal.x, -left.normal.x, accuracy: 0.0001)
        XCTAssertEqual(right.normal.y, left.normal.y, accuracy: 0.0001)

        let held = PageCurlGeometry.heldPoint(
            touchUV: CGPoint(x: 0.1, y: 0.5),
            spineX: 1, peelSign: -1, span: 1, aspect: 0.5
        )
        XCTAssertEqual(held.x, 0, accuracy: 0.0001)
        XCTAssertEqual(held.y, 0.5 / 0.5, accuracy: 0.0001)
    }

    func testOnePageBackIsOpaqueAndTheNextPageStartsPastTheFold() {
        // Straight drag from the right edge to x = 0.4. Bisector at x = 0.7.
        let p0 = CGPoint(x: 1, y: 0.5)
        let p = CGPoint(x: 0.4, y: 0.5)
        let radius: CGFloat = 0.05
        // Between the finger and the fold, past the cylinder: the flat back.
        let back = sample(
            uvX: 0.55, uvY: 0.5, progress: 0.4,
            spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(back.region, .flatBack)
        XCTAssertEqual(back.sheet, .outgoing)
        XCTAssertEqual(back.x, 0.85, accuracy: 0.02)
        // On the cylinder, still the back, not the page underneath.
        let roll = sample(
            uvX: 0.66, uvY: 0.5, progress: 0.4,
            spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(roll.region, .rollBack)
        XCTAssertEqual(roll.sheet, .outgoing)
        // Right of the fold: the next page, uncovered.
        let next = sample(
            uvX: 0.9, uvY: 0.5, progress: 0.4,
            spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(next.region, .flatIncoming)
        XCTAssertEqual(next.sheet, .incoming)
        // Spine side of the finger: the outgoing page, still flat.
        let front = sample(
            uvX: 0.2, uvY: 0.5, progress: 0.4,
            spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(front.region, .flatOutgoing)
        XCTAssertEqual(front.sheet, .outgoing)
    }

    func testTwoPageBackIsTheFacingHalfAndTheStaticPageStays() {
        // Right-hand leaf, straight drag. Bisector at x = 0.81. Radius 0.04,
        // so x = 0.70 is the flat back and x = 0.78 is still on the cylinder.
        let spine: CGFloat = 0.5
        let span: CGFloat = 0.5
        let p0 = CGPoint(x: 1, y: 0.7)
        let p = CGPoint(x: 0.62, y: 0.7)
        let radius: CGFloat = 0.04

        let flat = sample(
            uvX: 0.70, uvY: 0.7, progress: 0.4,
            spineX: spine, peelSign: 1, span: span,
            twoPage: true, realVerso: true,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(flat.region, .flatBack)
        XCTAssertEqual(flat.sheet, .incoming)
        XCTAssertLessThan(flat.x, spine)
        XCTAssertGreaterThanOrEqual(flat.x, 0)
        // Not the mirror of the outgoing right page (that would be the outgoing sheet).
        XCTAssertNotEqual(flat.sheet, .outgoing)

        let roll = sample(
            uvX: 0.78, uvY: 0.7, progress: 0.4,
            spineX: spine, peelSign: 1, span: span,
            twoPage: true, realVerso: true,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(roll.region, .rollBack)
        XCTAssertEqual(roll.sheet, .incoming)
        XCTAssertLessThan(roll.x, spine)

        let staticLeft = sample(
            uvX: 0.2, uvY: 0.7, progress: 0.4,
            spineX: spine, peelSign: 1, span: span,
            twoPage: true, realVerso: true,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(staticLeft.region, .flatOutgoing)
        XCTAssertEqual(staticLeft.sheet, .outgoing)

        let revealed = sample(
            uvX: 0.95, uvY: 0.7, progress: 0.4,
            spineX: spine, peelSign: 1, span: span,
            twoPage: true, realVerso: true,
            p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(revealed.region, .flatIncoming)
        XCTAssertEqual(revealed.sheet, .incoming)
        XCTAssertGreaterThan(revealed.x, spine)
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

    /// A slow drag used to stop halfway. The fold keeps
    /// moving toward the spine all the way to the far edge, and is on it
    /// there; early on the leaf stays at the finger.
    func testSlowDragTurnsThePageAllTheWayToTheEdge() {
        let aspect: CGFloat = 402.0 / 874.0
        let height = 1 / aspect
        for (spineX, peelSign, span, originX, edgeX) in [
            (CGFloat(0), CGFloat(1), CGFloat(1), CGFloat(388.0 / 402), CGFloat(0)),
            (1, -1, 1, 14.0 / 402, 1),
        ] {
            let p0 = PageCurlGeometry.heldPoint(
                touchUV: CGPoint(x: originX, y: 0.5), spineX: spineX, peelSign: peelSign, span: span, aspect: aspect
            )
            let origin = CGPoint(x: originX, y: 0.5 / aspect)
            var lastFold = CGFloat.infinity
            var lastProgress: CGFloat = -1
            for step in 0 ... 40 {
                let fx = originX + (edgeX - originX) * CGFloat(step) / 40
                let finger = CGPoint(x: fx, y: origin.y)
                let aim = PageCurlGeometry.fingerAim(
                    p0: p0, origin: origin, finger: finger, spineX: spineX, peelSign: peelSign, span: span, pageHeight: 2.2
                )
                let progress = PageCurlPanStateMachine.progress(
                    translationX: (fx - originX) * 402, width: 402, forward: true, rtl: peelSign < 0
                )
                XCTAssertGreaterThanOrEqual(progress, lastProgress)
                lastProgress = progress
                guard step > 0 else { continue }
                let fold = tryGrab(p0: p0, p: aim, radius: 0, spineX: spineX, pageHeight: height)
                // Distance of the fold from the spine shrinks every step.
                let fromSpine = abs(fold.point.x - spineX)
                XCTAssertLessThan(fromSpine, lastFold, "step \(step)")
                lastFold = fromSpine
                if step == 10 {
                    // A quarter of the way: the leaf's edge is within ~7 pt of the finger.
                    XCTAssertLessThan(abs(aim.x - (p0.x + fx - originX)) * 402, 8)
                }
            }
            XCTAssertLessThan(lastFold, 0.01)
            XCTAssertGreaterThan(lastProgress, 0.9)
            XCTAssertEqual(
                PageCurlPanStateMachine.release(progress: lastProgress, turnVelocity: 0, width: 402, cancelled: false),
                .commit
            )
        }
        // Two pages: the finger's own travel already reaches the landing; no lead.
        let p0 = CGPoint(x: 1, y: 0.7)
        let aim = PageCurlGeometry.fingerAim(
            p0: p0, origin: CGPoint(x: 0.97, y: 0.7), finger: CGPoint(x: 0, y: 0.7),
            spineX: 0.5, peelSign: 1, span: 0.5, pageHeight: 1.4
        )
        XCTAssertEqual(aim.x, 0, accuracy: 0.0001)
    }

    /// Two pages, a drag from inside the right page to the left edge: the
    /// fold is on the spine, so the left page is all new (the leaf's back).
    /// The radius used to follow the finger's travel alone (still 0.057 at
    /// progress 0.75), the roll's axis crossed the spine, and a strip of the
    /// old left page showed between the roll and the spine.
    func testTwoPageDragToTheEdgeShowsNoStripOfTheOldFacingPage() {
        let aspect: CGFloat = 1032.0 / 1376.0
        let height = 1 / aspect
        let spineX: CGFloat = 0.5
        let span: CGFloat = 0.5
        for originX in [CGFloat(0.55), 0.75, 0.97] {
            let origin = CGPoint(x: originX, y: 0.6 / aspect)
            let p0 = PageCurlGeometry.heldPoint(
                touchUV: CGPoint(x: originX, y: 0.6), spineX: spineX, peelSign: 1, span: span, aspect: aspect
            )
            let finger = CGPoint(x: 0, y: origin.y)
            let p = PageCurlGeometry.fingerAim(
                p0: p0, origin: origin, finger: finger, spineX: spineX, peelSign: 1, span: span, pageHeight: height
            )
            let progress = PageCurlPanStateMachine.progress(
                translationX: -originX * 1032, width: 1032, forward: true, rtl: false
            )
            let radius = PageCurlGeometry.spineSafeRadius(
                PageCurlGeometry.cylinderRadius(progress: progress, span: span),
                p0: p0, p: p, spineX: spineX, pageHeight: height
            )
            for col in 0 ..< 200 {
                let u = (CGFloat(col) + 0.5) / 200 * spineX
                for v in [CGFloat(0.1), 0.5, 0.9] {
                    let sample = PageCurlGeometry.spreadSample(
                        uvX: u, uvY: v, progress: progress, spineX: spineX, peelSign: 1, span: span,
                        twoPage: true, realVerso: true, p0: p0, p: p, radius: radius, aspect: aspect
                    )
                    XCTAssertEqual(sample.sheet, .incoming, "origin \(originX) u \(u) v \(v) radius \(radius)")
                }
            }
        }
    }

    /// The cut only binds near the spine: mid-turn the roll keeps its size,
    /// and one page (spine on the view's edge) is never cut.
    func testSpineSafeRadiusLeavesTheRollAloneAwayFromTheSpine() {
        let p0 = CGPoint(x: 1, y: 0.8)
        let mid = PageCurlGeometry.cylinderRadius(progress: 0.3, span: 0.5)
        XCTAssertEqual(
            PageCurlGeometry.spineSafeRadius(mid, p0: p0, p: CGPoint(x: 0.7, y: 0.8), spineX: 0.5, pageHeight: 1.4),
            mid, accuracy: 0.000_1
        )
        let onePage = PageCurlGeometry.cylinderRadius(progress: 0.9, span: 1)
        XCTAssertEqual(
            PageCurlGeometry.spineSafeRadius(onePage, p0: p0, p: CGPoint(x: -0.98, y: 0.8), spineX: 0, pageHeight: 2.2),
            onePage, accuracy: 0.000_1
        )
        // On the spine: a crease.
        XCTAssertEqual(
            PageCurlGeometry.spineSafeRadius(mid, p0: p0, p: CGPoint(x: 0, y: 0.8), spineX: 0.5, pageHeight: 1.4),
            0, accuracy: 0.000_1
        )
    }

    /// Book pose with the hinge right of centre: the finger's own travel
    /// reaches the landing before the edge. The leaf stays at the finger;
    /// it used to be held up to 8% of the width behind it.
    func testOffCentreSpineNeverHoldsTheLeafBehindTheFinger() {
        for (spineX, peelSign, originX) in [(CGFloat(0.65), CGFloat(1), CGFloat(0.95)), (0.35, -1, 0.05)] {
            let span = PageCurlGeometry.span(spine: .center(normalizedX: spineX), peelSign: peelSign)
            let p0 = PageCurlGeometry.heldPoint(
                touchUV: CGPoint(x: originX, y: 0.5), spineX: spineX, peelSign: peelSign, span: span, aspect: 1.4
            )
            let origin = CGPoint(x: originX, y: 0.5 / 1.4)
            for step in 1 ... 20 {
                let fx = originX + ((peelSign > 0 ? 0 : 1) - originX) * CGFloat(step) / 20
                let finger = CGPoint(x: fx, y: origin.y)
                let aim = PageCurlGeometry.fingerAim(
                    p0: p0, origin: origin, finger: finger, spineX: spineX, peelSign: peelSign, span: span, pageHeight: 2.2
                )
                let follow = p0.x + (fx - originX)
                // Ahead means further in the turn's direction (-x for +peel).
                XCTAssertLessThanOrEqual((aim.x - follow) * peelSign, 0.000_1, "spine \(spineX) step \(step)")
            }
        }
    }

    func testCommitLandsOnTheMirrorOfTheHeldPoint() {
        let straight = PageCurlGeometry.commitLanding(
            p0: CGPoint(x: 1, y: 1.2), spineX: 0, peelSign: 1, span: 1
        )
        XCTAssertEqual(straight.x, -1, accuracy: 0.0001)
        XCTAssertEqual(straight.y, 1.2, accuracy: 0.0001)
        // A corner lands flat too: the fold is on the spine at the end.
        let corner = PageCurlGeometry.commitLanding(
            p0: CGPoint(x: 1, y: 2), spineX: 0, peelSign: 1, span: 1
        )
        XCTAssertEqual(corner.x, -1, accuracy: 0.0001)
        XCTAssertEqual(corner.y, 2, accuracy: 0.0001)
        let fold = tryGrab(p0: CGPoint(x: 1, y: 2), p: corner, radius: 0.01, spineX: 0, pageHeight: 2)
        XCTAssertEqual(fold.point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(fold.normal.y, 0, accuracy: 0.0001)
        // Two pages: the mirror across the centre spine.
        let spread = PageCurlGeometry.commitLanding(
            p0: CGPoint(x: 1, y: 0.4), spineX: 0.5, peelSign: 1, span: 0.5
        )
        XCTAssertEqual(spread.x, 0, accuracy: 0.0001)
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

    /// A real cylinder: the front runs up the near side, the back comes
    /// over the top, both meet at the crest, and the flat back beyond is the
    /// mirror across the bisector (so the edge still lands on the finger).
    func testRollArcIsContinuousFromFrontOverTheCrestToTheBack() throws {
        let r: CGFloat = 0.08
        XCTAssertNil(PageCurlGeometry.rollArc(w: r + 0.001, radius: r).back)
        XCTAssertNil(PageCurlGeometry.rollArc(w: r + 0.001, radius: r).front)
        let crest = PageCurlGeometry.rollArc(w: r, radius: r)
        XCTAssertEqual(try XCTUnwrap(crest.back), r * .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(crest.front), r * .pi / 2, accuracy: 0.0001)
        let base = PageCurlGeometry.rollArc(w: 0, radius: r)
        XCTAssertEqual(try XCTUnwrap(base.front), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(base.back), r * .pi, accuracy: 0.0001)
        let flat = PageCurlGeometry.rollArc(w: -0.0001, radius: r)
        XCTAssertNil(flat.front)
        XCTAssertEqual(try XCTUnwrap(flat.back), r * .pi + 0.0001, accuracy: 0.00001)
        // Squeezed toward the crest: more paper per point of screen.
        let a = try XCTUnwrap(PageCurlGeometry.rollArc(w: 0.9 * r, radius: r).front)
        let b = try XCTUnwrap(PageCurlGeometry.rollArc(w: 0.99 * r, radius: r).front)
        XCTAssertGreaterThan((b - a) / (0.09 * r), 2)
        // No radius: the old flat fold, a mirror across the axis.
        XCTAssertEqual(try XCTUnwrap(PageCurlGeometry.rollArc(w: -0.1, radius: 0).back), 0.1, accuracy: 0.0001)
    }

    /// Gentle darkening only where the sheet turns edge-on.
    func testRollShadeIsGentleAndOnlyOnTheRoll() {
        let r: CGFloat = 0.08
        XCTAssertEqual(PageCurlGeometry.rollShade(w: -0.05, radius: r), 1)
        XCTAssertEqual(PageCurlGeometry.rollShade(w: 0, radius: r), 1, accuracy: 0.0001)
        XCTAssertEqual(PageCurlGeometry.rollShade(w: r, radius: r), 1 - PageCurlGeometry.rollCrestDarkening, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(PageCurlGeometry.rollCrestDarkening, 0.15)
        XCTAssertLessThanOrEqual(PageCurlGeometry.rollShadowStrength, 0.12)
        XCTAssertLessThanOrEqual(PageCurlGeometry.flapShadowStrength, 0.10)
        var last: CGFloat = 1
        for step in 0 ... 10 {
            let shade = PageCurlGeometry.rollShade(w: CGFloat(step) * r / 10, radius: r)
            XCTAssertLessThanOrEqual(shade, last)
            last = shade
        }
        let source = PageCurlShader.source
        XCTAssertTrue(source.contains(String(format: "1.0 - %.4f * sinT * sinT", PageCurlGeometry.rollCrestDarkening)))
        XCTAssertFalse(source.contains("smoothstep(0.0, 0.0600, s)"))
    }

    /// Early in a drag the leaf is shorter than the roll's top: the front
    /// text squeezes onto the near side of the roll instead of a flat crease.
    func testFrontSqueezesOntoTheRollWhereTheBackIsShort() {
        let p0 = CGPoint(x: 1, y: 0.5)
        let p = CGPoint(x: 0.9, y: 0.5)
        let radius: CGFloat = 0.05
        // Axis at 0.95 - π/2 · 0.05 = 0.8715; the edge is 0.1285 of arc from it.
        let near = sample(
            uvX: 0.875, uvY: 0.5, progress: 0.1, spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false, p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(near.region, .rollFront)
        XCTAssertEqual(near.sheet, .outgoing)
        let crestSide = sample(
            uvX: 0.895, uvY: 0.5, progress: 0.1, spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false, p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(crestSide.region, .rollFront)
        // Nearer the crest the short leaf's edge has come over the top.
        let over = sample(
            uvX: 0.92, uvY: 0.5, progress: 0.1, spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false, p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(over.region, .rollBack)
        // The page under it shows past the crest.
        let past = sample(
            uvX: 0.93, uvY: 0.5, progress: 0.1, spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false, p0: p0, p: p, radius: radius, aspect: 1
        )
        XCTAssertEqual(past.region, .flatIncoming)
        // 0.02 of screen holds more than 0.02 of the page.
        XCTAssertGreaterThan(crestSide.x - near.x, 0.895 - 0.875)
    }

    /// A mid-edge drag: the moved edge lands on P, the fold is the
    /// midpoint, so the flap is half the finger's travel wide.
    func testMidEdgeFlapIsHalfTheTravel() {
        let p0 = CGPoint(x: 1, y: 1)
        let travel: CGFloat = 0.54
        let p = CGPoint(x: 1 - travel, y: 1)
        let fold = tryGrab(p0: p0, p: p, radius: 0.08, spineX: 0, pageHeight: 2)
        XCTAssertEqual(fold.point.x, 1 - travel / 2, accuracy: 0.0001)
        let width = fold.point.x - p.x
        XCTAssertEqual(width, travel / 2, accuracy: 0.0001)
        // Just inside the moved edge is the back; just past it is the page.
        let inside = sample(
            uvX: p.x + 0.01, uvY: 0.5, progress: 0.5, spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false, p0: p0, p: p, radius: 0.08, aspect: 0.5
        )
        XCTAssertEqual(inside.sheet, .outgoing)
        XCTAssertNotEqual(inside.region, .flatOutgoing)
        let outside = sample(
            uvX: p.x - 0.01, uvY: 0.5, progress: 0.5, spineX: 0, peelSign: 1, span: 1,
            twoPage: false, realVerso: false, p0: p0, p: p, radius: 0.08, aspect: 0.5
        )
        XCTAssertEqual(outside.region, .flatOutgoing)
    }

    func testShaderDrawsAnOpaqueBackFromTheGrab() {
        let source = PageCurlShader.source
        XCTAssertTrue(source.contains("versoAlong"))
        XCTAssertTrue(source.contains("PageCurlGeometry.spreadSample"))
        XCTAssertTrue(source.contains("paperBack"))
        XCTAssertFalse(source.contains("return float4(inC, 1.0)"))
        XCTAssertFalse(source.contains("u.tilt"))
    }

    private func tryGrab(
        p0: CGPoint,
        p: CGPoint,
        radius: CGFloat,
        spineX: CGFloat,
        pageHeight: CGFloat
    ) -> PageCurlGrabFold {
        guard let fold = PageCurlGeometry.grabFold(
            p0: p0, p: p, radius: radius, spineX: spineX, pageHeight: pageHeight
        ) else {
            XCTFail("expected a fold")
            return PageCurlGrabFold(
                point: .zero, normal: CGPoint(x: 1, y: 0), axis: .zero, radius: 0, clamped: false
            )
        }
        return fold
    }

    private func sample(
        uvX: CGFloat,
        uvY: CGFloat,
        progress: CGFloat,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        twoPage: Bool,
        realVerso: Bool,
        p0: CGPoint,
        p: CGPoint,
        radius: CGFloat,
        aspect: CGFloat
    ) -> PageCurlGeometry.SpreadSample {
        PageCurlGeometry.spreadSample(
            uvX: uvX, uvY: uvY, progress: progress,
            spineX: spineX, peelSign: peelSign, span: span,
            twoPage: twoPage, realVerso: realVerso,
            p0: p0, p: p, radius: radius, aspect: aspect
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

    /// Twenty floats, as `CurlUniforms` in the shader (no padding).
    func testUniformStrideMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<PageCurlUniforms>.stride, 20 * 4)
        XCTAssertEqual(MemoryLayout<PageCurlUniforms>.size, 20 * 4)
        let fields = PageCurlShader.source.components(separatedBy: "struct CurlUniforms {")[1]
            .components(separatedBy: "};")[0]
            .components(separatedBy: ";")
            .filter { $0.contains("float ") }
        XCTAssertEqual(fields.count, 20)
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
