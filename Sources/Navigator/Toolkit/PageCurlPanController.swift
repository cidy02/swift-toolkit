//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

struct PageCurlPanFrame {
    var outgoing: UIImage
    var incoming: UIImage
    var background: UIColor
    var spine: PageCurlSpine
    var peelSign: CGFloat
    var realVerso: Bool
    var withinResource: Bool
    /// One-page turn back to the previous page. The cylinder runs backwards
    /// from the binding spine instead of peeling off the opposite edge.
    var reversed: Bool
    /// Set when `incoming` is only a page-colour placeholder: the real bitmap is
    /// still being taken (a cache miss). The finger tracks the placeholder at once
    /// and the real page replaces it when this resolves. Nil result = it failed.
    var pendingIncoming: Task<UIImage?, Never>? = nil
}

/// The incoming side of a turn whose real page is not cached yet: the page
/// colour of the current theme, no text.
enum PageCurlPlaceholder {
    static func image(background: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

/// The navigator owns location and the web view. The controller owns the finger.
@MainActor
protocol PageCurlPanDelegate: AnyObject {
    func curlPanContext(in view: UIView) -> PageCurlPanContext
    func curlPanHostView() -> UIView?
    func curlPanMakeOverlayView(frame: CGRect) -> any PageTurnOverlayView
    /// First finger down while idle, before the pan is recognised. May start
    /// work that has no visible effect; the delegate drops it if no drag follows.
    func curlPanTouchDown()
    /// The touch sequence ended (lifted, failed or rejected) without starting
    /// a drag. Work started at the touch-down can go.
    func curlPanTouchSequenceEnded()
    func curlPanDidBegin(direction: PageCurlTurnDirection) -> Bool
    func curlPanCaptureOutgoing() async -> (image: UIImage, background: UIColor)?
    func curlPanRevealIncoming(
        direction: PageCurlTurnDirection,
        outgoing: UIImage,
        background: UIColor
    ) async -> PageCurlPanFrame?
    /// Runs alongside the committing spring, before `curlPanCommit`.
    func curlPanPrerenderBeyond(direction: PageCurlTurnDirection, withinResource: Bool) async
    /// Lands the committed turn. True once the page under the cover is the new one;
    /// false when the spread it was prepared on is gone (reload, detach).
    func curlPanCommit(direction: PageCurlTurnDirection, withinResource: Bool) async -> Bool
    /// The drag's turn has landed and nothing aborted it: reported exactly once per
    /// committed drag, never for a snap-back or an aborted one.
    func curlPanDidCommitTurn(direction: PageCurlTurnDirection)
    func curlPanCancel(direction: PageCurlTurnDirection, withinResource: Bool) async
    func curlPanDidFinish()
}

extension PageCurlPanDelegate {
    func curlPanDidCommitTurn(direction: PageCurlTurnDirection) {}

    func curlPanMakeOverlayView(frame: CGRect) -> any PageTurnOverlayView {
        PageCurlView(frame: frame)
    }
}

/// Horizontal pan that lifts the page under the finger. Scroll mode, Reduce
/// Motion, VoiceOver and a text selection never start it.
@MainActor
final class PageCurlPanController: NSObject, UIGestureRecognizerDelegate {
    let recognizer: UIPanGestureRecognizer
    weak var delegate: PageCurlPanDelegate?

    var isEnabled: Bool = false {
        didSet { recognizer.isEnabled = isEnabled }
    }

    private enum Phase {
        case idle
        case preparing
        case armed
        case finishing
    }

    private var phase: Phase = .idle
    private var direction: PageCurlTurnDirection = .forward
    private var withinResource = false
    private var curlView: (any PageTurnOverlayView)?
    private var metalArmed = false
    private var revealed = false
    /// Last tracked finger, velocities and the release decision.
    private var tracker = PageCurlReleaseTracker()
    private var lastProgress: CGFloat {
        get { tracker.lastProgress }
        set { tracker.lastProgress = newValue }
    }
    /// Touch-down, in the host view. The held point is this height on the
    /// peeling edge. `.possible` reports the origin, so a settled gesture
    /// keeps the last point from `.began` / `.changed` / `.ended`.
    private var grabStart = CGPoint(x: 0, y: 0)
    /// First touch of the current sequence, recorded before the pan begins,
    /// and that touch. A second finger makes the origin ambiguous.
    private var touchDown: CGPoint?
    private weak var touchDownTouch: UITouch?
    private var sawAnotherTouch = false
    private var lastFinger: CGPoint {
        get { tracker.lastFinger }
        set { tracker.lastFinger = newValue }
    }
    /// Reading direction for this drag. Sampled once so a move does not rebuild
    /// the pan context on every touch.
    private var rtl = false
    private var endConsumed = false
    private var prepareTask: Task<Void, Never>?
    /// Set when the finger lifts before the incoming page is ready.
    private var pendingRelease: (commit: Bool, velocity: CGFloat, finger: CGPoint)?
    private var aborted = false
    /// The real incoming page, arriving behind the placeholder. `finish` waits for it
    /// before it commits or reverts, so the web view's column state is settled.
    private var incomingArrival: Task<Void, Never>?
    private var incomingFailed = false

    override init() {
        let pan = PageCurlPanRecognizer()
        recognizer = pan
        super.init()
        pan.onReset = { [weak self] in
            self?.recognizerDidReset()
        }
        recognizer.addTarget(self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        recognizer.delaysTouchesBegan = false
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        recognizer.isEnabled = false
    }

    func attach(to view: UIView) {
        view.addGestureRecognizer(recognizer)
    }

    /// True from the first touch until the cover is gone, including the spring.
    var turnInFlight: Bool {
        phase != .idle
    }

    /// The leaf's cover is over the web view, so a hidden scroll is invisible.
    var isCovering: Bool {
        !aborted && curlView?.superview != nil
    }

    /// True once `beginInteractive` has succeeded and the overlay is tracking.
    var isArmedForTesting: Bool {
        phase == .armed && metalArmed
    }

    /// Detach, reload, rotation, Reduce Motion, VoiceOver, background, or a
    /// posture change. The cover comes off immediately. A spring already
    /// running is cut, and `finish` will not commit onto a navigator that
    /// has since reloaded.
    /// `keepingCover`: the reader stays where it is (rotation, background,
    /// Reduce Motion, a posture or CSS change). The leaf stops, but its still
    /// cover stays up until the column under it is back on the page the drag
    /// started from: a commit spring may have stepped the web view one
    /// column past the landing to render it. A reload or a navigation takes
    /// the cover off at once; the spread under it is being replaced.
    func abort(keepingCover: Bool = false) {
        beginTeardown(keepingCover: keepingCover)
    }

    /// Posture changed under the finger. Same teardown as `abort`, then wait
    /// until the cover is gone so the reflow anchor is the page the reader was on.
    /// Every caller gets a continuation. One slot was overwritten by a second
    /// abort, and the first waiter never resumed.
    private var abortContinuations: [CheckedContinuation<Void, Never>] = []

    func abortDrag() async {
        guard phase != .idle else {
            return
        }
        beginTeardown(keepingCover: true)
        if phase == .idle {
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if phase == .idle {
                cont.resume()
            } else {
                abortContinuations.append(cont)
            }
        }
    }

    private func beginTeardown(keepingCover: Bool) {
        guard phase != .idle else {
            return
        }
        aborted = true
        prepareTask?.cancel()
        // Unblock `finishInteractive` and `drawAndWait`. The cover comes off
        // now before a reload installs a new spread under it; otherwise in
        // `tearDown`, once `finish` has put the column back.
        if keepingCover {
            curlView?.freezeOnCover()
        } else {
            curlView?.releaseResources()
            curlView?.removeFromSuperview()
        }
        guard phase == .armed else {
            return
        }
        Task { @MainActor in
            await self.finish(commit: false, velocity: 0)
        }
    }

    private func resumeAbortWaiter() {
        let continuations = abortContinuations
        abortContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Records the touch-down. The pan's own translation starts where it was
    /// recognised, not where the finger landed.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard phase == .idle, let view = gestureRecognizer.view else {
            return true
        }
        if gestureRecognizer.numberOfTouches == 0 {
            touchDown = touch.location(in: view)
            touchDownTouch = touch
            sawAnotherTouch = false
            PageCurlLatency.touchDown(at: touch.timestamp, x: touch.location(in: view).x)
            if isEnabled, touch.type == .direct {
                delegate?.curlPanTouchDown()
            }
        } else if touch !== touchDownTouch {
            sawAnotherTouch = true
        }
        return true
    }

    /// UIKit resets the recognizer once the touch sequence is over, whether or
    /// not it began. Still idle means no drag took the touch-down.
    private func recognizerDidReset() {
        guard phase == .idle else {
            return
        }
        delegate?.curlPanTouchSequenceEnded()
    }

    /// The recorded touch-down, if it is still the one touch on the page.
    private func currentTouchDown() -> CGPoint? {
        let ended = touchDownTouch.map { $0.phase == .ended || $0.phase == .cancelled } ?? true
        return PageCurlPanStateMachine.touchDown(touchDown, sawAnotherTouch: sawAnotherTouch, touchEnded: ended)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard phase == .idle, let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view, let delegate else {
            return false
        }
        let decision = PageCurlPanStateMachine.shouldBegin(
            sample: sample(of: pan),
            context: delegate.curlPanContext(in: view)
        )
        PageCurlLatency.mark("should-begin", "\(decision)")
        guard case let .track(direction) = decision else {
            return false
        }
        self.direction = direction
        return true
    }

    /// A long-press is a selection. The pan waits, and gives up when the press wins.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UILongPressGestureRecognizer
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            begin(gesture)
        case .changed:
            move(gesture)
        case .ended:
            end(gesture, cancelled: false)
        case .cancelled, .failed:
            end(gesture, cancelled: true)
        default:
            break
        }
    }

