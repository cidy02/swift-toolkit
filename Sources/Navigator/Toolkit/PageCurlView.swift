//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Metal
import MetalKit
import UIKit

/// Progress-driven cylinder curl. A tap runs 0→1 on a display link. A finger
/// sets `progress` and `touchY` itself. Nothing in here times the shader.
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
    private var touchY: CGFloat = PageCurlGeometry.tapTouchY
    private var realVerso = false
    private var reversed = false
    private var paper = PageCurlPaper(r: 0.96, g: 0.96, b: 0.96, mix: PageCurlGeometry.backsideMix, specular: 0.3)
    private var progress: CGFloat = 0

    /// Finger position while a drag is in flight. The display link reads it.
    private var fingerProgress: CGFloat = 0
    private var interactivePhase: InteractivePhase = .none
    private var catchUpStart: CFTimeInterval = 0
    private var springStart: CFTimeInterval = 0
    private var springFrom: CGFloat = 0
    private var springVelocity: CGFloat = 0
    private var springTarget: CGFloat = 1
    private var springOmega: CGFloat = PageCurlPanStateMachine.settleOmega
    private var interactiveContinuation: CheckedContinuation<Void, Never>?

    private enum InteractivePhase {
        case none
        case catchUp
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
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
        self.touchY = PageCurlGeometry.tapTouchY
        progress = 0

        guard isAttached else {
            return
        }
        guard let renderer, let metalView else {
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        guard await renderer.prepare(outgoing: outgoing, incoming: incoming) else {
            guard isAttached else {
                return
            }
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        guard isAttached else {
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

    /// The outgoing cover is already up. The first presented frame is the flat
    /// page, then the leaf catches the finger over `catchUpDuration`.
    func beginInteractive(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        reversed: Bool = false,
        progress: CGFloat,
        touchY: CGFloat
    ) async -> Bool {
        finishTap()
        endInteractive()
        self.spine = spine
        self.peelSign = peelSign
        self.realVerso = realVerso
        self.reversed = reversed
        self.touchY = touchY
        fingerProgress = PageCurlGeometry.clampProgress(progress)
        self.progress = 0
        interactivePhase = .catchUp

        guard isAttached, let renderer, let metalView else {
            interactivePhase = .none
            return false
        }
        guard await renderer.prepare(outgoing: outgoing, incoming: incoming) else {
            interactivePhase = .none
            return false
        }
        guard isAttached else {
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
        coverView.isHidden = true
        catchUpStart = CACurrentMediaTime()
        clockIsTap = false
        startClock()
        return true
    }

    func track(progress: CGFloat, touchY: CGFloat) {
        fingerProgress = PageCurlGeometry.clampProgress(progress)
        self.touchY = touchY
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
        springFrom = progress
        springVelocity = velocity
        springTarget = target
        springOmega = PageCurlPanStateMachine.omega(progressVelocity: velocity)
        springStart = CACurrentMediaTime()
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

    func releaseResources() {
        stopClock()
        resumeWaiters()
        renderer?.cancelDrawWait()
        renderer?.releaseTextures()
    }

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
        let radius = PageCurlGeometry.cylinderRadius(progress: shown, span: span)
        let size = metal.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        let twoPage: Bool = {
            if case .center = spine { return true }
            return false
        }()
        let tilt = PageCurlGeometry.tiltRadians(touchY: touchY)
        let overhang = PageCurlGeometry.tiltOverhang(tilt: tilt, aspect: CGFloat(aspect))
        let fold = PageCurlGeometry.foldCenter(
            progress: shown,
            span: span,
            overhang: overhang,
            curlWidth: radius * 2,
            far: PageCurlGeometry.farSpan(twoPage: twoPage, span: span)
        )
        return PageCurlUniforms(
            progress: Float(shown),
            spineX: Float(spine.normalizedX),
            peelSign: Float(peelSign),
            radius: Float(radius),
            tilt: Float(tilt),
            span: Float(span),
            realVerso: realVerso ? 1 : 0,
            specular: Float(paper.specular),
            paperR: Float(paper.r),
            paperG: Float(paper.g),
            paperB: Float(paper.b),
            paperMix: Float(paper.mix),
            aspect: aspect,
            twoPage: twoPage ? 1 : 0,
            fold: Float(fold)
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
        case .catchUp:
            let duration = PageCurlPanStateMachine.catchUpDuration
            let elapsed = CACurrentMediaTime() - catchUpStart
            let u = duration > 0 ? min(1, elapsed / duration) : 1
            progress = fingerProgress * PageCurlGeometry.easeInOut(CGFloat(u))
            if u >= 1 {
                interactivePhase = .track
                progress = fingerProgress
            }
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
        renderer.drawNow(uniforms: uniforms(in: metalView), in: metalView, reversed: reversed)
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

    func prepare(outgoing: UIImage, incoming: UIImage) async -> Bool {
        guard await ensurePipeline() else {
            return false
        }
        self.outgoing = texture(from: outgoing)
        self.incoming = texture(from: incoming)
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

    func drawNow(uniforms: PageCurlUniforms, in view: MTKView, reversed: Bool) {
        guard inFlight < 2, let buffer = encode(uniforms: uniforms, in: view, reversed: reversed) else {
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

    private func texture(from image: UIImage) -> MTLTexture? {
        guard let cgImage = image.cgImage else {
            return nil
        }
        return try? loader.newTexture(cgImage: cgImage, options: [
            .origin: MTKTextureLoader.Origin.topLeft,
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    /// `MTKView.currentDrawable` is filled at the end of `-draw`. This path
    /// never calls `-draw` (the view stays paused), so that property stays
    /// empty after the first accidental grab and the leaf never moves.
    /// `nextDrawable()` is the layer's own drawable, valid from the display link.
    private func encode(uniforms: PageCurlUniforms, in view: MTKView, reversed: Bool) -> MTLCommandBuffer? {
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
