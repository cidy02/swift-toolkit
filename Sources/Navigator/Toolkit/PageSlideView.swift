//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// Common contract shared by the Metal page curl (`PageCurlView`) and the
/// lifted-card slide (`PageSlideView`). Keeps one pan controller, release
/// tracker, prerender cache and tap orchestration for both transitions.
@MainActor
protocol PageTurnOverlayView: UIView {
    func showCover(_ image: UIImage, background: UIColor)
    func runTap(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        reversed: Bool,
        duration: TimeInterval
    ) async
    func beginInteractive(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        reversed: Bool,
        progress: CGFloat,
        grabUV: CGPoint,
        fingerUV: CGPoint
    ) async -> Bool
    func track(progress: CGFloat, fingerUV: CGPoint)
    func finishInteractive(target: CGFloat, progressVelocity: CGFloat) async
    func freezeOnCover(showing image: UIImage?)
    func releaseResources()
    /// The incoming bitmap of the next `beginInteractive` is a placeholder in the page colour.
    func expectIncomingPlaceholder()
    /// The real page has arrived: swap it in, with a fade unless Reduce Motion is on.
    func replaceIncoming(_ image: UIImage, fade: Bool) async -> Bool
}

extension PageTurnOverlayView {
    func freezeOnCover() {
        freezeOnCover(showing: nil)
    }
}

/// Apple Books–style Slide transition: the turning page lifts into a
/// screen-corner-rounded card and slides over the still page underneath.
/// Driven directly from `PageSlideGeometry` on Core Animation layers (no Metal).
@MainActor
final class PageSlideView: UIView, PageTurnOverlayView {
    private let underImageView = UIImageView()
    private let staticHalfClipView = UIView()
    private let staticHalfImageView = UIImageView()
    private let cardShadowView = UIView()
    private let cardClipView = UIView()
    private let cardImageView = UIImageView()
    private let elevationTintView = UIView()
    private let coverView = UIImageView()
    /// Invisible full-bounds probe used on iOS 26+ to read the display's
    /// concentric corner radius via public `UICornerConfiguration`.
    private var cornerProbeView: UIView?

    private var displayLink: CADisplayLink?
    private let clock = PageSlideClock()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var tapStart: CFTimeInterval = 0
    private var tapDuration: CFTimeInterval = PageSlideGeometry.tapDuration
    private var tapContinuation: CheckedContinuation<Void, Never>?
    private var clockIsTap = true

    private var spine: PageCurlSpine = .leading
    private var peelSign: CGFloat = 1
    private var reversed = false
    private var pageRGB = PageCurlRGB(r: 1, g: 1, b: 1)
    private var resolvedCornerRadius: CGFloat = PageSlideGeometry.fallbackPhoneCornerRadius
    private var progress: CGFloat = 0
    private var isArmed = false
    private var latencyFrames = 0

    private var interactivePhase: InteractivePhase = .none
    private var springStart: CFTimeInterval = 0
    private var springFrom: CGFloat = 0
    private var springVelocity: CGFloat = 0
    private var springTarget: CGFloat = 1
    private var springOmega: CGFloat = PageCurlPanStateMachine.settleOmega
    private var interactiveContinuation: CheckedContinuation<Void, Never>?
    private var lifecycleStops = 0

    var currentProgress: CGFloat { progress }
    var cardFrameForTesting: CGRect { cardShadowView.frame }
    var staticHalfClipFrameForTesting: CGRect? {
        staticHalfClipView.isHidden ? nil : staticHalfClipView.frame
    }
    var isCoverHiddenForTesting: Bool { coverView.isHidden }
    var underImageForTesting: UIImage? { underImageView.image }
    var cardImageForTesting: UIImage? { cardImageView.image }
    var staticHalfImageForTesting: UIImage? { staticHalfImageView.image }
    var cornerRadiusForTesting: CGFloat { cardClipView.layer.cornerRadius }
    var shadowOpacityForTesting: Float { cardShadowView.layer.shadowOpacity }
    var elevationTintAlphaForTesting: CGFloat { elevationTintView.alpha }
    /// Test hook called after each display-link tick so tests can observe live
    /// tap and spring frames without racing sleeps.
    var onClockTickForTesting: ((CGFloat) -> Void)?