    /// `.began`. Internal for tests: UIKit does not let a test set a recognizer's state.
    func begin(_ gesture: UIPanGestureRecognizer) {
        guard let delegate, delegate.curlPanDidBegin(direction: direction) else {
            phase = .idle
            return
        }
        phase = .preparing
        aborted = false
        revealed = false
        metalArmed = false
        withinResource = false
        tracker.start(progress: 0, finger: lastFinger)
        endConsumed = false
        pendingRelease = nil
        if let host = gesture.view {
            rtl = delegate.curlPanContext(in: host).rtl
            tracker.forward = direction == .forward
            tracker.rtl = rtl
            grabStart = PageCurlPanStateMachine.grabOrigin(
                touchDown: currentTouchDown(),
                location: gesture.location(in: host),
                translation: gesture.translation(in: host)
            )
            touchDown = nil
            touchDownTouch = nil
            let finger = fingerState(of: gesture, in: host)
            lastFinger = finger.point
            lastProgress = finger.progress
            PageCurlLatency.finger(x: finger.point.x)
            PageCurlLatency.mark(
                "began",
                String(format: "travel=%.0fpt", finger.point.x - grabStart.x)
            )
        }
        let direction = direction
        prepareTask = Task { @MainActor [weak self] in
            await self?.prepare(direction: direction, gesture: gesture)
        }
    }

