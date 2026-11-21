//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!

    /// Read at each turn. The notification updates it and cuts short a smooth
    /// scroll that was already running.
    private var isReduceMotionEnabled = UIAccessibility.isReduceMotionEnabled

    private var isSuppressingProgressionUpdates = false
    /// Set when a hidden scroll changed the progression, so lifting the
    /// suppression emits that one change and no earlier one.
    private var progressionChangedWhileSuppressed = false
    /// Column step applied for a finger curl. Cancel scrolls it back.
    private var curlDelta: CGFloat = 0
    /// `contentOffset.x` the commit must land on. A flick's touch-end can
    /// undo the `scrollBy` that was made for the snapshot.
    private var curlTargetOffset: CGFloat?
    /// Cache hit: the column scroll runs under the cover while the leaf
    /// already follows the finger. Commit, cancel and the prerender wait for it.
    private var pendingCurlScroll: Task<Void, Never>?
    /// The navigator's content generation, read when a tap curl starts, and
    /// where its pages go once it lands, so a later drag can use them.
    var curlContentGeneration: (() -> Int)?
    var curlTapDidLand: ((PageCurlLandedPages) -> Void)?
    /// A cancel restores the previous column, then a late scroll message can
    /// still arrive. Drop progression events until this time so the peek does
    /// not become a location, including on the last page of a work.
    private var ignoreProgressionUntil: CFTimeInterval = 0

    private static let reflowableScript = loadScript(named: "readium-reflowable")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        super.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [
                WKUserScript(source: Self.reflowableScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
                WKUserScript(source: Self.foldInsetScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false),
            ],
            animatedLoad: animatedLoad
        )
    }

    /// The curl or slide overlay, if a turn is in flight. Cleared with the spread
    /// so a reload or a close cannot leave the display link running.
    private weak var activeCurlView: (any PageTurnOverlayView)?
    /// A posture cancel removed the cover. The turn's defer must not clear
    /// progression suppression a reflow hold just took.
    private var curlCancelKeepsSuppression = false
    /// While the column past the landing is being rendered under the leaf,
    /// the page the tap lands on. A cancel then keeps the cover up on it
    /// until the web view is back on that column.
    private var activeCurlLanding: UIImage?

    /// After the Readium stylesheets. Their body padding is `!important`, so an
    /// earlier style element loses. Newlines are spaces: the CSS sits inside one
    /// JavaScript string.
    private static let foldInsetScript: String = {
        let css = PageCurlGeometry.foldInsetRules
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return """
        (function() {
          if (document.getElementById('readium-fold-inset')) { return; }
          var node = document.createElement('style');
          node.id = 'readium-fold-inset';
          node.textContent = '\(css)';
          (document.head || document.documentElement).appendChild(node);
        })();
        """
    }()

    override func cancelActiveCurl() {
        guard activeCurlView != nil else {
            return
        }
        curlCancelKeepsSuppression = true
        stopActiveCurl()
    }

    override func stopActiveCurlForLifecycle() {
        stopActiveCurl()
    }

    /// Takes the leaf down. During the render past the landing the web view
    /// may be a column further on: the still cover shows the landing page
    /// until `curl(by:)` has stepped back and removes it.
    private func stopActiveCurl() {
        guard let curlView = activeCurlView else {
            return
        }
        activeCurlView = nil
        if let landing = activeCurlLanding {
            curlView.freezeOnCover(showing: landing)
        } else {
            curlView.releaseResources()
            curlView.removeFromSuperview()
        }
    }

    /// The cancel kept progression suppression so a reflow hold could take it.
    /// A caller that does not hold has to drop it, or the page position sticks.
    override func releaseCurlCancelSuppression() {
        curlCancelKeepsSuppression = false
        if isSuppressingProgressionUpdates {
            setSuppressingProgressionUpdates(false)
        }
    }

    override func clear() {
        activeCurlView?.releaseResources()
        activeCurlView?.removeFromSuperview()
        activeCurlView = nil
        pendingCurlScroll = nil
        super.clear()

        // Clean up go to continuations.
        for continuation in goToContinuations {
            continuation.resume()
        }
        goToContinuations.removeAll()

        scrollDidEnd()
    }

    override func setupWebView() {
        super.setupWebView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        scrollView.isPagingEnabled = !viewModel.scroll

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.readingOrderIndices.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let url = viewModel.url(to: spread.first.link)
        webView.load(URLRequest(url: url.url))
    }

    override func applySettings() {
        super.applySettings()

        // Disables paginated mode if scroll is on.
        scrollView.isPagingEnabled = !viewModel.scroll

        updateContentInset()
    }

    private func updateContentInset() {
        let contentInset = delegate?.spreadViewContentInset(self) ?? .zero

        if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.constant = 0
            scrollView.contentInset = contentInset

        } else {
            topConstraint.constant = contentInset.top
            bottomConstraint.constant = -contentInset.bottom
            scrollView.contentInset = .zero
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            if scrollView.contentOffset.x < 0 {
                point.x += abs(scrollView.contentOffset.x)
            }
            if scrollView.contentOffset.y < 0 {
                point.y += abs(scrollView.contentOffset.y)
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    override func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        guard
            spread.first.index == index,
            let progression = progression
        else {
            return 0 ... 0
        }
        return progression
    }

    override func spreadDidLoad() async {
        let link = spread.first.link
        if let linkJSON = try? link.jsonString() {
            await evaluateScript("readium.link = \(linkJSON);")
        }

        // TODO: Better solution for delaying scrolling to pending location
        // This delay is used to wait for the web view pagination to settle and give the CSS and webview time to layout
        // correctly before attempting to scroll to the target progression, otherwise we might end up at the wrong spot.
        // 0.2 seconds seems like a good value for it to work on an iPhone 5s.
        try? await Task.sleep(seconds: 0.2)

        let location = pendingLocation
        await go(to: location.location, animated: location.animated)

        // The rendering is sometimes very slow. So in case we don't show the first page of the resource, we add
        // a generous delay before showing the spread again.
        let delayed = !location.location.isStart
        try? await Task.sleep(seconds: delayed ? 0.3 : 0)
    }

    override func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        // A cancelled curl ignores progression for a short window. A real turn
        // in that window is not the peek, so the window ends here.
        ignoreProgressionUntil = 0
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        guard let offsetX = pageDelta(for: direction) else {
            return false
        }

        // We use JavaScript instead of `UIScrollView.setContentOffset()` to
        // prevent glitches when turning pages without animation.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        //
        // `scrollBy` is used instead of `scrollTo` because RTL content uses
        // negative `window.scrollX` values in WKWebView, whereas UIKit's
        // `contentOffset.x` is always non-negative. A relative displacement
        // (`offsetX`) is coordinate-system agnostic and works for both LTR and
        // RTL.
        let transition = PageTransitionPolicy.rendered(PageTransitionPolicy.resolve(
            PageTransitionPolicy.Request(
                preference: viewModel.settings.pageTransition,
                animated: options.animated,
                reduceMotion: isReduceMotionEnabled,
                scrolls: false,
                voiceOverRunning: UIAccessibility.isVoiceOverRunning,
                resourceDistance: nil,
                overrideRaw: options.pageTransitionOverride
            )
        ))

        switch transition {
        case .fade:
            await fade(by: offsetX)
        case .curl:
            await turnWithOverlay(by: offsetX, direction: direction, style: .curl)
        case .slide:
            await turnWithOverlay(by: offsetX, direction: direction, style: .slide)
        case .none:
            await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: 'instant' });")
        }

        return true
    }

    /// Cylinder curl or lifted-card slide. The outgoing bitmap is up before the
    /// column scrolls. The incoming bitmap is taken after the paint wait, then
    /// the overlay animates. Progression stays suppressed until the overlay is
    /// gone, so the scroll reports one location.
    private func turnWithOverlay(by offsetX: CGFloat, direction: Direction, style: PageTransition) async {
        setSuppressingProgressionUpdates(true)
        let generation = curlContentGeneration?()
        let startOffset = scrollView.contentOffset.x
        let background = viewModel.settings.effectiveBackgroundColor.uiColor
        // The page is already on screen. `afterScreenUpdates: true` is for the
        // incoming column, after the scroll.
        guard let outgoing = await PageCurlSnapshotter.capture(
            of: self,
            backgroundColor: background,
            afterScreenUpdates: false
        ) else {
            setSuppressingProgressionUpdates(false)
            guard curlHostAttached else {
                return
            }
            await slide(by: offsetX)
            return
        }
        guard curlHostAttached else {
            setSuppressingProgressionUpdates(false)
            return
        }

        let columns = await renderedColumnCount()
        guard curlHostAttached else {
            setSuppressingProgressionUpdates(false)
            return
        }
        let rtl = viewModel.readingProgression == .rtl
        let forward = isForward(direction)
        let divisionX = pageCurlDivisionNormalizedX
        let spine = PageCurlSpine.resolve(
            renderedColumns: columns,
            rtl: rtl,
            divisionNormalizedX: divisionX
        )
        let divisionText = divisionX.map { String(format: "%.3f", $0) } ?? "nil"
        let logPrefix = style == .slide ? "slide-spine" : "curl-spine"
        log(.info, "\(logPrefix) columns=\(columns) division=\(divisionText) spine=\(spine) forward=\(forward)")
        PageCurlDebug.log("\(logPrefix) columns=\(columns) division=\(divisionText) spine=\(spine) forward=\(forward)")
        let overlayView: any PageTurnOverlayView = style == .slide
            ? PageSlideView(frame: bounds)
            : PageCurlView(frame: bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.showCover(outgoing, background: background)
        addSubview(overlayView)
        activeCurlView = overlayView
        // False once cancelled, even while a frozen cover is still up.
        let running = { [weak self, weak overlayView] in
            overlayView != nil && overlayView?.superview != nil && self?.activeCurlView === overlayView
        }
        defer {
            if activeCurlView === overlayView {
                activeCurlView = nil
            }
            activeCurlLanding = nil
            overlayView.releaseResources()
            overlayView.removeFromSuperview()
            let keepSuppression = curlCancelKeepsSuppression
            curlCancelKeepsSuppression = false
            if superview != nil, !keepSuppression {
                setSuppressingProgressionUpdates(false)
            }
        }

        await scrollByAwaitingPaint(offsetX)
        guard curlHostAttached, running() else {
            return
        }
        let shot = await PageCurlSnapshotter.capture(of: self, backgroundColor: background)
        guard curlHostAttached, running() else {
            return
        }
        switch PageCurlGeometry.incomingReveal(snapshotSucceeded: shot != nil) {
        case .crossfade:
            await PageTransitionAnimator.fade(overlayView, to: 0, duration: PageTransitionAnimator.fadeDuration)
        case .cylinder:
            guard let shot else {
                return
            }
            // The overlay covers the web view while it runs: render the column
            // past this one behind it, as a drag's spring does.
            let target = startOffset + offsetX
            activeCurlLanding = shot
            let beyond = Task { @MainActor [weak self] in
                await self?.prerenderCurlBeyond(
                    direction: direction,
                    target: target,
                    background: background,
                    covered: running
                )
            }
            // Resigned active since the turn began (the cover's own observer
            // already fired): skip the animation. The cover shows the landing
            // page while the render past it steps back.
            guard UIApplication.shared.applicationState == .active else {
                stopActiveCurl()
                _ = await beyond.value
                return
            }
            await overlayView.runTap(
                outgoing: outgoing,
                incoming: shot,
                spine: spine,
                peelSign: PageCurlGeometry.peelSign(spine: spine, rtl: rtl, forward: forward),
                realVerso: columns >= 2,
                reversed: PageCurlGeometry.playsReversed(renderedColumns: columns, forward: forward),
                duration: style == .slide ? PageSlideGeometry.tapDuration : PageCurlGeometry.tapDuration
            )
            let beyondImage = await beyond.value
            if let generation, curlHostAttached, running(),
               abs(scrollView.contentOffset.x - target) <= 2
            {
                curlTapDidLand?(PageCurlLandedPages(
                    outgoing: outgoing,
                    incoming: shot,
                    beyond: beyondImage,
                    forward: forward,
                    generation: generation
                ))
            }
        }
    }

    /// False once the spread has left the window or the app is in the background.
    /// A curl that continues from there submits GPU work to a detached layer.
    private var curlHostAttached: Bool {
        window != nil && superview != nil && UIApplication.shared.applicationState != .background
    }

    /// Same column step `go(to:)` scrolls. Nil on the first or last column,
    /// where the navigator turns to the neighbour resource instead.
    override func canGo(to direction: Direction) -> Bool {
        pageDelta(for: direction) != nil
    }

    /// Scrolls one column under the curl cover. The caller has already shown
    /// the outgoing bitmap. Returns the incoming bitmap, or nil if this
    /// resource has no further column.
    func prepareCurlIncoming(direction: Direction, background: UIColor) async -> UIImage? {
        // A cached drag whose session was dropped (reload) left its scroll here.
        await awaitPendingCurlScroll()
        guard let delta = pageDelta(for: direction) else {
            return nil
        }
        curlDelta = delta
        let startOffset = scrollView.contentOffset.x
        curlTargetOffset = startOffset + delta
        setSuppressingProgressionUpdates(true)
        await scrollByAwaitingPaint(delta)
        PageCurlLatency.mark("incoming-scrolled")
        guard var image = await PageCurlSnapshotter.capture(of: self, backgroundColor: background) else {
            await revertCurlIncoming()
            return nil
        }
        PageCurlLatency.mark("incoming-snapshot")
        // `takeSnapshot(afterScreenUpdates:)` drains the run loop. A flick's
        // touch-end lands in that drain and WebKit puts the column back, so
        // the bitmap is the page already showing. Scroll the remaining distance
        // to the absolute column — not another `delta`, which skips a page when
        // the offset is only a few points off. `setContentOffset` snaps this
        // web view back (toolkit #737).
        var corrected = false
        if let target = curlTargetOffset {
            let correction = PageCurlGeometry.curlColumnCorrection(
                offset: scrollView.contentOffset.x,
                target: target
            )
            if correction != 0 {
                await scrollByAwaitingPaint(correction)
                corrected = true
            }
        }
        if corrected,
           let target = curlTargetOffset,
           abs(scrollView.contentOffset.x - target) <= 2,
           let again = await PageCurlSnapshotter.capture(
               of: self,
               backgroundColor: background,
               afterScreenUpdates: false
           )
        {
            image = again
        }
        return image
    }

    /// The incoming bitmap came from the prerender cache. Scroll one column
    /// under the cover without waiting for the paint: nothing reads this
    /// column until commit or cancel, and both wait for the scroll first.
    func beginCurlIncomingScroll(direction: Direction) -> Bool {
        guard pendingCurlScroll == nil, let delta = pageDelta(for: direction) else {
            return false
        }
        curlDelta = delta
        curlTargetOffset = scrollView.contentOffset.x + delta
        setSuppressingProgressionUpdates(true)
        pendingCurlScroll = Task { @MainActor [weak self] in
            await self?.scrollByAwaitingPaint(delta)
            PageCurlLatency.mark("incoming-scrolled-behind")
        }
        return true
    }

    private func awaitPendingCurlScroll() async {
        guard let pending = pendingCurlScroll else {
            return
        }
        await pending.value
        pendingCurlScroll = nil
    }

    /// While a committed leaf springs to rest, the cover still hides the web
    /// view. Step one more column the same way, snapshot it, and step back,
    /// so the next drag in this direction has its page ready. Nil at the end
    /// of the resource, or if the column did not land where expected.
    /// `covered` is false once the leaf's cover is gone (an abort): the web
    /// view is visible again, so no further column may be shown.
    func prerenderCurlBeyond(
        direction: Direction,
        background: UIColor,
        covered: @escaping () -> Bool
    ) async -> UIImage? {
        await awaitPendingCurlScroll()
        guard let target = curlTargetOffset else {
            return nil
        }
        guard let image = await prerenderCurlBeyond(
            direction: direction,
            target: target,
            background: background,
            covered: covered
        ),
              curlTargetOffset == target
        else {
            return nil
        }
        return image
    }

    /// `target` is the column the turn lands on, already scrolled to.
    private func prerenderCurlBeyond(
        direction: Direction,
        target: CGFloat,
        background: UIColor,
        covered: () -> Bool
    ) async -> UIImage? {
        guard curlHostAttached, covered() else {
            return nil
        }
        let onIncoming = PageCurlGeometry.curlColumnCorrection(offset: scrollView.contentOffset.x, target: target)
        if onIncoming != 0 {
            await scrollByAwaitingPaint(onIncoming)
        }
        guard curlHostAttached, covered(),
              abs(scrollView.contentOffset.x - target) <= 2,
              let delta = pageDelta(for: direction)
        else {
            return nil
        }
        await scrollByAwaitingPaint(delta)
        var image: UIImage?
        if curlHostAttached, covered(), abs(scrollView.contentOffset.x - (target + delta)) <= 2 {
            image = await PageCurlSnapshotter.capture(of: self, backgroundColor: background)
            // The snapshot drains the run loop. Keep it only if the column held
            // and the cover was up the whole time.
            if abs(scrollView.contentOffset.x - (target + delta)) > 2 || !covered() {
                image = nil
            }
        }
        let back = PageCurlGeometry.curlColumnCorrection(offset: scrollView.contentOffset.x, target: target)
        if back != 0 {
            await scrollByAwaitingPaint(back)
        }
        return image
    }

    /// Puts the column back and drops the peeked progression. No location event.
    func revertCurlIncoming() async {
        await awaitPendingCurlScroll()
        let delta = curlDelta
        let target = curlTargetOffset
        curlDelta = 0
        curlTargetOffset = nil
        if delta != 0, let target {
            let correction = PageCurlGeometry.curlColumnCorrection(
                offset: scrollView.contentOffset.x,
                target: target - delta
            )
            if correction != 0 {
                await scrollByAwaitingPaint(correction)
            }
        }
        discardSuppressedProgression()
    }

    /// The column is the one the finger committed to. A flick's touch-end can
    /// undo the scroll that was made for the snapshot; do that scroll again
    /// now that the finger is up. Emit the location once.
    func commitCurlIncoming() async {
        await awaitPendingCurlScroll()
        if let target = curlTargetOffset {
            let correction = PageCurlGeometry.curlColumnCorrection(
                offset: scrollView.contentOffset.x,
                target: target
            )
            if correction != 0 {
                await scrollByAwaitingPaint(correction)
            }
        }
        curlTargetOffset = nil
        curlDelta = 0
        setSuppressingProgressionUpdates(false)
    }

    private func pageDelta(for direction: Direction) -> CGFloat? {
        guard !viewModel.scroll else {
            return nil
        }
        guard scrollView.bounds.width > 0 else {
            return nil
        }
        let factor: CGFloat = direction == .left ? -1 : 1
        let offsetX = scrollView.bounds.width * factor
        guard offsetX != 0 else {
            return nil
        }
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard (0 ..< scrollView.contentSize.width).contains(targetX) else {
            return nil
        }
        return offsetX
    }

    /// LTR forward is `.right` (`goForward`). RTL forward is `.left`.
    private func isForward(_ direction: Direction) -> Bool {
        let rtl = viewModel.readingProgression == .rtl
        switch direction {
        case .right:
            return !rtl
        case .left:
            return rtl
        }
    }

    /// Columns WebKit actually laid out. CSS `column-count` stays at the
    /// requested count when `column-width` does not fit, which would slice a
    /// one-column page down the middle. A fixed double spread is already 2.
    override func renderedColumnCount() async -> Int {
        if case .double = spread {
            return 2
        }
        let result = await evaluateScript(
            "(function(){ var cs = getComputedStyle(document.documentElement);"
                + " var cc = parseInt(cs.columnCount, 10); if (isNaN(cc) || cc < 1) { cc = 1; }"
                + " var cw = parseFloat(cs.columnWidth); if (isNaN(cw) || cw < 0) { cw = 0; }"
                + " var gap = parseFloat(cs.columnGap); if (isNaN(gap) || gap < 0) { gap = 0; }"
                + " return [cc, cw, gap, window.innerWidth || 0]; })()"
        )
        guard case let .success(value) = result else {
            return 1
        }
        return PageCurlGeometry.usedColumnCount(parsing: value)
    }

    /// WebKit smooth scroll. Progression is held until the scroll settles so
    /// the turn reports one location.
    private func slide(by offsetX: CGFloat) async {
        setSuppressingProgressionUpdates(true)
        await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: 'smooth' });")
        await waitForScrollAnimation()
        setSuppressingProgressionUpdates(false)
    }

    /// Cross-dissolve. The outgoing page stays up, opaque, until the incoming
    /// column has been scrolled to and painted. Not a fade through blank.
    private func fade(by offsetX: CGFloat) async {
        setSuppressingProgressionUpdates(true)
        let cover = PageTransitionAnimator.makeCover(
            of: self,
            backgroundColor: viewModel.settings.effectiveBackgroundColor.uiColor
        )
        addSubview(cover)
        await scrollByAwaitingPaint(offsetX)
        await PageTransitionAnimator.fade(cover, to: 0, duration: PageTransitionAnimator.fadeDuration)
        cover.removeFromSuperview()
        setSuppressingProgressionUpdates(false)
    }

    private enum PaintScroll: Equatable {
        /// `scrollBy` ran inside the script.
        case painted
        /// The script failed before it could be trusted to have scrolled.
        case failed
        /// The paint wait gave up. The script may still scroll; do not scroll again.
        case timedOut
    }

    private func scrollByAwaitingPaint(_ offsetX: CGFloat) async {
        await scrollAwaitingPaint("window.scrollBy({ left: x, behavior: 'instant' });", x: offsetX)
    }

    private func scrollAwaitingPaint(_ scrollCall: String, x: CGFloat) async {
        // Same retain as `ReadyResume.awaitFirst`. A weak box here never
        // resumes, so the fade cover stays up and the column looks unturned.
        let result: PaintScroll = await ReadyResume.awaitFirst { box in
            Task { @MainActor in
                try? await Task.sleep(seconds: PageTransitionAnimator.paintTimeout)
                box.resume(returning: .timedOut)
            }
            Task { @MainActor in
                do {
                    _ = try await self.webView.callAsyncJavaScript(
                        """
                        document.documentElement.dataset.readiumTransitioning = '1';
                        \(scrollCall)
                        return await new Promise((resolve) => {
                          requestAnimationFrame(() => {
                            requestAnimationFrame(() => resolve(true));
                          });
                        });
                        """,
                        arguments: ["x": x],
                        in: nil,
                        contentWorld: .page
                    )
                    box.resume(returning: .painted)
                } catch {
                    box.resume(returning: .failed)
                }
            }
        }
        // A timeout must not scroll a second time: the script may already have
        // moved by one page, and a fallback `scrollBy` would skip the next one.
        if result == .failed {
            let call = scrollCall.replacingOccurrences(of: "left: x", with: "left: \(x)")
            await evaluateScript(call)
        }
    }

    private func waitForScrollAnimation() async {
        await withCheckedContinuation { continuation in
            let request = ScrollAnimationRequest(continuation)
            pendingScrollAnimation?.resume()
            pendingScrollAnimation = request

            // Safety net in case `scrollDidEnd` never fires. The identity
            // check on `request` ensures a stale timeout from a previous
            // request does not resume a newer one.
            Task { @MainActor in
                try? await Task.sleep(seconds: 0.8)
                scrollDidEnd(for: request)
            }
        }
    }

    private struct PendingLocation {
        var location: PageLocation
        var animated: Bool
    }

    /// Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PendingLocation = .init(location: .start, animated: false)

    override func go(to location: PageLocation, animated: Bool) async {
        ignoreProgressionUntil = 0
        guard isSpreadLoaded else {
            // Delays moving to the location until the document is loaded.
            pendingLocation = PendingLocation(location: location, animated: animated)

            await waitGoToCompletion()
            return
        }

        switch location {
        case let .locator(locator):
            await go(to: locator, animated: animated)
        case .start:
            await scroll(toProgression: 0, animated: animated)
        case .end:
            await scroll(toProgression: 1, animated: animated)
        }

        didCompleteGoTo()
    }

    private func waitGoToCompletion() async {
        await withCheckedContinuation { continuation in
            goToContinuations.append(continuation)
        }
    }

    private func didCompleteGoTo() {
        for cont in goToContinuations {
            cont.resume()
        }
        goToContinuations.removeAll()
    }

    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    private var pendingScrollAnimation: ScrollAnimationRequest?

    /// Represents an in-flight animated page turn, waiting for the scroll
    /// animation to settle before completing.
    private class ScrollAnimationRequest {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Resumes the continuation. Safe to call multiple times; only the
        /// first call has any effect.
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func scrollDidEnd(for request: ScrollAnimationRequest? = nil) {
        guard request == nil || pendingScrollAnimation === request else {
            return
        }
        pendingScrollAnimation?.resume()
        pendingScrollAnimation = nil
    }

    @discardableResult
    private func go(to locator: Locator, animated: Bool) async -> Bool {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                log(.warning, "The locator's href is not in the spread")
                return false
            }
        }

        // A seek that stays on the page already shown must not scroll and
        // must not start a transition. Read Aloud asks for this on every
        // utterance, including one that has not left the column.
        if await isZeroDisplacement(to: locator) {
            return true
        }

        if locator.text.highlight != nil {
            return await scroll(toLocator: locator, animated: animated)
            // TODO: find the first fragment matching a tag ID (need a regex)
        } else if let id = locator.locations.fragments.first, !id.isEmpty {
            return await scroll(toTagID: id, animated: animated)
        } else {
            let progression = locator.locations.progression ?? 0
            return await scroll(toProgression: progression, animated: animated)
        }
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double, animated: Bool) async -> Bool {
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            return true
        } else {
            let dir = viewModel.readingProgression.rawValue
            await evaluateScript("readium.scrollToPosition(\'\(progression)\', \'\(dir)\', \(animated))")
            return true
        }
    }

    /// Scrolls at the tag with ID `tagID`.
    @discardableResult
    private func scroll(toTagID tagID: String, animated: Bool) async -> Bool {
        let result = await evaluateScript("readium.scrollToId(\'\(tagID)\', \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    /// Scrolls at the snippet matching the given text context.
    @discardableResult
    private func scroll(toLocator locator: Locator, animated: Bool) async -> Bool {
        guard let json = try? locator.jsonString() else {
            return false
        }
        let result = await evaluateScript("readium.scrollToLocator(\(json), \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    // MARK: - Progression

    /// Current progression range in the page.
    private var progression: ClosedRange<Double>?
    /// To check if a progression change was cancelled or not.
    private var previousProgression: ClosedRange<Double>?

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        if CACurrentMediaTime() < ignoreProgressionUntil {
            return
        }
        guard
            isSpreadLoaded,
            let body = body as? [String: Any],
            var firstProgression = body["first"] as? Double,
            var lastProgression = body["last"] as? Double
        else {
            return
        }
        precondition(firstProgression <= lastProgression)
        firstProgression = min(max(firstProgression, 0.0), 1.0)
        lastProgression = min(max(lastProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = firstProgression ... lastProgression

        if isSuppressingProgressionUpdates {
            progressionChangedWhileSuppressed = true
            return
        }
        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        scrollDidEnd()
        delegate?.spreadViewPagesDidChange(self)
        logStrideIfDebugging()
    }

    /// One line per settled page. `scrollX` is the paging offset (n × viewport
    /// when the stride holds). `starts` are column origins in document space:
    /// a column-gap between pages makes those origins drift from n × viewport.
    private func logStrideIfDebugging() {
        guard PageCurlDebug.enabled else {
            return
        }
        let offset = scrollView.contentOffset.x
        let viewport = scrollView.bounds.width
        Task { @MainActor in
            let measured = try? await self.webView.evaluateJavaScript(
                """
                (function() {
                  var w = window.innerWidth || 0;
                  var nodes = document.querySelectorAll('p, h1, h2, h3');
                  var starts = [];
                  for (var i = 0; i < nodes.length && starts.length < 8; i++) {
                    var rects = nodes[i].getClientRects();
                    for (var j = 0; j < rects.length && starts.length < 8; j++) {
                      var x = Math.round(rects[j].left + window.scrollX);
                      if (!starts.length || Math.abs(x - starts[starts.length - 1]) > 30) starts.push(x);
                    }
                  }
                  return { scrollX: window.scrollX, inner: w, starts: starts.join(',') };
                })()
                """
            )
            let record = measured as? [String: Any]
            func number(_ value: Any?) -> Double? {
                (value as? NSNumber)?.doubleValue
            }
            let scrollX = number(record?["scrollX"]) ?? Double(offset)
            let inner = number(record?["inner"]) ?? Double(viewport)
            let starts = record?["starts"] as? String ?? ""
            let width = inner > 1 ? inner : Double(viewport)
            let n = width > 1 ? Int((scrollX / width).rounded()) : 0
            let expected = Double(n) * width
            PageCurlDebug.log(
                "stride scrollX=\(String(format: "%.1f", scrollX)) viewport=\(String(format: "%.1f", width)) n=\(n) expected=\(String(format: "%.1f", expected)) delta=\(String(format: "%.1f", scrollX - expected)) starts=\(starts)"
            )
        }
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        if isSuppressingProgressionUpdates || CACurrentMediaTime() < ignoreProgressionUntil {
            return
        }
        setNeedsNotifyPagesDidChange()
    }

    override func setSuppressingProgressionUpdates(_ suppressing: Bool) {
        if suppressing {
            ignoreProgressionUntil = 0
            progressionChangedWhileSuppressed = false
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
            isSuppressingProgressionUpdates = true
            setTransitioningDataset(true)
            return
        }

        isSuppressingProgressionUpdates = false
        setTransitioningDataset(false)
        if progressionChangedWhileSuppressed {
            progressionChangedWhileSuppressed = false
            notifyPagesDidChange()
        }
    }

    /// Cancel path. The column is already back where the gesture started, so
    /// the peeked range must not be reported when suppression lifts.
    private func discardSuppressedProgression() {
        if let previousProgression {
            progression = previousProgression
        }
        self.previousProgression = nil
        progressionChangedWhileSuppressed = false
        isSuppressingProgressionUpdates = false
        setTransitioningDataset(false)
        ignoreProgressionUntil = CACurrentMediaTime() + 0.45
    }

    @objc private func reduceMotionStatusDidChange() {
        isReduceMotionEnabled = UIAccessibility.isReduceMotionEnabled
        if isReduceMotionEnabled {
            scrollDidEnd()
            stopActiveCurl()
        }
    }

    /// Tells the host page's indicator that a hidden scroll is not a user drag.
    /// The flag is a dataset attribute so it does not need a new script bundle.
    private func setTransitioningDataset(_ on: Bool) {
        let script = on
            ? "document.documentElement.dataset.readiumTransitioning = '1';"
            : "delete document.documentElement.dataset.readiumTransitioning;"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// `true` when the locator's snapped column is the one already on screen.
    /// Highlight snippets stay on the existing path: their target is a text
    /// range the script layer finds, and measuring it here would fork that.
    private func isZeroDisplacement(to locator: Locator) async -> Bool {
        // The first `go` runs from `spreadDidLoad`, before `showSpread()`.
        // Column metrics are not real yet: a probe here either hangs the
        // open (the continuation used to be dropped) or reports the origin
        // and skips the scroll that reveals the chapter.
        guard isSpreadReadyForPresentation else {
            return false
        }
        guard !viewModel.scroll, locator.text.highlight == nil else {
            return false
        }

        let fragment = locator.locations.fragments.first { !$0.isEmpty }
        let progression = locator.locations.progression
        guard fragment != nil || progression != nil else {
            return false
        }

        let measured: [String: Any]? = await ReadyResume.awaitFirst { box in
            Task { @MainActor in
                try? await Task.sleep(seconds: PageTransitionAnimator.paintTimeout)
                box.resume(returning: nil)
            }
            Task { @MainActor in
                do {
                    let value = try await self.webView.callAsyncJavaScript(
                        """
                        const style = getComputedStyle(document.documentElement);
                        const rtl = style.direction === 'rtl' || style.writingMode === 'vertical-rl';
                        const viewport = window.innerWidth || 0;
                        const current = window.scrollX;
                        if (elementId) {
                          const el = document.getElementById(elementId);
                          if (!el) return { ok: false };
                          return {
                            ok: true,
                            kind: 'element',
                            current: current,
                            viewport: viewport,
                            raw: el.getBoundingClientRect().left + current,
                            rtl: rtl
                          };
                        }
                        const scrolling = document.scrollingElement;
                        return {
                          ok: true,
                          kind: 'progression',
                          current: current,
                          viewport: viewport,
                          width: scrolling ? scrolling.scrollWidth : 0,
                          rtl: rtl
                        };
                        """,
                        arguments: [
                            "elementId": fragment ?? "",
                            "progression": progression ?? 0,
                        ],
                        in: nil,
                        contentWorld: .page
                    )
                    box.resume(returning: value as? [String: Any])
                } catch {
                    box.resume(returning: nil)
                }
            }
        }

        guard
            let measured,
            (measured["ok"] as? Bool) == true,
            let viewport = jsDouble(measured["viewport"]),
            viewport > 0,
            let current = jsDouble(measured["current"]),
            let rtl = measured["rtl"] as? Bool
        else {
            return false
        }

        let target: Double
        if (measured["kind"] as? String) == "element", let raw = jsDouble(measured["raw"]) {
            target = PageDisplacement.snapOffset(raw, rtl: rtl, viewportWidth: viewport)
        } else if let progression, let width = jsDouble(measured["width"]) {
            target = PageDisplacement.progressionOffset(
                progression: progression,
                documentWidth: width,
                rtl: rtl,
                viewportWidth: viewport
            )
        } else {
            return false
        }
        return PageDisplacement.isZero(current: current, target: target)
    }

    private func jsDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }
}

/// A tap curl that landed inside the resource: the page it left, the page
/// now on screen, and the column past it (nil at the end of the resource).
struct PageCurlLandedPages {
    var outgoing: UIImage
    var incoming: UIImage
    var beyond: UIImage?
    var forward: Bool
    var generation: Int
}
