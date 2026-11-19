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
    /// Highest progress while the finger was down. `.ended` sometimes reports
    /// a zero translation, which would cancel a flick that had already crossed.
    private var trackedProgress: CGFloat = 0
    private var endConsumed = false
    private var prepareTask: Task<Void, Never>?
    /// Set when the finger lifts before the incoming page is ready.
    private var pendingRelease: (commit: Bool, velocity: CGFloat)?
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

    /// Rotation or Reduce Motion landed in the middle of a drag. The page goes back.
    /// A prepare still in flight reverts itself when it sees `aborted`: finishing
    /// here as well would drop the cover before the hidden scroll had been undone.
    func abort() {
        aborted = true
        prepareTask?.cancel()
        guard phase == .armed else { return }
        Task { @MainActor in
            await self.finish(commit: false, velocity: 0)
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
        trackedProgress = 0
        endConsumed = false
        pendingRelease = nil
        let direction = direction
        prepareTask = Task { @MainActor [weak self] in
            await self?.prepare(direction: direction, gesture: gesture)
        }
    }

    private func prepare(direction: PageCurlTurnDirection, gesture: UIPanGestureRecognizer) async {
        guard let delegate, let host = delegate.curlPanHostView() else {
            await failBeforeReveal()
            return
        }
        guard let shot = await delegate.curlPanCaptureOutgoing() else {
            await failBeforeReveal()
            return
        }
        if aborted || Task.isCancelled {
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
        if aborted || Task.isCancelled {
            await finish(commit: false, velocity: 0)
            return
        }

        let finger = fingerState(of: gesture, in: host)
        let armed = await curl.beginInteractive(
            outgoing: frame.outgoing,
            incoming: frame.incoming,
            spine: frame.spine,
            peelSign: frame.peelSign,
            realVerso: frame.realVerso,
            progress: finger.progress,
            touchY: finger.touchY
        )
        metalArmed = armed
        phase = .armed
        // The snapshot await is long enough for the finger to move. The
        // progress passed above is from before that wait. Sample again before
        // the first frame, while the gesture is still down.
        if armed, gesture.state == .began || gesture.state == .changed {
            let now = fingerState(of: gesture, in: host)
            curl.track(progress: now.progress, touchY: now.touchY)
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
            rtl: delegate?.curlPanContext(in: host).rtl ?? false
        )
        velocities.append(turn)
        if velocities.count > 3 {
            velocities.removeFirst(velocities.count - 3)
        }
        let finger = fingerState(of: gesture, in: host)
        trackedProgress = max(trackedProgress, finger.progress)
        guard phase == .armed, metalArmed, let curlView else { return }
        curlView.track(progress: finger.progress, touchY: finger.touchY)
    }

    private func end(_ gesture: UIPanGestureRecognizer, cancelled: Bool) {
        // A flick can jump from .began to .ended without a .changed sample.
        if let host = gesture.view {
            velocities.append(PageCurlPanStateMachine.turnVelocity(
                velocityX: gesture.velocity(in: host).x,
                forward: direction == .forward,
                rtl: delegate?.curlPanContext(in: host).rtl ?? false
            ))
        }
        let velocity = PageCurlPanStateMachine.smoothedVelocity(velocities)
        let width = gesture.view?.bounds.width ?? 1
        let live = gesture.view.map { fingerState(of: gesture, in: $0).progress } ?? 0
        let progress = releaseProgress(
            live: live,
            cancelled: cancelled,
            turnVelocity: velocity,
            width: width
        )
        let decision = PageCurlPanStateMachine.release(
            progress: progress,
            turnVelocity: velocity,
            width: width,
            cancelled: cancelled || aborted
        )
        let commit = decision == .commit
        switch phase {
        case .preparing:
            pendingRelease = (commit, velocity)
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

    /// A flick's `.ended` sample can report a zero translation after the leaf
    /// has already crossed. A drag that came back to the start has no forward
    /// velocity, so that release still cancels.
    private func releaseProgress(
        live: CGFloat,
        cancelled: Bool,
        turnVelocity: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        if cancelled {
            return live
        }
        let crossed = trackedProgress > PageCurlPanStateMachine.distanceCommit
        if live < 0.02, crossed, turnVelocity > 0, width > 1 {
            return trackedProgress
        }
        return live
    }

    private func finish(commit: Bool, velocity: CGFloat) async {
        guard phase != .idle, phase != .finishing else { return }
        phase = .finishing
        let width = delegate?.curlPanHostView()?.bounds.width ?? 1
        let progressVelocity = width > 1 ? velocity / width : 0
        // A load during the spring sets `aborted`. The release already chose.
        // Re-reading the flag after the spring turned a finished curl into a
        // cancel, and the page under the cover was the one the finger left.
        let willCommit = commit && !aborted
        if metalArmed, let curlView {
            // A cancel does not carry a forward flick: that velocity already lost
            // the commit test, and keeping it would drag the page the wrong way.
            await curlView.finishInteractive(
                target: willCommit ? 1 : 0,
                progressVelocity: willCommit ? progressVelocity : min(0, progressVelocity)
            )
        } else if willCommit, let curlView {
            await fadeOut(curlView)
        }
        if willCommit {
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
    }

    private func fadeOut(_ view: UIView) async {
        await withCheckedContinuation { continuation in
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut]) {
                view.alpha = 0
            } completion: { _ in
                continuation.resume()
            }
        }
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
        let rtl = delegate?.curlPanContext(in: view).rtl ?? false
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