    private func prepare(direction: PageCurlTurnDirection, gesture: UIPanGestureRecognizer) async {
        guard !aborted, !Task.isCancelled else {
            await failBeforeReveal()
            return
        }
        guard let delegate, let host = delegate.curlPanHostView(), host.window != nil else {
            await failBeforeReveal()
            return
        }
        guard let shot = await delegate.curlPanCaptureOutgoing() else {
            await failBeforeReveal()
            return
        }
        PageCurlLatency.mark("outgoing-ready")
        if aborted || Task.isCancelled || host.window == nil {
            await failBeforeReveal()
            return
        }

        let curl = delegate.curlPanMakeOverlayView(frame: host.bounds)
        curl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curl.showCover(shot.image, background: shot.background)
        host.addSubview(curl)
        curlView = curl
        host.layoutIfNeeded()
        PageCurlLatency.mark("cover-up")

        guard let frame = await delegate.curlPanRevealIncoming(
            direction: direction,
            outgoing: shot.image,
            background: shot.background
        ) else {
            await failBeforeReveal()
            return
        }
        withinResource = frame.withinResource
        revealed = true
        PageCurlLatency.mark("incoming-ready")
        // A cancel that arrived while the snapshot was in flight must not
        // upload textures just to spring back to zero.
        if aborted || Task.isCancelled || host.window == nil || pendingRelease?.commit == false {
            pendingRelease = nil
            await finish(commit: false, velocity: 0)
            return
        }

        let gestureLive = gesture.state == .began || gesture.state == .changed
        let sampled = gestureLive ? fingerState(of: gesture, in: host) : nil
        if let sampled {
            lastProgress = sampled.progress
            lastFinger = sampled.point
        }
        let fingerPoint = sampled?.point ?? pendingRelease?.finger ?? lastFinger
        let progress = sampled?.progress ?? lastProgress
        if frame.pendingIncoming != nil {
            curl.expectIncomingPlaceholder()
        }
        let armed = await curl.beginInteractive(
            outgoing: frame.outgoing,
            incoming: frame.incoming,
            spine: frame.spine,
            peelSign: frame.peelSign,
            realVerso: frame.realVerso,
            reversed: frame.reversed,
            progress: progress,
            grabUV: uv(grabStart, in: host),
            fingerUV: uv(fingerPoint, in: host)
        )
        metalArmed = armed
        PageCurlLatency.mark("armed", "ok=\(armed)")
        // Detach during the upload leaves `beginInteractive` false. Staying
        // `.armed` would pin the reader behind a cover that never finishes.
        if aborted || Task.isCancelled || !armed || host.window == nil {
            await finish(commit: false, velocity: 0)
            return
        }
        phase = .armed
        if let pending = frame.pendingIncoming {
            incomingArrival = Task { @MainActor [weak self, weak curl] in
                let image = await pending.value
                // A late snapshot of a drag that ended, aborted or moved on is dropped.
                guard let self, let curl, self.curlView === curl, !self.aborted, self.phase != .idle else {
                    return
                }
                PageCurlLatency.mark("incoming-arrived", "ok=\(image != nil)")
                if let image {
                    await curl.replaceIncoming(image, fade: true)
                } else {
                    // The page could not be taken: end the drag cleanly, back where it started.
                    self.incomingFailed = true
                    if self.phase == .armed, !self.endConsumed {
                        self.endConsumed = true
                        // Not awaited here: `finish` waits for this very task.
                        Task { @MainActor in
                            await self.finish(commit: false, velocity: 0)
                        }
                    }
                }
            }
        }
        if gesture.state == .began || gesture.state == .changed {
            let now = fingerState(of: gesture, in: host)
            lastProgress = now.progress
            lastFinger = now.point
            curl.track(progress: now.progress, fingerUV: uv(now.point, in: host))
        } else {
            // The finger lifted while the textures uploaded: its last tracked
            // point, not the one sampled before the wait.
            curl.track(progress: lastProgress, fingerUV: uv(lastFinger, in: host))
        }
        if let pending = pendingRelease {
            pendingRelease = nil
            await finish(commit: pending.commit && !aborted, velocity: pending.velocity)
            return
        }
        if aborted {
            await finish(commit: false, velocity: 0)
        }
    }

