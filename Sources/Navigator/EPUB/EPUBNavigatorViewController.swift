//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumInternal
import ReadiumShared
import SafariServices
import SwiftSoup
import UIKit
import WebKit

@MainActor public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate,
    ViewportObservingNavigatorDelegate
{
    // MARK: - WebView Customization

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController)
}

public extension EPUBNavigatorDelegate {
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {}
}

public typealias EPUBContentInsets = (top: CGFloat, bottom: CGFloat)

open class EPUBNavigatorViewController: InputObservableViewController,
    VisualNavigator, ViewportObservingNavigator, SelectableNavigator,
    DecorableNavigator, Configurable, Loggable
{
    public enum EPUBError: Error {
        /// The provided publication is restricted. Check that any DRM was
        /// properly unlocked using a Content Protection.
        case publicationRestricted

        /// Returned when calling evaluateJavaScript() before a resource is
        /// loaded.
        case spreadNotLoaded

        /// Failed to serve the publication or assets with the provided HTTP
        /// server.
        @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
        case serverFailure(Error)
    }

    public struct Configuration {
        /// Initial set of setting preferences.
        public var preferences: EPUBPreferences

        /// Provides default fallback values and ranges for the user settings.
        public var defaults: EPUBDefaults

        /// Editing actions which will be displayed in the default text selection menu.
        ///
        /// The default set of editing actions is `EditingAction.defaultActions`.
        ///
        /// You can provide custom actions with `EditingAction(title: "Highlight", action: #selector(highlight:))`.
        /// Then, implement the selector in one of your classes in the responder chain. Typically, in the
        /// `UIViewController` wrapping the `EPUBNavigatorViewController`.
        public var editingActions: [EditingAction]

        /// Disables horizontal page turning when scroll is enabled.
        public var disablePageTurnsWhileScrolling: Bool

        /// Content insets used to add some vertical margins around reflowable
        /// EPUB publications. Note that the margins include the safe area
        /// insets. To avoid any "jump" when toggling the status bar, provide
        /// values large enough.
        ///
        /// The insets can be configured for each size class to allow smaller
        /// margins on compact screens.
        ///
        /// For more control, implement the `navigatorContentInset()` delegate
        /// method, which takes precedence over this configuration property
        /// when implemented.
        public var contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]

        /// Number of positions (as in `Publication.positionList`) to preload before the current page.
        public var preloadPreviousPositionCount: Int

        /// Number of positions (as in `Publication.positionList`) to preload after the current page.
        public var preloadNextPositionCount: Int

        /// Supported HTML decoration templates.
        public var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate]

        /// Additional font families which will be available in the preferences.
        public var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]

        /// Readium CSS reading system settings.
        ///
        /// See https://readium.org/readium-css/docs/CSS19-api.html#reading-system-styles
        public var readiumCSSRSProperties: CSSRSProperties

        /// Logs the state changes when true.
        public var debugState: Bool

        public init(
            preferences: EPUBPreferences = .empty,
            defaults: EPUBDefaults = EPUBDefaults(),
            editingActions: [EditingAction] = EditingAction.defaultActions,
            disablePageTurnsWhileScrolling: Bool = false,
            contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
                .compact: (top: 34, bottom: 34),
                .regular: (top: 62, bottom: 62),
            ],
            preloadPreviousPositionCount: Int = 2,
            preloadNextPositionCount: Int = 6,
            decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = HTMLDecorationTemplate.defaultTemplates(),
            fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [],
            readiumCSSRSProperties: CSSRSProperties = CSSRSProperties(),
            debugState: Bool = false
        ) {
            self.preferences = preferences
            self.defaults = defaults
            self.editingActions = editingActions
            self.disablePageTurnsWhileScrolling = disablePageTurnsWhileScrolling
            self.contentInset = contentInset
            self.preloadPreviousPositionCount = preloadPreviousPositionCount
            self.preloadNextPositionCount = preloadNextPositionCount
            self.decorationTemplates = decorationTemplates
            self.fontFamilyDeclarations = fontFamilyDeclarations
            self.readiumCSSRSProperties = readiumCSSRSProperties
            self.debugState = debugState
        }

        func contentInset(for sizeClass: UIUserInterfaceSizeClass) -> EPUBContentInsets {
            contentInset[sizeClass]
                ?? contentInset[.regular]
                ?? contentInset[.unspecified]
                ?? (top: 0, bottom: 0)
        }
    }

    public weak var delegate: EPUBNavigatorDelegate?

    /// Information about the visible portion of the publication, when rendered.
    public private(set) var viewport: NavigatorViewport? {
        didSet {
            if oldValue != viewport {
                delegate?.navigator(self, viewportDidChange: viewport)
            }
        }
    }

    @available(*, deprecated, renamed: "NavigatorViewport")
    public typealias Viewport = NavigatorViewport

    /// Navigation state.
    private enum State: Equatable {
        /// Initializing the navigator.
        case initializing
        /// Loading the spreads at the `pendingLocator`, for example after
        /// changing the user settings, rotating the screen or loading the
        /// publication.
        case loading(pendingLocator: Locator?)
        /// Waiting for further navigation instructions.
        case idle
        /// Jumping to `pendingLocator`.
        case jumping(pendingLocator: Locator)
        /// Turning the page in the given `direction`.
        case moving(direction: EPUBSpreadView.Direction)
        /// A finger is dragging a curl. Location stays unpublished until the
        /// finger commits, so a cancelled peek cannot mark the work finished.
        case interactiveMoving(direction: EPUBSpreadView.Direction)

        var pendingLocator: Locator? {
            switch self {
            case let .loading(pendingLocator: locator):
                return locator
            case let .jumping(pendingLocator: locator):
                return locator
            default:
                return nil
            }
        }

        mutating func transition(_ event: Event) -> Bool {
            switch (self, event) {
            // Loading the spreads is always possible, because it can be triggered by rotating the
            // screen. In which case it cancels any on-going state.
            case let (_, .load(locator)):
                self = .loading(pendingLocator: locator)

            // All events are ignored when loading spreads, except for `loaded` and `load`.
            case (.loading, .loaded):
                self = .idle

            case (.loading, _):
                return false

            case let (.idle, .jump(locator)):
                self = .jumping(pendingLocator: locator)

            case let (.idle, .move(direction)):
                self = .moving(direction: direction)

            case let (.idle, .interactiveMove(direction)):
                self = .interactiveMoving(direction: direction)

            case (.jumping, .jumped):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending jump.
            case (.jumping, .jump),
                 (.jumping, .move),
                 (.jumping, .interactiveMove):
                return false

            case (.moving, .moved):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending move.
            case (.moving, .jump),
                 (.moving, .move),
                 (.moving, .interactiveMove):
                return false

            case (.interactiveMoving, .moved):
                self = .idle

            case (.interactiveMoving, .jump),
                 (.interactiveMoving, .move),
                 (.interactiveMoving, .interactiveMove):
                return false

            default:
                log(.error, "Invalid event \(event) for state \(self)")
                return false
            }

            return true
        }
    }

    /// Navigation event.
    private enum Event: Equatable {
        /// Load the spreads at the given locator, for example after changing
        /// the user settings, rotating the screen or loading the publication.
        case load(Locator?)
        /// The spreads were loaded.
        case loaded
        /// Jump to the given locator.
        case jump(Locator)
        /// Finished jumping to a locator.
        case jumped
        /// Turn the page in the given direction.
        case move(EPUBSpreadView.Direction)
        /// A finger started a curl in the given direction.
        case interactiveMove(EPUBSpreadView.Direction)
        /// Finished turning the page.
        case moved
    }

    /// Current navigation state.
    private var state: State = .initializing {
        didSet {
            if config.debugState {
                log(.debug, "* \(state)")
            }

            // Disable user interaction while transitioning, to avoid UX issues.
            // A finger curl keeps interaction on: turning it off cancels the pan.
            switch state {
            case .initializing, .loading, .jumping, .moving:
                paginationView?.isUserInteractionEnabled = false
            case .idle, .interactiveMoving:
                paginationView?.isUserInteractionEnabled = true
            }
            if case .interactiveMoving = oldValue {
                switch state {
                case .idle, .interactiveMoving:
                    break
                default:
                    curlPan?.abort()
                }
            }
        }
    }

    private let readingOrder: [Link]
    public private(set) var currentLocation: Locator?
    private let loadPositionsByReadingOrder: () async -> ReadResult<[[Locator]]>
    private var positionsByReadingOrder: [[Locator]] = []

    private let viewModel: EPUBNavigatorViewModel
    public var publication: Publication {
        viewModel.publication
    }

    var config: Configuration {
        viewModel.config
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    ///
    /// - Parameters:
    ///   - publication: EPUB publication to render.
    ///   - initialLocation: Starting location in the publication, defaults to
    ///   the beginning.
    ///   - readingOrder: Custom order of resources to display. Used for example
    ///   to display a non-linear resource on its own.
    ///   - config: Additional navigator configuration.
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init()
    ) throws {
        precondition(readingOrder.map { !$0.isEmpty } ?? true)

        guard !publication.isRestricted else {
            throw EPUBError.publicationRestricted
        }

        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: readingOrder ?? publication.readingOrder,
            config: config
        )

        self.init(
            viewModel: viewModel,
            initialLocation: initialLocation,
            readingOrder: viewModel.readingOrder,
            positionsByReadingOrder:
            // Positions and total progression only make sense in the context
            // of the publication's actual reading order. Therefore when
            // provided with a different reading order, we should assume the
            // positions list is empty, and also not compute the
            // totalProgression when calculating the current locator.
            (readingOrder != nil) ? { .success([]) } : publication.positionsByReadingOrder
        )
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init(),
        httpServer: HTTPServer
    ) throws {
        try self.init(
            publication: publication,
            initialLocation: initialLocation,
            readingOrder: readingOrder,
            config: config
        )
    }

    private init(
        viewModel: EPUBNavigatorViewModel,
        initialLocation: Locator?,
        readingOrder: [Link],
        positionsByReadingOrder: @escaping () async -> ReadResult<[[Locator]]>
    ) {
        self.viewModel = viewModel
        currentLocation = initialLocation
        self.readingOrder = readingOrder
        loadPositionsByReadingOrder = positionsByReadingOrder

        super.init(nibName: nil, bundle: nil)

        viewModel.delegate = self
        viewModel.editingActions.delegate = self

        setupLegacyInputCallbacks(
            onTap: { [weak self] point in
                guard let self else { return }
                self.delegate?.navigator(self, didTapAt: point)
            },
            onPressKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didPressKey: event)
            },
            onReleaseKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didReleaseKey: event)
            }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(curlAccessibilityChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(curlAccessibilityChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(releaseCurlPrerender),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        // Will call `accessibilityScroll()` when VoiceOver reaches the end of
        // the current resource. We can use this to go to the next resource.
        view.accessibilityTraits.insert(.causesPageTurn)

        Task {
            await initialize()
        }
    }

    /// A tap curl turns off the pagination view's touches, and the drag's
    /// cover passes nothing on, so a tap mid-turn lands here. It must not
    /// reach the observers as a tap on the page (the host's chrome toggle).
    override func pointerEventToForward(_ event: PointerEvent) -> PointerEvent? {
        switch state {
        case .moving, .interactiveMoving:
            return event.deliveredWhileNavigatorBusy()
        default:
            return event
        }
    }

    private var isActive = true

    @objc private func willResignActive() {
        isActive = false
        // A drag in flight must revert. Leaving it resumes in the background
        // and submits Metal work the GPU will abort.
        curlPan?.abort(keepingCover: true)
        (paginationView?.currentView as? EPUBSpreadView)?.stopActiveCurlForLifecycle()
        invalidateCurlPrerender("resign-active")
    }

    @objc private func didBecomeActive() {
        isActive = true

        // The device may have rotated since the last time the app was active.
        // We may need to refresh the spreads in this situation. Unfortunately,
        // the `viewWillTransition(to:with:)` API is called before we receive
        // the `didBecomeActive` notification, so we cannot rely on it here.
        viewModel.viewSizeWillChange(view.bounds.size)

        if needsReloadSpreadsOnActive {
            needsReloadSpreadsOnActive = false
            reloadSpreads()
        }
    }

    private func initialize() async {
        do {
            positionsByReadingOrder = try await loadPositionsByReadingOrder().get()
        } catch {
            log(.error, DebugError("Failed to load positions.", cause: error))
        }

        paginationView = makePaginationView(
            hasPositions: !positionsByReadingOrder.isEmpty
        )

        paginationView!.frame = view.bounds
        paginationView!.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(paginationView!)

        let pan = PageCurlPanController()
        pan.delegate = self
        pan.attach(to: paginationView!)
        curlPan = pan

        applySettings()

        _reloadSpreads()

        onInitializedCallbacks.complete()
    }

    private let onInitializedCallbacks = CompletionList()

    private func initialized() async {
        await withCheckedContinuation { continuation in
            whenInitialized {
                continuation.resume()
            }
        }
    }

    private func whenInitialized(_ callback: @escaping () -> Void) {
        let callback = onInitializedCallbacks.add(callback)
        if state != .initializing {
            callback()
        }
    }

    @available(iOS 13.0, *)
    override open func buildMenu(with builder: UIMenuBuilder) {
        viewModel.editingActions.buildMenu(with: builder)
        super.buildMenu(with: builder)
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.viewSizeWillChange(view.bounds.size)
    }

    /// Closing the reader frees the curl's cached bitmaps.
    override open func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        invalidateCurlPrerender("disappear")
    }

    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        invalidateCurlPrerender("size")

        // A spring is still this turn. Resizing under it would commit the old
        // page width onto the new spread. The restore waits until the
        // transition's completion, which is after the cover is down: scheduling
        // it from the abort would fire while the bounds are still moving.
        cancelInFlightPageCurls()
        if curlPan?.turnInFlight == true {
            Task { @MainActor in
                await self.curlPan?.abortDrag()
            }
        }
        holdReadingPositionForSizeChange()
        releaseCurlSuppressionIfIdle()

        if isActive {
            viewModel.viewSizeWillChange(size)
        }

        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.reflowPosition.scheduleRestore()
        }
    }

    /// The probe starts before this returns. WebKit still has the old column
    /// layout. A drag uses the element saved while idle: the DOM is the peek.
    private func holdReadingPositionForSizeChange() {
        guard let spread = paginationView?.currentView as? EPUBSpreadView,
              spread.isSpreadReadyForPresentation
        else {
            return
        }
        let turning = curlPan?.turnInFlight == true
        if turning {
            reflowPosition.hold(
                on: spread,
                locator: reflowPosition.resolvedAnchor(on: spread, fallback: currentLocation)
            )
            return
        }
        reflowPosition.hold(on: spread, fallback: currentLocation) { [weak spread] done in
            spread?.startVisibleLocatorProbe(done)
        }
    }

    /// CSS that changes columns or the fold gap. The locator is taken before
    /// the script runs, while the old columns are still on screen.
    private func holdReadingPositionBeforeCSSRelayout(of view: EPUBSpreadView) async {
        guard view === paginationView?.currentView, view.isSpreadReadyForPresentation else {
            return
        }
        if reflowPosition.isHolding {
            return
        }
        cancelInFlightPageCurls()
        if curlPan?.turnInFlight == true {
            reflowPosition.hold(
                on: view,
                locator: reflowPosition.resolvedAnchor(on: view, fallback: currentLocation)
            )
            await curlPan?.abortDrag()
            return
        }
        let visible = await view.findFirstVisibleElementLocator()
        guard view === paginationView?.currentView, !reflowPosition.isHolding else {
            // The tap curl cancelled above kept its suppression for a hold
            // this call no longer takes.
            if view !== paginationView?.currentView {
                view.releaseCurlCancelSuppression()
            }
            releaseCurlSuppressionIfIdle()
            return
        }
        let locator = visible ?? reflowPosition.resolvedAnchor(on: view, fallback: currentLocation)
        reflowPosition.hold(on: view, locator: locator)
    }

    @discardableResult
    private func on(_ event: Event) -> Bool {
        assert(Thread.isMainThread, "Raising navigation events must be done from the main thread")

        if config.debugState {
            log(.debug, "-> on \(event)")
        }

        let wasIdle = state == .idle
        let accepted = state.transition(event)
        if accepted, wasIdle, state != .idle, !openPointers.isEmpty {
            let cancels = openPointers.cancelAll()
            Task {
                for cancel in cancels {
                    _ = await inputObservers.didReceive(cancel)
                }
            }
        }
        if accepted {
            switch anchorNavigation(for: event) {
            case .load, .jump:
                reflowPosition.discardSettledAnchor()
            case .move, .interactiveMove:
                reflowPosition.dropInFlightSettledProbe()
            default:
                break
            }
            if anchorNavigation(for: event).cancelsPendingRestore {
                reflowPosition.cancelForNavigation()
            }
        }
        return accepted
    }

    private func anchorNavigation(for event: Event) -> ReflowAnchorNavigation {
        switch event {
        case .load:
            return .load
        case .loaded:
            return .loaded
        case .jump:
            return .jump
        case .jumped:
            return .jumped
        case .move:
            return .move
        case .interactiveMove:
            return .interactiveMove
        case .moved:
            return .moved
        }
    }

    /// Mapping between reading order hrefs and the table of contents title.
    private var tableOfContentsTitleByHref: [AnyURL: String] {
        get async { await tableOfContentsTitleByHrefTask.value }
    }

    private lazy var tableOfContentsTitleByHrefTask: Task<[AnyURL: String], Never> = Task {
        func fulfill(linkList: [Link]) -> [AnyURL: String] {
            var result = [AnyURL: String]()

            for link in linkList {
                if let title = link.title {
                    result[link.url()] = title
                }
                let subResult = fulfill(linkList: link.children)
                result.merge(subResult) { current, _ -> String in
                    current
                }
            }
            return result
        }

        guard let toc = try? await publication.tableOfContents().get() else {
            return [:]
        }

        return fulfill(linkList: toc)
    }

    /// Goes to the next or previous page in the given scroll direction.
    private func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard
            let paginationView = paginationView,
            on(.move(direction))
        else {
            return false
        }

        let generation = paginationView.turnGeneration
        if
            let spreadView = paginationView.currentView as? EPUBSpreadView,
            await spreadView.go(to: direction, options: options)
        {
            // A reload during the await already moved the state machine on.
            // `.moved` here would close a turn that started after that reload.
            guard paginationView.turnGeneration == generation else {
                return false
            }
            on(.moved)
            return true
        }

        let isRTL = (viewModel.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        let moved: Bool = await {
            switch direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndex(currentSpreadIndex - delta, location: location, options: options)
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndex(currentSpreadIndex + delta, location: location, options: options)
            }
        }()

        guard paginationView.turnGeneration == generation else {
            return false
        }
        on(.moved)
        return moved
    }

    // MARK: - Pagination and spreads

    private var paginationView: PaginationView?
    private var curlPan: PageCurlPanController?
    /// Spread and reload generation captured when the finger curl began.
    /// Commit and cancel no-op once a reload has replaced that spread.
    private var curlSessionGeneration: UInt = 0
    private weak var curlSessionSpread: EPUBSpreadView?
    /// Neighbour bitmaps for the next drag, taken under the previous turn's
    /// leaf. See `PageCurlPrerenderCache`.
    private var curlPrerender = PageCurlPrerenderCache()
    /// Bumped by every change that can alter a page's pixels. A bitmap taken
    /// under an older generation is never stored or shown from the cache.
    private var curlContentGeneration = 0
    /// The page under the finger at the latest touch-down, taken before the
    /// pan is recognised. Dropped when that touch turns out to be a tap.
    private var curlTouchDownShot: Task<CurlPageShot?, Never>?
    /// This drag's pages and the generation they belong to.
    private var curlDragOutgoing: CurlPageShot?
    private var curlDragIncoming: UIImage?
    private var curlDragBeyond: UIImage?
    private var curlDragGeneration = 0
    private let reflowPosition = ReflowPositionKeeper()
    private var foldGapRequests = LatestRequest()
    private var openPointers = OpenPointerSequences()

    private func makePaginationView(hasPositions: Bool) -> PaginationView {
        let view = PaginationView(
            frame: .zero,
            preloadPreviousPositionCount: hasPositions ? config.preloadPreviousPositionCount : 0,
            preloadNextPositionCount: hasPositions ? config.preloadNextPositionCount : 0,
            isScrollEnabled: isPaginationViewScrollingEnabled
        )
        view.delegate = self
        view.backgroundColor = .clear
        return view
    }

    private func invalidatePaginationView() {
        guard let paginationView = paginationView else {
            return
        }

        paginationView.isScrollEnabled = isPaginationViewScrollingEnabled
        reloadSpreads()
    }

    private var spreads: [EPUBSpread] = []

    /// Index of the currently visible spread.
    private var currentSpreadIndex: Int {
        paginationView?.currentIndex ?? 0
    }

    private var needsReloadSpreadsOnActive = false

    private func reloadSpreads() {
        guard
            state != .initializing,
            isViewLoaded
        else {
            return
        }

        guard isActive else {
            // If we reload the spreads while the app is in the background, the
            // web view will reset to progression 0 instead of the current one.
            // We need to wait for the application to return to the foreground
            // to maintain the current location.
            needsReloadSpreadsOnActive = true
            return
        }

        _reloadSpreads()
    }

    private func _reloadSpreads() {
        invalidateCurlPrerender("reload")
        // The held spread is about to be destroyed. Leaving the hold set
        // blocks a later hold on the new spread, and the restore never runs.
        reflowPosition.cancelForNavigation()
        let locator = currentLocation

        guard
            let paginationView = paginationView,
            on(.load(locator))
        else {
            return
        }

        spreads = EPUBSpread.makeSpreads(
            for: publication,
            readingOrder: readingOrder,
            readingProgression: viewModel.readingProgression,
            spread: viewModel.spreadEnabled,
            offsetFirstPage: viewModel.offsetFirstPage
        )

        let initialIndex: ReadingOrder.Index = {
            if
                let href = locator?.href,
                let index = readingOrder.firstIndexWithHREF(href),
                let foundIndex = self.spreads.firstIndexWithReadingOrderIndex(index)
            {
                return foundIndex
            } else {
                return 0
            }
        }()

        paginationView.reloadAtIndex(
            initialIndex,
            location: PageLocation(locator),
            pageCount: spreads.count,
            readingProgression: viewModel.readingProgression
        )

        on(.loaded)
    }

    private func loadedSpreadViewForHREF<T: URLConvertible>(_ href: T) -> EPUBSpreadView? {
        guard
            let loadedViews = paginationView?.loadedViews,
            let index = readingOrder.firstIndexWithHREF(href)
        else {
            return nil
        }

        return loadedViews
            .compactMap { _, view in view as? EPUBSpreadView }
            .first { $0.spread.contains(index: index) }
    }

    // MARK: - Navigator

    private var interactiveCurlEnabled: Bool {
        PageCurlPanStateMachine.allowsInteractiveCurl(
            preference: settings.pageTransition,
            scrolls: settings.scroll,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning
        )
    }

    private var isPaginationViewScrollingEnabled: Bool {
        !(config.disablePageTurnsWhileScrolling && settings.scroll) && !interactiveCurlEnabled
    }

    public var presentation: VisualNavigatorPresentation {
        VisualNavigatorPresentation(
            readingProgression: settings.readingProgression,
            scroll: settings.scroll,
            axis: (settings.scroll && !settings.verticalText)
                ? .vertical
                : .horizontal
        )
    }

    private func computeCurrentLocationAndViewport() async -> (Locator?, NavigatorViewport?) {
        if case .initializing = state {
            assertionFailure("Cannot update current location when initializing the navigator")
            return (nil, nil)
        }

        // Returns any pending locator to prevent returning invalid locations
        // while loading it.
        if let pendingLocator = state.pendingLocator {
            return (pendingLocator, nil)
        }

        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return (nil, nil)
        }

        let (locator, viewport) = await EPUBViewportAndLocationCalculator.compute(
            readingOrderIndices: spreadView.spread.readingOrderIndices,
            progression: { spreadView.progression(in: $0) },
            readingOrder: readingOrder,
            positionsByReadingOrder: positionsByReadingOrder,
            tableOfContentsTitleByHref: tableOfContentsTitleByHref,
            fallbackLocator: { [publication] in await publication.locate($0) }
        )
        return (locator, viewport)
    }

    public func firstVisibleElementLocator() async -> Locator? {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        return await spreadView.findFirstVisibleElementLocator()
    }

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?

    private lazy var updateCurrentLocation = execute(
        // If we're not in an `idle` state, we postpone the notification.
        when: { [weak self] in self?.state == .idle },
        pollingInterval: 0.1
    ) { [weak self] in
        guard let self = self else {
            return
        }

        (currentLocation, viewport) = await computeCurrentLocationAndViewport()

        if
            let delegate = delegate,
            let location = currentLocation,
            location != notifiedCurrentLocation
        {
            notifiedCurrentLocation = location
            delegate.navigator(self, locationDidChange: location)
        }
        if state == .idle {
            reflowPosition.noteSettledLocation(
                on: paginationView?.currentView as? EPUBSpreadView
            )
        }
    }

    public func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        let locator = publication.normalizeLocator(locator)

        guard
            let paginationView = paginationView,
            let index = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(index),
            on(.jump(locator))
        else {
            return false
        }

        let success = await paginationView.goToIndex(spreadIndex, location: .locator(locator), options: options)
        on(.jumped)
        if success {
            delegate?.navigator(self, didJumpTo: locator)
        }
        return success
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        guard let locator = await publication.locate(link) else {
            return false
        }
        return await go(to: locator, options: options)
    }

    @discardableResult
    public func goForward(options: NavigatorGoOptions) async -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .right
            case .rtl:
                return .left
            }
        }()
        return await go(to: direction, options: options)
    }

    @discardableResult
    public func goBackward(options: NavigatorGoOptions) async -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .left
            case .rtl:
                return .right
            }
        }()
        return await go(to: direction, options: options)
    }

    // MARK: - SelectableNavigator

    public var currentSelection: Selection? {
        viewModel.editingActions.selection
    }

    public func clearSelection() {
        guard let paginationView = paginationView else {
            return
        }

        for (_, pageView) in paginationView.loadedViews {
            (pageView as? EPUBSpreadView)?.webView.clearSelection()
        }
    }

    // MARK: - DecorableNavigator

    private var decorations: [DecorationGroup: [DiffableDecoration]] = [:]

    /// Decoration group callbacks, indexed by the group name.
    private var decorationCallbacks: [DecorationGroup: [DecorableNavigator.OnActivatedCallback]] = [:]

    /// Pending decoration tasks, indexed by group name. Stored to allow
    /// cancellation when a new `apply(decorations:in:)` call supersedes a
    /// previous one.
    private var decorationTasks: [DecorationGroup: Task<Void, Never>] = [:]

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        config.decorationTemplates.keys.contains(style)
    }

    public func apply(decorations: [Decoration], in group: DecorationGroup) {
        decorationTasks[group]?.cancel()
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            defer {
                if let self, self.decorationTasks[group] == task {
                    self.decorationTasks[group] = nil
                }
            }
            guard let self else { return }
            await self.initialized()

            guard
                !Task.isCancelled,
                let paginationView = self.paginationView
            else {
                return
            }

            var changed = false
            await withTaskGroup(of: Void.self) { tasks in
                guard !Task.isCancelled else { return }

                let source = self.decorations[group] ?? []
                let target = decorations.map {
                    var d = $0
                    d.locator = self.publication.normalizeLocator(d.locator)
                    return DiffableDecoration(decoration: d)
                }
                self.decorations[group] = target
                if source != target {
                    changed = true
                    self.invalidateCurlPrerender("decorations")
                }

                if decorations.isEmpty {
                    for (_, pageView) in paginationView.loadedViews {
                        tasks.addTask {
                            guard !Task.isCancelled else { return }
                            await (pageView as? EPUBSpreadView)?.evaluateScript(
                                // The updates command are using `requestAnimationFrame()`, so we need it for
                                // `clear()` as well otherwise we might recreate a highlight after it has been
                                // cleared.
                                "requestAnimationFrame(function () { readium.getDecorations('\(group)').clear(); });"
                            )
                        }
                    }
                } else {
                    for (href, changes) in target.changesByHREF(from: source) {
                        guard let script = changes.javascript(forGroup: group, styles: self.config.decorationTemplates) else {
                            continue
                        }
                        tasks.addTask { @MainActor [weak self] in
                            guard
                                !Task.isCancelled,
                                let spreadView = self?.loadedSpreadViewForHREF(href),
                                spreadView.isSpreadLoaded
                            else {
                                return
                            }
                            await spreadView.evaluateScript(script, inHREF: href)
                        }
                    }
                }
            }
            // The scripts draw in `requestAnimationFrame`. A neighbour taken
            // between the first invalidation and that paint is the old page.
            if changed {
                await (self.paginationView?.currentView as? EPUBSpreadView)?.awaitNextPaint()
                self.invalidateCurlPrerender("decorations-painted")
            }
        }
        decorationTasks[group] = task
    }

    public func observeDecorationInteractions(inGroup group: DecorationGroup, onActivated: @escaping OnActivatedCallback) {
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            await withTaskGroup(of: Void.self) { tasks in
                for (_, view) in paginationView.loadedViews {
                    tasks.addTask {
                        await (view as? EPUBSpreadView)?.evaluateScript("readium.getDecorations('\(group)').setActivable();")
                    }
                }
            }
        }
    }

    // MARK: - Configurable

    public var settings: EPUBSettings {
        viewModel.settings
    }

    public func submitPreferences(_ preferences: EPUBPreferences) {
        invalidateCurlPrerender("preferences")
        viewModel.submitPreferences(preferences)
        applySettings()

        delegate?.navigator(self, presentationDidChange: presentation)
    }

    public func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        viewModel.editor(of: preferences)
    }

    /// Applies user settings that require native configuration instead of
    /// CSS properties.
    private func applySettings() {
        guard isViewLoaded else {
            return
        }

        view.backgroundColor = settings.effectiveBackgroundColor.uiColor
        let curl = interactiveCurlEnabled
        paginationView?.isScrollEnabled = isPaginationViewScrollingEnabled
        paginationView?.pageTransition = settings.pageTransition
        paginationView?.scrolls = settings.scroll
        paginationView?.transitionBackgroundColor = settings.effectiveBackgroundColor.uiColor
        curlPan?.isEnabled = curl
        applySpreadPanPolicy(interactiveCurl: curl)
        if settings.pageTransition == .curl {
            PageCurlView.prewarm()
        }
    }

    /// Reflowable paging pans are off while the curl recognizer owns the drag.
    /// Fixed layout keeps its pan so a zoomed page can still move. Slide, fade
    /// and none leave both pans alone.
    private func applySpreadPanPolicy(interactiveCurl: Bool) {
        guard let loaded = paginationView?.loadedViews else {
            return
        }
        for (_, view) in loaded {
            applySpreadPanPolicy(interactiveCurl: interactiveCurl, to: view)
        }
    }

    /// A spread's own pan is on from the moment the web view exists. Curl has
    /// to turn it off here, not after `spreadViewDidLoad`, or the first drag
    /// slides the column instead of lifting the page.
    private func applySpreadPanPolicy(interactiveCurl: Bool, to view: UIView) {
        guard let spread = view as? EPUBSpreadView else {
            return
        }
        let blockPan = interactiveCurl && !(spread is EPUBFixedSpreadView)
        spread.scrollView.panGestureRecognizer.isEnabled = !blockPan
    }

    @objc private func curlAccessibilityChanged() {
        if !interactiveCurlEnabled {
            curlPan?.abort(keepingCover: true)
        }
        invalidateCurlPrerender("accessibility")
        applySettings()
    }

    @objc private func releaseCurlPrerender() {
        invalidateCurlPrerender("memory")
    }

    /// Anything that may change what a page looks like, and the reader
    /// leaving the screen. Frees the bitmaps and the preloaded textures.
    private func invalidateCurlPrerender(_ reason: String) {
        curlContentGeneration &+= 1
        if PageCurlDebug.enabled, !curlPrerender.isEmpty || curlTouchDownShot != nil {
            PageCurlDebug.log("curl-cache invalidate reason=\(reason) bytes=\(curlPrerender.byteCount)")
        }
        curlPrerender.invalidate()
        cancelCurlTouchDownShot()
        PageCurlView.dropPreloadedTextures()
    }

    /// The shot's task checks for this before it uploads anything, so a
    /// snapshot that resolves after the drop does not refill the preloads.
    private func cancelCurlTouchDownShot() {
        curlTouchDownShot?.cancel()
        curlTouchDownShot = nil
    }

    // MARK: - EPUB-specific extensions

    /// Evaluates the given JavaScript on the currently visible HTML resource.
    @discardableResult
    public func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return .failure(EPUBError.spreadNotLoaded)
        }
        let result = await spreadView.evaluateScript(script)
        // The host's script may have changed any page. Bumping the generation
        // afterwards also drops a neighbour taken while it was running.
        invalidateCurlPrerender("script")
        return result
    }

    // MARK: - UIAccessibilityAction

    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !super.accessibilityScroll(direction) else {
            return true
        }

        let options = NavigatorGoOptions(animated: false)

        Task {
            switch direction {
            case .right:
                await goLeft(options: options)
            case .left:
                await goRight(options: options)
            case .next, .down:
                await goForward(options: options)
            case .previous, .up:
                await goBackward(options: options)
            @unknown default:
                break
            }
        }
        return true
    }
}

