//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Metal
import MetalKit
import UIKit

/// Progress-driven cylinder curl. A tap runs 0→1 on a display link, along a
/// synthetic grab from the lower corner. A finger sets `progress` and the
/// grab points itself. Nothing in here times the shader.
@MainActor
final class PageCurlView: UIView {
    private let coverView = UIImageView()
    private let incomingCover = UIImageView()
    private var metalView: MTKView?
    private var renderer: PageCurlRenderer?
    private var displayLink: CADisplayLink?
    private let clock = PageCurlClock()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var tapStart: CFTimeInterval = 0
    private var tapDuration: CFTimeInterval = PageCurlGeometry.tapDuration
    private var tapContinuation: CheckedContinuation<Void, Never>?
    private var clockIsTap = true

    private var spine: PageCurlSpine = .leading
    private var peelSign: CGFloat = 1
    private var realVerso = false
    private var reversed = false
    private var paper = PageCurlPaper(r: 0.96, g: 0.96, b: 0.96, mix: PageCurlGeometry.backsideMix)
    private var progress: CGFloat = 0
    /// Tap follows `tapGrab`. A finger uses the points below.
    private var fingerDriven = false
    /// Touch-down and the current finger, in view UV (origin top-left).
    private var grabUV = CGPoint(x: 1, y: 1)
    private var fingerUV = CGPoint(x: 1, y: 1)
    /// Isotropic finger positions captured when the spring starts.
    private var springPFrom = CGPoint(x: 1, y: 1)
    private var springPTo = CGPoint(x: 1, y: 1)
    private var springPControl = CGPoint(x: 1, y: 1)

    /// Finger position while a drag is in flight. The display link reads it.
    private var fingerProgress: CGFloat = 0
    private var interactivePhase: InteractivePhase = .none
    private var springStart: CFTimeInterval = 0
    private var springFrom: CGFloat = 0
    private var springVelocity: CGFloat = 0
    private var springTarget: CGFloat = 1
    private var springOmega: CGFloat = PageCurlPanStateMachine.settleOmega
    private var interactiveContinuation: CheckedContinuation<Void, Never>?
    /// Curl debug only: live frames logged for this drag.
    private var latencyFrames = 0

    private enum InteractivePhase {
        case none
        case track
        case spring
    }

