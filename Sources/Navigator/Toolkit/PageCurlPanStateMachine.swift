//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreGraphics
import Foundation

/// Which way the leaf travels. Screen-left is not forward: RTL flips it.
enum PageCurlTurnDirection: Equatable {
    case forward
    case backward
}

struct PageCurlPanSample: Equatable {
    var translationX: CGFloat
    var translationY: CGFloat
    var velocityX: CGFloat
    var velocityY: CGFloat
    var locationX: CGFloat
    var locationY: CGFloat
}

struct PageCurlPanContext: Equatable {
    var rtl: Bool
    var viewWidth: CGFloat
    var viewHeight: CGFloat
    var canGoForward: Bool
    var canGoBackward: Bool
    var hasSelection: Bool
    /// Paged curl, Reduce Motion off, VoiceOver off.
    var interactiveCurlEnabled: Bool
    /// Fixed-layout zoom keeps its own pan.
    var zoomed: Bool = false
    /// Navigator is idle. A turn already in flight rejects a second pan.
    var acceptsGesture: Bool = true
}

enum PageCurlPanBegin: Equatable {
    case track(PageCurlTurnDirection)
    case rejectVertical
    case rejectBezel
    case rejectBoundary
    case rejectSelection
    case rejectDisabled
    case rejectZoomed
}

enum PageCurlPanRelease: Equatable {
    case commit
    case cancel
}

/// Finger-curl decisions. No gesture object and no clock: the controller asks,
/// then drives `PageCurlView`.
enum PageCurlPanStateMachine {
    /// Distance alone commits strictly above this. 0.35 does not.
    static let distanceCommit: CGFloat = 0.35
    /// Seconds of velocity mixed into the release.
    static let velocityHorizon: CGFloat = 0.18
    /// `progress + (turnVelocity / width) * velocityHorizon` commits above this.
    static let projectedCommit: CGFloat = 0.50
    /// `abs(vx) > abs(vy) * horizontalDominance` or the drag is vertical.
    static let horizontalDominance: CGFloat = 1.25
    /// Leading-edge inset left for the reader's dismiss swipe.
    static let bezelInset: CGFloat = 20
    /// How long the leaf takes to catch a finger that moved during the snapshot.
    static let catchUpDuration: TimeInterval = 0.05
    /// At rest, a critically damped spring is within ~2% in about 300 ms.
    static let settleOmega: CGFloat = 16
    /// A flick (about 4 page-widths per second) lands nearer 190 ms.
    static let flickOmega: CGFloat = 26
    /// Progress-per-second at which the spring is fully in the flick regime.
    static let flickVelocity: CGFloat = 4

    static func allowsInteractiveCurl(
        preference: PageTransition,
        scrolls: Bool,
        reduceMotion: Bool,
        voiceOverRunning: Bool
    ) -> Bool {
        preference == .curl && !scrolls && !reduceMotion && !voiceOverRunning
    }

    static func shouldBegin(sample: PageCurlPanSample, context: PageCurlPanContext) -> PageCurlPanBegin {
        guard context.acceptsGesture, context.interactiveCurlEnabled else {
            return .rejectDisabled
        }
        guard !context.hasSelection else {
            return .rejectSelection
        }
        guard !context.zoomed else {
            return .rejectZoomed
        }

        let vx = finite(sample.velocityX)
        let vy = finite(sample.velocityY)
        let dx = finite(sample.translationX)
        let dy = finite(sample.translationY)
        let horizontal: Bool
        let goingRight: Bool
        if abs(vx) > 20 || abs(vy) > 20 {
            horizontal = abs(vx) > abs(vy) * horizontalDominance
            goingRight = vx > 0
        } else if abs(dx) > 1 || abs(dy) > 1 {
            horizontal = abs(dx) > abs(dy) * horizontalDominance
            goingRight = dx > 0
        } else {
            return .rejectVertical
        }
        guard horizontal else {
            return .rejectVertical
        }

        // LTR forward peels to the left. RTL forward peels to the right.
        let forward = context.rtl ? goingRight : !goingRight
        let direction: PageCurlTurnDirection = forward ? .forward : .backward

        // Recognition happens after the finger has already moved, so the bezel
        // test uses where the touch went down, not where it is now.
        let startX = finite(sample.locationX) - finite(sample.translationX)
        if isDismissBezel(locationX: startX, forward: forward, context: context) {
            return .rejectBezel
        }
        if forward, !context.canGoForward {
            return .rejectBoundary
        }
        if !forward, !context.canGoBackward {
            return .rejectBoundary
        }
        return .track(direction)
    }

    /// Leading edge, and only when the drag matches the system back swipe.
    /// LTR: left 20 pt, dragging right. RTL: the mirrored right edge, dragging left.
    static func isDismissBezel(locationX: CGFloat, forward: Bool, context: PageCurlPanContext) -> Bool {
        guard !forward, locationX.isFinite else {
            return false
        }
        if context.rtl {
            return locationX > context.viewWidth - bezelInset
        }
        return locationX < bezelInset
    }

    /// LTR forward moves the spread to the right (`.right`). RTL forward moves it left.
    static func spreadGoesRight(forward: Bool, rtl: Bool) -> Bool {
        rtl ? !forward : forward
    }

