//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

class PageCurlPanStateMachineTests: XCTestCase {
    private func context(
        rtl: Bool = false,
        width: CGFloat = 390,
        height: CGFloat = 844,
        canGoForward: Bool = true,
        canGoBackward: Bool = true,
        hasSelection: Bool = false,
        enabled: Bool = true,
        zoomed: Bool = false,
        acceptsGesture: Bool = true
    ) -> PageCurlPanContext {
        PageCurlPanContext(
            rtl: rtl,
            viewWidth: width,
            viewHeight: height,
            canGoForward: canGoForward,
            canGoBackward: canGoBackward,
            hasSelection: hasSelection,
            interactiveCurlEnabled: enabled,
            zoomed: zoomed,
            acceptsGesture: acceptsGesture
        )
    }

    private func sample(
        translationX: CGFloat = 0,
        translationY: CGFloat = 0,
        velocityX: CGFloat = 0,
        velocityY: CGFloat = 0,
        locationX: CGFloat = 200,
        locationY: CGFloat = 400
    ) -> PageCurlPanSample {
        PageCurlPanSample(
            translationX: translationX,
            translationY: translationY,
            velocityX: velocityX,
            velocityY: velocityY,
            locationX: locationX,
            locationY: locationY
        )
    }

    func testInteractiveCurlIsPagedOnly() {
        XCTAssertTrue(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .curl, scrolls: false, reduceMotion: false, voiceOverRunning: false
        ))
        XCTAssertFalse(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .slide, scrolls: false, reduceMotion: false, voiceOverRunning: false
        ))
        XCTAssertFalse(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .fade, scrolls: false, reduceMotion: false, voiceOverRunning: false
        ))
        XCTAssertFalse(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .none, scrolls: false, reduceMotion: false, voiceOverRunning: false
        ))
        XCTAssertFalse(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .curl, scrolls: true, reduceMotion: false, voiceOverRunning: false
        ))
        XCTAssertFalse(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .curl, scrolls: false, reduceMotion: true, voiceOverRunning: false
        ))
        XCTAssertFalse(PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: .curl, scrolls: false, reduceMotion: false, voiceOverRunning: true
        ))
    }

    func testDistanceThresholdAndVelocityProjection() {
        // Strictly above 0.35. Sitting on the line is not a commit.
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.35, turnVelocity: 0, width: 390, cancelled: false),
            .cancel
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.351, turnVelocity: 0, width: 390, cancelled: false),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.2, turnVelocity: 0, width: 390, cancelled: false),
            .cancel
        )

        // Progress + (v / width) * 0.18 > 0.50.
        // 500 pt/s on a 390 pt page from 0.30 crosses the line. From 0.10 it does not.
        // The older "any velocity over 500 commits" rule does not.
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.30, turnVelocity: 500, width: 390, cancelled: false),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.10, turnVelocity: 500, width: 390, cancelled: false),
            .cancel
        )
        let width: CGFloat = 400
        let velocity = (0.31 / PageCurlPanStateMachine.velocityHorizon) * width
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.20, turnVelocity: velocity, width: width, cancelled: false),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.20, turnVelocity: 100, width: width, cancelled: false),
            .cancel
        )
        // A backward flick does not commit a short drag.
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.20, turnVelocity: -800, width: width, cancelled: false),
            .cancel
        )
    }

    /// The leaf is anchored where the finger landed, not where the
    /// pan was recognised (about 50 pt later on a slow drag).
    func testGrabOriginIsTheTouchDown() {
        let origin = PageCurlPanStateMachine.grabOrigin(
            touchDown: CGPoint(x: 388, y: 437),
            location: CGPoint(x: 323, y: 437),
            translation: CGPoint(x: -14, y: 0)
        )
        XCTAssertEqual(origin, CGPoint(x: 388, y: 437))
        let fallback = PageCurlPanStateMachine.grabOrigin(
            touchDown: nil,
            location: CGPoint(x: 323, y: 437),
            translation: CGPoint(x: -14, y: 2)
        )
        XCTAssertEqual(fallback, CGPoint(x: 337, y: 435))
        let notFinite = PageCurlPanStateMachine.grabOrigin(
            touchDown: CGPoint(x: CGFloat.nan, y: 0),
            location: CGPoint(x: 10, y: 10),
            translation: .zero
        )
        XCTAssertEqual(notFinite, CGPoint(x: 10, y: 10))
    }

    /// Pages snapped back when the finger neared the edge.
    /// UIKit ending the pan (`.cancelled`) is not the reader asking for the
    /// page back: past the commit distance it commits. Short, or moving
    /// back, it reverts.
    func testSystemCancelledReleasePastTheThresholdCommits() {
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.9, turnVelocity: 2000, width: 390, cancelled: true),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.5, turnVelocity: 0, width: 390, cancelled: true),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.2, turnVelocity: 2000, width: 390, cancelled: true),
            .cancel
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.9, turnVelocity: -600, width: 390, cancelled: true),
            .cancel
        )
    }

    /// A finger that reached the far edge has carried the page across, even
    /// from a start near the middle (progress under the commit distance).
    func testReleaseAtTheFarEdgeCommits() {
        let w: CGFloat = 402
        XCTAssertTrue(PageCurlPanStateMachine.isAtFarEdge(locationX: 10, width: w, forward: true, rtl: false))
        XCTAssertFalse(PageCurlPanStateMachine.isAtFarEdge(locationX: 60, width: w, forward: true, rtl: false))
        XCTAssertTrue(PageCurlPanStateMachine.isAtFarEdge(locationX: 395, width: w, forward: false, rtl: false))
        XCTAssertTrue(PageCurlPanStateMachine.isAtFarEdge(locationX: 395, width: w, forward: true, rtl: true))
        XCTAssertFalse(PageCurlPanStateMachine.isAtFarEdge(locationX: 10, width: w, forward: false, rtl: false))
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.3, turnVelocity: 0, width: w, cancelled: false, atFarEdge: true),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.3, turnVelocity: 0, width: w, cancelled: true, atFarEdge: true),
            .commit
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.3, turnVelocity: 0, width: w, cancelled: false, atFarEdge: false),
            .cancel
        )
        // Pulled back off the edge on purpose, or a nudge that started there.
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.3, turnVelocity: -400, width: w, cancelled: false, atFarEdge: true),
            .cancel
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: 0.05, turnVelocity: 0, width: w, cancelled: false, atFarEdge: true),
            .cancel
        )
    }

    /// A cancel with no touch left reports the view's origin. Read as the
    /// finger, a 5% peek from x 360 became a drag to x 0: progress 0.9 and
    /// the far edge, so it committed. The last tracked point stands instead,
    /// and a real release at the edge still commits from there.
    func testAZeroTouchCancelKeepsTheLastTrackedFinger() {
        let w: CGFloat = 402
        XCTAssertFalse(PageCurlPanStateMachine.releaseLocationIsLive(cancelled: true, numberOfTouches: 0, location: .zero))
        XCTAssertFalse(PageCurlPanStateMachine.releaseLocationIsLive(cancelled: true, numberOfTouches: 0, location: CGPoint(x: 200, y: 300)))
        XCTAssertFalse(PageCurlPanStateMachine.releaseLocationIsLive(cancelled: false, numberOfTouches: 0, location: .zero))
        XCTAssertFalse(PageCurlPanStateMachine.releaseLocationIsLive(cancelled: false, numberOfTouches: 1, location: CGPoint(x: CGFloat.nan, y: 1)))
        XCTAssertTrue(PageCurlPanStateMachine.releaseLocationIsLive(cancelled: false, numberOfTouches: 0, location: CGPoint(x: 340, y: 440)))
        XCTAssertTrue(PageCurlPanStateMachine.releaseLocationIsLive(cancelled: true, numberOfTouches: 1, location: CGPoint(x: 10, y: 440)))

        // What the origin would have decided.
        let fromOrigin = PageCurlPanStateMachine.progress(translationX: 0 - 360, width: w, forward: true, rtl: false)
        XCTAssertGreaterThan(fromOrigin, 0.85)
        XCTAssertTrue(PageCurlPanStateMachine.isAtFarEdge(locationX: 0, width: w, forward: true, rtl: false))
        // The last tracked finger: x 340 after a 20 pt peek.
        let lastProgress = PageCurlPanStateMachine.progress(translationX: 340 - 360, width: w, forward: true, rtl: false)
        let progress = PageCurlPanStateMachine.progressAtRelease(live: nil, lastProgress: lastProgress)
        let edge = PageCurlPanStateMachine.isAtFarEdge(locationX: 340, width: w, forward: true, rtl: false)
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: progress, turnVelocity: 0, width: w, cancelled: true, atFarEdge: edge),
            .cancel
        )
        // Backward LTR to the right edge, then a zero-touch cancel: still the edge.
        let backEdge = PageCurlPanStateMachine.isAtFarEdge(locationX: 395, width: w, forward: false, rtl: false)
        let backProgress = PageCurlPanStateMachine.progress(translationX: 395 - 280, width: w, forward: false, rtl: false)
        XCTAssertEqual(
            PageCurlPanStateMachine.release(progress: backProgress, turnVelocity: 0, width: w, cancelled: true, atFarEdge: backEdge),
            .commit
        )
    }

    func testRTLSignFlip() {
        // LTR forward is a leftward drag. RTL forward is a rightward drag.
        let ltr = PageCurlPanStateMachine.progress(translationX: -195, width: 390, forward: true, rtl: false)
        XCTAssertEqual(ltr, 0.5, accuracy: 0.001)
        let ltrOpposite = PageCurlPanStateMachine.progress(translationX: 195, width: 390, forward: true, rtl: false)
        XCTAssertEqual(ltrOpposite, 0, accuracy: 0.001)

        let rtl = PageCurlPanStateMachine.progress(translationX: 195, width: 390, forward: true, rtl: true)
        XCTAssertEqual(rtl, 0.5, accuracy: 0.001)
        let rtlOpposite = PageCurlPanStateMachine.progress(translationX: -195, width: 390, forward: true, rtl: true)
        XCTAssertEqual(rtlOpposite, 0, accuracy: 0.001)

        XCTAssertEqual(
            PageCurlPanStateMachine.turnVelocity(velocityX: -400, forward: true, rtl: false),
            400,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.turnVelocity(velocityX: 400, forward: true, rtl: true),
            400,
            accuracy: 0.001
        )
        XCTAssertTrue(PageCurlPanStateMachine.spreadGoesRight(forward: true, rtl: false))
        XCTAssertFalse(PageCurlPanStateMachine.spreadGoesRight(forward: true, rtl: true))
        XCTAssertFalse(PageCurlPanStateMachine.spreadGoesRight(forward: false, rtl: false))
        XCTAssertTrue(PageCurlPanStateMachine.spreadGoesRight(forward: false, rtl: true))

        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -800, velocityY: 40, locationX: 300),
                context: context()
            ),
            .track(.forward)
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 800, velocityY: 40, locationX: 300),
                context: context(rtl: true)
            ),
            .track(.forward)
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 800, velocityY: 40, locationX: 200),
                context: context()
            ),
            .track(.backward)
        )
    }

    func testBoundaries() {
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -600, velocityY: 10),
                context: context(canGoForward: false)
            ),
            .rejectBoundary
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 600, velocityY: 10, locationX: 200),
                context: context(canGoBackward: false)
            ),
            .rejectBoundary
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 600, velocityY: 10, locationX: 300),
                context: context(rtl: true, canGoForward: false)
            ),
            .rejectBoundary
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -600, velocityY: 10, locationX: 200),
                context: context(rtl: true, canGoBackward: false)
            ),
            .rejectBoundary
        )
    }

    func testVerticalRejectionAndDominance() {
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 100, velocityY: 400),
                context: context()
            ),
            .rejectVertical
        )
        // 100 is not greater than 80 * 1.25.
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 100, velocityY: 80),
                context: context()
            ),
            .rejectVertical
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -200, velocityY: 100),
                context: context()
            ),
            .track(.forward)
        )
        // A tap with no travel is not a curl.
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(sample: sample(), context: context()),
            .rejectVertical
        )
        // Translation is the fallback while velocity is still tiny.
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(translationX: -12, translationY: 2, velocityX: 0, velocityY: 0),
                context: context()
            ),
            .track(.forward)
        )
    }

    func testLeftBezelExclusion() {
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 700, velocityY: 20, locationX: 10),
                context: context()
            ),
            .rejectBezel
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: 700, velocityY: 20, locationX: 20),
                context: context()
            ),
            .track(.backward)
        )
        // The finger has left the bezel, but the touch went down inside it.
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(translationX: 24, velocityX: 700, velocityY: 20, locationX: 32),
                context: context()
            ),
            .rejectBezel
        )
        // A forward drag in the left bezel is still a page turn.
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -700, velocityY: 20, locationX: 8),
                context: context()
            ),
            .track(.forward)
        )
        // RTL dismiss comes off the right edge, dragging left.
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -700, velocityY: 20, locationX: 380),
                context: context(rtl: true, width: 390)
            ),
            .rejectBezel
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -700, velocityY: 20, locationX: 300),
                context: context(rtl: true)
            ),
            .track(.backward)
        )
    }

    func testSelectionZoomAndDisabledReject() {
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -800, velocityY: 10),
                context: context(hasSelection: true)
            ),
            .rejectSelection
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -800, velocityY: 10),
                context: context(zoomed: true)
            ),
            .rejectZoomed
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -800, velocityY: 10),
                context: context(enabled: false)
            ),
            .rejectDisabled
        )
        XCTAssertEqual(
            PageCurlPanStateMachine.shouldBegin(
                sample: sample(velocityX: -800, velocityY: 10),
                context: context(acceptsGesture: false)
            ),
            .rejectDisabled
        )
    }

    func testSmoothedVelocity() {
        XCTAssertEqual(PageCurlPanStateMachine.smoothedVelocity([100, 200, 300]), 200, accuracy: 0.001)
        XCTAssertEqual(PageCurlPanStateMachine.smoothedVelocity([10, 100, 200, 300]), 200, accuracy: 0.001)
        XCTAssertEqual(PageCurlPanStateMachine.smoothedVelocity([40]), 40, accuracy: 0.001)
        XCTAssertEqual(PageCurlPanStateMachine.smoothedVelocity([]), 0, accuracy: 0.001)
    }

    func testReleaseUsesTheLiveLiftOrTheLastTrackedProgress() {
        // No usable location (a zero-touch cancel): the last tracked progress.
        XCTAssertEqual(PageCurlPanStateMachine.progressAtRelease(live: nil, lastProgress: 0.42), 0.42, accuracy: 0.0001)
        // A live lift is used as it is, even 0: the finger came back to its start.
        XCTAssertEqual(PageCurlPanStateMachine.progressAtRelease(live: 0, lastProgress: 0.42), 0, accuracy: 0.0001)
        XCTAssertEqual(
            PageCurlPanStateMachine.release(
                progress: PageCurlPanStateMachine.progressAtRelease(live: 0.01, lastProgress: 0.50),
                turnVelocity: 2,
                width: 390,
                cancelled: false
            ),
            .cancel
        )
    }

    /// The pan's own release path (`PageCurlReleaseTracker`, which the
    /// controller feeds): out past the commit line, back to the right edge
    /// 150 pt lower, lifted. A live `.ended` at the start reads 0, so it
    /// cancels. It used to keep the last progress above 0 (0.37) and commit.
    func testDragOutAndBackToTheStartEdgeCancelsThroughTheReleasePath() {
        let w: CGFloat = 402
        func progress(_ x: CGFloat) -> CGFloat {
            PageCurlPanStateMachine.progress(translationX: x - 380, width: w, forward: true, rtl: false)
        }
        for liftX in [CGFloat(380), 385, 397] {
            var tracker = PageCurlReleaseTracker()
            tracker.start(progress: 0, finger: CGPoint(x: 380, y: 437))
            for x in stride(from: CGFloat(370), through: 230, by: -10) {
                tracker.move(progress: progress(x), finger: CGPoint(x: x, y: 437), velocityX: -500)
            }
            XCTAssertGreaterThan(tracker.lastProgress, 0.35)
            for k in 1 ... 15 {
                let x = 230 + (liftX - 230) * CGFloat(k) / 15
                tracker.move(progress: progress(x), finger: CGPoint(x: x, y: 437 + 10 * CGFloat(k)), velocityX: 400)
            }
            let release = tracker.release(
                cancelled: false, numberOfTouches: 0, location: CGPoint(x: liftX, y: 587),
                progress: progress(liftX), velocityX: 0, width: w
            )
            XCTAssertEqual(release.decision, .cancel, "lifted at \(liftX)")
            XCTAssertEqual(release.progress, 0, accuracy: 0.000_1, "lifted at \(liftX)")
        }
        // A quick pull-back whose `.ended` jumps straight from past the line: still the lift point.
        var quick = PageCurlReleaseTracker()
        quick.start(progress: 0, finger: CGPoint(x: 380, y: 437))
        quick.move(progress: progress(230), finger: CGPoint(x: 230, y: 437), velocityX: -800)
        let back = quick.release(
            cancelled: false, numberOfTouches: 0, location: CGPoint(x: 385, y: 450),
            progress: progress(385), velocityX: 2000, width: w
        )
        XCTAssertEqual(back.decision, .cancel)
        // The far-edge rule still holds through the same path.
        var edge = PageCurlReleaseTracker()
        edge.start(progress: 0, finger: CGPoint(x: 200, y: 437))
        edge.move(progress: 0.45, finger: CGPoint(x: 20, y: 437), velocityX: -60)
        XCTAssertEqual(
            edge.release(cancelled: true, numberOfTouches: 0, location: .zero, progress: 0.9, velocityX: 0, width: w).decision,
            .commit
        )
        // A zero-touch cancel near the start keeps the last tracked finger: no commit from (0, 0).
        var peek = PageCurlReleaseTracker()
        peek.start(progress: 0, finger: CGPoint(x: 360, y: 437))
        peek.move(progress: 0.05, finger: CGPoint(x: 340, y: 437), velocityX: -100)
        XCTAssertEqual(
            peek.release(cancelled: true, numberOfTouches: 0, location: .zero, progress: 0.9, velocityX: 0, width: w).decision,
            .cancel
        )
    }

    func testSpringDoesNotOvershootAndAFlickIsFaster() {
        let rest = PageCurlPanStateMachine.omega(progressVelocity: 0)
        XCTAssertEqual(rest, PageCurlPanStateMachine.settleOmega, accuracy: 0.001)
        let flick = PageCurlPanStateMachine.omega(progressVelocity: 8)
        XCTAssertEqual(flick, PageCurlPanStateMachine.flickOmega, accuracy: 0.001)

        var previous: CGFloat = 0.4
        for step in 1 ... 40 {
            let progress = PageCurlPanStateMachine.springProgress(
                elapsed: Double(step) * 0.01,
                from: 0.4,
                velocity: 0,
                target: 1,
                omega: rest
            )
            XCTAssertGreaterThanOrEqual(progress, previous - 0.000_1)
            XCTAssertLessThanOrEqual(progress, 1)
            previous = progress
        }
        let slowAt300 = PageCurlPanStateMachine.springProgress(
            elapsed: 0.30, from: 0.4, velocity: 0, target: 1, omega: rest
        )
        XCTAssertGreaterThan(slowAt300, 0.9)
        XCTAssertLessThan(slowAt300, 1)

        // A hard flick would cross the target in the raw solution. The clamp stays on it.
        let overshoot = PageCurlPanStateMachine.springProgress(
            elapsed: 0.5, from: 0.2, velocity: 30, target: 1, omega: flick
        )
        XCTAssertEqual(overshoot, 1, accuracy: 0.000_1)

        let cancel = PageCurlPanStateMachine.springProgress(
            elapsed: 0.34, from: 0.25, velocity: 0, target: 0, omega: rest
        )
        XCTAssertGreaterThan(cancel, 0)
        XCTAssertLessThan(cancel, 0.05)

        func timeToLand(velocity: CGFloat) -> TimeInterval {
            let omega = PageCurlPanStateMachine.omega(progressVelocity: velocity)
            var elapsed = 0.0
            while elapsed < 1 {
                elapsed += 0.005
                let progress = PageCurlPanStateMachine.springProgress(
                    elapsed: elapsed, from: 0.4, velocity: velocity, target: 1, omega: omega
                )
                if progress > 0.98 { return elapsed }
            }
            return 1
        }
        let slow = timeToLand(velocity: 0)
        let fast = timeToLand(velocity: 3.8)
        XCTAssertGreaterThan(slow, 0.26)
        XCTAssertLessThan(slow, 0.40)
        XCTAssertGreaterThan(fast, 0.12)
        XCTAssertLessThan(fast, 0.24)
        XCTAssertLessThan(fast, slow)
    }

    /// A slow back swipe from 10 pt is recognised about 50 pt later. The
    /// bezel test must use the touch-down, or the curl steals the dismiss.
    func testBezelUsesTheTouchDownNotTheLateOrigin() {
        let late = PageCurlPanSample(
            translationX: 51, translationY: 0, velocityX: 0, velocityY: 0,
            locationX: 112, locationY: 400, touchDownX: 10
        )
        XCTAssertEqual(PageCurlPanStateMachine.shouldBegin(sample: late, context: context()), .rejectBezel)
        var unknown = late
        unknown.touchDownX = nil
        XCTAssertEqual(PageCurlPanStateMachine.shouldBegin(sample: unknown, context: context()), .track(.backward))
    }

    /// A resting thumb's touch-down is not the origin of another finger's drag.
    func testTouchDownBelongsToTheMovingTouch() {
        let thumb = CGPoint(x: 20, y: 700)
        XCTAssertEqual(PageCurlPanStateMachine.touchDown(thumb, sawAnotherTouch: false, touchEnded: false), thumb)
        XCTAssertNil(PageCurlPanStateMachine.touchDown(thumb, sawAnotherTouch: true, touchEnded: false))
        XCTAssertNil(PageCurlPanStateMachine.touchDown(thumb, sawAnotherTouch: false, touchEnded: true))
        XCTAssertNil(PageCurlPanStateMachine.touchDown(nil, sawAnotherTouch: false, touchEnded: false))
    }
}
