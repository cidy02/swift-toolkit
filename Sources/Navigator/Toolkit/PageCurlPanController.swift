//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

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
}

/// The navigator owns location and the web view. The controller owns the finger.
@MainActor
protocol PageCurlPanDelegate: AnyObject {
    func curlPanContext(in view: UIView) -> PageCurlPanContext
    func curlPanHostView() -> UIView?
    func curlPanDidBegin(direction: PageCurlTurnDirection) -> Bool
    func curlPanCaptureOutgoing() async -> (image: UIImage, background: UIColor)?
    func curlPanRevealIncoming(
        direction: PageCurlTurnDirection,
        outgoing: UIImage,
        background: UIColor
    ) async -> PageCurlPanFrame?
    func curlPanCommit(direction: PageCurlTurnDirection, withinResource: Bool) async
    func curlPanCancel(direction: PageCurlTurnDirection, withinResource: Bool) async
    func curlPanDidFinish()
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
    private var curlView: PageCurlView?
    private var metalArmed = false
    private var revealed = false
    private var velocities: [CGFloat] = []
    /// Latest `.changed` progress. A release that reports a zero translation
    /// uses this. It is not the high-water mark: dragging back under the line
    /// and then lifting must cancel.
    private var lastProgress: CGFloat = 0
    /// Latest touch while the gesture was still `.began` or `.changed`.
    /// `.possible` reports the origin, which peels a flick from the top corner.
    private var lastTouchY: CGFloat = PageCurlGeometry.tapTouchY
    /// Reading direction for this drag. Sampled once so a move does not rebuild
    /// the pan context on every touch.
    private var rtl = false
    private var endConsumed = false
    private var prepareTask: Task<Void, Never>?
    /// Set when the finger lifts before the incoming page is ready.
    private var pendingRelease: (commit: Bool, velocity: CGFloat, touchY: CGFloat)?
    private var aborted = false

