//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Metal
import MetalKit
import UIKit

/// Progress-driven cylinder curl. A tap runs 0→1 on a display link. A finger
/// (Task 4) sets `progress` and `touchY` itself. Nothing in here times the shader.
@MainActor
final class PageCurlView: UIView {
    private let coverView = UIImageView()
    private let incomingCover = UIImageView()
    private var metalView: MTKView?
    private var renderer: PageCurlRenderer?
    private var displayLink: CADisplayLink?
    private var tapStart: CFTimeInterval = 0
    private var tapDuration: CFTimeInterval = PageCurlGeometry.tapDuration
    private var tapContinuation: CheckedContinuation<Void, Never>?
    private var clockIsTap = true

    private var spine: PageCurlSpine = .leading
    private var peelSign: CGFloat = 1
    private var touchY: CGFloat = PageCurlGeometry.tapTouchY
    private var realVerso = false
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

        if let device = MTLCreateSystemDefaultDevice() {
            let metal = MTKView(frame: bounds, device: device)
            metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            metal.isPaused = true
            metal.enableSetNeedsDisplay = false
            metal.framebufferOnly = true
            metal.isOpaque = true
            metal.colorPixelFormat = .bgra8Unorm
            metal.isAccessibilityElement = false
            metal.accessibilityElementsHidden = true
            metalView = metal
            renderer = PageCurlRenderer(device: device)
            insertSubview(metal, at: 0)
        }
        addSubview(incomingCover)
        addSubview(coverView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    /// Outgoing page, shown immediately so the scroll underneath is covered
    /// before Metal has compiled or presented anything.
    func showCover(_ image: UIImage, background: UIColor) {
        backgroundColor = background
        metalView?.clearColor = background.mtlClearColor
        coverView.image = image
        coverView.frame = bounds
        coverView.alpha = 1
        incomingCover.frame = bounds
        paper = PageCurlGeometry.backsidePaper(background: background.pageCurlRGB)
    }

    /// Runs the leaf from flat to landed. `prepare` scrolls or changes
    /// resource while `showCover` is already up. The incoming bitmap is taken
    /// after that, so the first lifted frame already has the next page.
    func runTap(
        outgoing: UIImage,
        incoming: UIImage,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        realVerso: Bool,
        duration: TimeInterval = PageCurlGeometry.tapDuration
    ) async {
        self.spine = spine
        self.peelSign = peelSign
        self.realVerso = realVerso
        self.touchY = PageCurlGeometry.tapTouchY
        progress = 0

        guard let renderer, let metalView, renderer.prepare(outgoing: outgoing, incoming: incoming) else {
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        metalView.layoutIfNeeded()
        let presented = await renderer.drawAndWait(uniforms: uniforms(in: metalView), in: metalView)
        guard presented else {
            await fadeFallback(to: incoming, duration: duration)
            return
        }
        coverView.isHidden = true

        guard duration > 0 else {
            progress = 1
            renderer.drawNow(uniforms: uniforms(in: metalView), in: metalView)
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
        progress: CGFloat,
        touchY: CGFloat
    ) async -> Bool {
        self.spine = spine
        self.peelSign = peelSign
        self.realVerso = realVerso
        self.touchY = touchY
        fingerProgress = PageCurlGeometry.clampProgress(progress)
        self.progress = 0
        interactivePhase = .catchUp

        guard let renderer, let metalView, renderer.prepare(outgoing: outgoing, incoming: incoming) else {
            interactivePhase = .none
            return false
        }
        metalView.layoutIfNeeded()
        let presented = await renderer.drawAndWait(uniforms: uniforms(in: metalView), in: metalView)
        guard presented else {
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
        finishTap()
        endInteractive()
        renderer?.releaseTextures()
        coverView.image = nil
        incomingCover.image = nil
    }

    private func uniforms(in metal: MTKView) -> PageCurlUniforms {
        let span = PageCurlGeometry.span(spine: spine, peelSign: peelSign)
        let radius = PageCurlGeometry.cylinderRadius(progress: progress, span: span)
        let size = metal.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        let twoPage: Float = {
            if case .center = spine { return 1 }
            return 0
        }()
        return PageCurlUniforms(
            progress: Float(PageCurlGeometry.clampProgress(progress)),
            spineX: Float(spine.normalizedX),
            peelSign: Float(peelSign),
            radius: Float(radius),
            tilt: Float(PageCurlGeometry.tiltRadians(touchY: touchY)),
            span: Float(span),
            realVerso: realVerso ? 1 : 0,
            specular: Float(paper.specular),
            paperR: Float(paper.r),
            paperG: Float(paper.g),
            paperB: Float(paper.b),
            paperMix: Float(paper.mix),
            aspect: aspect,
            twoPage: twoPage
        )
    }

    /// Prefer 120 Hz. A minimum above the screen's maximum (a 60 Hz simulator,
    /// a ProMotion display that is currently throttled) skips the callback and
    /// the leaf snaps, so the floor stays under the screen's own cap.
    private func startClock() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(stepClock))
        let hz = Float(window?.screen.maximumFramesPerSecond ?? 60)
        let cap = min(120, max(hz, 1))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: cap)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func stepClock() {
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
            renderer.drawNow(uniforms: uniforms(in: metalView), in: metalView)
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
        renderer.drawNow(uniforms: uniforms(in: metalView), in: metalView)
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

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func fadeFallback(to incoming: UIImage, duration: TimeInterval) async {
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

/// One library per device, textures only while a turn is on screen.
private final class PageCurlRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var outgoing: MTLTexture?
    private var incoming: MTLTexture?
    private let loader: MTKTextureLoader
    /// The library compile is the slow part. One per device, shared by turns.
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedDevice: MTLDevice?
    private static var compileFailed = false

    init(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.loader = MTKTextureLoader(device: device)
    }

    func prepare(outgoing: UIImage, incoming: UIImage) -> Bool {
        guard ensurePipeline() else {
            return false
        }
        self.outgoing = texture(from: outgoing)
        self.incoming = texture(from: incoming)
        return self.outgoing != nil && self.incoming != nil
    }

    func releaseTextures() {
        outgoing = nil
        incoming = nil
    }

    /// Presents one frame and waits until the GPU is done, so the still cover
    /// can come off without a blank drawable underneath.
    func drawAndWait(uniforms: PageCurlUniforms, in view: MTKView) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let buffer = encode(uniforms: uniforms, in: view) else {
                continuation.resume(returning: false)
                return
            }
            buffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    continuation.resume(returning: true)
                }
            }
            buffer.commit()
        }
    }