extension EPUBNavigatorViewController: EPUBNavigatorViewModelDelegate {
    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {
        invalidatePaginationView()
    }

    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, runScript script: String, in scope: EPUBScriptScope) {
        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            // Font size and theme commit through `readium.setCSSProperties`,
            // which reflows the columns without reloading the spread.
            let relayouts = script.contains("readium.setCSSProperties(")

            func run(_ view: EPUBSpreadView, href: AnyURL? = nil) async {
                if relayouts {
                    await self.holdReadingPositionBeforeCSSRelayout(of: view)
                }
                await view.evaluateScript(script, inHREF: href)
                // The preferences invalidated before the script ran; a
                // neighbour taken while it was in flight shows the old CSS.
                await MainActor.run {
                    self.invalidateCurlPrerender("script-applied")
                }
                if relayouts {
                    // The script task is not on the main actor. The flag lives
                    // on the spread view, which is.
                    await MainActor.run {
                        view.settlePresentationAfterRelayout()
                        if view === self.paginationView?.currentView {
                            self.reflowPosition.scheduleRestore()
                        }
                    }
                }
            }

            switch scope {
            case .currentResource:
                if let view = paginationView.currentView as? EPUBSpreadView {
                    await run(view)
                }

            case .loadedResources:
                await withTaskGroup(of: Void.self) { tasks in
                    for (_, view) in paginationView.loadedViews {
                        tasks.addTask {
                            guard let view = view as? EPUBSpreadView else {
                                return
                            }
                            await run(view)
                        }
                    }
                }

            case let .resource(href):
                for (_, view) in paginationView.loadedViews {
                    guard
                        let view = view as? EPUBSpreadView,
                        let index = readingOrder.firstIndexWithHREF(href),
                        view.spread.contains(index: index)
                    else {
                        continue
                    }
                    await run(view, href: href)
                    return
                }
            }
        }
    }

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        DispatchQueue.main.async {
            self.delegate?.navigator(self, didFailToLoadResourceAt: href, withError: error)
        }
    }
}