    override init() {
        recognizer = UIPanGestureRecognizer()
        super.init()
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

    /// True while a finger curl is preparing or tracking. A commit spring that
    /// has already started is not a drag: a posture change leaves that release.
    var dragInFlight: Bool {
        phase == .preparing || phase == .armed
    }

    /// True from the first touch until the cover is gone, including the spring.
    var turnInFlight: Bool {
        phase != .idle
    }

    /// Detach, reload, rotation, Reduce Motion, VoiceOver, background, or a
    /// posture change. The cover comes off immediately. A spring already
    /// running is cut, and `finish` will not commit onto a navigator that
    /// has since reloaded.
    func abort() {
        beginTeardown()
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
        beginTeardown()
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

    private func beginTeardown() {
        guard phase != .idle else {
            return
        }
        aborted = true
        prepareTask?.cancel()
        // Unblock `finishInteractive` and `drawAndWait`, and take the cover
        // down before a reload installs a new spread under it.
        curlView?.releaseResources()
        curlView?.removeFromSuperview()
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

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard phase == .idle, let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view, let delegate else {
            return false
        }
        let decision = PageCurlPanStateMachine.shouldBegin(
            sample: sample(of: pan),
            context: delegate.curlPanContext(in: view)
        )
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

    private func begin(_ gesture: UIPanGestureRecognizer) {
        guard let delegate, delegate.curlPanDidBegin(direction: direction) else {
            phase = .idle
            return
        }
        phase = .preparing
        aborted = false
        revealed = false
        metalArmed = false
        withinResource = false
        velocities = []
        lastProgress = 0
        lastTouchY = PageCurlGeometry.tapTouchY
        endConsumed = false
        pendingRelease = nil
        if let host = gesture.view {
            rtl = delegate.curlPanContext(in: host).rtl
            let finger = fingerState(of: gesture, in: host)
            lastProgress = finger.progress
            lastTouchY = finger.touchY
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
        if aborted || Task.isCancelled || host.window == nil {
            await failBeforeReveal()
            return
        }

        let curl = PageCurlView(frame: host.bounds)
        curl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curl.showCover(shot.image, background: shot.background)
        host.addSubview(curl)
        curlView = curl
        host.layoutIfNeeded()

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
            lastTouchY = sampled.touchY
        }
        let touchY = PageCurlPanStateMachine.touchYForArm(
            gestureSettled: sampled == nil,
            liveTouchY: sampled?.touchY ?? 0,
            storedTouchY: pendingRelease?.touchY ?? lastTouchY
        )
        let progress = sampled?.progress ?? lastProgress
        let armed = await curl.beginInteractive(
            outgoing: frame.outgoing,
            incoming: frame.incoming,
            spine: frame.spine,
            peelSign: frame.peelSign,
            realVerso: frame.realVerso,
            reversed: frame.reversed,
            progress: progress,
            touchY: touchY
        )
        metalArmed = armed
        // Detach during the upload leaves `beginInteractive` false. Staying
        // `.armed` would pin the reader behind a cover that never finishes.
        if aborted || Task.isCancelled || !armed || host.window == nil {
            await finish(commit: false, velocity: 0)
            return
        }
        phase = .armed
        if gesture.state == .began || gesture.state == .changed {
            let now = fingerState(of: gesture, in: host)
            lastProgress = now.progress
            lastTouchY = now.touchY
            curl.track(progress: now.progress, touchY: now.touchY)
        } else {
            curl.track(progress: lastProgress, touchY: touchY)
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
        let turn = PageCurlPanStateMachine.turnVelocity(
            velocityX: gesture.velocity(in: host).x,
            forward: direction == .forward,
            rtl: rtl
        )
        velocities.append(turn)
        if velocities.count > 3 {
            velocities.removeFirst(velocities.count - 3)
        }
        let finger = fingerState(of: gesture, in: host)
        lastProgress = finger.progress
        lastTouchY = finger.touchY
        guard phase == .armed, metalArmed, let curlView else { return }
        curlView.track(progress: finger.progress, touchY: finger.touchY)
    }

    private func end(_ gesture: UIPanGestureRecognizer, cancelled: Bool) {
        // A flick can jump from .began to .ended without a .changed sample.
        // The location is still valid here. After this returns, UIKit resets
        // the gesture to `.possible` and a later sample reads the origin.
        var live: CGFloat = 0
        if let host = gesture.view {
            velocities.append(PageCurlPanStateMachine.turnVelocity(
                velocityX: gesture.velocity(in: host).x,
                forward: direction == .forward,
                rtl: rtl
            ))
            if gesture.state != .possible {
                let finger = fingerState(of: gesture, in: host)
                live = finger.progress
                if finger.progress > 0 {
                    lastProgress = finger.progress
                }
                lastTouchY = finger.touchY
            }
        }
        let velocity = PageCurlPanStateMachine.smoothedVelocity(velocities)
        let width = gesture.view?.bounds.width ?? 1
        let progress = cancelled
            ? live
            : PageCurlPanStateMachine.progressAtRelease(live: live, lastProgress: lastProgress)
        let decision = PageCurlPanStateMachine.release(
            progress: progress,
            turnVelocity: velocity,
            width: width,
            cancelled: cancelled || aborted
        )
        let commit = decision == .commit
        switch phase {
        case .preparing:
            pendingRelease = (commit, velocity, lastTouchY)
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

    private func finish(commit: Bool, velocity: CGFloat) async {
        guard phase != .idle, phase != .finishing else { return }
        phase = .finishing
        let width = delegate?.curlPanHostView()?.bounds.width ?? 1
        let progressVelocity = width > 1 ? velocity / width : 0
        let willCommit = commit && !aborted
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
        // `aborted` may flip during the spring. A stale finish must not commit
        // onto a navigator that reloaded while the leaf was moving. The delegate
        // also drops the call when the spread it prepared is gone.
        let landed = willCommit && !aborted
        if landed {
            await delegate?.curlPanCommit(direction: direction, withinResource: withinResource)
        } else if revealed {
            await delegate?.curlPanCancel(direction: direction, withinResource: withinResource)
        }
        tearDown()
        delegate?.curlPanDidFinish()
        phase = .idle
        revealed = false
        metalArmed = false
        pendingRelease = nil
        aborted = false
        resumeAbortWaiter()
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
            locationY: location.y
        )
    }

    private func fingerState(of pan: UIPanGestureRecognizer, in view: UIView) -> (progress: CGFloat, touchY: CGFloat) {
        let translation = pan.translation(in: view)
        let location = pan.location(in: view)
        return (
            PageCurlPanStateMachine.progress(
                translationX: translation.x,
                width: view.bounds.width,
                forward: direction == .forward,
                rtl: rtl
            ),
            PageCurlPanStateMachine.touchY(locationY: location.y, height: view.bounds.height)
        )
    }
}
