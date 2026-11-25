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
        /// A capture that has not arrived: the turn starts on a placeholder.
        var heldCapture: Task<UIImage?, Never>?

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
            if let held = heldCapture {
                return PageCurlPanFrame(
                    outgoing: outgoing,
                    incoming: PageCurlPlaceholder.image(background: background),
                    background: background,
                    spine: .leading,
                    peelSign: 1,
                    realVerso: false,
                    withinResource: true,
                    reversed: direction == .backward,
                    pendingIncoming: held
                )
            }
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
        var commitLands = true
        var commits = 0
        var committedTurns: [PageCurlTurnDirection] = []
        var onCommit: (() -> Void)?
        func curlPanCommit(direction: PageCurlTurnDirection, withinResource: Bool) async -> Bool {
            commits += 1
            onCommit?()
            return commitLands
        }
        func curlPanDidCommitTurn(direction: PageCurlTurnDirection) { committedTurns.append(direction) }
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

    /// An armed Slide drag, ready to be released. `finish` is what the recognizer's
    /// end state runs.
    private func armedSlideDrag() async -> (PageCurlPanController, Delegate) {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let host = UIView(frame: bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let delegate = Delegate()
        delegate.accepts = true
        delegate.hostView = host
        delegate.makeSlide = true
        delegate.outgoingImage = renderer.image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        delegate.incomingImage = renderer.image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let controller = PageCurlPanController()
        controller.delegate = delegate
        controller.attach(to: host)
        controller.begin(controller.recognizer)
        for _ in 0 ..< 100 where !controller.isArmedForTesting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        windows.append(window)
        return (controller, delegate)
    }

    private var windows: [UIWindow] = []

    @MainActor private final class CaptureGate {
        var continuation: CheckedContinuation<UIImage?, Never>?
        func task() -> Task<UIImage?, Never> {
            Task { @MainActor in await withCheckedContinuation { self.continuation = $0 } }
        }
        func release(_ image: UIImage?) async {
            for _ in 0 ..< 100 where continuation == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
            continuation?.resume(returning: image)
            continuation = nil
        }
    }

    private func heldDrag(gate: CaptureGate) async -> (PageCurlPanController, Delegate) {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let host = UIView(frame: bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()
        windows.append(window)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let delegate = Delegate()
        delegate.accepts = true
        delegate.hostView = host
        delegate.makeSlide = true
        delegate.outgoingImage = renderer.image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        delegate.heldCapture = gate.task()
        let controller = PageCurlPanController()
        controller.delegate = delegate
        controller.attach(to: host)
        controller.begin(controller.recognizer)
        for _ in 0 ..< 100 where !controller.isArmedForTesting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return (controller, delegate)
    }

    /// A cache miss must not make the finger wait: the drag arms on the placeholder
    /// while the capture is still held, and the real page replaces it on arrival.
    @MainActor
    func testADragArmsOnAPlaceholderWhileTheCaptureIsHeldThenTheRealPageReplacesIt() async throws {
        let gate = CaptureGate()
        let (controller, delegate) = await heldDrag(gate: gate)
        XCTAssertTrue(controller.isArmedForTesting, "armed with the capture still outstanding")
        let slide = try XCTUnwrap(delegate.overlayMade as? PageSlideView)
        let placeholder = try XCTUnwrap(slide.underImageForTesting)
        XCTAssertEqual(placeholder.size, CGSize(width: 8, height: 8))

        let real = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        await gate.release(real)
        for _ in 0 ..< 100 where slide.underImageForTesting !== real { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(slide.underImageForTesting === real, "the real page replaced the placeholder")
        await controller.finish(commit: true, velocity: 0)
        XCTAssertEqual(delegate.commits, 1)
    }

    /// Cancelling before the snapshot arrives ends cleanly, and the late snapshot is dropped.
    @MainActor
    func testCancellingBeforeTheCaptureArrivesEndsCleanlyAndDropsTheLateImage() async throws {
        let gate = CaptureGate()
        let (controller, delegate) = await heldDrag(gate: gate)
        let slide = try XCTUnwrap(delegate.overlayMade as? PageSlideView)
        let release = Task { await gate.release(UIImage()) }
        await controller.finish(commit: false, velocity: 0)
        await release.value
        XCTAssertEqual(delegate.commits, 0)
        XCTAssertEqual(delegate.didCancel, 1)
        XCTAssertEqual(delegate.didFinish, 1)
        XCTAssertFalse(controller.turnInFlight)
        XCTAssertNil(slide.superview)
    }

    /// A capture that fails mid-drag ends the turn back where it started.
    @MainActor
    func testACaptureThatFailsEndsTheDragWithoutACommit() async {
        let gate = CaptureGate()
        let (controller, delegate) = await heldDrag(gate: gate)
        await gate.release(nil)
        for _ in 0 ..< 100 where controller.turnInFlight { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.turnInFlight)
        XCTAssertEqual(delegate.commits, 0)
        XCTAssertEqual(delegate.didCancel, 1)
    }

    func testACommittedDragReportsItsTurnExactlyOnce() async {
        let (controller, delegate) = await armedSlideDrag()
        XCTAssertTrue(controller.isArmedForTesting)
        await controller.finish(commit: true, velocity: 0)
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertEqual(delegate.committedTurns, [.forward])
        XCTAssertEqual(delegate.didCancel, 0)
        XCTAssertEqual(delegate.didFinish, 1)
        // A second release of the same drag does nothing.
        await controller.finish(commit: true, velocity: 0)
        XCTAssertEqual(delegate.committedTurns, [.forward])
    }

    func testADragThatSnapsBackReportsNoTurn() async {
        let (controller, delegate) = await armedSlideDrag()
        await controller.finish(commit: false, velocity: 0)
        XCTAssertEqual(delegate.commits, 0)
        XCTAssertEqual(delegate.didCancel, 1)
        XCTAssertTrue(delegate.committedTurns.isEmpty)
    }

    func testACommitThatDoesNotLandReportsNoTurn() async {
        // The spread the drag prepared was replaced (reload): nothing turned.
        let (controller, delegate) = await armedSlideDrag()
        delegate.commitLands = false
        await controller.finish(commit: true, velocity: 0)
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertTrue(delegate.committedTurns.isEmpty)
    }

    func testAStopDuringTheCommitReportsNoTurn() async {
        // Reload, background, Reduce Motion or VoiceOver cuts the turn while it lands.
        let (controller, delegate) = await armedSlideDrag()
        delegate.onCommit = { controller.abort() }
        await controller.finish(commit: true, velocity: 0)
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertTrue(delegate.committedTurns.isEmpty)
        XCTAssertFalse(controller.turnInFlight)
    }

    func testAStopBeforeTheReleaseReportsNoTurnAndTheDragCancels() async {
        let (controller, delegate) = await armedSlideDrag()
        controller.abort()
        await controller.finish(commit: true, velocity: 0)
        XCTAssertEqual(delegate.commits, 0)
        XCTAssertTrue(delegate.committedTurns.isEmpty)
    }

    func testAGoMarkedAsUserInputCarriesItsSource() {
        var options = NavigatorGoOptions(animated: true)
        XCTAssertNil(options.userTurnSource)
        for source in [UserPageTurnSource.drag, .trackpad, .tap, .key] {
            options.userTurnSource = source
            XCTAssertEqual(options.userTurnSource, source)
            XCTAssertTrue(options.animated)
        }
        options.userTurnSource = nil
        XCTAssertNil(options.userTurnSource)
        // Another option is not a source.
        var other = NavigatorGoOptions()
        other.otherOptions["userTurnSource"] = .string("somethingElse")
        XCTAssertNil(other.userTurnSource)
    }

    private final class ScrollDelegate: PageSlideScrollDelegate {
        var rtl = false
        var canGoForward = true
        var canGoBackward = true
        var hasSelection = false
        var zoomed = false
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
                hasSelection: hasSelection,
                interactiveCurlEnabled: enabled,
                zoomed: zoomed,
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

    private final class SyntheticPanGestureRecognizer: UIPanGestureRecognizer {
        var syntheticTranslation: CGPoint = .zero
        var syntheticVelocity: CGPoint = .zero
        var syntheticLocation: CGPoint = .zero

        override func translation(in view: UIView?) -> CGPoint { syntheticTranslation }
        override func velocity(in view: UIView?) -> CGPoint { syntheticVelocity }
        override func location(in view: UIView?) -> CGPoint { syntheticLocation }
    }

    /// A short horizontal trackpad start that turns vertical, acquires a text
    /// selection, zooms, or hits a boundary before release must not turn on `.ended`.
    /// Exercises `gestureRecognizerShouldBegin` so recognition-time state is populated.
    func testSlideScrollControllerRejectsReleaseAfterTurningVerticalOrSelectingText() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let controller = PageSlideScrollController()
        let delegate = ScrollDelegate()
        controller.delegate = delegate
        controller.attach(to: host)
        controller.isEnabled = true

        let pan = SyntheticPanGestureRecognizer()
        host.addGestureRecognizer(pan)
        pan.syntheticLocation = CGPoint(x: 500, y: 400)

        let shortHorizontalStart = PageCurlPanSample(
            translationX: -8, translationY: 0, velocityX: -40, velocityY: 0, locationX: 500, locationY: 400
        )

        func recognizeShortHorizontalStart() {
            pan.syntheticTranslation = CGPoint(x: -8, y: 0)
            pan.syntheticVelocity = CGPoint(x: -40, y: 0)
            XCTAssertTrue(controller.gestureRecognizerShouldBegin(pan))
        }

        // 1. Starts 8 pt horizontal (below 12 pt early commit), then turns vertical (8 pt H, 30 pt V).
        recognizeShortHorizontalStart()
        controller.handle(state: .began, sample: shortHorizontalStart, in: host)
        XCTAssertTrue(delegate.turns.isEmpty)
        controller.handle(
            state: .changed,
            sample: PageCurlPanSample(
                translationX: -8, translationY: -20, velocityX: 0, velocityY: -80, locationX: 500, locationY: 380
            ),
            in: host
        )
        controller.handle(
            state: .ended,
            sample: PageCurlPanSample(
                translationX: -8, translationY: -30, velocityX: 0, velocityY: 0, locationX: 500, locationY: 370
            ),
            in: host
        )
        XCTAssertTrue(delegate.turns.isEmpty, "Gesture that ended mostly vertical must not turn the page")

        // 2. Starts horizontal, then a text selection appears before release.
        recognizeShortHorizontalStart()
        controller.handle(state: .began, sample: shortHorizontalStart, in: host)
        delegate.hasSelection = true
        controller.handle(
            state: .ended,
            sample: PageCurlPanSample(
                translationX: -8, translationY: 0, velocityX: 0, velocityY: 0, locationX: 500, locationY: 400
            ),
            in: host
        )
        XCTAssertTrue(delegate.turns.isEmpty, "Selection appearing before release must block the turn")
        delegate.hasSelection = false

        // 3. Starts horizontal, then the page becomes zoomed before release.
        recognizeShortHorizontalStart()
        controller.handle(state: .began, sample: shortHorizontalStart, in: host)
        delegate.zoomed = true
        controller.handle(
            state: .ended,
            sample: PageCurlPanSample(
                translationX: -8, translationY: 0, velocityX: 0, velocityY: 0, locationX: 500, locationY: 400
            ),
            in: host
        )
        XCTAssertTrue(delegate.turns.isEmpty, "Zooming before release must block the turn")
        delegate.zoomed = false

        // 4. Starts horizontal, then forward navigation becomes unavailable before release.
        recognizeShortHorizontalStart()
        controller.handle(state: .began, sample: shortHorizontalStart, in: host)
        delegate.canGoForward = false
        controller.handle(
            state: .ended,
            sample: PageCurlPanSample(
                translationX: -8, translationY: 0, velocityX: 0, velocityY: 0, locationX: 500, locationY: 400
            ),
            in: host
        )
        XCTAssertTrue(delegate.turns.isEmpty, "Unavailable direction before release must block the turn")
        delegate.canGoForward = true

        // 5. Genuine short horizontal gesture released with near-zero velocity still turns once.
        recognizeShortHorizontalStart()
        controller.handle(state: .began, sample: shortHorizontalStart, in: host)
        XCTAssertTrue(delegate.turns.isEmpty)
        controller.handle(
            state: .ended,
            sample: PageCurlPanSample(
                translationX: -8, translationY: 0, velocityX: 0, velocityY: 0, locationX: 500, locationY: 400
            ),
            in: host
        )
        XCTAssertEqual(delegate.turns, [.forward])
    }
}
