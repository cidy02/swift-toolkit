//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import UIKit
import XCTest

class PageSlideGeometryTests: XCTestCase {
    private let phoneBounds = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let padBounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
    private let lightBG = PageCurlRGB(r: 1, g: 1, b: 1)
    private let sepiaBG = PageCurlRGB(r: 0.984, g: 0.941, b: 0.851)
    private let darkBG = PageCurlRGB(r: 0.086, g: 0.086, b: 0.105)
    private let oledBG = PageCurlRGB(r: 0, g: 0, b: 0)

    func testSinglePageForwardSlidesOutgoingLeftOverStillIncoming() {
        let start = PageSlideGeometry.layout(
            progress: 0, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: lightBG
        )
        XCTAssertEqual(start.cardFrame, phoneBounds)
        XCTAssertFalse(start.usesIncomingAsCard)
        XCTAssertNil(start.staticHalfClipFrame)
        XCTAssertEqual(start.cornerRadius, 0, accuracy: 0.001)
        XCTAssertEqual(start.lift, 0, accuracy: 0.001)
        XCTAssertEqual(start.shadowOpacity, 0, accuracy: 0.001)

        let mid = PageSlideGeometry.layout(
            progress: 0.4, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: lightBG
        )
        XCTAssertEqual(mid.cardFrame.origin.x, -0.4 * phoneBounds.width, accuracy: 0.01)
        XCTAssertEqual(mid.cardFrame.size, phoneBounds.size)
        XCTAssertTrue(mid.roundsLeadingCorners)
        XCTAssertTrue(mid.roundsTrailingCorners)
        XCTAssertEqual(mid.cornerRadius, 55, accuracy: 0.01)
        XCTAssertEqual(mid.lift, 1, accuracy: 0.01)
        XCTAssertEqual(mid.elevationTintAlpha, 0, accuracy: 0.001)
        XCTAssertEqual(mid.shadowOpacity, PageSlideGeometry.lightShadowMaxOpacity, accuracy: 0.01)
        XCTAssertGreaterThan(mid.shadowOffsetX, 0)

        let end = PageSlideGeometry.layout(
            progress: 1, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: lightBG
        )
        XCTAssertEqual(end.cardFrame.maxX, 0, accuracy: 0.01)
        // Exterior shadow tapers to 0 at exit so no shadow band pops when the overlay tears down.
        XCTAssertEqual(end.shadowOpacity, 0, accuracy: 0.001)
    }

    func testSinglePageBackwardBringsIncomingFromLeftOverStillOutgoing() {
        let start = PageSlideGeometry.layout(
            progress: 0, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: true, displayCornerRadius: 55, background: oledBG
        )
        XCTAssertTrue(start.usesIncomingAsCard)
        XCTAssertEqual(start.cardFrame.maxX, 0, accuracy: 0.01)
        XCTAssertEqual(start.shadowOpacity, 0, accuracy: 0.001)

        // At progress 0.4 the previous page has entered 40% from the left edge.
        let mid = PageSlideGeometry.layout(
            progress: 0.4, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: true, displayCornerRadius: 55, background: oledBG
        )
        XCTAssertEqual(mid.cardFrame.maxX, 0.4 * phoneBounds.width, accuracy: 0.01)
        XCTAssertEqual(mid.cornerRadius, 55, accuracy: 0.01)
        XCTAssertEqual(mid.lift, 1, accuracy: 0.01)
        XCTAssertEqual(mid.elevationTintAlpha, PageSlideGeometry.darkElevationTintMax, accuracy: 0.001)

        // Settled back on screen: flat, untinted, unrounded.
        let end = PageSlideGeometry.layout(
            progress: 1, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: true, displayCornerRadius: 55, background: oledBG
        )
        XCTAssertEqual(end.cardFrame, phoneBounds)
        XCTAssertEqual(end.cornerRadius, 0, accuracy: 0.001)
        XCTAssertEqual(end.lift, 0, accuracy: 0.001)
        XCTAssertEqual(end.elevationTintAlpha, 0, accuracy: 0.001)
        XCTAssertEqual(end.shadowOpacity, 0, accuracy: 0.001)
    }

    func testRTLSinglePageMirrorsSlideDirectionAndShadow() {
        let fwd = PageSlideGeometry.layout(
            progress: 0.35, bounds: phoneBounds, spine: .trailing, peelSign: -1,
            reversed: false, displayCornerRadius: 55, background: lightBG
        )
        XCTAssertEqual(fwd.cardFrame.minX, 0.35 * phoneBounds.width, accuracy: 0.01)
        XCTAssertLessThan(fwd.shadowOffsetX, 0)

        let back = PageSlideGeometry.layout(
            progress: 0.35, bounds: phoneBounds, spine: .trailing, peelSign: -1,
            reversed: true, displayCornerRadius: 55, background: lightBG
        )
        // Incoming enters 35% from the right edge.
        XCTAssertEqual(back.cardFrame.minX, 0.65 * phoneBounds.width, accuracy: 0.01)
    }