    private enum InteractivePhase {
        case none
        case track
        case spring
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true
        // Eat touches while the overlay covers the web view so a tap during
        // the settle spring never leaks through to the page or chrome toggle.
        isUserInteractionEnabled = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .black

        underImageView.frame = bounds
        underImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        underImageView.contentMode = .scaleToFill
        underImageView.isAccessibilityElement = false
        underImageView.accessibilityElementsHidden = true

        staticHalfClipView.clipsToBounds = true
        staticHalfClipView.isHidden = true
        staticHalfClipView.isUserInteractionEnabled = false
        staticHalfImageView.contentMode = .scaleToFill
        staticHalfClipView.addSubview(staticHalfImageView)

        cardShadowView.clipsToBounds = false
        cardShadowView.isUserInteractionEnabled = false
        cardShadowView.layer.shadowColor = UIColor.black.cgColor

        cardClipView.clipsToBounds = true
        cardClipView.isUserInteractionEnabled = false
        cardClipView.layer.cornerCurve = .continuous

        cardImageView.contentMode = .scaleToFill
        cardClipView.addSubview(cardImageView)

        // Subtle cool-neutral white overlay that lifts OLED #000000 to ~#1C1C1E
        // and Dark #16161A to ~#2F2F34 without washing out body text.
        elevationTintView.backgroundColor = UIColor(red: 0.95, green: 0.95, blue: 1.0, alpha: 1.0)
        elevationTintView.alpha = 0
        elevationTintView.isUserInteractionEnabled = false
        cardClipView.addSubview(elevationTintView)

        cardShadowView.addSubview(cardClipView)

        coverView.frame = bounds
        coverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coverView.contentMode = .scaleToFill
        coverView.isAccessibilityElement = false
        coverView.accessibilityElementsHidden = true

        addSubview(underImageView)
        addSubview(staticHalfClipView)
        addSubview(cardShadowView)
        addSubview(coverView)

        if #available(iOS 26.0, *) {
            let probe = UIView(frame: bounds)
            probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            probe.backgroundColor = .clear
            probe.isOpaque = false
            probe.isUserInteractionEnabled = false
            probe.isAccessibilityElement = false
            probe.accessibilityElementsHidden = true
            probe.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
            addSubview(probe)
            cornerProbeView = probe
        }

        observeLifecycle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
        let center = NotificationCenter.default
        for token in lifecycleObservers {
            center.removeObserver(token)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coverView.frame = bounds
        underImageView.frame = bounds
        cornerProbeView?.frame = bounds
        if isArmed {
            resolvedCornerRadius = resolveDisplayCornerRadius()
            applyLayout()
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            cancelForLifecycle()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelForLifecycle()
        }
    }

    func showCover(_ image: UIImage, background: UIColor) {
        backgroundColor = background
        pageRGB = background.pageCurlRGB
        coverView.image = image
        coverView.frame = bounds
        coverView.alpha = 1
        coverView.isHidden = false
    }