    private func move(_ gesture: UIPanGestureRecognizer) {
        guard let host = gesture.view else { return }
        let finger = fingerState(of: gesture, in: host)
        tracker.move(progress: finger.progress, finger: finger.point, velocityX: gesture.velocity(in: host).x)
        PageCurlLatency.finger(x: finger.point.x)
        guard phase == .armed, metalArmed, let curlView else { return }
        curlView.track(progress: finger.progress, fingerUV: uv(finger.point, in: host))
    }

    private func end(_ gesture: UIPanGestureRecognizer, cancelled: Bool) {
        // A flick can jump from .began to .ended without a .changed sample.
        // The location is still valid here. After this returns, UIKit resets
        // the gesture to `.possible` and a later sample reads the origin.
        // A cancel with no touch left reports the view's origin, not the
        // finger: the tracker keeps the last tracked position and velocity
        // then. A live lift is used as it is, even back at the start (0).
        var touches = 0
        var location = CGPoint.zero
        var there: CGFloat = 0
        var velocityX: CGFloat = 0
        if let host = gesture.view, gesture.state != .possible {
            touches = gesture.numberOfTouches
            location = gesture.location(in: host)
            there = fingerState(of: gesture, in: host).progress
            velocityX = gesture.velocity(in: host).x
        }
        let result = tracker.release(
            cancelled: cancelled,
            numberOfTouches: touches,
            location: location,
            progress: there,
            velocityX: velocityX,
            width: gesture.view?.bounds.width ?? 1,
            aborted: aborted
        )
        let decision = result.decision
        let velocity = result.velocity
        let progress = result.progress
        let atFarEdge = result.atFarEdge
        let live = result.live ?? -1
        let commit = decision == .commit
        PageCurlLatency.mark("released", "commit=\(commit) phase=\(phase)")
        PageCurlDebug.log(String(
            format: "curl-release state=%@ touches=%d live=%.3f last=%.3f progress=%.3f v=%.0f x=%.0f edge=%@ aborted=%@ -> %@",
            "\(gesture.state.rawValue)\(cancelled ? "(cancelled)" : "")",
            touches, live, lastProgress, progress, velocity, lastFinger.x,
            atFarEdge ? "yes" : "no", aborted ? "yes" : "no", commit ? "commit" : "cancel"
        ))
        switch phase {
        case .preparing:
            pendingRelease = (commit, velocity, lastFinger)
        case .armed:
            // `.ended` then `.cancelled` must not start a second finish that
            // reverts a turn the first one is about to commit.
            guard !endConsumed else { return }
            endConsumed = true
            Task { @MainActor in
                await self.finish(commit: commit, velocity: velocity)
            }
        case .idle, .finishing:
            break
        }
    }