    func testLiftAndCornersAppearWithinFirstFewPointsAndEaseOutOnSettle() {
        // 6 pt into drag (~1.5% of a 402 pt iPhone): corners and lift are already visibly engaged.
        let p6 = 6 / phoneBounds.width
        let early = PageSlideGeometry.layout(
            progress: p6, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: oledBG
        )
        XCTAssertGreaterThan(early.cornerRadius, 10)
        XCTAssertLessThan(early.cornerRadius, 55)
        XCTAssertGreaterThan(early.lift, 0.15)
        XCTAssertGreaterThan(early.elevationTintAlpha, 0.015)

        // By 12 pt, corners reach the full display radius.
        let p12 = 12 / phoneBounds.width
        let cornersFull = PageSlideGeometry.layout(
            progress: p12, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: oledBG
        )
        XCTAssertEqual(cornersFull.cornerRadius, 55, accuracy: 0.01)
        XCTAssertGreaterThan(cornersFull.lift, early.lift)

        // By 64 pt, elevation lift reaches full strength.
        let p64 = 64 / phoneBounds.width
        let liftFull = PageSlideGeometry.layout(
            progress: p64, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: oledBG
        )
        XCTAssertEqual(liftFull.lift, 1, accuracy: 0.001)
    }

    func testDarkAndLightThemeStyling() {
        XCTAssertTrue(PageSlideGeometry.isDark(background: oledBG))
        XCTAssertTrue(PageSlideGeometry.isDark(background: darkBG))
        XCTAssertFalse(PageSlideGeometry.isDark(background: lightBG))
        XCTAssertFalse(PageSlideGeometry.isDark(background: sepiaBG))

        let darkFrame = PageSlideGeometry.layout(
            progress: 0.5, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: darkBG
        )
        XCTAssertTrue(darkFrame.isDarkTheme)
        XCTAssertEqual(darkFrame.elevationTintAlpha, PageSlideGeometry.darkElevationTintMax, accuracy: 0.001)
        XCTAssertGreaterThan(darkFrame.rimAlpha, 0)

        let sepiaFrame = PageSlideGeometry.layout(
            progress: 0.5, bounds: phoneBounds, spine: .leading, peelSign: 1,
            reversed: false, displayCornerRadius: 55, background: sepiaBG
        )
        XCTAssertFalse(sepiaFrame.isDarkTheme)
        XCTAssertEqual(sepiaFrame.elevationTintAlpha, 0, accuracy: 0.001)
        XCTAssertEqual(sepiaFrame.shadowOpacity, PageSlideGeometry.lightShadowMaxOpacity, accuracy: 0.01)
    }

    func testDisplayCornerRadiusPrefersEffectiveRadiusAndFallsBackByDeviceClass() {
        XCTAssertEqual(
            PageSlideGeometry.displayCornerRadius(effectiveRadius: 62, isPad: false, hasBottomSafeArea: true),
            62
        )
        XCTAssertEqual(
            PageSlideGeometry.displayCornerRadius(effectiveRadius: nil, isPad: false, hasBottomSafeArea: true),
            PageSlideGeometry.fallbackPhoneCornerRadius
        )
        XCTAssertEqual(
            PageSlideGeometry.displayCornerRadius(effectiveRadius: 0, isPad: false, hasBottomSafeArea: false),
            0
        )
        XCTAssertEqual(
            PageSlideGeometry.displayCornerRadius(effectiveRadius: nil, isPad: true, hasBottomSafeArea: true),
            PageSlideGeometry.fallbackPadCornerRadius
        )
        // Clamped on very small view bounds so corners never invert.
        let tiny = PageSlideGeometry.layout(
            progress: 0.5, bounds: CGRect(x: 0, y: 0, width: 60, height: 100),
            spine: .leading, peelSign: 1, reversed: false, displayCornerRadius: 55, background: lightBG
        )
        XCTAssertEqual(tiny.cornerRadius, 60 * 0.45, accuracy: 0.01)
    }