    /// Compiles the curl pipeline once, off the caller's wait, the first time
    /// a curl is selected. Turns reuse the cached pipeline.
    static func prewarm() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }
        Task { @MainActor in
            await PageCurlRenderer.warmPipeline(device: device)
        }
    }

    /// Uploads bitmaps a drag is about to use (touch-down), off the main actor.
    static func preloadTextures(_ images: [UIImage]) {
        PageCurlRenderer.preload(images)
    }

    static func dropPreloadedTextures() {
        PageCurlRenderer.dropPreloads()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        // The cover sits above the scrolled web view. Eating touches stops a
        // second finger, and a tap during the spring, from hitting the hidden page.
        isUserInteractionEnabled = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .black

        coverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coverView.contentMode = .scaleToFill
        coverView.isAccessibilityElement = false
        coverView.accessibilityElementsHidden = true
        incomingCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        incomingCover.contentMode = .scaleToFill
        incomingCover.alpha = 0
        incomingCover.isAccessibilityElement = false
        incomingCover.accessibilityElementsHidden = true

        if let device = MTLCreateSystemDefaultDevice(), let renderer = PageCurlRenderer(device: device) {
            let metal = MTKView(frame: bounds, device: device)
            metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            metal.isPaused = true
            metal.enableSetNeedsDisplay = false
            metal.framebufferOnly = true
            metal.isOpaque = true
            metal.colorPixelFormat = .bgra8Unorm
            metal.isAccessibilityElement = false
            metal.accessibilityElementsHidden = true
            if let layer = metal.layer as? CAMetalLayer {
                layer.device = device
                layer.pixelFormat = metal.colorPixelFormat
                layer.framebufferOnly = true
                layer.isOpaque = true
                // `true` returns nil after about a second when the drawable
                // pool is busy. `false` blocks the main thread until one is
                // free, which is a watchdog kill if the view has detached.
                layer.allowsNextDrawableTimeout = true
            }
            metalView = metal
            self.renderer = renderer
            insertSubview(metal, at: 0)
        }
        addSubview(incomingCover)
        addSubview(coverView)
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

    /// Outgoing page, shown immediately so the scroll underneath is covered
    /// before Metal has compiled or presented anything.
    func showCover(_ image: UIImage, background: UIColor) {
        backgroundColor = background
        metalView?.clearColor = background.mtlClearColor
        coverView.image = image
        coverView.frame = bounds
        coverView.alpha = 1
        coverView.isHidden = false
        incomingCover.frame = bounds
        paper = PageCurlGeometry.backsidePaper(background: background.pageCurlRGB)
    }

    /// Runs the leaf from flat to landed. `prepare` scrolls or changes
    /// resource while `showCover` is already up. The incoming bitmap is taken
    /// after that, so the first lifted frame already has the next page.
    /// `reversed` plays that motion backwards with the bitmaps swapped: a
    /// one-page turn back to the previous page, uncurling from the binding spine.
    func runTap(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        reversed: Bool = false,
        duration: TimeInterval = PageCurlGeometry.tapDuration
    ) async {
        // A second call must not leak the first clock or its continuation.
        finishTap()
        endInteractive()
        self.spine = spine
        self.peelSign = peelSign
        self.realVerso = realVerso
        self.reversed = reversed
        fingerDriven = false
        progress = 0

        guard isAttached else {
            return
        }
        guard let renderer, let metalView else {
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        let stops = lifecycleStops
        guard await renderer.prepare(outgoing: outgoing, incoming: incoming) else {
            guard isAttached else {
                return
            }
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        // Resigning active while the textures uploaded stops the turn, as it
        // does one already running.
        guard isAttached, lifecycleStops == stops else {
            renderer.releaseTextures()
            return
        }
        metalView.layoutIfNeeded()
        let presented = await renderer.drawAndWait(
            uniforms: uniforms(in: metalView),
            in: metalView,
            reversed: reversed
        )
        guard isAttached, presented else {
            renderer.releaseTextures()
            guard isAttached else {
                return
            }
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        coverView.isHidden = true

        guard duration > 0 else {
            progress = 1
            renderer.drawNow(uniforms: uniforms(in: metalView), in: metalView, reversed: reversed)
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

    /// The outgoing cover is already up. The first presented frame already has
    /// the leaf under the finger: no catch-up, so the page moves with the
    /// finger from the first frame.
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
        finishTap()
        endInteractive()
        self.spine = spine
        self.peelSign = peelSign
        self.realVerso = realVerso
        self.reversed = reversed
        fingerDriven = true
        self.grabUV = grabUV
        self.fingerUV = fingerUV
        fingerProgress = PageCurlGeometry.clampProgress(progress)
        self.progress = fingerProgress
        interactivePhase = .track
        latencyFrames = 0

        guard isAttached, let renderer, let metalView else {
            interactivePhase = .none
            return false
        }
        let stops = lifecycleStops
        guard await renderer.prepare(outgoing: outgoing, incoming: incoming) else {
            interactivePhase = .none
            return false
        }
        PageCurlLatency.mark("textures")
        guard isAttached, lifecycleStops == stops else {
            renderer.releaseTextures()
            interactivePhase = .none
            return false
        }
        metalView.layoutIfNeeded()
        let presented = await renderer.drawAndWait(
            uniforms: uniforms(in: metalView),
            in: metalView,
            reversed: reversed
        )
        guard isAttached, presented else {
            renderer.releaseTextures()
            interactivePhase = .none
            return false
        }
        PageCurlLatency.mark("first-frame-done")
        coverView.isHidden = true
        clockIsTap = false
        startClock()
        return true
    }

    func track(progress: CGFloat, fingerUV: CGPoint) {
        fingerProgress = PageCurlGeometry.clampProgress(progress)
        if fingerUV.x.isFinite, fingerUV.y.isFinite {
            self.fingerUV = fingerUV
        }
        logGrab()
    }

    private var grabLogCount = 0

    /// Every eighth sample: the grab, the finger and the moved edge, in points.
    /// The flap is the strip between `fold` and `p`, half the finger's travel.
    private func logGrab() {
        guard PageCurlDebug.enabled else {
            return
        }
        grabLogCount += 1
        guard grabLogCount % 8 == 1 else {
            return
        }
        let aspect = pageAspect()
        let leaf = PageCurlGeometry.span(spine: spine, peelSign: peelSign)
        let grab = liveGrab(span: leaf, aspect: aspect)
        let w = bounds.width
        func pt(_ q: CGPoint) -> String {
            String(format: "%.0f,%.0f", q.x * w, q.y * w)
        }
        let fold = PageCurlGeometry.mix(grab.p0, grab.p, 0.5)
        PageCurlDebug.log(
            "curl-grab phase=\(interactivePhase) start=\(String(format: "%.0f,%.0f", grabUV.x * w, grabUV.y * bounds.height)) "
                + "finger=\(String(format: "%.0f,%.0f", fingerUV.x * w, fingerUV.y * bounds.height)) "
                + "p0=\(pt(grab.p0)) p=\(pt(grab.p)) fold=\(pt(fold)) progress=\(String(format: "%.3f", progress))"
        )
    }

    /// Runs the critically damped spring from the live progress. `progressVelocity`
    /// is pages per second and keeps its sign across the finger lifting.
    func finishInteractive(target: CGFloat, progressVelocity: CGFloat) async {
        let target = PageCurlGeometry.clampProgress(target)
        let velocity = progressVelocity.isFinite ? progressVelocity : 0
        guard interactivePhase != .none else {
            progress = target
            return
        }
        // A release between display-link ticks (or before the first one)
        // springs from the finger, not from the last frame drawn.
        if interactivePhase == .track {
            progress = fingerProgress
        }
        springFrom = progress
        springVelocity = velocity
        springTarget = target
        springOmega = PageCurlPanStateMachine.omega(progressVelocity: velocity)
        springStart = CACurrentMediaTime()
        let aspect = pageAspect()
        let leaf = PageCurlGeometry.span(spine: spine, peelSign: peelSign)
        let grab = liveGrab(span: leaf, aspect: aspect)
        // The point the shader drew, kept within the spine's reach. Outside
        // it the spring would sit on the boundary until the curve came back in.
        springPFrom = PageCurlGeometry.attachedHeldPoint(
            p0: grab.p0,
            p: grab.p,
            spineX: spine.normalizedX,
            pageHeight: 1 / max(aspect, 0.05)
        )
        let landing = PageCurlGeometry.commitLanding(
            p0: grab.p0,
            spineX: spine.normalizedX,
            peelSign: peelSign,
            span: leaf
        )
        // A reversed drag is the forward curl run backwards: committing it
        // closes onto the previous page (P returns to the held point).
        if reversed {
            springPTo = target >= 0.5 ? grab.p0 : landing
        } else {
            springPTo = target >= 0.5 ? landing : grab.p0
        }
        // The leaf is at the finger from the first frame, so the spring
        // starts on the drag's own aim and keeps its angle.
        springPControl = PageCurlGeometry.mix(springPFrom, springPTo, 0.5)
        interactivePhase = .spring
        if abs(progress - target) < 0.004, abs(velocity) < 0.02 {
            progress = target
            drawInteractive()
            endInteractive()
            return
        }
        if displayLink == nil {
            clockIsTap = false
            startClock()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            interactiveContinuation = continuation
        }
    }

    // The cover takes the touches (`isUserInteractionEnabled`) and keeps
    // them: UIView's default passes them up the responder chain, to the
    // navigator's own touch observers, as a tap on the hidden page.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    /// Stops the leaf and shows a still page (`image`, or the one the turn
    /// started from) for a host that has to move the web view back under it
    /// before it takes this view down.
    func freezeOnCover(showing image: UIImage? = nil) {
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
        renderer?.cancelDrawWait()
        renderer?.releaseTextures()
    }

    /// Bumped by every resign-active or background. A turn awaiting its
    /// texture upload when it changes does not start.
    private var lifecycleStops = 0

    private var isAttached: Bool {
        window != nil && superview != nil && UIApplication.shared.applicationState != .background
    }

    private var turnIsRunning: Bool {
        displayLink != nil
            || tapContinuation != nil
            || interactiveContinuation != nil
            || (renderer?.isWaitingForDraw ?? false)
    }

    /// Background, or the view leaving the hierarchy. Stop the clock before
    /// another frame can submit GPU work, and unblock whoever is awaiting.
    private func cancelForLifecycle() {
        lifecycleStops &+= 1
        guard turnIsRunning else {
            releaseResources()
            return
        }
        // The still cover is the outgoing page. The metal layer is about to
        // lose its textures; showing the cover avoids a blank frame until the
        // host removes this view. A finished turn has already dropped the
        // clock, so removing it does not flash the cover back up.
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

    private func uniforms(in metal: MTKView) -> PageCurlUniforms {
        let span = PageCurlGeometry.span(spine: spine, peelSign: peelSign)
        let shown = shownProgress
        let aspect = pageAspect(of: metal)
        let live = liveGrab(span: span, aspect: aspect)
        let pageHeight = 1 / max(aspect, 0.05)
        let held = PageCurlGeometry.attachedHeldPoint(
            p0: live.p0,
            p: live.p,
            spineX: spine.normalizedX,
            pageHeight: pageHeight
        )
        let grab = (p0: live.p0, p: held)
        let radius = PageCurlGeometry.spineSafeRadius(
            PageCurlGeometry.cylinderRadius(progress: shown, span: span),
            p0: grab.p0,
            p: grab.p,
            spineX: spine.normalizedX,
            pageHeight: pageHeight
        )
        return PageCurlUniforms(
            progress: Float(shown),
            spineX: Float(spine.normalizedX),
            peelSign: Float(peelSign),
            radius: Float(radius),
            p0x: Float(grab.p0.x),
            p0y: Float(grab.p0.y),
            px: Float(grab.p.x),
            py: Float(grab.p.y),
            span: Float(span),
            realVerso: realVerso ? 1 : 0,
            paperR: Float(paper.r),
            paperG: Float(paper.g),
            paperB: Float(paper.b),
            paperMix: Float(paper.mix),
            aspect: Float(aspect)
        )
    }

    /// Drawable aspect when the layer has a size, otherwise the view's.
    /// The grab and the shader must share this, or the fold shears.
    private func pageAspect(of metal: MTKView) -> CGFloat {
        let size = metal.drawableSize
        if size.height > 1, size.width > 1 {
            return size.width / size.height
        }
        return pageAspect()
    }

    private func pageAspect() -> CGFloat {
        if bounds.height > 1, bounds.width > 1 {
            return bounds.width / bounds.height
        }
        return 1
    }

    /// P0 is the outer edge at the grab height. The finger's movement is applied
    /// to that point, so the material point travels with the finger and a touch
    /// that starts inset from the edge does not fold until the finger moves.
    /// A reversed drag runs the same path backwards with `shownProgress`.
    private func liveGrab(span: CGFloat, aspect: CGFloat) -> (p0: CGPoint, p: CGPoint) {
        let spineX = spine.normalizedX
        let pageH = 1 / max(aspect, 0.05)
        if !fingerDriven {
            return PageCurlGeometry.tapGrab(
                progress: shownProgress,
                spineX: spineX,
                peelSign: peelSign,
                span: span,
                pageHeight: pageH
            )
        }
        let p0 = PageCurlGeometry.heldPoint(
            touchUV: grabUV,
            spineX: spineX,
            peelSign: peelSign,
            span: span,
            aspect: aspect
        )
        if interactivePhase == .spring {
            let denom = springTarget - springFrom
            let u: CGFloat
            if abs(denom) < 0.0001 {
                u = 1
            } else {
                u = min(1, max(0, (progress - springFrom) / denom))
            }
            return (p0, PageCurlGeometry.springGrab(from: springPFrom, control: springPControl, to: springPTo, u: u))
        }
        if reversed {
            let origin = PageCurlGeometry.fingerPoint(touchUV: grabUV, aspect: aspect)
            let finger = PageCurlGeometry.fingerPoint(touchUV: fingerUV, aspect: aspect)
            return (p0, PageCurlGeometry.reversedGrab(
                p0: p0,
                fingerDY: finger.y - origin.y,
                shown: shownProgress,
                spineX: spineX,
                peelSign: peelSign,
                span: span,
                pageHeight: pageH
            ))
        }
        return (p0, fingerAim(p0: p0, aspect: aspect, span: span))
    }

    /// The held point moved by the finger's travel since the touch-down,
    /// running ahead to the landing near the far edge (`PageCurlGeometry.fingerAim`).
    private func fingerAim(p0: CGPoint, aspect: CGFloat, span: CGFloat) -> CGPoint {
        PageCurlGeometry.fingerAim(
            p0: p0,
            origin: PageCurlGeometry.fingerPoint(touchUV: grabUV, aspect: aspect),
            finger: PageCurlGeometry.fingerPoint(touchUV: fingerUV, aspect: aspect),
            spineX: spine.normalizedX,
            peelSign: peelSign,
            span: span,
            pageHeight: 1 / max(aspect, 0.05)
        )
    }

    /// Visual progress. A reversed one-page turn runs the forward curl from
    /// landed back to flat, which uncurls the previous page off the spine.
    private var shownProgress: CGFloat {
        let value = PageCurlGeometry.clampProgress(progress)
        return reversed ? (1 - value) : value
    }

    /// Prefer 120 Hz. A minimum above the screen's maximum (a 60 Hz simulator,
    /// a ProMotion display that is currently throttled) skips the callback and
    /// the leaf snaps, so the floor stays under the screen's own cap.
    private func startClock() {
        displayLink?.invalidate()
        clock.owner = self
        let link = CADisplayLink(target: clock, selector: #selector(PageCurlClock.step(_:)))
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
            stepInteractive()
        }
    }

    private func stepTap() {
        let elapsed = CACurrentMediaTime() - tapStart
        let t = tapDuration > 0 ? elapsed / tapDuration : 1
        progress = PageCurlGeometry.easeInOut(CGFloat(min(1, t)))
        if let metalView, let renderer {
            renderer.drawNow(uniforms: uniforms(in: metalView), in: metalView, reversed: reversed)
        }
        if t >= 1 {
            finishTap()
        }
    }

    private func stepInteractive() {
        var landed = false
        switch interactivePhase {
        case .none:
            return
        case .track:
            progress = fingerProgress
        case .spring:
            let elapsed = CACurrentMediaTime() - springStart
            progress = PageCurlPanStateMachine.springProgress(
                elapsed: elapsed,
                from: springFrom,
                velocity: springVelocity,
                target: springTarget,
                omega: springOmega
            )
            if abs(progress - springTarget) < 0.004 || elapsed > 0.7 {
                progress = springTarget
                landed = true
            }
        }
        drawInteractive()
        if landed {
            endInteractive()
        }
    }

    private func drawInteractive() {
        guard let metalView, let renderer else { return }
        renderer.drawNow(
            uniforms: uniforms(in: metalView),
            in: metalView,
            reversed: reversed,
            presented: latencyFrameLogger()
        )
    }

    /// Curl debug only, the first live frames of a drag: where the leaf is
    /// against the finger, in points, and how long ago the finger was where
    /// the leaf now is. Logged again when the GPU has finished the frame.
    private func latencyFrameLogger() -> ((CFTimeInterval) -> Void)? {
        guard PageCurlDebug.enabled, latencyFrames < 12,
              interactivePhase == .track
        else {
            return nil
        }
        latencyFrames += 1
        let frame = latencyFrames
        let w = bounds.width
        let span = PageCurlGeometry.span(spine: spine, peelSign: peelSign)
        let grab = liveGrab(span: span, aspect: pageAspect())
        let grabX = grabUV.x * w
        let fingerX = fingerUV.x * w
        let now = CACurrentMediaTime()
        var lag = "n/a"
        if !reversed {
            let latencyTrail = PageCurlLatency.trail
            let leafTravel = abs(grab.p.x - grab.p0.x) * w
            var at = latencyTrail.first?.time ?? now
            for index in stride(from: latencyTrail.count - 1, through: 0, by: -1) {
                let sample = latencyTrail[index]
                let travel = abs(sample.x - grabX)
                guard travel <= leafTravel + 0.5 else {
                    continue
                }
                at = sample.time
                if index + 1 < latencyTrail.count {
                    let next = latencyTrail[index + 1]
                    let step = abs(next.x - grabX) - travel
                    if step > 0.01 {
                        at += (next.time - sample.time) * min(1, max(0, (leafTravel - travel) / step))
                    }
                }
                break
            }
            lag = PageCurlLatency.ms(now - at)
            let leafX = grabX + (grab.p.x - grab.p0.x) * w
            lag += String(format: "ms gap=%.0fpt finger=%.0f leaf=%.0f", abs(fingerX - leafX), fingerX, leafX)
        }
        PageCurlDebug.log(
            "curl-frame n=\(frame) phase=\(interactivePhase) drawn=+\(PageCurlLatency.sinceTouchDown(now))ms "
                + "progress=\(String(format: "%.3f", progress)) lag=\(lag)"
        )
        return { presentedTime in
            guard presentedTime > 0 else {
                return
            }
            PageCurlDebug.log("curl-frame n=\(frame) gpu-done=+\(PageCurlLatency.sinceTouchDown(presentedTime))ms")
        }
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

    private func fadeFallback(to incoming: UIImage, duration: TimeInterval) async {
        guard isAttached else {
            return
        }
        incomingCover.image = incoming
        incomingCover.frame = bounds
        guard duration > 0 else {
            coverView.alpha = 0
            incomingCover.alpha = 1
            return
        }
        await withCheckedContinuation { continuation in
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                self.coverView.alpha = 0
                self.incomingCover.alpha = 1
            } completion: { _ in
                continuation.resume()
            }
        }
    }
}

/// The display link retains its target. This object does not retain the view,
/// so a curl that is still on screen can be released when its host drops it.
private final class PageCurlClock: NSObject {
    weak var owner: PageCurlView?

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

private extension UIColor {
    var pageCurlRGB: PageCurlRGB {
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return PageCurlRGB(r: r, g: g, b: b)
        }
        return PageCurlRGB(r: 1, g: 1, b: 1)
    }

    var mtlClearColor: MTLClearColor {
        let rgb = pageCurlRGB
        return MTLClearColor(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b), alpha: 1)
    }
}

/// One library, queue and loader per device. Textures live only while a turn
/// is on screen.
@MainActor
private final class PageCurlRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var outgoing: MTLTexture?
    private var incoming: MTLTexture?
    private let loader: MTKTextureLoader
    private var inFlight = 0
    private var drawContinuation: CheckedContinuation<Bool, Never>?
    /// The library compile is the slow part. One per device, shared by turns.
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedDevice: MTLDevice?
    private static var cachedQueue: MTLCommandQueue?
    private static var cachedLoader: MTKTextureLoader?
    private static var compileFailed = false
    private static var pipelineTask: Task<MTLRenderPipelineState?, Never>?

    var isWaitingForDraw: Bool {
        drawContinuation != nil
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let resources = Self.resources(for: device) else {
            return nil
        }
        self.queue = resources.queue
        self.loader = resources.loader
    }

    static func warmPipeline(device: MTLDevice) async {
        _ = await sharedPipeline(for: device)
    }

    /// Both bitmaps upload at once, on the texture loader's own queue, so the
    /// main actor only waits. A bitmap preloaded at touch-down is already
    /// (or nearly) a texture.
    func prepare(outgoing: UIImage, incoming: UIImage) async -> Bool {
        guard await ensurePipeline() else {
            return false
        }
        let outgoingUpload = Self.upload(outgoing, loader: loader)
        let incomingUpload = Self.upload(incoming, loader: loader)
        self.outgoing = await outgoingUpload.value
        self.incoming = await incomingUpload.value
        if self.outgoing == nil || self.incoming == nil {
            releaseTextures()
            return false
        }
        return true
    }

    func releaseTextures() {
        outgoing = nil
        incoming = nil
    }

    /// The waited frame failed, or the view went away before the GPU did.
    /// Resuming twice is a crash, so this and the completion share one slot.
    func cancelDrawWait() {
        let continuation = drawContinuation
        drawContinuation = nil
        continuation?.resume(returning: false)
    }

    /// Presents one frame and waits until the GPU is done, so the still cover
    /// can come off without a blank drawable underneath.
    func drawAndWait(uniforms: PageCurlUniforms, in view: MTKView, reversed: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            guard inFlight < 2, let buffer = encode(uniforms: uniforms, in: view, reversed: reversed) else {
                continuation.resume(returning: false)
                return
            }
            drawContinuation = continuation
            track(buffer, resumesWaiter: true)
        }
    }

    func drawNow(
        uniforms: PageCurlUniforms,
        in view: MTKView,
        reversed: Bool,
        presented: ((CFTimeInterval) -> Void)? = nil
    ) {
        guard inFlight < 2,
              let buffer = encode(uniforms: uniforms, in: view, reversed: reversed, presented: presented)
        else {
            if presented != nil {
                PageCurlDebug.log("curl-frame skipped inFlight=\(inFlight)")
            }
            return
        }
        track(buffer, resumesWaiter: false)
    }

    private func track(_ buffer: MTLCommandBuffer, resumesWaiter: Bool) {
        inFlight += 1
        buffer.addCompletedHandler { [weak self] buffer in
            let ok = buffer.status == .completed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    guard resumesWaiter else { return }
                    let continuation = self.drawContinuation
                    self.drawContinuation = nil
                    continuation?.resume(returning: ok)
                }
            }
        }
        buffer.commit()
    }

    private func ensurePipeline() async -> Bool {
        if pipeline != nil {
            return true
        }
        guard let compiled = await Self.sharedPipeline(for: device) else {
            return false
        }
        pipeline = compiled
        return true
    }

    private static func resources(for device: MTLDevice) -> (queue: MTLCommandQueue, loader: MTKTextureLoader)? {
        if cachedDevice !== device {
            // Textures belong to their device.
            dropPreloads()
            cachedPipeline = nil
            cachedQueue = nil
            cachedLoader = nil
            cachedDevice = nil
            compileFailed = false
            pipelineTask?.cancel()
            pipelineTask = nil
        }
        if cachedQueue == nil {
            cachedQueue = device.makeCommandQueue()
        }
        guard let queue = cachedQueue else {
            return nil
        }
        if cachedLoader == nil {
            cachedLoader = MTKTextureLoader(device: device)
        }
        guard let loader = cachedLoader else {
            return nil
        }
        cachedDevice = device
        return (queue, loader)
    }

    private static func sharedPipeline(for device: MTLDevice) async -> MTLRenderPipelineState? {
        if cachedDevice !== device {
            _ = resources(for: device)
        }
        if let cachedPipeline, cachedDevice === device {
            return cachedPipeline
        }
        if compileFailed {
            return nil
        }
        if let pipelineTask {
            return await pipelineTask.value
        }
        let task = Task { @MainActor () -> MTLRenderPipelineState? in
            do {
                let library = try await compileLibrary(device: device)
                guard
                    let vertex = library.makeFunction(name: "curlVertex"),
                    let fragment = library.makeFunction(name: "curlFragment")
                else {
                    compileFailed = true
                    return nil
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                let compiled = try await compilePipeline(device: device, descriptor: descriptor)
                // A device change cancels this task. Don't publish the old pipeline.
                guard !Task.isCancelled else {
                    return nil
                }
                cachedPipeline = compiled
                cachedDevice = device
                return compiled
            } catch {
                compileFailed = true
                return nil
            }
        }
        pipelineTask = task
        let compiled = await task.value
        if pipelineTask == task {
            pipelineTask = nil
        }
        return compiled
    }

    /// Metal compiles on its own queue. Awaiting here suspends the main actor
    /// instead of stalling it inside `makeLibrary(source:)`.
    private static func compileLibrary(device: MTLDevice) async throws -> MTLLibrary {
        try await withCheckedThrowingContinuation { continuation in
            device.makeLibrary(source: PageCurlShader.source, options: nil) { library, error in
                if let library {
                    continuation.resume(returning: library)
                } else {
                    continuation.resume(throwing: error ?? PageCurlCompileError.failed)
                }
            }
        }
    }

    private static func compilePipeline(
        device: MTLDevice,
        descriptor: MTLRenderPipelineDescriptor
    ) async throws -> MTLRenderPipelineState {
        try await withCheckedThrowingContinuation { continuation in
            device.makeRenderPipelineState(descriptor: descriptor) { pipeline, error in
                if let pipeline {
                    continuation.resume(returning: pipeline)
                } else {
                    continuation.resume(throwing: error ?? PageCurlCompileError.failed)
                }
            }
        }
    }

    /// Uploads started before the drag was recognised, newest last. Bounded:
    /// a turn needs two, and the oldest is dropped past `preloadLimit`.
    private static var preloads: [(image: UIImage, task: Task<MTLTexture?, Never>)] = []
    private static let preloadLimit = 3

    /// Starts uploading `images` now. `prepare` picks the textures up by bitmap.
    static func preload(_ images: [UIImage]) {
        guard UIApplication.shared.applicationState != .background,
              let device = cachedDevice ?? MTLCreateSystemDefaultDevice(),
              let loader = resources(for: device)?.loader
        else {
            return
        }
        for image in images where !preloads.contains(where: { $0.image === image }) {
            preloads.append((image, startUpload(image, loader: loader)))
        }
        if preloads.count > preloadLimit {
            preloads.removeFirst(preloads.count - preloadLimit)
        }
    }

    /// Drag over, reader closing, or the bitmaps went stale.
    static func dropPreloads() {
        for preload in preloads {
            preload.task.cancel()
        }
        preloads.removeAll()
    }

    private static func upload(_ image: UIImage, loader: MTKTextureLoader) -> Task<MTLTexture?, Never> {
        if let index = preloads.firstIndex(where: { $0.image === image }) {
            return preloads.remove(at: index).task
        }
        return startUpload(image, loader: loader)
    }

    private static func startUpload(_ image: UIImage, loader: MTKTextureLoader) -> Task<MTLTexture?, Never> {
        Task { @MainActor in
            // No GPU work from the background, and none for a dropped preload.
            guard !Task.isCancelled,
                  UIApplication.shared.applicationState != .background,
                  let cgImage = image.cgImage
            else {
                return nil
            }
            return try? await loader.newTexture(cgImage: cgImage, options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            ])
        }
    }

    /// `MTKView.currentDrawable` is filled at the end of `-draw`. This path
    /// never calls `-draw` (the view stays paused), so that property stays
    /// empty after the first accidental grab and the leaf never moves.
    /// `nextDrawable()` is the layer's own drawable, valid from the display link.
    private func encode(
        uniforms: PageCurlUniforms,
        in view: MTKView,
        reversed: Bool,
        presented: ((CFTimeInterval) -> Void)? = nil
    ) -> MTLCommandBuffer? {
        guard
            view.window != nil,
            UIApplication.shared.applicationState != .background,
            let pipeline,
            let outgoing,
            let incoming,
            let layer = view.layer as? CAMetalLayer,
            let drawable = nextDrawable(from: layer, view: view),
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass(for: drawable, clear: view.clearColor))
        else {
            return nil
        }
        var uniforms = uniforms
        // A reversed turn uncurls the incoming page off the binding spine.
        // Progress 0 in the shader shows texture 0, and that frame is the end
        // of the gesture, so texture 0 is the incoming page.
        let front = reversed ? incoming : outgoing
        let back = reversed ? outgoing : incoming
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(front, index: 0)
        encoder.setFragmentTexture(back, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PageCurlUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // `addPresentedHandler` is not in the simulator SDK. The GPU end time
        // is on the same clock; the drawable shows at the next vsync after it.
        if let presented {
            buffer.addCompletedHandler { buffer in
                let time = buffer.gpuEndTime
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        presented(time)
                    }
                }
            }
        }
        buffer.present(drawable)
        return buffer
    }

    private func nextDrawable(from layer: CAMetalLayer, view: MTKView) -> CAMetalDrawable? {
        let scale = max(view.window?.screen.scale ?? view.contentScaleFactor, 1)
        if layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        let size = CGSize(
            width: max(view.bounds.width, 1) * scale,
            height: max(view.bounds.height, 1) * scale
        )
        if layer.drawableSize != size {
            layer.drawableSize = size
        }
        layer.pixelFormat = view.colorPixelFormat
        layer.framebufferOnly = true
        layer.device = device
        layer.isOpaque = true
        layer.allowsNextDrawableTimeout = true
        return layer.nextDrawable()
    }

    private func pass(for drawable: CAMetalDrawable, clear: MTLClearColor) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        return pass
    }
}

private enum PageCurlCompileError: Error {
    case failed
}