    /// Internal for tests: UIKit does not let a test release a recognizer.
    func finish(commit: Bool, velocity: CGFloat) async {
        guard phase != .idle, phase != .finishing else { return }
        phase = .finishing
        // The real page is still being taken behind the placeholder: its column
        // scroll must finish before anything is committed or put back.
        if let arrival = incomingArrival {
            await arrival.value
            incomingArrival = nil
        }
        let width = delegate?.curlPanHostView()?.bounds.width ?? 1
        let progressVelocity = width > 1 ? velocity / width : 0
        let willCommit = commit && !aborted && !incomingFailed
        // The leaf covers the web view for the whole spring, so the next
        // column can be rendered behind it now instead of at the next touch.
        var prerender: Task<Void, Never>?
        if willCommit, revealed, let delegate {
            let direction = direction
            let withinResource = withinResource
            prerender = Task { @MainActor in
                await delegate.curlPanPrerenderBeyond(direction: direction, withinResource: withinResource)
            }
        }
        // Teardown releases the textures, which resumes this wait immediately.
        // Skip the spring: Reduce Motion and a reload must not keep animating.
        if !aborted, metalArmed, let curlView {
            // A cancel does not carry a forward flick: that velocity already lost
            // the commit test, and keeping it would drag the page the wrong way.
            await curlView.finishInteractive(
                target: willCommit ? 1 : 0,
                progressVelocity: willCommit ? progressVelocity : min(0, progressVelocity)
            )
        }
        await prerender?.value
        // `aborted` may flip during the spring. A stale finish must not commit
        // onto a navigator that reloaded while the leaf was moving. The delegate
        // also drops the call when the spread it prepared is gone.
        let landed = willCommit && !aborted
        var turned = false
        if landed {
            turned = await delegate?.curlPanCommit(direction: direction, withinResource: withinResource) ?? false
        } else if revealed {
            await delegate?.curlPanCancel(direction: direction, withinResource: withinResource)
        }
        // Read before `aborted` is cleared: a turn a stop (reload, background,
        // Reduce Motion, VoiceOver) cut while it landed is an aborted turn, not a user turn.
        let reportTurn = turned && !aborted
        let turnDirection = direction
        tearDown()
        delegate?.curlPanDidFinish()
        phase = .idle
        revealed = false
        metalArmed = false
        pendingRelease = nil
        aborted = false
        incomingFailed = false
        incomingArrival = nil
        resumeAbortWaiter()
        if reportTurn {
            delegate?.curlPanDidCommitTurn(direction: turnDirection)
        }
    }

    private func failBeforeReveal() async {
        guard phase != .idle, phase != .finishing else {
            tearDown()
            return
        }
        phase = .finishing
        tearDown()
        delegate?.curlPanDidFinish()
        phase = .idle
        aborted = false
        pendingRelease = nil
        resumeAbortWaiter()
    }

    private func tearDown() {
        PageCurlView.dropPreloadedTextures()
        curlView?.releaseResources()
        curlView?.removeFromSuperview()
        curlView = nil
        metalArmed = false
    }

    private func sample(of pan: UIPanGestureRecognizer) -> PageCurlPanSample {
        let translation = pan.translation(in: pan.view)
        let velocity = pan.velocity(in: pan.view)
        let location = pan.location(in: pan.view)
        return PageCurlPanSample(
            translationX: translation.x,
            translationY: translation.y,
            velocityX: velocity.x,
            velocityY: velocity.y,
            locationX: location.x,
            locationY: location.y,
            touchDownX: currentTouchDown()?.x
        )
    }

