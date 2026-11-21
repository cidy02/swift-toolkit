//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest

/// The touch-down starts a snapshot and a texture upload before the pan is
/// recognised. A sequence that ends without a drag (a tap on a link or a
/// highlight, whose up the web view never posts; a vertical scroll; a
/// rejected pan) must still tell the navigator to drop that work.
@MainActor
class PageCurlPanControllerTests: XCTestCase {
    private final class Delegate: PageCurlPanDelegate {
        var touchDowns = 0
        var sequencesEnded = 0
        var accepts = false
        var hostView: UIView?
        var makeSlide = false
        var overlayMade: (any PageTurnOverlayView)?
        var didFinish = 0
        var didCancel = 0
        var outgoingImage: UIImage?
        var incomingImage: UIImage?

        func curlPanContext(in view: UIView) -> PageCurlPanContext {
            PageCurlPanContext(
                rtl: false,
                viewWidth: view.bounds.width,
                viewHeight: view.bounds.height,
                canGoForward: true,
                canGoBackward: true,
                hasSelection: false,
                interactiveCurlEnabled: true
            )
        }

        func curlPanHostView() -> UIView? { hostView }
        func curlPanMakeOverlayView(frame: CGRect) -> any PageTurnOverlayView {
            let view: any PageTurnOverlayView = makeSlide ? PageSlideView(frame: frame) : PageCurlView(frame: frame)
            overlayMade = view
            return view
        }
        func curlPanTouchDown() { touchDowns += 1 }
        func curlPanTouchSequenceEnded() { sequencesEnded += 1 }
        func curlPanDidBegin(direction: PageCurlTurnDirection) -> Bool { accepts }
        func curlPanCaptureOutgoing() async -> (image: UIImage, background: UIColor)? {
            outgoingImage.map { ($0, .black) }
        }
        func curlPanRevealIncoming(
            direction: PageCurlTurnDirection,
            outgoing: UIImage,
            background: UIColor
        ) async -> PageCurlPanFrame? {
            guard let img = incomingImage else { return nil }
            return PageCurlPanFrame(
                outgoing: outgoing,
                incoming: img,
                background: background,
                spine: .leading,
                peelSign: 1,
                realVerso: false,
                withinResource: true,
                reversed: direction == .backward
            )
        }
        func curlPanPrerenderBeyond(direction: PageCurlTurnDirection, withinResource: Bool) async {}
        func curlPanCommit(direction: PageCurlTurnDirection, withinResource: Bool) async {}
        func curlPanCancel(direction: PageCurlTurnDirection, withinResource: Bool) async { didCancel += 1 }
        func curlPanDidFinish() { didFinish += 1 }
    }

    func testASequenceThatEndsWithoutADragIsReported() {
        let controller = PageCurlPanController()
        let delegate = Delegate()
        controller.delegate = delegate
        // UIKit resets the recognizer after every sequence, began or not.
        controller.recognizer.reset()
        XCTAssertEqual(delegate.sequencesEnded, 1)
        controller.recognizer.reset()
        XCTAssertEqual(delegate.sequencesEnded, 2)
        XCTAssertFalse(controller.turnInFlight)
    }

    /// A drag that began owns the touch-down shot: the reset at the end of its
    /// touch sequence must not drop it while the turn is in flight.
    func testAResetDuringADragIsNotReported() {
        let controller = PageCurlPanController()
        let delegate = Delegate()
        delegate.accepts = true
        controller.delegate = delegate
        controller.begin(controller.recognizer)
        XCTAssertTrue(controller.turnInFlight)
        controller.recognizer.reset()
        XCTAssertEqual(delegate.sequencesEnded, 0)
    }

