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
        XCTAssertGreaterThan(mid, 0.05)
        XCTAssertLessThan(mid, 0.2)
        // A narrow leaf does not grow a cylinder wider than itself.
        let narrow = PageCurlGeometry.cylinderRadius(progress: 0.5, span: 0.1)
        XCTAssertLessThanOrEqual(narrow, 0.1 * 0.45 + 0.0001)

        XCTAssertEqual(PageCurlGeometry.tiltRadians(touchY: PageCurlGeometry.tapTouchY), 0, accuracy: 0.0001)
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

    func testAnimationSpineFlipsTheEdgeOnTheWayBackAndKeepsTheCentre() {
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: false, forward: true, divisionNormalizedX: nil),
            .leading
        )
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: false, forward: false, divisionNormalizedX: nil),
            .trailing
        )
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: true, forward: true, divisionNormalizedX: nil),
            .trailing
        )
        XCTAssertEqual(
            PageCurlGeometry.animationSpine(renderedColumns: 1, rtl: true, forward: false, divisionNormalizedX: nil),
            .leading
        )
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

    func testBacksidePaperLiftsOLEDAndTintsLight() {
        let oled = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0, g: 0, b: 0))
        XCTAssertGreaterThan(oled.r, 0.05)
        XCTAssertLessThan(oled.r, 0.10)
        XCTAssertEqual(oled.mix, 0.78, accuracy: 0.0001)
        XCTAssertLessThan(oled.specular, 0.2)

        let light = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(light.mix, 0.78, accuracy: 0.0001)
        XCTAssertLessThan(light.r, 1)
        XCTAssertLessThan(light.b, light.r)

        let sepia = PageCurlGeometry.backsidePaper(background: PageCurlRGB(r: 0.984, g: 0.941, b: 0.851))
        XCTAssertEqual(sepia.mix, 0.78, accuracy: 0.0001)
        XCTAssertGreaterThan(sepia.r, sepia.b)
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
