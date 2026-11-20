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

        func curlPanHostView() -> UIView? { nil }
        func curlPanTouchDown() { touchDowns += 1 }
        func curlPanTouchSequenceEnded() { sequencesEnded += 1 }
        func curlPanDidBegin(direction: PageCurlTurnDirection) -> Bool { accepts }
        func curlPanCaptureOutgoing() async -> (image: UIImage, background: UIColor)? { nil }
        func curlPanRevealIncoming(
            direction: PageCurlTurnDirection,
            outgoing: UIImage,
            background: UIColor
        ) async -> PageCurlPanFrame? { nil }
        func curlPanPrerenderBeyond(direction: PageCurlTurnDirection, withinResource: Bool) async {}
        func curlPanCommit(direction: PageCurlTurnDirection, withinResource: Bool) async {}
        func curlPanCancel(direction: PageCurlTurnDirection, withinResource: Bool) async {}
        func curlPanDidFinish() {}
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
}