    /// 0 at the touch-down page, 1 when the finger has travelled one page width
    /// in the locked direction. The opposite drag clamps to 0.
    static func progress(
        translationX: CGFloat,
        width: CGFloat,
        forward: Bool,
        rtl: Bool
    ) -> CGFloat {
        guard width > 1, translationX.isFinite else {
            return 0
        }
        let screenSign = turnScreenSign(forward: forward, rtl: rtl)
        return PageCurlGeometry.clampProgress(translationX * screenSign / width)
    }

    /// Points per second in the turn direction. Positive continues the turn.
    static func turnVelocity(velocityX: CGFloat, forward: Bool, rtl: Bool) -> CGFloat {
        guard velocityX.isFinite else {
            return 0
        }
        return velocityX * turnScreenSign(forward: forward, rtl: rtl)
    }

    /// 0 is the top of the page, 1 is the bottom. Mid-page is a vertical axis.
    static func touchY(locationY: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 1, locationY.isFinite else {
            return 0.5
        }
        return min(1, max(0, locationY / height))
    }

    /// Mean of the last three samples. A one-frame spike does not commit a short drag.
    static func smoothedVelocity(_ samples: [CGFloat]) -> CGFloat {
        let recent = samples.suffix(3).filter(\.isFinite)
        guard !recent.isEmpty else {
            return 0
        }
        let total = recent.reduce(CGFloat(0), +)
        return total / CGFloat(recent.count)
    }

    /// A system cancel never commits, including on the last page.
    static func release(
        progress: CGFloat,
        turnVelocity: CGFloat,
        width: CGFloat,
        cancelled: Bool
    ) -> PageCurlPanRelease {
        if cancelled {
            return .cancel
        }
        let p = PageCurlGeometry.clampProgress(progress)
        if p > distanceCommit {
            return .commit
        }
        if projectedProgress(progress: p, turnVelocity: turnVelocity, width: width) > projectedCommit {
            return .commit
        }
        return .cancel
    }

    /// Progress the release decision should see. A flick's `.ended` sample can
    /// report a zero translation; use the last `.changed` progress. A drag that
    /// came back near the start must not be replaced by an earlier high-water mark.
    static func progressAtRelease(live: CGFloat, lastProgress: CGFloat) -> CGFloat {
        let liveValue = live.isFinite ? live : 0
        let last = lastProgress.isFinite ? lastProgress : 0
        if liveValue == 0, last > 0.02 {
            return last
        }
        return liveValue
    }

    /// Where the drag started. The pan begins late (it waits for the text
    /// long-press to fail), and `location - translation` at `.began` was about
    /// 50 pt inside the real touch-down on a slow drag, so the leaf trailed the
    /// finger by that much. The touch-down, when it was seen, is the origin.
    static func grabOrigin(touchDown: CGPoint?, location: CGPoint, translation: CGPoint) -> CGPoint {
        if let touchDown, touchDown.x.isFinite, touchDown.y.isFinite {
            return touchDown
        }
        return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    /// Once the gesture has reset to `.possible`, its location is the origin.
    /// The arm uses the touch stored while the finger was down.
    static func touchYForArm(gestureSettled: Bool, liveTouchY: CGFloat, storedTouchY: CGFloat) -> CGFloat {
        if gestureSettled {
            return storedTouchY
        }
        return liveTouchY.isFinite ? liveTouchY : storedTouchY
    }

    static func projectedProgress(progress: CGFloat, turnVelocity: CGFloat, width: CGFloat) -> CGFloat {
        let span = width > 1 ? width : 1
        let velocity = turnVelocity.isFinite ? turnVelocity : 0
        return progress + (velocity / span) * velocityHorizon
    }

    static func omega(progressVelocity: CGFloat) -> CGFloat {
        guard progressVelocity.isFinite else {
            return settleOmega
        }
        let t = min(1, abs(progressVelocity) / flickVelocity)
        return settleOmega + (flickOmega - settleOmega) * t
    }

    /// Critically damped approach to `target`. `velocity` is progress per second
    /// (positive increases progress). The result never crosses `target`.
    static func springProgress(
        elapsed: TimeInterval,
        from: CGFloat,
        velocity: CGFloat,
        target: CGFloat,
        omega: CGFloat
    ) -> CGFloat {
        guard elapsed.isFinite, from.isFinite, target.isFinite else {
            return PageCurlGeometry.clampProgress(target)
        }
        let dt = CGFloat(max(0, elapsed))
        let w = omega.isFinite ? max(omega, 0.01) : settleOmega
        let v = velocity.isFinite ? velocity : 0
        let error = from - target
        if abs(error) < 0.000_1 && abs(v) < 0.000_1 {
            return target
        }
        let b = v + w * error
        let y = (error + b * dt) * exp(-w * dt)
        // A sign change is the one overshoot a hard flick can produce. Land and stay.
        if (error > 0 && y < 0) || (error < 0 && y > 0) {
            return target
        }
        return target + y
    }

    /// +1 when increasing screen x increases progress.
    private static func turnScreenSign(forward: Bool, rtl: Bool) -> CGFloat {
        if rtl {
            return forward ? 1 : -1
        }
        return forward ? -1 : 1
    }

    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value : 0
    }
}