extension EPUBNavigatorViewController: EPUBSpreadViewDelegate {
    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets {
        if let inset = delegate?.navigatorContentInset(self) {
            return inset
        }

        // We use the window's safeAreaInsets instead of the view's because we
        // only want to take into account the device notch and status bar, not
        // the application's bars.
        var insets = view.window?.safeAreaInsets ?? .zero

        switch publication.metadata.epubLayout {
        case .fixed:
            // With iPadOS and macOS, we aim to display content edge-to-edge
            // since there are no physical notches or Dynamic Island like on the
            // iPhone.
            if UIDevice.current.userInterfaceIdiom != .phone {
                insets = .zero
            }

        case .reflowable:
            let configInset = config.contentInset(for: view.traitCollection.verticalSizeClass)
            insets.top = max(insets.top, configInset.top)
            insets.bottom = max(insets.bottom, configInset.bottom)
        }

        return insets
    }

    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async {
        invalidateCurlPrerender("spread-load")
        let templates = config.decorationTemplates.reduce(into: [String: JSONValue]()) { styles, item in
            styles[item.key.rawValue] = .object(item.value.jsonObject)
        }

        guard let stylesJSON = try? templates.jsonString() else {
            log(.error, "Can't serialize decoration styles to JSON")
            return
        }
        var script = "readium.registerDecorationTemplates(\(stylesJSON.replacingOccurrences(of: "\\n", with: " ")));\n"

        script += decorationCallbacks
            .compactMap { group, callbacks in
                guard !callbacks.isEmpty else {
                    return nil
                }
                return "readium.getDecorations('\(group)').setActivable();"
            }
            .joined(separator: "\n")

        let links = spreadView.spread.readingOrderIndices
            .compactMap { readingOrder.getOrNil($0) }

        for link in links {
            let href = link.url()
            for (group, decorations) in decorations {
                let decorations = decorations
                    .filter { $0.decoration.locator.href.isEquivalentTo(href) }
                    .map { DecorationChange.add($0.decoration) }

                guard let decorationsScript = decorations.javascript(forGroup: group, styles: config.decorationTemplates) else {
                    continue
                }
                script += decorationsScript
            }
        }

        await spreadView.evaluateScript("(function() {\n\(script)\n})();")
        // Settings already applied the pan policy when this spread was created.
        // Applying them again re-enables the pagination scroll under a slide.
        applySpreadPanPolicy(interactiveCurl: interactiveCurlEnabled, to: spreadView)
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {
        // A finger curl moves the state off `.idle` between its own touch's
        // down and up. The up must still reach the observers, as a cancel.
        let delivered = state == .idle ? event : event.deliveredWhileNavigatorBusy()
        if PageCurlDebug.enabled, event.phase != .move || state != .idle {
            PageCurlDebug.log("pointer \(event.phase) id=\(event.pointer.id) state=\(state) \(delivered.map { "delivered \($0.phase)" } ?? "dropped")")
        }
        guard let delivered else {
            return
        }
        if state == .idle, delivered.phase == .up || delivered.phase == .cancel {
            dropCurlTouchDownShot()
        }
        openPointers.note(delivered)
        Task {
            var event = delivered
            event.location = view.convert(event.location, from: spreadView)
            if let targetElement = event.targetElement {
                event.targetElement?.frame = view.convert(targetElement.frame, from: spreadView)
            }
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {
        Task {
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        guard state == .idle else { return }

        delegate?.navigator(self, presentExternalURL: url)
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {
        guard state == .idle else {
            return
        }
        guard
            let url = AnyURL(string: href),
            var link = publication.linkWithHREF(url)
        else {
            log(.warning, "Cannot find link with HREF: \(href)")
            return
        }
        link.href = href

        // Check to see if this was a noteref link and give delegate the opportunity to display it.
        if
            let clickEvent = clickEvent,
            let interactive = clickEvent.interactiveElement,
            let (note, referrer) = getNoteData(anchor: interactive, href: href),
            let delegate = delegate
        {
            if !delegate.navigator(
                self,
                shouldNavigateToNoteAt: link,
                content: note,
                referrer: referrer
            ) {
                return
            }
        }

        // Ask if we should navigate to the link
        if let delegate = delegate, !delegate.navigator(self, shouldNavigateToLink: link) {
            return
        }

        Task {
            await go(to: link)
        }
    }

    /// Checks if the internal link is a noteref, and retrieves both the referring text of the link and the body of the note.
    ///
    /// Uses the navigation href from didTapOnInternalLink because it is normalized to a path within the book,
    /// whereas the anchor tag may have just a hash fragment like `#abc123` which is hard to work with.
    /// We do at least validate to ensure that the two hrefs match.
    ///
    /// Uses `#id` when retrieving the body of the note, not `aside#id` because it may be a `<section>`.
    /// See https://idpf.github.io/epub-vocabs/structure/#footnotes
    /// and http://kb.daisy.org/publishing/docs/html/epub-type.html#ex
    func getNoteData(anchor: String, href: String) -> (String, String)? {
        do {
            let doc = try parse(anchor)
            guard let link = try doc.select("a[epub:type=noteref]").first() else { return nil }

            let anchorHref = try link.attr("href")
            guard href.hasSuffix(anchorHref) else { return nil }

            let hashParts = href.split(separator: "#")
            guard hashParts.count == 2 else {
                log(.warning, "Could not find hash in link \(href)")
                return nil
            }
            let id = String(hashParts[1])
            var withoutFragment = String(hashParts[0])
            if withoutFragment.hasPrefix("/") {
                withoutFragment = String(withoutFragment.dropFirst())
            }

            guard
                let url = RelativeURL(string: withoutFragment),
                let absolute = viewModel.publicationBaseURL.resolve(url)
            else {
                log(.warning, "Invalid URL: \(withoutFragment)")
                return nil
            }

            log(.debug, "Fetching note contents from \(absolute.string)")
            let contents = try String(contentsOf: absolute.url)
            let document = try parse(contents)

            guard let aside = try document.select("#\(id)").first() else {
                log(.warning, "Could not find the element '#\(id)' in document \(absolute)")
                return nil
            }

            return try (aside.html(), link.html())

        } catch {
            log(.warning, "Caught error while getting note content: \(error)")
            return nil
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?) {
        guard state == .idle else {
            return
        }
        guard
            let callbacks = decorationCallbacks[group].takeIf({ !$0.isEmpty }),
            let decoration: Decoration = decorations[group]?
            .first(where: { $0.decoration.id == id })
            .map(\.decoration)
        else {
            return
        }

        for callback in callbacks {
            callback(OnDecorationActivatedEvent(decoration: decoration, group: group, rect: frame, point: point))
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect) {
        guard
            let locator = currentLocation,
            let text = text
        else {
            viewModel.editingActions.selection = nil
            return
        }
        viewModel.editingActions.selection = Selection(
            locator: locator.copy(text: { $0 = text }),
            frame: frame
        )
    }

    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        if paginationView?.currentView == spreadView {
            updateCurrentLocation()
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

    func spreadViewDidTerminate() {
        reloadSpreads()
    }
}

extension EPUBNavigatorViewController: EditingActionsControllerDelegate {
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
    }

    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
        delegate?.navigator(self, shouldShowMenuForSelection: selection) ?? true
    }

    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        delegate?.navigator(self, canPerformAction: action, for: selection) ?? true
    }
}

extension EPUBNavigatorViewController: PaginationViewDelegate {
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
        let spread = spreads[index]
        let spreadViewType = (publication.metadata.layout == .fixed) ? EPUBFixedSpreadView.self : EPUBReflowableSpreadView.self
        let spreadView = spreadViewType.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [],
            animatedLoad: false
        )
        spreadView.delegate = self
        applySpreadPanPolicy(interactiveCurl: interactiveCurlEnabled, to: spreadView)
        if let reflow = spreadView as? EPUBReflowableSpreadView {
            reflow.curlContentGeneration = { [weak self] in self?.curlContentGeneration ?? -1 }
            reflow.curlTapDidLand = { [weak self, weak reflow] pages in
                guard let self, let reflow else {
                    return
                }
                self.storeTapCurlPages(pages, on: reflow)
            }
        }

        let userContentController = spreadView.webView.configuration.userContentController
        delegate?.navigator(self, setupUserScripts: userContentController)

        return spreadView
    }

    func paginationViewWillDiscardPages(_ paginationView: PaginationView) {
        curlPan?.abort()
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        invalidateCurlPrerender("views")
        // Note that you should set the delegate before you load views
        // otherwise, when open the publication, you may miss the first
        // invocation.
        updateCurrentLocation()
        applySettings()
    }

    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int {
        spreads[index].positionCount(in: readingOrder, positionsByReadingOrder: positionsByReadingOrder)
    }

    func paginationView(_ paginationView: PaginationView, divisionDidChange sample: FoldPostureSample) {
        let gap = PageCurlGeometry.columnGapClearingFold(
            defaultGap: 0,
            foldFrame: sample.division,
            viewport: paginationView.bounds
        )
        let x = sample.normalizedX.map { String(format: "%.3f", $0) } ?? "nil"
        log(.info, "fold-posture x=\(x) width=\(String(format: "%.1f", sample.width)) gap=\(String(format: "%.1f", gap)) bounds=\(paginationView.bounds.size)")
        PageCurlDebug.log("fold-posture x=\(x) width=\(String(format: "%.1f", sample.width)) gap=\(String(format: "%.1f", gap)) bounds=\(String(format: "%.0fx%.0f", paginationView.bounds.width, paginationView.bounds.height))")
        foldGapRequests.begin()
        let request = foldGapRequests.latest
        Task { @MainActor in
            await self.applyFoldColumnGap(gap, request: request)
        }
    }

    /// Applies the crease clearance, and keeps the visible element when it
    /// actually changes. A spine-only move (the fold slides, the width does
    /// not) updates `divisionNormalizedX` and leaves the columns alone.
    /// A newer posture report supersedes one still waiting on a drag abort or
    /// the visible-element probe: committing the older clearance after it
    /// would leave the old inset on screen.
    private func applyFoldColumnGap(_ gap: CGFloat, request: Int) async {
        let points: CGFloat? = gap > 0.5 ? gap : nil
        let cancelledOn = paginationView?.currentView as? EPUBSpreadView
        cancelInFlightPageCurls()
        // The tap curl cancelled above kept its suppression for a hold. Every
        // way out that does not take the hold gives it back, on whichever
        // spread it was (a spread not ready for presentation skips the hold).
        var tookHold = false
        defer {
            if !tookHold {
                if let cancelledOn, cancelledOn !== paginationView?.currentView {
                    cancelledOn.releaseCurlCancelSuppression()
                }
                releaseCurlSuppressionIfIdle()
            }
        }
        if curlPan?.turnInFlight == true {
            await curlPan?.abortDrag()
        }
        guard foldGapRequests.isLatest(request), viewModel.noteFoldClearance(points) else {
            return
        }
        invalidateCurlPrerender("fold")
        if let spread = paginationView?.currentView as? EPUBSpreadView,
           spread.isSpreadReadyForPresentation,
           !reflowPosition.isHolding
        {
            let visible = await spread.findFirstVisibleElementLocator()
            guard foldGapRequests.isLatest(request),
                  spread === paginationView?.currentView,
                  viewModel.foldInsetNeedsCommit,
                  !reflowPosition.isHolding
            else {
                if spread !== paginationView?.currentView {
                    spread.releaseCurlCancelSuppression()
                }
                return
            }
            let locator = visible ?? reflowPosition.resolvedAnchor(on: spread, fallback: currentLocation)
            reflowPosition.hold(on: spread, locator: locator)
            tookHold = true
        }
        viewModel.applyFoldColumnGap(points)
        // Only our own hold: a rotation's hold restores when its transition ends.
        if tookHold {
            reflowPosition.scheduleRestore()
        }
    }

    /// Tap curls and the pagination's neighbour curl. A posture change used
    /// to leave those springs running across the new column count.
    private func cancelInFlightPageCurls() {
        (paginationView?.currentView as? EPUBSpreadView)?.cancelActiveCurl()
        paginationView?.cancelActiveCurl()
    }

    /// A curl cancel keeps progression suppression so the hold can own it.
    /// With no hold, that suppression would freeze the page position.
    private func releaseCurlSuppressionIfIdle() {
        guard !reflowPosition.isHolding else {
            return
        }
        paginationView?.releaseCurlCancelSuppression()
        (paginationView?.currentView as? EPUBSpreadView)?.releaseCurlCancelSuppression()
    }
}

extension EPUBNavigatorViewController: PageCurlPanDelegate {
    private var curlSessionCurrent: Bool {
        guard let paginationView, let curlSessionSpread else {
            return false
        }
        return paginationView.turnGeneration == curlSessionGeneration
            && paginationView.currentView === curlSessionSpread
    }

    func curlPanContext(in view: UIView) -> PageCurlPanContext {
        let rtl = viewModel.readingProgression == .rtl
        let spread = paginationView?.currentView as? EPUBSpreadView
        let scale = spread?.scrollView.zoomScale ?? 1
        let minimum = spread?.scrollView.minimumZoomScale ?? 1
        return PageCurlPanContext(
            rtl: rtl,
            viewWidth: view.bounds.width,
            viewHeight: view.bounds.height,
            canGoForward: canCurl(forward: true),
            canGoBackward: canCurl(forward: false),
            hasSelection: currentSelection != nil,
            interactiveCurlEnabled: PageCurlPanStateMachine.allowsInteractiveCurl(
                preference: settings.pageTransition,
                scrolls: settings.scroll,
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                voiceOverRunning: UIAccessibility.isVoiceOverRunning
            ),
            zoomed: scale > minimum + 0.01,
            acceptsGesture: state == .idle
        )
    }

    func curlPanHostView() -> UIView? {
        paginationView
    }

    /// A finger landed while idle. Snapshot the page now, while the pan is
    /// still deciding, and start uploading it and the cached forward
    /// neighbour. Nothing moves and nothing covers the page, so a tap, a
    /// vertical scroll or a selection is unaffected; the shot is dropped when
    /// the touch ends without a drag.
    func curlPanTouchDown() {
        // The last sequence's shot, if its end was never seen, is not this one.
        dropCurlTouchDownShot()
        guard state == .idle, interactiveCurlEnabled, currentSelection == nil,
              let spread = paginationView?.currentView as? EPUBSpreadView,
              spread.isSpreadReadyForPresentation,
              // A zoomed fixed-layout page pans; it does not curl.
              spread.scrollView.zoomScale <= spread.scrollView.minimumZoomScale + 0.01
        else {
            return
        }
        let background = viewModel.settings.effectiveBackgroundColor.uiColor
        let key = curlPageKey(for: spread)
        let forward = curlPrerender.key == key
            ? (try? curlPrerender.neighbor(.forward, key: key, onScreen: curlPrerender.current).get())
            : nil
        curlTouchDownShot = Task { @MainActor [weak spread] in
            guard let spread, let image = await PageCurlSnapshotter.capture(
                of: spread,
                backgroundColor: background,
                afterScreenUpdates: false
            ) else {
                return nil
            }
            // The touch ended, the bitmaps went stale, or the app is resigning
            // or gone: no upload, and nothing for the preloads to keep.
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else {
                return nil
            }
            PageCurlLatency.mark("touch-outgoing")
            PageCurlView.preloadTextures([image] + (forward.map { [$0] } ?? []))
            let fingerprint = await Self.fingerprint(of: image)
            guard !Task.isCancelled else {
                return nil
            }
            return CurlPageShot(image: image, background: background, key: key, fingerprint: fingerprint)
        }
    }

    func curlPanDidBegin(direction: PageCurlTurnDirection) -> Bool {
        let accepted = on(.interactiveMove(spreadDirection(for: direction)))
        if accepted {
            curlSessionGeneration = paginationView?.turnGeneration ?? 0
            curlSessionSpread = paginationView?.currentView as? EPUBSpreadView
            curlDragGeneration = curlContentGeneration
            curlDragOutgoing = nil
            curlDragIncoming = nil
            curlDragBeyond = nil
        }
        return accepted
    }

    func curlPanCaptureOutgoing() async -> (image: UIImage, background: UIColor)? {
        guard let spread = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        // Left in `curlTouchDownShot` while it is awaited, so an invalidation
        // (resign active, memory) can still cancel it before it uploads.
        let pending = curlTouchDownShot
        let pendingShot = await pending?.value
        if let pending, curlTouchDownShot == pending {
            curlTouchDownShot = nil
        }
        // The touch-down shot is this page if nothing moved or changed since.
        if let shot = pendingShot, shot.key == curlPageKey(for: spread) {
            curlDragOutgoing = shot
            return (shot.image, shot.background)
        }
        let background = viewModel.settings.effectiveBackgroundColor.uiColor
        let key = curlPageKey(for: spread)
        guard let image = await PageCurlSnapshotter.capture(
            of: spread,
            backgroundColor: background,
            afterScreenUpdates: false
        ) else {
            return nil
        }
        curlDragOutgoing = CurlPageShot(image: image, background: background, key: key, fingerprint: nil)
        return (image, background)
    }

    func curlPanRevealIncoming(
        direction: PageCurlTurnDirection,
        outgoing: UIImage,
        background: UIColor
    ) async -> PageCurlPanFrame? {
        guard let spread = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        let rtl = viewModel.readingProgression == .rtl
        let forward = direction == .forward
        let columns = await spread.renderedColumnCount()
        PageCurlLatency.mark("columns", "n=\(columns)")
        let divisionX = paginationView?.divisionNormalizedX
        let spine = PageCurlSpine.resolve(
            renderedColumns: columns,
            rtl: rtl,
            divisionNormalizedX: divisionX
        )
        let divisionText = divisionX.map { String(format: "%.3f", $0) } ?? "nil"
        log(.info, "curl-spine columns=\(columns) division=\(divisionText) spine=\(spine) forward=\(forward)")
        PageCurlDebug.log("curl-spine columns=\(columns) division=\(divisionText) spine=\(spine) forward=\(forward)")
        let peel = PageCurlGeometry.peelSign(spine: spine, rtl: rtl, forward: forward)
        let spreadDirection = spreadDirection(for: direction)

        if spread.canGo(to: spreadDirection), let reflow = spread as? EPUBReflowableSpreadView {
            let incoming: UIImage
            if let cached = cachedCurlNeighbor(direction, on: reflow),
               reflow.beginCurlIncomingScroll(direction: spreadDirection)
            {
                incoming = cached
            } else {
                guard let shot = await reflow.prepareCurlIncoming(direction: spreadDirection, background: background) else {
                    return nil
                }
                incoming = shot
            }
            curlDragIncoming = incoming
            return PageCurlPanFrame(
                outgoing: outgoing,
                incoming: incoming,
                background: background,
                spine: spine,
                peelSign: peel,
                realVerso: columns >= 2,
                withinResource: true,
                reversed: PageCurlGeometry.playsReversed(renderedColumns: columns, forward: forward)
            )
        }

        guard let incoming = await paginationView?.captureNeighborForCurl(forward: forward, background: background) else {
            return nil
        }
        return PageCurlPanFrame(
            outgoing: outgoing,
            incoming: incoming,
            background: background,
            spine: spine,
            peelSign: peel,
            realVerso: columns >= 2,
            withinResource: false,
            reversed: PageCurlGeometry.playsReversed(renderedColumns: columns, forward: forward)
        )
    }

    /// Runs while the committed leaf springs to rest: renders the column past
    /// the incoming one under the cover, so the next drag the same way finds it.
    func curlPanPrerenderBeyond(direction: PageCurlTurnDirection, withinResource: Bool) async {
        guard withinResource, curlSessionCurrent, curlDragGeneration == curlContentGeneration,
              let reflow = curlSessionSpread as? EPUBReflowableSpreadView
        else {
            return
        }
        let background = viewModel.settings.effectiveBackgroundColor.uiColor
        let image = await reflow.prerenderCurlBeyond(
            direction: spreadDirection(for: direction),
            background: background,
            covered: { [weak self] in self?.curlPan?.isCovering ?? false }
        )
        PageCurlLatency.mark("prerender-beyond", "ok=\(image != nil)")
        curlDragBeyond = image
    }

    func curlPanCommit(direction: PageCurlTurnDirection, withinResource: Bool) async {
        guard curlSessionCurrent else {
            return
        }
        if withinResource {
            await (curlSessionSpread as? EPUBReflowableSpreadView)?.commitCurlIncoming()
            storeCommittedCurlPages(direction: direction)
            return
        }
        await paginationView?.commitCurlNeighbor(forward: direction == .forward)
    }

    func curlPanCancel(direction: PageCurlTurnDirection, withinResource: Bool) async {
        guard curlSessionCurrent else {
            return
        }
        guard withinResource else {
            // The neighbour index was never changed. `direction` only matters on commit.
            _ = direction
            return
        }
        await (curlSessionSpread as? EPUBReflowableSpreadView)?.revertCurlIncoming()
        storeCancelledCurlPages(direction: direction)
        // The revert clears progression suppression. A posture or size change
        // that aborted this drag has already taken its hold, and the relayout
        // it is about to run must stay suppressed.
        if let spread = curlSessionSpread {
            reflowPosition.reassertSuppression(on: spread)
        }
    }

    func curlPanDidFinish() {
        curlDragOutgoing = nil
        curlDragIncoming = nil
        curlDragBeyond = nil
        if case .interactiveMoving = state {
            on(.moved)
        }
    }

    private func curlPageKey(for spread: EPUBSpreadView) -> PageCurlPageKey {
        PageCurlPageKey(
            spread: ObjectIdentifier(spread),
            offsetX: spread.scrollView.contentOffset.x,
            // The web view, not the spread: a content inset change moves the
            // columns inside the same spread bounds.
            size: spread.webView.bounds.size,
            contentGeneration: curlContentGeneration
        )
    }

    /// The cached neighbour, if it belongs to this column and generation and
    /// the page under the finger still matches the one it was taken next to.
    private func cachedCurlNeighbor(_ direction: PageCurlTurnDirection, on spread: EPUBSpreadView) -> UIImage? {
        guard curlDragGeneration == curlContentGeneration else {
            return nil
        }
        let result = curlPrerender.neighbor(
            direction,
            key: curlPageKey(for: spread),
            onScreen: curlDragOutgoing?.fingerprint
        )
        switch result {
        case let .success(image):
            PageCurlLatency.mark("cache-hit", "direction=\(direction)")
            return image
        case let .failure(miss):
            PageCurlLatency.mark("cache-miss", "direction=\(direction) reason=\(miss)")
            return nil
        }
    }

    /// After a committed turn inside the resource: the incoming page is on
    /// screen, the outgoing page is behind it, and the prerender (if any) is
    /// past it. Nothing is stored if anything changed during the drag.
    private func storeCommittedCurlPages(direction: PageCurlTurnDirection) {
        guard curlDragGeneration == curlContentGeneration,
              let spread = curlSessionSpread,
              let incoming = curlDragIncoming
        else {
            return
        }
        let key = curlPageKey(for: spread)
        let behind = curlDragOutgoing?.image
        let beyond = curlDragBeyond
        curlPrerender.store(
            key: key,
            current: nil,
            forward: direction == .forward ? beyond : behind,
            backward: direction == .forward ? behind : beyond
        )
        fillCurlFingerprint(of: incoming, key: key)
    }

    /// A tap curl landed: same bookkeeping as a committed drag.
    private func storeTapCurlPages(_ pages: PageCurlLandedPages, on spread: EPUBReflowableSpreadView) {
        guard pages.generation == curlContentGeneration, paginationView?.currentView === spread else {
            return
        }
        let key = curlPageKey(for: spread)
        curlPrerender.store(
            key: key,
            current: nil,
            forward: pages.forward ? pages.beyond : pages.outgoing,
            backward: pages.forward ? pages.outgoing : pages.beyond
        )
        fillCurlFingerprint(of: pages.incoming, key: key)
    }

    /// A cancelled drag leaves the outgoing page on screen and has just
    /// rendered the neighbour it peeked at.
    private func storeCancelledCurlPages(direction: PageCurlTurnDirection) {
        guard curlDragGeneration == curlContentGeneration,
              let spread = curlSessionSpread,
              let incoming = curlDragIncoming,
              let outgoing = curlDragOutgoing
        else {
            return
        }
        let key = curlPageKey(for: spread)
        guard key == outgoing.key else {
            return
        }
        curlPrerender.set(incoming, for: direction, key: key, current: outgoing.fingerprint)
        if outgoing.fingerprint == nil {
            fillCurlFingerprint(of: outgoing.image, key: key)
        }
    }

    /// The fingerprint of the page now on screen, computed off the main actor.
    private func fillCurlFingerprint(of image: UIImage, key: PageCurlPageKey) {
        Task { @MainActor [weak self] in
            let fingerprint = await Self.fingerprint(of: image)
            guard let self, let fingerprint else {
                return
            }
            self.curlPrerender.setCurrent(fingerprint, key: key)
            PageCurlDebug.log("curl-cache stored key=\(key.offsetX) bytes=\(self.curlPrerender.byteCount) empty=\(self.curlPrerender.isEmpty)")
        }
    }

    private static func fingerprint(of image: UIImage) async -> PageCurlFingerprint? {
        guard let cgImage = image.cgImage else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            PageCurlFingerprint.of(cgImage)
        }.value
    }

    /// A tap or a scroll ended without a drag: its touch-down shot is unused.
    private func dropCurlTouchDownShot() {
        guard curlTouchDownShot != nil, curlPan?.turnInFlight != true else {
            return
        }
        cancelCurlTouchDownShot()
        PageCurlView.dropPreloadedTextures()
    }

    /// The touch sequence is over and no drag took it: a tap on a link or a
    /// highlight (the web view posts no up for those), a vertical scroll, a
    /// rejected pan.
    func curlPanTouchSequenceEnded() {
        dropCurlTouchDownShot()
    }

    private func canCurl(forward: Bool) -> Bool {
        let direction = spreadDirection(for: forward ? .forward : .backward)
        if let spread = paginationView?.currentView as? EPUBSpreadView, spread.canGo(to: direction) {
            return true
        }
        return paginationView?.hasNeighbor(forward: forward) ?? false
    }

    private func spreadDirection(for turn: PageCurlTurnDirection) -> EPUBSpreadView.Direction {
        let forward = turn == .forward
        let rtl = viewModel.readingProgression == .rtl
        return PageCurlPanStateMachine.spreadGoesRight(forward: forward, rtl: rtl) ? .right : .left
    }
}

/// A page bitmap and what was on screen when it was taken.
private struct CurlPageShot {
    var image: UIImage
    var background: UIColor
    var key: PageCurlPageKey
    var fingerprint: PageCurlFingerprint?
}