    func testTwoPageSpreadRightPageForwardAndLeftPageBackIncludingOffCentreDuoFold() {
        for division: CGFloat in [0.5, 0.42, 0.58] {
            let spine = PageCurlSpine.center(normalizedX: division)
            let spineX = division * padBounds.width
            let rightWidth = padBounds.width - spineX

            // Forward LTR: right page lifts and slides left across the spread.
            let fwdStart = PageSlideGeometry.layout(
                progress: 0, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(fwdStart.cardFrame, CGRect(x: spineX, y: 0, width: rightWidth, height: padBounds.height))
            XCTAssertEqual(fwdStart.cardImageOrigin.x, -spineX, accuracy: 0.01)
            XCTAssertEqual(fwdStart.staticHalfClipFrame, CGRect(x: 0, y: 0, width: spineX, height: padBounds.height))
            XCTAssertFalse(fwdStart.roundsLeadingCorners, "Spine edge stays square")
            XCTAssertTrue(fwdStart.roundsTrailingCorners, "Outer edge uses display corners")

            // Mid-turn before crossing left edge: static left half meets card's leading edge with zero gap/overlap.
            let fwdEarly = PageSlideGeometry.layout(
                progress: 0.2, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(fwdEarly.cardFrame.minX, spineX - 0.2 * padBounds.width, accuracy: 0.01)
            XCTAssertEqual(fwdEarly.staticHalfClipFrame?.maxX ?? -1, fwdEarly.cardFrame.minX, accuracy: 0.01)
            XCTAssertEqual(fwdEarly.shadowOffsetX, 0, accuracy: 0.001)

            // Past spine crossing: outgoing left half is completely gone so incoming left half reveals behind the card.
            let fwdLate = PageSlideGeometry.layout(
                progress: 0.75, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(fwdLate.staticHalfClipFrame?.width ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(fwdLate.cardFrame.minX, spineX - 0.75 * padBounds.width, accuracy: 0.01)

            let fwdEnd = PageSlideGeometry.layout(
                progress: 1, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(fwdEnd.cardFrame.maxX, 0, accuracy: 0.01)

            // Backward LTR: left page lifts and slides right across the spread.
            let backStart = PageSlideGeometry.layout(
                progress: 0, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(backStart.cardFrame, CGRect(x: 0, y: 0, width: spineX, height: padBounds.height))
            XCTAssertEqual(backStart.cardImageOrigin.x, 0, accuracy: 0.01)
            XCTAssertEqual(backStart.staticHalfClipFrame, CGRect(x: spineX, y: 0, width: rightWidth, height: padBounds.height))
            XCTAssertTrue(backStart.roundsLeadingCorners)
            XCTAssertFalse(backStart.roundsTrailingCorners)

            let backEarly = PageSlideGeometry.layout(
                progress: 0.2, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(backEarly.cardFrame.minX, 0.2 * padBounds.width, accuracy: 0.01)
            XCTAssertEqual(backEarly.staticHalfClipFrame?.minX ?? -1, backEarly.cardFrame.maxX, accuracy: 0.01)
            XCTAssertEqual(backEarly.staticHalfImageOrigin.x, -(backEarly.staticHalfClipFrame?.minX ?? 0), accuracy: 0.01)

            let backEnd = PageSlideGeometry.layout(
                progress: 1, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(backEnd.cardFrame.minX, padBounds.width, accuracy: 0.01)
            XCTAssertEqual(backEnd.staticHalfClipFrame?.width ?? -1, 0, accuracy: 0.001)
        }
    }

    func testTapEaseOutIsMonotonicAndBriskAtStart() {
        XCTAssertEqual(PageSlideGeometry.tapEaseOut(0), 0, accuracy: 0.0001)
        XCTAssertEqual(PageSlideGeometry.tapEaseOut(1), 1, accuracy: 0.0001)
        XCTAssertEqual(PageSlideGeometry.tapEaseOut(0.5), 0.875, accuracy: 0.0001)
        var prev: CGFloat = 0
        for step in 1 ... 20 {
            let value = PageSlideGeometry.tapEaseOut(CGFloat(step) / 20)
            XCTAssertGreaterThanOrEqual(value, prev)
            prev = value
        }
    }

    @MainActor
    func testSlideViewArmsSynchronouslyAndTracksAndReleasesCleanly() async {
        let window = UIWindow(frame: phoneBounds)
        let host = UIView(frame: phoneBounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let slide = PageSlideView(frame: phoneBounds)
        let image = solidImage(color: .black, size: CGSize(width: 20, height: 20))
        slide.showCover(image, background: .black)
        host.addSubview(slide)
        host.layoutIfNeeded()

        let armed = await slide.beginInteractive(
            outgoing: image,
            incoming: image,
            spine: .leading,
            peelSign: 1,
            realVerso: false,
            reversed: false,
            progress: 0.25,
            grabUV: CGPoint(x: 0.9, y: 0.5),
            fingerUV: CGPoint(x: 0.65, y: 0.5)
        )
        XCTAssertTrue(armed)

        slide.track(progress: 0.5, fingerUV: CGPoint(x: 0.4, y: 0.5))
        // Immediately freezing or releasing must clean up without hanging.
        slide.freezeOnCover(showing: image)
        await slide.finishInteractive(target: 0, progressVelocity: 0)
        slide.removeFromSuperview()
    }

    private func solidImage(color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