    /// Slide shares the curl's pan controller and installs `PageSlideView`
    /// through the overlay factory, arms it with distinct pages, then tears down cleanly on `abortDrag`.
    func testSlideDragInstallsPageSlideViewArmsAndAbortsCleanly() async {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let host = UIView(frame: bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let outgoing = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let incoming = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let controller = PageCurlPanController()
        let delegate = Delegate()
        delegate.accepts = true
        delegate.hostView = host
        delegate.makeSlide = true
        delegate.outgoingImage = outgoing
        delegate.incomingImage = incoming
        controller.delegate = delegate
        controller.attach(to: host)

        controller.begin(controller.recognizer)
        // Wait for `beginInteractive` to actually arm the overlay, not merely cover attachment.
        for _ in 0 ..< 50 where !controller.isArmedForTesting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let slide = delegate.overlayMade as? PageSlideView
        XCTAssertNotNil(slide)
        XCTAssertTrue(controller.isCovering)
        XCTAssertTrue(controller.isArmedForTesting)
        XCTAssertEqual(slide?.isCoverHiddenForTesting, true)
        XCTAssertTrue(slide?.cardImageForTesting === outgoing)
        XCTAssertTrue(slide?.underImageForTesting === incoming)

        await controller.abortDrag()
        XCTAssertFalse(controller.turnInFlight)
        XCTAssertFalse(controller.isCovering)
        XCTAssertFalse(controller.isArmedForTesting)
        XCTAssertEqual(delegate.didCancel, 1)
        XCTAssertEqual(delegate.didFinish, 1)
        XCTAssertNil(slide?.superview)
        XCTAssertNil(slide?.cardImageForTesting)
        XCTAssertNil(slide?.underImageForTesting)
    }

    private final class ScrollDelegate: PageSlideScrollDelegate {
        var rtl = false
        var canGoForward = true
        var canGoBackward = true
        var enabled = true
        var accepts = true
        var turns: [PageCurlTurnDirection] = []

        func slideScrollContext(in view: UIView) -> PageCurlPanContext {
            PageCurlPanContext(
                rtl: rtl,
                viewWidth: view.bounds.width,
                viewHeight: view.bounds.height,
                canGoForward: canGoForward,
                canGoBackward: canGoBackward,
                hasSelection: false,
                interactiveCurlEnabled: enabled,
                zoomed: false,
                acceptsGesture: accepts
            )
        }

        func slideScrollTurn(direction: PageCurlTurnDirection) {
            turns.append(direction)
        }
    }

    func testSlideScrollControllerAcceptsTrackpadScrollsAndTriggersOncePerGesture() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let controller = PageSlideScrollController()
        let delegate = ScrollDelegate()
        controller.delegate = delegate
        controller.attach(to: host)
        controller.isEnabled = true

        if #available(iOS 13.4, *) {
            XCTAssertEqual(controller.recognizer.allowedScrollTypesMask, .all)
        }
        let touchTypes = Set(controller.recognizer.allowedTouchTypes.map(\.intValue))
        XCTAssertFalse(touchTypes.contains(UITouch.TouchType.direct.rawValue))
        XCTAssertFalse(touchTypes.contains(UITouch.TouchType.indirectPointer.rawValue))
        XCTAssertTrue(touchTypes.contains(UITouch.TouchType.indirect.rawValue))

        // Continuous trackpad horizontal swipe: triggers once despite multiple momentum frames.
        let forwardSwipe = PageCurlPanSample(
            translationX: -28, translationY: 2, velocityX: -320, velocityY: 10, locationX: 8, locationY: 400
        )
        controller.handle(state: .began, sample: forwardSwipe, in: host)
        controller.handle(state: .changed, sample: forwardSwipe, in: host)
        controller.handle(state: .changed, sample: forwardSwipe, in: host)
        controller.handle(state: .ended, sample: forwardSwipe, in: host)
        XCTAssertEqual(delegate.turns, [.forward])

        // Next gesture in the opposite direction (even with cursor in left bezel) turns backward.
        let backwardSwipe = PageCurlPanSample(
            translationX: 24, translationY: 0, velocityX: 240, velocityY: 0, locationX: 4, locationY: 400
        )
        controller.handle(state: .began, sample: backwardSwipe, in: host)
        controller.handle(state: .ended, sample: backwardSwipe, in: host)
        XCTAssertEqual(delegate.turns, [.forward, .backward])

        // Small discrete scroll tick commits on .ended; tiny zeroed nudge does not.
        let discreteTick = PageCurlPanSample(
            translationX: -8, translationY: 0, velocityX: 0, velocityY: 0, locationX: 500, locationY: 400
        )
        controller.handle(state: .began, sample: discreteTick, in: host)
        XCTAssertEqual(delegate.turns.count, 2)
        controller.handle(state: .ended, sample: discreteTick, in: host)
        XCTAssertEqual(delegate.turns, [.forward, .backward, .forward])

        let cancelledNudge = PageCurlPanSample(
            translationX: 0, translationY: 0, velocityX: 0, velocityY: 0, locationX: 500, locationY: 400
        )
        controller.handle(state: .began, sample: cancelledNudge, in: host)
        controller.handle(state: .ended, sample: cancelledNudge, in: host)
        XCTAssertEqual(delegate.turns.count, 3)

        // Vertical trackpad scroll never turns.
        let vertical = PageCurlPanSample(
            translationX: -5, translationY: -80, velocityX: -20, velocityY: -400, locationX: 500, locationY: 400
        )
        controller.handle(state: .began, sample: vertical, in: host)
        controller.handle(state: .ended, sample: vertical, in: host)
        XCTAssertEqual(delegate.turns.count, 3)
    }
}
