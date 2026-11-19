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
            ],
            animatedLoad: animatedLoad
        )
    }

    override func clear() {
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
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        let factor: CGFloat = {
            switch direction {
            case .left:
                return -1
            case .right:
                return 1
            }
        }()

        guard scrollView.bounds.width > 0 else { return false }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
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
            await curl(by: offsetX, direction: direction)
        case .slide:
            await slide(by: offsetX)
        case .none:
            await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: 'instant' });")
        }

        return true
    }

    /// Cylinder curl. The outgoing bitmap is up before the column scrolls.
    /// The incoming bitmap is taken after the paint wait, then the leaf lifts.
    /// Progression stays suppressed until the leaf is gone, so the scroll
    /// reports one location.
    private func curl(by offsetX: CGFloat, direction: Direction) async {
        setSuppressingProgressionUpdates(true)
        let background = viewModel.settings.effectiveBackgroundColor.uiColor
        guard let outgoing = await PageCurlSnapshotter.capture(of: self, backgroundColor: background) else {
            setSuppressingProgressionUpdates(false)
            await slide(by: offsetX)
            return
        }

        let columns = await renderedColumnCount()
        let rtl = viewModel.readingProgression == .rtl
        let forward = isForward(direction)
        let spine = PageCurlGeometry.animationSpine(
            renderedColumns: columns,
            rtl: rtl,
            forward: forward,
            divisionNormalizedX: nil
        )
        let curlView = PageCurlView(frame: bounds)
        curlView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curlView.showCover(outgoing, background: background)
        addSubview(curlView)
        defer {
            curlView.releaseResources()
            curlView.removeFromSuperview()
            setSuppressingProgressionUpdates(false)
        }

        await scrollByAwaitingPaint(offsetX)
        let incoming = await PageCurlSnapshotter.capture(of: self, backgroundColor: background) ?? outgoing
        await curlView.runTap(
            outgoing: outgoing,
            incoming: incoming,
            spine: spine,
            peelSign: PageCurlGeometry.peelSign(spine: spine, rtl: rtl, forward: forward),
            realVerso: columns >= 2
        )
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

    /// CSS `column-count` on the root, which is what Readium actually painted.
    /// A fixed double spread is already 2. One column stays an edge curl.
    override func renderedColumnCount() async -> Int {
        if case .double = spread {
            return 2
        }
        let result = await evaluateScript(
            "(function(){ var n = parseInt(getComputedStyle(document.documentElement).columnCount, 10); return (isNaN(n) || n < 1) ? 1 : n; })()"
        )
        guard case let .success(value) = result else {
            return 1
        }
        if let number = value as? NSNumber {
            return max(1, number.intValue)
        }
        return 1
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
                        window.scrollBy({ left: offsetX, behavior: 'instant' });
                        return await new Promise((resolve) => {
                          requestAnimationFrame(() => {
                            requestAnimationFrame(() => resolve(true));
                          });
                        });
                        """,
                        arguments: ["offsetX": offsetX],
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
            await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: 'instant' });")
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
        if isSuppressingProgressionUpdates {
            return
        }
        setNeedsNotifyPagesDidChange()
    }

    override func setSuppressingProgressionUpdates(_ suppressing: Bool) {
        if suppressing {
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

    @objc private func reduceMotionStatusDidChange() {
        isReduceMotionEnabled = UIAccessibility.isReduceMotionEnabled
        if isReduceMotionEnabled {
            scrollDidEnd()
        }
    }

    /// Tells the host page (Kudos's page digit) that a hidden scroll is not a
    /// user drag. The flag is a dataset attribute so it does not need a new
    /// script bundle.
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