    func drawNow(uniforms: PageCurlUniforms, in view: MTKView) {
        guard let buffer = encode(uniforms: uniforms, in: view) else {
            return
        }
        buffer.commit()
    }

    private func ensurePipeline() -> Bool {
        if pipeline != nil {
            return true
        }
        if let cached = Self.cachedPipeline, Self.cachedDevice === device {
            pipeline = cached
            return true
        }
        if Self.compileFailed {
            return false
        }
        do {
            let library = try device.makeLibrary(source: PageCurlShader.source, options: nil)
            guard
                let vertex = library.makeFunction(name: "curlVertex"),
                let fragment = library.makeFunction(name: "curlFragment")
            else {
                Self.compileFailed = true
                return false
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let compiled = try device.makeRenderPipelineState(descriptor: descriptor)
            pipeline = compiled
            Self.cachedPipeline = compiled
            Self.cachedDevice = device
            return true
        } catch {
            Self.compileFailed = true
            return false
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
    private func encode(uniforms: PageCurlUniforms, in view: MTKView) -> MTLCommandBuffer? {
        guard
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
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(outgoing, index: 0)
        encoder.setFragmentTexture(incoming, index: 1)
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
        // Nil instead of blocking the display link when the pool is busy.
        layer.allowsNextDrawableTimeout = false
        layer.pixelFormat = view.colorPixelFormat
        layer.framebufferOnly = true
        layer.device = device
        layer.isOpaque = true
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
