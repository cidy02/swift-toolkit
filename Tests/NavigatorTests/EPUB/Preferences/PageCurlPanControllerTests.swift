//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
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
        /// The reveal itself is slow: the pan is still preparing while it waits.
        var revealGate: (() async -> Void)?
        var overlayFactory: ((CGRect) -> any PageTurnOverlayView)?

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
            if let overlayFactory {
                let spy = overlayFactory(frame)
                overlayMade = spy
                return spy
            }
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
            await revealGate?()
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
        var onCancelForTesting: (() -> Void)?
        func curlPanCancel(direction: PageCurlTurnDirection, withinResource: Bool) async {
            didCancel += 1
            onCancelForTesting?()
        }
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

    /// The Slide's 0.18 s cross-dissolve is not cut short by a release at the far edge; a cancel need not wait.
    @MainActor
    func testSlideDoesNotLandBeforeItsCrossDissolveHasRunButACancelDoesNotWait() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "no dissolve under Reduce Motion")
        for commit in [true, false] {
            let gate = CaptureGate()
            let (controller, delegate) = await heldDrag(gate: gate)
            let slide = try XCTUnwrap(delegate.overlayMade as? PageSlideView)
            let real = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
            await gate.release(real)
            for _ in 0 ..< 100 where slide.underImageForTesting !== real { try? await Task.sleep(nanoseconds: 5_000_000) }
            slide.track(progress: commit ? 1 : 0, fingerUV: .zero)
            let start = CACurrentMediaTime()
            await slide.finishInteractive(target: commit ? 1 : 0, progressVelocity: 0)
            let took = CACurrentMediaTime() - start
            if commit {
                XCTAssertGreaterThan(took, 0.1, "landed before the dissolve finished")
            } else {
                XCTAssertLessThan(took, 0.1, "a cancel is already flat and does not wait")
            }
            await controller.abortDrag()
        }
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

    /// Counts what the pan controller does to its overlay.
    @MainActor private final class SpyOverlay: UIView, PageTurnOverlayView {
        var replaced: [UIImage] = []
        var replaceFades: [Bool] = []
        var replaceResult = true
        var released = false
        func showCover(_ image: UIImage, background: UIColor) {}
        func runTap(outgoing: UIImage, incoming: UIImage, spine: PageCurlSpine, peelSign: CGFloat, realVerso: Bool, reversed: Bool, duration: TimeInterval) async {}
        func beginInteractive(outgoing: UIImage, incoming: UIImage, spine: PageCurlSpine, peelSign: CGFloat, realVerso: Bool, reversed: Bool, progress: CGFloat, grabUV: CGPoint, fingerUV: CGPoint) async -> Bool { true }
        func track(progress: CGFloat, fingerUV: CGPoint) {}
        func finishInteractive(target: CGFloat, progressVelocity: CGFloat) async {}
        func freezeOnCover(showing image: UIImage?) {}
        func releaseResources() { released = true }
        func expectIncomingPlaceholder() {}
        func replaceIncoming(_ image: UIImage, fade: Bool) async -> Bool {
            replaced.append(image)
            replaceFades.append(fade)
            return replaceResult
        }
    }

    private func spyDrag(
        gate: CaptureGate,
        held: Task<UIImage?, Never>? = nil,
        revealGate: (() async -> Void)? = nil
    ) async -> (PageCurlPanController, Delegate, SpyOverlay?) {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let host = UIView(frame: bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()
        windows.append(window)
        let delegate = Delegate()
        delegate.accepts = true
        delegate.hostView = host
        delegate.outgoingImage = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        delegate.heldCapture = held ?? gate.task()
        delegate.revealGate = revealGate
        delegate.overlayFactory = { SpyOverlay(frame: $0) }
        let controller = PageCurlPanController()
        controller.delegate = delegate
        controller.attach(to: host)
        controller.begin(controller.recognizer)
        if revealGate == nil {
            for _ in 0 ..< 100 where !controller.isArmedForTesting { try? await Task.sleep(nanoseconds: 10_000_000) }
        } else {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return (controller, delegate, delegate.overlayMade as? SpyOverlay)
    }

    /// P1: a drag cancelled while it is still preparing must keep the cover up until the capture
    /// it started has finished. Without that the capture moves the live column uncovered.
    @MainActor
    func testACancelWhilePreparingKeepsTheCoverUntilTheStartedCaptureFinishes() async throws {
        let capture = CaptureGate()
        var openReveal: CheckedContinuation<Void, Never>?
        let (controller, delegate, spy) = await spyDrag(gate: capture, revealGate: {
            await withCheckedContinuation { openReveal = $0 }
        })
        let overlay = try XCTUnwrap(spy)
        XCTAssertFalse(controller.isArmedForTesting, "still preparing: the reveal has not returned")
        // Cancelled (the finger lifted early), then the reveal returns with its capture running.
        let aborting = Task { @MainActor in await controller.abortDrag() }
        try await Task.sleep(nanoseconds: 100_000_000)
        openReveal?.resume()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(overlay.superview, "the cover stays while the capture is outstanding")
        XCTAssertTrue(controller.turnInFlight)
        await capture.release(UIImage())
        await aborting.value
        XCTAssertFalse(controller.turnInFlight)
        XCTAssertNil(overlay.superview)
        XCTAssertEqual(delegate.commits, 0)
    }

    /// P2: a capture that never returns cannot wedge the turn: it is bounded, the drag ends as a cancel.
    @MainActor
    func testACaptureThatNeverReturnsIsBoundedAndTheDragCancelsCleanly() async throws {
        let saved = PageCurlPanController.incomingDeadline
        PageCurlPanController.incomingDeadline = 0.3
        let savedGrace = PageCurlPanController.captureSettleGrace
        PageCurlPanController.captureSettleGrace = 0.2
        defer {
            PageCurlPanController.incomingDeadline = saved
            PageCurlPanController.captureSettleGrace = savedGrace
        }
        let gate = CaptureGate()
        let (controller, delegate, spy) = await spyDrag(gate: gate)
        let overlay = try XCTUnwrap(spy)
        let done = Task { @MainActor in await controller.finish(commit: true, velocity: 0) }
        var finished = false
        Task { @MainActor in await done.value; finished = true }
        for _ in 0 ..< 200 where !finished { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(finished, "finish returned without the capture")
        XCTAssertEqual(delegate.commits, 0, "a turn whose page never arrived is not committed")
        XCTAssertEqual(delegate.didCancel, 1)
        XCTAssertNil(overlay.superview)
    }

    /// Stands in for a capture that scrolls the live column step by step, honouring cancellation
    /// the way `prepareCurlIncoming` does.
    @MainActor private final class SteppingCapture {
        var steps = 0
        var uncoveredSteps = 0
        weak var cover: UIView?
        func task() -> Task<UIImage?, Never> {
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if Task.isCancelled { break }
                    steps += 1
                    if let cover, cover.superview == nil { uncoveredSteps += 1 }
                }
                return nil
            }
        }
    }

    /// P1 (round 3): a capture still running when the backstop fires is cancelled; it never moves
    /// the column once the cover is gone, and the column is restored (cancel) before the cover goes.
    @MainActor
    func testACaptureRunningPastTheBackstopNeverMovesTheColumnAfterTheCoverIsGone() async throws {
        let saved = (PageCurlPanController.incomingDeadline, PageCurlPanController.captureSettleGrace)
        PageCurlPanController.incomingDeadline = 0.2
        PageCurlPanController.captureSettleGrace = 0.5
        defer { (PageCurlPanController.incomingDeadline, PageCurlPanController.captureSettleGrace) = saved }
        let capture = SteppingCapture()
        let gate = CaptureGate()
        let (controller, delegate, spy) = await spyDrag(gate: gate, held: capture.task())
        let overlay = try XCTUnwrap(spy)
        capture.cover = overlay
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(capture.steps, 0, "the capture is running")
        var coverUpAtCancel = false
        delegate.onCancelForTesting = { coverUpAtCancel = overlay.superview != nil }
        await controller.finish(commit: true, velocity: 0)
        let stepsAtEnd = capture.steps
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(capture.steps, stepsAtEnd, "nothing moves after the backstop")
        XCTAssertEqual(capture.uncoveredSteps, 0)
        XCTAssertTrue(coverUpAtCancel, "the column is restored under the cover")
        XCTAssertEqual(delegate.didCancel, 1)
        XCTAssertEqual(delegate.commits, 0)
        XCTAssertNil(overlay.superview)
    }

    /// The backstop clears the sum of the capture's own bounds, and the neighbour load clears
    /// `spreadDidLoad`'s fixed 0.5 s of sleeps with margin.
    func testTheBackstopExceedsTheCapturesOwnBounds() {
        let snapshot = PageCurlSnapshotter.snapshotDeadline
        let paint = PageTransitionAnimator.paintTimeout
        let reflowable = 2 * (paint + paint) + paint * 2 + 2 * snapshot
        let neighbour = PaginationView.neighborLoadDeadline + paint + snapshot
        XCTAssertGreaterThan(PageCurlPanController.defaultIncomingDeadline, max(reflowable, neighbour))
        XCTAssertGreaterThanOrEqual(PaginationView.neighborLoadDeadline, 0.5 + 1.0)
    }

    /// A page that arrives after the turn was already being cancelled is not uploaded.
    @MainActor
    func testALateImageAfterACancelIsNotUploaded() async throws {
        let gate = CaptureGate()
        let (controller, _, spy) = await spyDrag(gate: gate)
        let overlay = try XCTUnwrap(spy)
        let release = Task { await gate.release(UIImage()) }
        await controller.finish(commit: false, velocity: 0)
        await release.value
        XCTAssertTrue(overlay.replaced.isEmpty, "no texture upload for a turn that is cancelling")
    }

    /// A release that is a commit swaps the page in without a fade; a failed upload cancels.
    @MainActor
    func testACommitSwapsTheRealPageWithoutAFadeAndAFailedUploadCancels() async throws {
        let gate = CaptureGate()
        let (controller, delegate, spy) = await spyDrag(gate: gate)
        let overlay = try XCTUnwrap(spy)
        let real = UIImage()
        let release = Task { await gate.release(real) }
        await controller.finish(commit: true, velocity: 0)
        await release.value
        XCTAssertEqual(overlay.replaced.count, 1)
        XCTAssertEqual(overlay.replaceFades, [false], "released: nothing to fade")
        XCTAssertEqual(delegate.commits, 1)

        let gate2 = CaptureGate()
        let (controller2, delegate2, spy2) = await spyDrag(gate: gate2)
        let overlay2 = try XCTUnwrap(spy2)
        overlay2.replaceResult = false
        let release2 = Task { await gate2.release(UIImage()) }
        await controller2.finish(commit: true, velocity: 0)
        await release2.value
        XCTAssertEqual(delegate2.commits, 0, "a page that could not be uploaded is not committed")
        XCTAssertEqual(delegate2.didCancel, 1)
    }

    /// A capture that fails after the finger committed cancels instead.
    @MainActor
    func testACaptureThatFailsAfterACommitReleaseCancels() async throws {
        let gate = CaptureGate()
        let (controller, delegate, _) = await spyDrag(gate: gate)
        let release = Task { await gate.release(nil) }
        await controller.finish(commit: true, velocity: 0)
        await release.value
        XCTAssertEqual(delegate.commits, 0)
        XCTAssertEqual(delegate.didCancel, 1)
    }

    /// The placeholder is the page colour, custom paper included.
    func testThePlaceholderIsThePageColour() throws {
        let paper = UIColor(red: 0.98, green: 0.94, blue: 0.85, alpha: 1)
        let image = PageCurlPlaceholder.image(background: paper)
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(Double(pixel[0]), 0.98 * 255, accuracy: 3)
        XCTAssertEqual(Double(pixel[1]), 0.94 * 255, accuracy: 3)
        XCTAssertEqual(Double(pixel[2]), 0.85 * 255, accuracy: 3)
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

    @MainActor
    private func makeCacheNavigator() async throws -> (EPUBNavigatorViewController, UIWindow) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kudos-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let body = (1 ... 120).map { "<p>Paragraph \($0). The city never switched its streetlamps off.</p>" }.joined()
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>a</title></head><body>\(body)</body></html>"
            .write(to: directory.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        let container = try await DirectoryContainer(directory: XCTUnwrap(FileURL(url: directory)))
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Cache"), readingOrder: [Link(href: "a.xhtml", mediaType: .xhtml)]),
            container: container
        )
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: nil,
            config: .init(preferences: EPUBPreferences(pageTransition: .curl))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigator
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        for _ in 0 ..< 200 where navigator.currentLocation == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        navigator.seedCurlPrerenderForTesting()
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting, "the seeded cache is readable under the current key")
        return (navigator, window)
    }

    /// Events that cannot change a cached neighbour's pixels keep the cache.
    @MainActor
    func testLeavingAndReturningToTheAppAndHidingTheReaderKeepTheCache() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        navigator.viewDidDisappear(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting)
    }

    @MainActor
    func testTheReadAloudDecorationGroupKeepsTheCacheButHighlightsClearIt() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.transientDecorationGroups = ["tts"]
        let locator = Locator(href: RelativeURL(string: "a.xhtml")!, mediaType: .xhtml, locations: .init(progression: 0.0))
        let mark = Decoration(id: "w", locator: locator, style: .highlight(tint: .yellow))
        navigator.apply(decorations: [mark], in: "tts")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting, "a spoken-word mark does not empty the cache")

        navigator.apply(decorations: [mark], in: "highlights")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting, "a user highlight can be on the neighbour")
    }

    private func page(_ lines: Int) -> PageCurlFingerprint {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 120)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
            UIColor.black.setFill()
            for i in 0 ..< lines { ctx.fill(CGRect(x: 6, y: 8 + i * 6, width: 48, height: 2)) }
        }
        return PageCurlFingerprint.of(image.cgImage!)!
    }

    /// A moving spoken-word mark changes the page's pixels but not the page: the fingerprint must not call
    /// the next drag a miss; without such a mark it still does.
    @MainActor
    func testASpokenWordMarkDoesNotMakeTheNextDragAFingerprintMiss() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.transientDecorationGroups = ["tts"]
        navigator.seedCurlPrerenderForTesting(current: page(10))
        XCTAssertFalse(navigator.curlCachedNeighborIsServedForTesting(.forward, onScreen: page(2)), "a different page is a miss")
        XCTAssertTrue(navigator.curlCachedNeighborIsServedForTesting(.forward, onScreen: page(10)))
        let locator = Locator(href: RelativeURL(string: "a.xhtml")!, mediaType: .xhtml, locations: .init(progression: 0.0))
        navigator.apply(decorations: [Decoration(id: "w", locator: locator, style: .highlight(tint: .yellow))], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(navigator.curlCachedNeighborIsServedForTesting(.forward, onScreen: page(2)), "with the mark showing, the highlighted page still matches")
    }

    private func ttsMark(_ id: String = "w") -> Decoration {
        let locator = Locator(href: RelativeURL(string: "a.xhtml")!, mediaType: .xhtml, locations: .init(progression: 0.0))
        return Decoration(id: id, locator: locator, style: .highlight(tint: .yellow))
    }

    /// Stopping Read Aloud must not leave a highlight baked into a cached page.
    @MainActor
    func testStoppingReadAloudClearsPagesTakenWhileItsMarkShowed() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.transientDecorationGroups = ["tts"]
        navigator.apply(decorations: [ttsMark()], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        navigator.seedCurlPrerenderForTesting(current: page(10))
        navigator.apply(decorations: [], in: "tts")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting, "a page taken with the mark showing is dropped when it clears")

        // A page taken with no mark showing survives a mark appearing and then clearing.
        navigator.seedCurlPrerenderForTesting(current: page(10))
        navigator.apply(decorations: [ttsMark()], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        navigator.apply(decorations: [], in: "tts")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting)
    }

    /// A tap curl's pages are tainted like a drag's.
    @MainActor
    func testAPageStoredByATapWhileTheMarkShowedIsDroppedWhenItClears() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.transientDecorationGroups = ["tts"]
        // Start from an empty cache so the tap's own store is what is under test.
        navigator.apply(decorations: [ttsMark("h")], in: "highlights")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting)
        navigator.apply(decorations: [ttsMark()], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        navigator.storeTapCurlPagesForTesting()
        XCTAssertTrue(navigator.curlPrerenderTaintedForTesting, "the tap's store is tainted while the mark shows")
        navigator.apply(decorations: [], in: "tts")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(navigator.curlPrerenderTaintedForTesting, "the clear emptied the cache")
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting)
    }

    /// The mark moving does not wash the taint out of what was stored while it showed.
    @MainActor
    func testAPageStoredWhileTheMarkShowedStaysTaintedWhenTheMarkMoves() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.transientDecorationGroups = ["tts"]
        navigator.apply(decorations: [ttsMark("a")], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        navigator.seedCurlPrerenderForTesting(current: page(10))
        navigator.apply(decorations: [ttsMark("b")], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting, "a moving mark keeps the cache")
        navigator.apply(decorations: [], in: "tts")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting)
    }

    /// A page stored after the mark was cleared but before WebKit painted the clear still carries it.
    @MainActor
    func testAPageStoredBetweenTheClearAndItsPaintIsDropped() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.transientDecorationGroups = ["tts"]
        navigator.apply(decorations: [ttsMark()], in: "tts")
        try await Task.sleep(nanoseconds: 400_000_000)
        navigator.apply(decorations: [], in: "tts")
        navigator.seedCurlPrerenderForTesting(current: page(10))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting)
    }

    /// A shot that outlives its drag is not written into the next one.
    @MainActor
    func testALateShotIsNotWrittenIntoTheNextDrag() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        let shot = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let first = navigator.curlDragTokenForTesting
        navigator.beginDragTokenForTesting()
        XCTAssertNil(navigator.keepCurlIncomingForTesting(shot, drag: first))
        XCTAssertNil(navigator.curlDragIncomingForTesting)
        XCTAssertNotNil(navigator.keepCurlIncomingForTesting(shot, drag: navigator.curlDragTokenForTesting))
        XCTAssertNotNil(navigator.curlDragIncomingForTesting)
    }

    /// Light/dark (and the other traits the page depends on) change while the app is active.
    @MainActor
    func testAnAppearanceChangeWhileActiveClearsTheCache() async throws {
        let (navigator, window) = try await makeCacheNavigator()
        window.overrideUserInterfaceStyle = window.traitCollection.userInterfaceStyle == .dark ? .light : .dark
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting)
    }

    /// iOS flips the appearance to take App Switcher snapshots: not looked at while inactive,
    /// compared on becoming active.
    @MainActor
    func testAnAppearanceFlipWhileInactiveIsComparedOnBecomingActive() async throws {
        let (navigator, window) = try await makeCacheNavigator()
        let original = window.traitCollection.userInterfaceStyle
        let other: UIUserInterfaceStyle = original == .dark ? .light : .dark
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        window.overrideUserInterfaceStyle = other
        try await Task.sleep(nanoseconds: 300_000_000)
        window.overrideUserInterfaceStyle = original
        try await Task.sleep(nanoseconds: 300_000_000)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting, "flipped and back while inactive: nothing changed")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        window.overrideUserInterfaceStyle = other
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(navigator.curlPrerenderIsSeededForTesting, "not looked at while inactive")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting, "a real change is picked up on becoming active")
    }

    @MainActor
    func testPreferencesAndMemoryPressureClearTheCache() async throws {
        let (navigator, _) = try await makeCacheNavigator()
        navigator.submitPreferences(EPUBPreferences(fontSize: 1.3, pageTransition: .curl))
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting, "a preference change can change every page")
        try await Task.sleep(nanoseconds: 800_000_000)
        navigator.seedCurlPrerenderForTesting()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(navigator.curlPrerenderIsSeededForTesting, "memory pressure frees it")
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