    func runTap(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        reversed: Bool = false,
        duration: TimeInterval = PageSlideGeometry.tapDuration
    ) async {
        _ = realVerso
        incomingFadeEnd = nil
        finishTap()
        endInteractive()
        guard isAttached else {
            return
        }
        configurePages(
            outgoing: outgoing,
            incoming: incoming,
            spine: spine,
            peelSign: peelSign,
            reversed: reversed
        )
        progress = 0
        isArmed = true
        applyLayout()
        coverView.isHidden = true

        guard duration > 0 else {
            progress = 1
            applyLayout()
            return
        }
        guard isAttached else {
            return
        }

        clockIsTap = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tapContinuation = continuation
            tapStart = CACurrentMediaTime()
            tapDuration = duration
            startClock()
        }
    }

    func beginInteractive(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        reversed: Bool = false,
        progress: CGFloat,
        grabUV: CGPoint,
        fingerUV: CGPoint
    ) async -> Bool {
        _ = realVerso
        _ = grabUV
        _ = fingerUV
        incomingFadeEnd = nil
        finishTap()
        endInteractive()
        guard isAttached else {
            interactivePhase = .none
            return false
        }
        let stops = lifecycleStops
        configurePages(
            outgoing: outgoing,
            incoming: incoming,
            spine: spine,
            peelSign: peelSign,
            reversed: reversed
        )
        guard isAttached, lifecycleStops == stops else {
            interactivePhase = .none
            return false
        }
        self.progress = PageCurlGeometry.clampProgress(progress)
        interactivePhase = .track
        isArmed = true
        latencyFrames = 0
        applyLayout()
        coverView.isHidden = true
        PageCurlLatency.mark("first-frame-done")
        return true
    }

    func track(progress: CGFloat, fingerUV: CGPoint) {
        _ = fingerUV
        let clamped = PageCurlGeometry.clampProgress(progress)
        self.progress = clamped
        guard interactivePhase == .track, isArmed else {
            return
        }
        applyLayout()
        logLatencyFrame()
    }

    func expectIncomingPlaceholder() {}

    func replaceIncoming(_ image: UIImage, fade: Bool) async -> Bool {
        guard interactivePhase != .none, isArmed else {
            return true
        }
        let views = reversed ? [cardImageView, staticHalfImageView] : [underImageView]
        let animate = fade && !UIAccessibility.isReduceMotionEnabled
        for view in views {
            if animate {
                UIView.transition(with: view, duration: Self.incomingFadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    view.image = image
                }
            } else {
                view.image = image
            }
        }
        incomingFadeEnd = animate ? CACurrentMediaTime() + Self.incomingFadeDuration : nil
        return true
    }

    private static let incomingFadeDuration: CFTimeInterval = 0.18
    private var incomingFadeEnd: CFTimeInterval?

    /// The cross-dissolve has run its course (or there was none): the page may land.
    /// A cancel is already flat on the outgoing page, so it does not wait.
    private func incomingFadeSettled(target: CGFloat) -> Bool {
        guard target >= 0.5, let end = incomingFadeEnd else { return true }
        return CACurrentMediaTime() >= end
    }

    func finishInteractive(target: CGFloat, progressVelocity: CGFloat) async {
        let target = PageCurlGeometry.clampProgress(target)
        let velocity = progressVelocity.isFinite ? progressVelocity : 0
        guard interactivePhase != .none else {
            progress = target
            if isArmed {
                applyLayout()
            }
            return
        }
        springFrom = progress
        springVelocity = velocity
        springTarget = target
        springOmega = PageCurlPanStateMachine.omega(progressVelocity: velocity)
        springStart = CACurrentMediaTime()
        interactivePhase = .spring
        if abs(progress - target) < 0.002, abs(velocity) < 0.02, incomingFadeSettled(target: target) {
            progress = target
            applyLayout()
            endInteractive()
            return
        }
        clockIsTap = false
        startClock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            interactiveContinuation = continuation
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    func freezeOnCover(showing image: UIImage? = nil) {
        lifecycleStops &+= 1
        if let image {
            coverView.image = image
        }
        coverView.alpha = 1
        coverView.isHidden = false
        releaseResources()
    }

    func releaseResources() {
        stopClock()
        resumeWaiters()
        incomingFadeEnd = nil
        isArmed = false
        underImageView.image = nil
        cardImageView.image = nil
        staticHalfImageView.image = nil
    }

    private func configurePages(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        reversed: Bool
    ) {
        self.spine = spine
        self.peelSign = peelSign
        self.reversed = reversed
        resolvedCornerRadius = resolveDisplayCornerRadius()
        // Reversed (backward): incoming enters as the lifted card (and its
        // complementary half on two-page spreads) over the still outgoing spread.
        // Forward: outgoing lifts and slides over the still incoming spread.
        underImageView.image = reversed ? outgoing : incoming
        cardImageView.image = reversed ? incoming : outgoing
        staticHalfImageView.image = reversed ? incoming : outgoing
        PageCurlDebug.log(
            "slide-begin spine=\(spine) peel=\(String(format: "%.0f", peelSign)) "
                + "reversed=\(reversed) radius=\(String(format: "%.1f", resolvedCornerRadius)) "
                + "dark=\(PageSlideGeometry.isDark(background: pageRGB))"
        )
    }

    private func applyLayout() {
        let frame = PageSlideGeometry.layout(
            progress: progress,
            bounds: bounds,
            spine: spine,
            peelSign: peelSign,
            reversed: reversed,
            displayCornerRadius: resolvedCornerRadius,
            background: pageRGB
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        underImageView.frame = bounds

        if let clip = frame.staticHalfClipFrame, clip.width > 0.25 {
            staticHalfClipView.isHidden = false
            staticHalfClipView.frame = clip
            staticHalfImageView.frame = CGRect(origin: frame.staticHalfImageOrigin, size: bounds.size)
        } else {
            staticHalfClipView.isHidden = true
        }

        cardShadowView.frame = frame.cardFrame
        cardClipView.frame = cardShadowView.bounds
        cardImageView.frame = CGRect(origin: frame.cardImageOrigin, size: bounds.size)
        elevationTintView.frame = cardClipView.bounds
        elevationTintView.alpha = frame.elevationTintAlpha

        var masked: CACornerMask = []
        var rectCorners: UIRectCorner = []
        if frame.roundsLeadingCorners {
            masked.insert([.layerMinXMinYCorner, .layerMinXMaxYCorner])
            rectCorners.insert([.topLeft, .bottomLeft])
        }
        if frame.roundsTrailingCorners {
            masked.insert([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
            rectCorners.insert([.topRight, .bottomRight])
        }
        cardClipView.layer.maskedCorners = masked
        cardClipView.layer.cornerRadius = frame.cornerRadius

        let scale = max(window?.screen.scale ?? contentScaleFactor, 1)
        if frame.rimAlpha > 0.001 {
            cardClipView.layer.borderWidth = 1 / scale
            cardClipView.layer.borderColor = (
                frame.isDarkTheme
                    ? UIColor(white: 1, alpha: frame.rimAlpha)
                    : UIColor(white: 0, alpha: frame.rimAlpha)
            ).cgColor
        } else {
            cardClipView.layer.borderWidth = 0
            cardClipView.layer.borderColor = nil
        }

        cardShadowView.layer.shadowOpacity = frame.shadowOpacity
        cardShadowView.layer.shadowRadius = frame.shadowRadius
        cardShadowView.layer.shadowOffset = CGSize(width: frame.shadowOffsetX, height: 0)
        if frame.shadowOpacity > 0.001 {
            if frame.cornerRadius > 0.5, !rectCorners.isEmpty {
                cardShadowView.layer.shadowPath = UIBezierPath(
                    roundedRect: cardClipView.bounds,
                    byRoundingCorners: rectCorners,
                    cornerRadii: CGSize(width: frame.cornerRadius, height: frame.cornerRadius)
                ).cgPath
            } else {
                cardShadowView.layer.shadowPath = UIBezierPath(rect: cardClipView.bounds).cgPath
            }
        } else {
            cardShadowView.layer.shadowPath = nil
        }
    }

    private func resolveDisplayCornerRadius() -> CGFloat {
        var effective: CGFloat?
        if #available(iOS 26.0, *), let probe = cornerProbeView, window != nil {
            probe.frame = bounds
            probe.layoutIfNeeded()
            let radius = max(
                probe.effectiveRadius(corner: .topLeft),
                probe.effectiveRadius(corner: .topRight),
                probe.effectiveRadius(corner: .bottomLeft),
                probe.effectiveRadius(corner: .bottomRight)
            )
            if radius.isFinite, radius > 0 {
                effective = radius
            }
        }
        let isPad = traitCollection.userInterfaceIdiom == .pad
        let safeBottom = window?.safeAreaInsets.bottom ?? safeAreaInsets.bottom
        return PageSlideGeometry.displayCornerRadius(
            effectiveRadius: effective,
            isPad: isPad,
            hasBottomSafeArea: safeBottom > 0
        )
    }

    private var isAttached: Bool {
        window != nil && superview != nil && UIApplication.shared.applicationState != .background
    }

    private var turnIsRunning: Bool {
        displayLink != nil
            || tapContinuation != nil
            || interactiveContinuation != nil
            || interactivePhase != .none
    }

    private func cancelForLifecycle() {
        lifecycleStops &+= 1
        guard turnIsRunning else {
            releaseResources()
            return
        }
        coverView.isHidden = false
        releaseResources()
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelForLifecycle()
                }
            }
            lifecycleObservers.append(token)
        }
    }

    private func startClock() {
        displayLink?.invalidate()
        clock.owner = self
        let link = CADisplayLink(target: clock, selector: #selector(PageSlideClock.step(_:)))
        let hz = Float(window?.screen.maximumFramesPerSecond ?? 60)
        let cap = min(120, max(hz, 1))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: cap)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func stepClock() {
        guard isAttached else {
            cancelForLifecycle()
            return
        }
        if clockIsTap {
            stepTap()
        } else {
            stepSpring()
        }
    }

    private func stepTap() {
        let elapsed = CACurrentMediaTime() - tapStart
        let t = tapDuration > 0 ? elapsed / tapDuration : 1
        progress = PageSlideGeometry.tapEaseOut(CGFloat(min(1, t)))
        applyLayout()
        onClockTickForTesting?(progress)
        if t >= 1 {
            progress = 1
            applyLayout()
            finishTap()
        }
    }

    private func stepSpring() {
        guard interactivePhase == .spring else {
            stopClock()
            return
        }
        let elapsed = CACurrentMediaTime() - springStart
        progress = PageCurlPanStateMachine.springProgress(
            elapsed: elapsed,
            from: springFrom,
            velocity: springVelocity,
            target: springTarget,
            omega: springOmega
        )
        // The dissolve from the page colour is not cut short by a quick landing.
        let landed = (abs(progress - springTarget) < 0.002 && incomingFadeSettled(target: springTarget)) || elapsed > 0.7
        if landed {
            progress = springTarget
        }
        applyLayout()
        onClockTickForTesting?(progress)
        if landed {
            endInteractive()
        }
    }

    private func logLatencyFrame() {
        guard PageCurlDebug.enabled, latencyFrames < 12 else {
            return
        }
        latencyFrames += 1
        PageCurlDebug.log(
            "slide-frame n=\(latencyFrames) drawn=+\(PageCurlLatency.sinceTouchDown(CACurrentMediaTime()))ms "
                + "progress=\(String(format: "%.3f", progress))"
        )
    }

    private func finishTap() {
        stopClock()
        let continuation = tapContinuation
        tapContinuation = nil
        continuation?.resume()
    }

    private func endInteractive() {
        interactivePhase = .none
        stopClock()
        let continuation = interactiveContinuation
        interactiveContinuation = nil
        continuation?.resume()
    }

    private func resumeWaiters() {
        let tap = tapContinuation
        tapContinuation = nil
        tap?.resume()
        let drag = interactiveContinuation
        interactiveContinuation = nil
        drag?.resume()
        interactivePhase = .none
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

private final class PageSlideClock: NSObject {
    weak var owner: PageSlideView?

    @objc func step(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        MainActor.assumeIsolated {
            owner.stepClock()
        }
    }
}
