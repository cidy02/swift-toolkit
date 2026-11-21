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
        XCTAssertFalse(PageSlideGeometry.playsReversed(forward: true))
        XCTAssertTrue(PageSlideGeometry.playsReversed(forward: false))
        XCTAssertEqual(PageSlideGeometry.peelSign(rtl: false), 1)
        XCTAssertEqual(PageSlideGeometry.peelSign(rtl: true), -1)
        // Curl keeps its own two-page direction rule untouched.
        XCTAssertFalse(PageCurlGeometry.playsReversed(renderedColumns: 2, forward: false))

        for division: CGFloat in [0.5, 0.42, 0.58] {
            let spine = PageCurlSpine.center(normalizedX: division)
            let spineX = division * padBounds.width
            let rightWidth = padBounds.width - spineX

            // Forward LTR: right outgoing half lifts and slides left across the spread.
            let fwdStart = PageSlideGeometry.layout(
                progress: 0, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertFalse(fwdStart.usesIncomingAsCard)
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

            // Backward LTR: previous spread's right half enters from the left edge as the
            // lifted card over the still current spread, uncovering the previous left half behind its spine.
            let backStart = PageSlideGeometry.layout(
                progress: 0, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertTrue(backStart.usesIncomingAsCard)
            XCTAssertEqual(backStart.cardFrame.maxX, 0, accuracy: 0.01)
            XCTAssertEqual(backStart.staticHalfClipFrame?.width ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(backStart.shadowOpacity, 0, accuracy: 0.001)
            XCTAssertFalse(backStart.roundsLeadingCorners)
            XCTAssertTrue(backStart.roundsTrailingCorners)

            let backEarly = PageSlideGeometry.layout(
                progress: 0.25, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(backEarly.cardFrame.maxX, 0.25 * padBounds.width, accuracy: 0.01)
            XCTAssertEqual(backEarly.staticHalfClipFrame?.width ?? -1, 0, accuracy: 0.001)

            let backLate = PageSlideGeometry.layout(
                progress: 0.8, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(backLate.cardFrame.minX, spineX - 0.2 * padBounds.width, accuracy: 0.01)
            XCTAssertEqual(backLate.staticHalfClipFrame?.maxX ?? -1, backLate.cardFrame.minX, accuracy: 0.01)

            let backEnd = PageSlideGeometry.layout(
                progress: 1, bounds: padBounds, spine: spine, peelSign: 1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(backEnd.cardFrame, CGRect(x: spineX, y: 0, width: rightWidth, height: padBounds.height))
            XCTAssertEqual(backEnd.staticHalfClipFrame, CGRect(x: 0, y: 0, width: spineX, height: padBounds.height))
            XCTAssertEqual(backEnd.cornerRadius, 0, accuracy: 0.001)
            XCTAssertEqual(backEnd.lift, 0, accuracy: 0.001)
            XCTAssertEqual(backEnd.shadowOpacity, 0, accuracy: 0.001)

            // Forward RTL: left outgoing half lifts and slides right.
            let rtlFwdStart = PageSlideGeometry.layout(
                progress: 0, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: false, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertFalse(rtlFwdStart.usesIncomingAsCard)
            XCTAssertEqual(rtlFwdStart.cardFrame, CGRect(x: 0, y: 0, width: spineX, height: padBounds.height))
            XCTAssertEqual(rtlFwdStart.staticHalfClipFrame, CGRect(x: spineX, y: 0, width: rightWidth, height: padBounds.height))
            XCTAssertTrue(rtlFwdStart.roundsLeadingCorners)
            XCTAssertFalse(rtlFwdStart.roundsTrailingCorners)

            // Backward RTL: previous spread's left half enters from the right edge as the
            // lifted card over the still current spread, uncovering the previous right half behind its spine.
            let rtlBackStart = PageSlideGeometry.layout(
                progress: 0, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertTrue(rtlBackStart.usesIncomingAsCard)
            XCTAssertEqual(rtlBackStart.cardFrame.minX, padBounds.width, accuracy: 0.01)
            XCTAssertEqual(rtlBackStart.staticHalfClipFrame?.width ?? -1, 0, accuracy: 0.001)

            let rtlBackLate = PageSlideGeometry.layout(
                progress: 0.8, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(rtlBackLate.cardFrame.minX, 0.2 * padBounds.width, accuracy: 0.01)
            XCTAssertEqual(rtlBackLate.staticHalfClipFrame?.minX ?? -1, rtlBackLate.cardFrame.maxX, accuracy: 0.01)
            XCTAssertEqual(rtlBackLate.staticHalfImageOrigin.x, -(rtlBackLate.staticHalfClipFrame?.minX ?? 0), accuracy: 0.01)

            let rtlBackEnd = PageSlideGeometry.layout(
                progress: 1, bounds: padBounds, spine: spine, peelSign: -1,
                reversed: true, displayCornerRadius: 18, background: lightBG
            )
            XCTAssertEqual(rtlBackEnd.cardFrame, CGRect(x: 0, y: 0, width: spineX, height: padBounds.height))
            XCTAssertEqual(rtlBackEnd.staticHalfClipFrame, CGRect(x: spineX, y: 0, width: rightWidth, height: padBounds.height))
            XCTAssertEqual(rtlBackEnd.cornerRadius, 0, accuracy: 0.001)
            XCTAssertEqual(rtlBackEnd.lift, 0, accuracy: 0.001)
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
    func testSlideViewArmsTracksSpringsToLandingAndClearsImagesOnRelease() async {
        let window = UIWindow(frame: phoneBounds)
        let host = UIView(frame: phoneBounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let outgoing = solidImage(color: .red, size: CGSize(width: 20, height: 20))
        let incoming = solidImage(color: .blue, size: CGSize(width: 20, height: 20))
        let slide = PageSlideView(frame: phoneBounds)
        slide.showCover(outgoing, background: .black)
        host.addSubview(slide)
        host.layoutIfNeeded()
        XCTAssertFalse(slide.isCoverHiddenForTesting)

        let armed = await slide.beginInteractive(
            outgoing: outgoing,
            incoming: incoming,
            spine: .leading,
            peelSign: 1,
            realVerso: false,
            reversed: false,
            progress: 0.25,
            grabUV: CGPoint(x: 0.9, y: 0.5),
            fingerUV: CGPoint(x: 0.65, y: 0.5)
        )
        XCTAssertTrue(armed)
        XCTAssertTrue(slide.isCoverHiddenForTesting)
        XCTAssertTrue(slide.cardImageForTesting === outgoing)
        XCTAssertTrue(slide.underImageForTesting === incoming)
        XCTAssertEqual(slide.cardFrameForTesting.origin.x, -0.25 * phoneBounds.width, accuracy: 0.5)
        XCTAssertGreaterThan(slide.cornerRadiusForTesting, 10)
        XCTAssertGreaterThan(slide.elevationTintAlphaForTesting, 0.05)

        // Tracking must move the card frame directly with progress.
        slide.track(progress: 0.5, fingerUV: CGPoint(x: 0.4, y: 0.5))
        XCTAssertEqual(slide.currentProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(slide.cardFrameForTesting.origin.x, -0.5 * phoneBounds.width, accuracy: 0.5)

        // Normal spring handoff without freezing: observe live frames moving from 0.5 → 1.0.
        var commitFrames: [(progress: CGFloat, cardMinX: CGFloat)] = []
        slide.onClockTickForTesting = { [weak slide] p in
            guard let slide else { return }
            commitFrames.append((p, slide.cardFrameForTesting.minX))
        }
        await slide.finishInteractive(target: 1, progressVelocity: 2.0)
        XCTAssertGreaterThanOrEqual(commitFrames.count, 2, "Spring must animate across multiple frames")
        let firstCommit = commitFrames[0]
        XCTAssertGreaterThan(firstCommit.progress, 0.5)
        XCTAssertLessThan(firstCommit.progress, 1.0)
        XCTAssertLessThan(firstCommit.cardMinX, -0.5 * phoneBounds.width)
        XCTAssertEqual(slide.currentProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(slide.cardFrameForTesting.maxX, 0, accuracy: 0.5)
        XCTAssertEqual(slide.shadowOpacityForTesting, 0, accuracy: 0.001)

        // Cancel spring back to 0: lands flat at bounds with lift and corners eased out.
        let armedCancel = await slide.beginInteractive(
            outgoing: outgoing,
            incoming: incoming,
            spine: .leading,
            peelSign: 1,
            realVerso: false,
            reversed: false,
            progress: 0.3,
            grabUV: CGPoint(x: 0.9, y: 0.5),
            fingerUV: CGPoint(x: 0.6, y: 0.5)
        )
        XCTAssertTrue(armedCancel)
        var cancelFrames: [CGFloat] = []
        slide.onClockTickForTesting = { p in cancelFrames.append(p) }
        await slide.finishInteractive(target: 0, progressVelocity: 0)
        XCTAssertGreaterThanOrEqual(cancelFrames.count, 2)
        XCTAssertLessThan(cancelFrames[0], 0.3)
        XCTAssertEqual(slide.currentProgress, 0, accuracy: 0.001)
        XCTAssertEqual(slide.cardFrameForTesting, phoneBounds)
        XCTAssertEqual(slide.cornerRadiusForTesting, 0, accuracy: 0.01)
        XCTAssertEqual(slide.elevationTintAlphaForTesting, 0, accuracy: 0.001)

        // Teardown releases every animated image reference.
        slide.releaseResources()
        XCTAssertNil(slide.underImageForTesting)
        XCTAssertNil(slide.cardImageForTesting)
        XCTAssertNil(slide.staticHalfImageForTesting)
        slide.removeFromSuperview()
    }

    @MainActor
    func testResignActiveDuringTrackRestoresCoverAndUnblocksFinish() async {
        let window = UIWindow(frame: phoneBounds)
        let host = UIView(frame: phoneBounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let slide = PageSlideView(frame: phoneBounds)
        let outgoing = solidImage(color: .red, size: CGSize(width: 20, height: 20))
        let incoming = solidImage(color: .blue, size: CGSize(width: 20, height: 20))
        slide.showCover(outgoing, background: .black)
        host.addSubview(slide)
        host.layoutIfNeeded()

        let armed = await slide.beginInteractive(
            outgoing: outgoing,
            incoming: incoming,
            spine: .leading,
            peelSign: 1,
            realVerso: false,
            reversed: false,
            progress: 0.3,
            grabUV: CGPoint(x: 0.9, y: 0.5),
            fingerUV: CGPoint(x: 0.6, y: 0.5)
        )
        XCTAssertTrue(armed)
        XCTAssertTrue(slide.isCoverHiddenForTesting)

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        // Resigning active during `.track` must restore the still cover (no blank frame)
        // and leave `finishInteractive` non-blocking.
        XCTAssertFalse(slide.isCoverHiddenForTesting)
        XCTAssertNil(slide.cardImageForTesting)
        XCTAssertNil(slide.underImageForTesting)
        await slide.finishInteractive(target: 1, progressVelocity: 0)
        slide.removeFromSuperview()
    }

    @MainActor
    func testRunTapAnimatesVisiblyLandsAndClearsImagesOnRelease() async {
        let window = UIWindow(frame: phoneBounds)
        let host = UIView(frame: phoneBounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let slide = PageSlideView(frame: phoneBounds)
        let outgoing = solidImage(color: .red, size: CGSize(width: 20, height: 20))
        let incoming = solidImage(color: .blue, size: CGSize(width: 20, height: 20))
        slide.showCover(outgoing, background: .white)
        host.addSubview(slide)
        host.layoutIfNeeded()
        XCTAssertFalse(slide.isCoverHiddenForTesting)

        var midFrames: [(progress: CGFloat, cardMinX: CGFloat, radius: CGFloat, coverHidden: Bool)] = []
        slide.onClockTickForTesting = { [weak slide] p in
            guard let slide else { return }
            midFrames.append((p, slide.cardFrameForTesting.minX, slide.cornerRadiusForTesting, slide.isCoverHiddenForTesting))
        }

        await slide.runTap(
            outgoing: outgoing,
            incoming: incoming,
            spine: .leading,
            peelSign: 1,
            realVerso: false,
            reversed: false,
            duration: 0.12
        )

        XCTAssertTrue(slide.isCoverHiddenForTesting)
        XCTAssertTrue(slide.cardImageForTesting === outgoing)
        XCTAssertTrue(slide.underImageForTesting === incoming)
        let intermediate = midFrames.filter { $0.progress > 0.02 && $0.progress < 0.98 }
        XCTAssertFalse(intermediate.isEmpty, "Tap must step through visible intermediate frames")
        if let sample = intermediate.first {
            XCTAssertTrue(sample.coverHidden)
            XCTAssertLessThan(sample.cardMinX, 0)
            XCTAssertGreaterThan(sample.radius, 0)
        }
        XCTAssertEqual(slide.currentProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(slide.cardFrameForTesting.maxX, 0, accuracy: 0.5)
        XCTAssertEqual(slide.shadowOpacityForTesting, 0, accuracy: 0.001)

        slide.releaseResources()
        XCTAssertNil(slide.underImageForTesting)
        XCTAssertNil(slide.cardImageForTesting)
        XCTAssertNil(slide.staticHalfImageForTesting)
        slide.removeFromSuperview()
    }

    @MainActor
    func testTwoPageBackwardCompositionShowsPreviousSpreadEnteringOverStillCurrentSpread() async {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let window = UIWindow(frame: bounds)
        let host = UIView(frame: bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        // Distinct 4-half bitmaps: outgoing = red (left) | blue (right),
        // incoming = green (left) | yellow (right).
        let outgoing = splitImage(left: .red, right: .blue, size: bounds.size, division: 0.5)
        let incoming = splitImage(left: .green, right: .yellow, size: bounds.size, division: 0.5)

        // LTR backward: incoming right half (yellow) enters from the left edge over
        // still outgoing (red|blue), uncovering incoming left half (green) behind its spine.
        let ltr = PageSlideView(frame: bounds)
        ltr.showCover(outgoing, background: .white)
        host.addSubview(ltr)
        host.layoutIfNeeded()

        let armedLTR = await ltr.beginInteractive(
            outgoing: outgoing,
            incoming: incoming,
            spine: .center(normalizedX: 0.5),
            peelSign: 1,
            realVerso: true,
            reversed: true,
            progress: 0,
            grabUV: CGPoint(x: 0.1, y: 0.5),
            fingerUV: CGPoint(x: 0.1, y: 0.5)
        )
        XCTAssertTrue(armedLTR)
        let ltrP0 = snapshot(ltr)
        assertPixel(ltrP0, at: CGPoint(x: 40, y: 50), matches: .red, "LTR p=0 left must be outgoing left")
        assertPixel(ltrP0, at: CGPoint(x: 160, y: 50), matches: .blue, "LTR p=0 right must be outgoing right")

        ltr.track(progress: 0.25, fingerUV: CGPoint(x: 0.35, y: 0.5))
        let ltrP25 = snapshot(ltr)
        assertPixel(ltrP25, at: CGPoint(x: 20, y: 50), matches: .yellow, "LTR p=0.25 entering card must be incoming right half")
        assertPixel(ltrP25, at: CGPoint(x: 75, y: 50), matches: .red, "LTR p=0.25 ahead of card must stay outgoing left")
        assertPixel(ltrP25, at: CGPoint(x: 160, y: 50), matches: .blue, "LTR p=0.25 right half must stay outgoing right")

        ltr.track(progress: 0.75, fingerUV: CGPoint(x: 0.85, y: 0.5))
        let ltrP75 = snapshot(ltr)
        assertPixel(ltrP75, at: CGPoint(x: 20, y: 50), matches: .green, "LTR p=0.75 behind card spine must show incoming left half")
        assertPixel(ltrP75, at: CGPoint(x: 100, y: 50), matches: .yellow, "LTR p=0.75 card must show incoming right half")
        assertPixel(ltrP75, at: CGPoint(x: 180, y: 50), matches: .blue, "LTR p=0.75 far right must stay outgoing right")

        ltr.track(progress: 1.0, fingerUV: CGPoint(x: 1.0, y: 0.5))
        let ltrP100 = snapshot(ltr)
        assertPixel(ltrP100, at: CGPoint(x: 40, y: 50), matches: .green, "LTR p=1 left must be incoming left")
        assertPixel(ltrP100, at: CGPoint(x: 160, y: 50), matches: .yellow, "LTR p=1 right must be incoming right")
        ltr.releaseResources()
        ltr.removeFromSuperview()

        // RTL backward: incoming left half (green) enters from the right edge over
        // still outgoing (red|blue), uncovering incoming right half (yellow) behind its spine.
        let rtl = PageSlideView(frame: bounds)
        rtl.showCover(outgoing, background: .white)
        host.addSubview(rtl)
        host.layoutIfNeeded()

        let armedRTL = await rtl.beginInteractive(
            outgoing: outgoing,
            incoming: incoming,
            spine: .center(normalizedX: 0.5),
            peelSign: -1,
            realVerso: true,
            reversed: true,
            progress: 0,
            grabUV: CGPoint(x: 0.9, y: 0.5),
            fingerUV: CGPoint(x: 0.9, y: 0.5)
        )
        XCTAssertTrue(armedRTL)
        let rtlP0 = snapshot(rtl)
        assertPixel(rtlP0, at: CGPoint(x: 40, y: 50), matches: .red, "RTL p=0 left must be outgoing left")
        assertPixel(rtlP0, at: CGPoint(x: 160, y: 50), matches: .blue, "RTL p=0 right must be outgoing right")

        rtl.track(progress: 0.25, fingerUV: CGPoint(x: 0.65, y: 0.5))
        let rtlP25 = snapshot(rtl)
        assertPixel(rtlP25, at: CGPoint(x: 40, y: 50), matches: .red, "RTL p=0.25 left half must stay outgoing left")
        assertPixel(rtlP25, at: CGPoint(x: 125, y: 50), matches: .blue, "RTL p=0.25 ahead of card must stay outgoing right")
        assertPixel(rtlP25, at: CGPoint(x: 180, y: 50), matches: .green, "RTL p=0.25 entering card must be incoming left half")

        rtl.track(progress: 0.75, fingerUV: CGPoint(x: 0.15, y: 0.5))
        let rtlP75 = snapshot(rtl)
        assertPixel(rtlP75, at: CGPoint(x: 20, y: 50), matches: .red, "RTL p=0.75 far left must stay outgoing left")
        assertPixel(rtlP75, at: CGPoint(x: 100, y: 50), matches: .green, "RTL p=0.75 card must show incoming left half")
        assertPixel(rtlP75, at: CGPoint(x: 180, y: 50), matches: .yellow, "RTL p=0.75 behind card spine must show incoming right half")

        rtl.track(progress: 1.0, fingerUV: CGPoint(x: 0.0, y: 0.5))
        let rtlP100 = snapshot(rtl)
        assertPixel(rtlP100, at: CGPoint(x: 40, y: 50), matches: .green, "RTL p=1 left must be incoming left")
        assertPixel(rtlP100, at: CGPoint(x: 160, y: 50), matches: .yellow, "RTL p=1 right must be incoming right")
        rtl.releaseResources()
        rtl.removeFromSuperview()
    }

    private func splitImage(left: UIColor, right: UIColor, size: CGSize, division: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let splitX = size.width * division
            left.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: splitX, height: size.height))
            right.setFill()
            ctx.fill(CGRect(x: splitX, y: 0, width: size.width - splitX, height: size.height))
        }
    }

    @MainActor
    private func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: view.bounds.size, format: format)
        return renderer.image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
    }

    private func assertPixel(
        _ image: UIImage,
        at point: CGPoint,
        matches expected: UIColor,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cg = image.cgImage else {
            XCTFail("Missing CGImage", file: file, line: line)
            return
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create pixel context", file: file, line: line)
            return
        }
        ctx.draw(cg, in: CGRect(x: -point.x, y: -(CGFloat(cg.height) - 1 - point.y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
        let ar = CGFloat(pixel[0]) / 255
        let ag = CGFloat(pixel[1]) / 255
        let ab = CGFloat(pixel[2]) / 255
        XCTAssertEqual(ar, er, accuracy: 0.12, "\(message) (R)", file: file, line: line)
        XCTAssertEqual(ag, eg, accuracy: 0.12, "\(message) (G)", file: file, line: line)
        XCTAssertEqual(ab, eb, accuracy: 0.12, "\(message) (B)", file: file, line: line)
    }

    private func solidImage(color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