    /// Progress is measured from the touch-down (`grabStart`), the same
    /// origin the leaf uses, so the commit line and the leaf agree.
    private func fingerState(of pan: UIPanGestureRecognizer, in view: UIView) -> (progress: CGFloat, point: CGPoint) {
        let location = pan.location(in: view)
        return (
            PageCurlPanStateMachine.progress(
                translationX: location.x - grabStart.x,
                width: view.bounds.width,
                forward: direction == .forward,
                rtl: rtl
            ),
            location
        )
    }

    private func uv(_ point: CGPoint, in view: UIView) -> CGPoint {
        let width = view.bounds.width
        let height = view.bounds.height
        guard width > 1, height > 1, point.x.isFinite, point.y.isFinite else {
            return CGPoint(x: 1, y: 1)
        }
        return CGPoint(x: point.x / width, y: point.y / height)
    }
}

/// Reports `reset()`, the one callback UIKit makes for a sequence that ended
/// without the pan beginning (a tap, a rejected or failed pan).
private final class PageCurlPanRecognizer: UIPanGestureRecognizer {
    var onReset: (() -> Void)?

    override func reset() {
        super.reset()
        onReset?()
    }
}

@MainActor
protocol PageSlideScrollDelegate: AnyObject {
    func slideScrollContext(in view: UIView) -> PageCurlPanContext
    func slideScrollTurn(direction: PageCurlTurnDirection)
}

/// Indirect horizontal paging (iPad trackpad two-finger scroll and mouse scroll
/// wheel) for paged Slide while native scrolling is disabled for direct drags.
/// Direct finger touches stay on `PageCurlPanController`; click-drag pointer
/// selection (`.indirectPointer`) stays untouched.
@MainActor
final class PageSlideScrollController: NSObject, UIGestureRecognizerDelegate {
    let recognizer: UIPanGestureRecognizer
    weak var delegate: PageSlideScrollDelegate?

    var isEnabled: Bool = false {
        didSet {
            recognizer.isEnabled = isEnabled
            if !isEnabled {
                resetSequence()
            }
        }
    }

    private var hasTriggered = false

    override init() {
        recognizer = UIPanGestureRecognizer()
        super.init()
        recognizer.addTarget(self, action: #selector(handleScroll(_:)))
        recognizer.delegate = self
        recognizer.delaysTouchesBegan = false
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        if #available(iOS 13.4, *) {
            recognizer.allowedScrollTypesMask = .all
        }
        recognizer.isEnabled = false
    }

    func attach(to view: UIView) {
        view.addGestureRecognizer(recognizer)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let view = pan.view,
              let delegate
        else {
            return false
        }
        return PageCurlPanStateMachine.indirectScrollDirection(
            sample: sample(of: pan),
            context: delegate.slideScrollContext(in: view)
        ) != nil
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        handle(state: gesture.state, sample: sample(of: gesture), in: gesture.view)
    }

    /// Internal for tests: UIKit does not let a test set a recognizer's state.
    func handle(state: UIGestureRecognizer.State, sample: PageCurlPanSample, in view: UIView?) {
        switch state {
        case .began:
            hasTriggered = false
            maybeTrigger(sample: sample, in: view, ended: false)
        case .changed:
            guard !hasTriggered else {
                return
            }
            maybeTrigger(sample: sample, in: view, ended: false)
        case .ended:
            if !hasTriggered {
                maybeTrigger(sample: sample, in: view, ended: true)
            }
            resetSequence()
        case .cancelled, .failed:
            resetSequence()
        default:
            break
        }
    }

    private func maybeTrigger(sample: PageCurlPanSample, in view: UIView?, ended: Bool) {
        guard isEnabled, let view, let delegate else {
            return
        }
        let context = delegate.slideScrollContext(in: view)
        guard let direction = PageCurlPanStateMachine.indirectScrollDirection(
            sample: sample,
            context: context
        ) else {
            return
        }
        guard PageCurlPanStateMachine.shouldTriggerIndirectScroll(sample: sample, ended: ended) else {
            return
        }
        hasTriggered = true
        delegate.slideScrollTurn(direction: direction)
    }

    private func resetSequence() {
        hasTriggered = false
    }

    private func sample(of pan: UIPanGestureRecognizer) -> PageCurlPanSample {
        let translation = pan.translation(in: pan.view)
        let velocity = pan.velocity(in: pan.view)
        let location = pan.location(in: pan.view)
        return PageCurlPanSample(
            translationX: translation.x,
            translationY: translation.y,
            velocityX: velocity.x,
            velocityY: velocity.y,
            locationX: location.x,
            locationY: location.y
        )
    }
}
