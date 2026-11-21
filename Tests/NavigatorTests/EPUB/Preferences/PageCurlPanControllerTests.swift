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
        var sampleImage: UIImage?

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
            sampleImage.map { ($0, .black) }
        }
        func curlPanRevealIncoming(
            direction: PageCurlTurnDirection,
            outgoing: UIImage,
            background: UIColor
        ) async -> PageCurlPanFrame? {
            guard let img = sampleImage else { return nil }
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
    /// through the overlay factory, then tears down cleanly on `abortDrag`.
    func testSlideDragInstallsPageSlideViewAndAbortsCleanly() async {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let host = UIView(frame: bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let img = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let controller = PageCurlPanController()
        let delegate = Delegate()
        delegate.accepts = true
        delegate.hostView = host
        delegate.makeSlide = true
        delegate.sampleImage = img
        controller.delegate = delegate
        controller.attach(to: host)

        controller.begin(controller.recognizer)
        // Let the prepare task arm the slide overlay.
        for _ in 0 ..< 20 where !controller.isCovering {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(delegate.overlayMade is PageSlideView)
        XCTAssertTrue(controller.isCovering)

        await controller.abortDrag()
        XCTAssertFalse(controller.turnInFlight)
        XCTAssertFalse(controller.isCovering)
        XCTAssertEqual(delegate.didCancel, 1)
        XCTAssertEqual(delegate.didFinish, 1)
    }
}
