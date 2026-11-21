//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest

class EPUBPageTransitionTests: XCTestCase {
    private func settings(
        preferences: EPUBPreferences = EPUBPreferences(),
        defaults: EPUBDefaults = EPUBDefaults()
    ) -> EPUBSettings {
        EPUBSettings(
            preferences: preferences,
            defaults: defaults,
            metadata: Metadata(title: "Fake title")
        )
    }

    func testPageTransitionDefaultsToSlide() {
        XCTAssertEqual(settings().pageTransition, .slide)
    }

    func testPageTransitionPreferenceBeatsTheDefault() {
        let resolved = settings(
            preferences: EPUBPreferences(pageTransition: .fade),
            defaults: EPUBDefaults(pageTransition: PageTransition.none)
        )
        XCTAssertEqual(resolved.pageTransition, .fade)
    }

    func testPageTransitionFallsBackToTheNavigatorDefault() {
        let resolved = settings(
            preferences: EPUBPreferences(),
            defaults: EPUBDefaults(pageTransition: PageTransition.none)
        )
        XCTAssertEqual(resolved.pageTransition, .none)
    }

    func testPageTransitionIsSharedAcrossPublications() {
        let preferences = EPUBPreferences(language: Language(code: .bcp47("en")), pageTransition: .fade, spread: .always)

        let shared = preferences.filterSharedPreferences()
        XCTAssertEqual(shared.pageTransition, .fade)
        XCTAssertNil(shared.spread)
        XCTAssertNil(shared.language)

        let publication = preferences.filterPublicationPreferences()
        XCTAssertNil(publication.pageTransition)
        XCTAssertEqual(publication.spread, .always)
        XCTAssertEqual(publication.language, preferences.language)
    }

    func testMergingPageTransitionLetsTheOtherValueWin() {
        let base = EPUBPreferences(pageTransition: .slide, scroll: false)
        let over = EPUBPreferences(pageTransition: .fade)

        XCTAssertEqual(base.merging(over).pageTransition, .fade)
        XCTAssertEqual(base.merging(over).scroll, false)
        XCTAssertEqual(over.merging(EPUBPreferences()).pageTransition, .fade)
    }

    func testMissingPageTransitionDecodesAsUnset() throws {
        let decoded = try JSONDecoder().decode(EPUBPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.pageTransition)

        let encoded = try JSONEncoder().encode(EPUBPreferences(pageTransition: .curl))
        let roundTripped = try JSONDecoder().decode(EPUBPreferences.self, from: encoded)
        XCTAssertEqual(roundTripped.pageTransition, .curl)
    }

    func testPageTransitionIsIneffectiveWhileScrollingOrInVerticalText() {
        let scrolled = EPUBPreferencesEditor(
            initialPreferences: EPUBPreferences(scroll: true),
            metadata: Metadata(title: "Fake title"),
            defaults: EPUBDefaults()
        )
        XCTAssertFalse(scrolled.pageTransition.isEffective)
        XCTAssertEqual(scrolled.pageTransition.effectiveValue, .slide)

        let vertical = EPUBPreferencesEditor(
            initialPreferences: EPUBPreferences(verticalText: true),
            metadata: Metadata(title: "Fake title"),
            defaults: EPUBDefaults()
        )
        XCTAssertFalse(vertical.pageTransition.isEffective)

        let paged = EPUBPreferencesEditor(
            initialPreferences: EPUBPreferences(pageTransition: .fade, scroll: false),
            metadata: Metadata(title: "Fake title"),
            defaults: EPUBDefaults()
        )
        XCTAssertTrue(paged.pageTransition.isEffective)
        XCTAssertEqual(paged.pageTransition.effectiveValue, .fade)
        XCTAssertEqual(paged.pageTransition.supportedValues, [.none, .slide, .fade, .curl])
    }

    func testEffectivenessMatchesScrollAndVoiceOver() {
        XCTAssertTrue(PageTransitionPolicy.isEffective(scroll: false, voiceOverRunning: false))
        XCTAssertFalse(PageTransitionPolicy.isEffective(scroll: true, voiceOverRunning: false))
        XCTAssertFalse(PageTransitionPolicy.isEffective(scroll: false, voiceOverRunning: true))
        XCTAssertFalse(PageTransitionPolicy.isEffective(scroll: true, voiceOverRunning: true))
    }

    func testResolveGates() {
        func resolve(
            preference: PageTransition = .fade,
            animated: Bool = true,
            reduceMotion: Bool = false,
            scrolls: Bool = false,
            voiceOverRunning: Bool = false,
            resourceDistance: Int? = nil,
            overrideRaw: String? = nil
        ) -> PageTransition {
            PageTransitionPolicy.resolve(PageTransitionPolicy.Request(
                preference: preference,
                animated: animated,
                reduceMotion: reduceMotion,
                scrolls: scrolls,
                voiceOverRunning: voiceOverRunning,
                resourceDistance: resourceDistance,
                overrideRaw: overrideRaw
            ))
        }

        XCTAssertEqual(resolve(animated: false), .none)
        XCTAssertEqual(resolve(reduceMotion: true), .none)
        // Reduce Motion turns a requested Slide into Fast Fade; Curl, Fast Fade and
        // None stay instant, and explicit unanimated calls still win.
        XCTAssertEqual(resolve(preference: .slide, reduceMotion: true), .fade)
        XCTAssertEqual(resolve(preference: .slide, reduceMotion: true, resourceDistance: 4), .fade)
        XCTAssertEqual(resolve(preference: .slide, animated: false, reduceMotion: true), .none)
        XCTAssertEqual(resolve(preference: .slide, reduceMotion: true, scrolls: true), .none)
        XCTAssertEqual(resolve(preference: .slide, reduceMotion: true, voiceOverRunning: true), .none)
        XCTAssertEqual(resolve(preference: .fade, reduceMotion: true), .none)
        XCTAssertEqual(resolve(preference: .curl, reduceMotion: true), .none)
        XCTAssertEqual(resolve(scrolls: true), .none)
        XCTAssertEqual(resolve(voiceOverRunning: true), .none)
        XCTAssertEqual(resolve(preference: .none), .none)
        XCTAssertEqual(resolve(preference: .slide), .slide)
        XCTAssertEqual(resolve(preference: .fade), .fade)
        XCTAssertEqual(resolve(preference: .curl), .curl)
        XCTAssertEqual(resolve(preference: .curl, resourceDistance: 1), .curl)
        XCTAssertEqual(resolve(preference: .curl, resourceDistance: 2), .fade)
        XCTAssertEqual(resolve(preference: .slide, resourceDistance: 4), .slide)
        XCTAssertEqual(resolve(preference: .slide, overrideRaw: "fade"), .fade)
        XCTAssertEqual(resolve(preference: .slide, overrideRaw: "nope"), .slide)
        XCTAssertEqual(resolve(animated: false, overrideRaw: "fade"), .none)
    }

    func testSlideUnderReduceMotionFallsBackToFastFadeWhileOtherGatesHold() {
        func resolve(
            preference: PageTransition = .slide,
            animated: Bool = true,
            reduceMotion: Bool = true,
            scrolls: Bool = false,
            voiceOverRunning: Bool = false,
            resourceDistance: Int? = nil,
            overrideRaw: String? = nil
        ) -> PageTransition {
            PageTransitionPolicy.resolve(PageTransitionPolicy.Request(
                preference: preference,
                animated: animated,
                reduceMotion: reduceMotion,
                scrolls: scrolls,
                voiceOverRunning: voiceOverRunning,
                resourceDistance: resourceDistance,
                overrideRaw: overrideRaw
            ))
        }

        XCTAssertEqual(resolve(preference: .slide), .fade)
        XCTAssertEqual(resolve(preference: .slide, resourceDistance: 1), .fade)
        XCTAssertEqual(resolve(preference: .slide, resourceDistance: 3), .fade)
        XCTAssertEqual(resolve(preference: .slide, animated: false), .none)
        XCTAssertEqual(resolve(preference: .slide, scrolls: true), .none)
        XCTAssertEqual(resolve(preference: .slide, voiceOverRunning: true), .none)
        XCTAssertEqual(resolve(preference: .curl), .none)
        XCTAssertEqual(resolve(preference: .curl, resourceDistance: 1), .none)
        XCTAssertEqual(resolve(preference: .fade), .none)
        XCTAssertEqual(resolve(preference: .none), .none)
        XCTAssertEqual(resolve(preference: .slide, overrideRaw: "none"), .none)
        XCTAssertEqual(resolve(preference: .slide, overrideRaw: "curl"), .none)
        XCTAssertEqual(resolve(preference: .curl, overrideRaw: "slide"), .fade)
    }

    func testCurlRendersAsACurl() {
        XCTAssertEqual(PageTransitionPolicy.rendered(.curl), .curl)
        XCTAssertEqual(PageTransitionPolicy.rendered(.fade), .fade)
        XCTAssertEqual(PageTransitionPolicy.rendered(.none), .none)
        XCTAssertEqual(PageTransitionPolicy.rendered(.slide), .slide)
    }

    func testSnapOffsetMatchesTheReflowablePaginator() {
        // Values checked against `snapOffset` in the reflowable script:
        // `value - (value % viewportWidth)`, sign of the dividend.
        XCTAssertEqual(PageDisplacement.snapOffset(0, rtl: false, viewportWidth: 390), 0)
        XCTAssertEqual(PageDisplacement.snapOffset(390, rtl: false, viewportWidth: 390), 390)
        XCTAssertEqual(PageDisplacement.snapOffset(389.2, rtl: false, viewportWidth: 390), 390)
        XCTAssertEqual(PageDisplacement.snapOffset(780, rtl: false, viewportWidth: 400), 400)
        XCTAssertEqual(PageDisplacement.snapOffset(-390, rtl: true, viewportWidth: 390), -390)
        XCTAssertEqual(PageDisplacement.snapOffset(-780, rtl: true, viewportWidth: 390), -780)
        XCTAssertEqual(PageDisplacement.snapOffset(-1, rtl: true, viewportWidth: 390), 0)
        XCTAssertEqual(PageDisplacement.snapOffset(0, rtl: false, viewportWidth: 0), 0)

        XCTAssertEqual(
            PageDisplacement.progressionOffset(progression: 0, documentWidth: 1560, rtl: false, viewportWidth: 390),
            0
        )
        XCTAssertEqual(
            PageDisplacement.progressionOffset(progression: 0.5, documentWidth: 1560, rtl: false, viewportWidth: 390),
            780
        )
        XCTAssertEqual(
            PageDisplacement.progressionOffset(progression: 1, documentWidth: 1560, rtl: false, viewportWidth: 390),
            1560
        )
        XCTAssertEqual(
            PageDisplacement.progressionOffset(progression: 1, documentWidth: 1560, rtl: true, viewportWidth: 390),
            -1560
        )
        XCTAssertTrue(PageDisplacement.isZero(current: 780, target: 780.4))
        XCTAssertFalse(PageDisplacement.isZero(current: 780, target: 782))
    }

    /// The box has to outlive the turn that scheduled the racers. A weak
    /// capture resumes nothing, and this returns the watchdog's nil.
    func testReadyResumeSurvivesUntilTheNextTurn() async {
        let value: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let painted: String = await ReadyResume.awaitFirst { box in
                    DispatchQueue.main.async {
                        box.resume(returning: "painted")
                    }
                }
                return painted
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        XCTAssertEqual(value, "painted")
    }

    func testReadyResumeKeepsTheFirstValue() async {
        let value: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let first: String = await ReadyResume.awaitFirst { box in
                    box.resume(returning: "first")
                    box.resume(returning: "second")
                }
                return first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        XCTAssertEqual(value, "first")
    }

    // MARK: - Accessibility mid-turn preparation & chapter-boundary cancellation

    @MainActor
    private final class MockPageView: UIView, PageView {
        var onRenderedColumnCount: (() async -> Int)?
        var onReadyForPresentation: (() async -> Void)?
        private(set) var isSuppressing = false

        func go(to location: PageLocation, animated: Bool) async {}

        func readyForPresentation() async {
            if let onReadyForPresentation {
                await onReadyForPresentation()
            }
        }

        func awaitNextPaint() async {}

        func setSuppressingProgressionUpdates(_ suppressing: Bool) {
            isSuppressing = suppressing
        }

        func renderedColumnCount() async -> Int {
            if let onRenderedColumnCount {
                return await onRenderedColumnCount()
            }
            return 1
        }
    }

    @MainActor
    private final class MockPaginationDelegate: PaginationViewDelegate {
        var pages: [Int: MockPageView] = [:]

        func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
            pages[index]
        }

        func paginationViewDidUpdateViews(_ paginationView: PaginationView) {}
        func paginationViewWillDiscardPages(_ paginationView: PaginationView) {}
        func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int { 1 }
        func paginationView(_ paginationView: PaginationView, divisionDidChange sample: FoldPostureSample) {}
    }

    @MainActor
    private func makePaginationHarness(
        transition: PageTransition
    ) -> (UIWindow, PaginationView, MockPaginationDelegate, MockPageView, MockPageView) {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let window = UIWindow(frame: bounds)
        let pagination = PaginationView(
            frame: bounds,
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            isScrollEnabled: true
        )
        pagination.pageTransition = transition
        let page0 = MockPageView(frame: bounds)
        page0.backgroundColor = .red
        let page1 = MockPageView(frame: bounds)
        page1.backgroundColor = .blue
        let delegate = MockPaginationDelegate()
        delegate.pages = [0: page0, 1: page1]
        pagination.delegate = delegate
        window.addSubview(pagination)
        window.makeKeyAndVisible()
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        pagination.layoutIfNeeded()
        return (window, pagination, delegate, page0, page1)
    }

    @MainActor
    func testAccessibilityChangeDuringSlidePreparationSkipsCardAnimation() async {
        for toggleVoiceOver in [false, true] {
            let (window, pagination, delegate, page0, _) = makePaginationHarness(transition: .slide)
            _ = (window, delegate)
            var reduceMotion = false
            var voiceOver = false
            pagination.reduceMotionProvider = { reduceMotion }
            pagination.voiceOverProvider = { voiceOver }

            var columnGate: CheckedContinuation<Int, Never>?
            var columnEntered = false
            page0.onRenderedColumnCount = {
                await withCheckedContinuation { cont in
                    columnEntered = true
                    columnGate = cont
                }
            }

            let turn = Task { @MainActor in
                await pagination.goToIndex(1, location: .start, options: NavigatorGoOptions(animated: true))
            }
            for _ in 0 ..< 50 where !columnEntered {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(columnEntered, "Turn must suspend in preparation before mounting overlay")
            XCTAssertNil(pagination.activeOverlayForTesting)

            // Flip accessibility ON while preparation is suspended (before overlay exists).
            if toggleVoiceOver {
                voiceOver = true
            } else {
                reduceMotion = true
            }
            pagination.stopActiveCurlForAccessibility()
            columnGate?.resume(returning: 1)

            // While the fallback finishes, no PageSlideView card overlay may mount.
            var sawSlideOverlay = false
            while !turn.isCancelled {
                if pagination.subviews.contains(where: { $0 is PageSlideView }) {
                    sawSlideOverlay = true
                }
                if pagination.currentIndex == 1 && !pagination.isSuppressingProgressionForTesting {
                    break
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let moved = await turn.value
            XCTAssertTrue(moved)
            XCTAssertFalse(sawSlideOverlay, "Slide card must not animate after accessibility changed during preparation (voiceOver=\(toggleVoiceOver))")
            XCTAssertFalse(pagination.isSuppressingProgressionForTesting)
            pagination.removeFromSuperview()
        }
    }

    @MainActor
    func testAccessibilityStopWhileNextChapterLoadsKeepsCoverAndSuppressionUntilReady() async {
        for transition in [PageTransition.slide, .curl] {
            let (window, pagination, delegate, _, page1) = makePaginationHarness(transition: transition)
            _ = (window, delegate)
            var reduceMotion = false
            pagination.reduceMotionProvider = { reduceMotion }
            pagination.voiceOverProvider = { false }

            var readyGate: CheckedContinuation<Void, Never>?
            var readyEntered = false
            page1.onReadyForPresentation = {
                await withCheckedContinuation { cont in
                    readyEntered = true
                    readyGate = cont
                }
            }

            let turn = Task { @MainActor in
                await pagination.goToIndex(1, location: .start, options: NavigatorGoOptions(animated: true))
            }
            for _ in 0 ..< 50 where !readyEntered {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(readyEntered, "Next chapter must be loading under the outgoing cover")
            let overlay = pagination.activeOverlayForTesting
            XCTAssertNotNil(overlay)
            XCTAssertTrue(overlay?.superview === pagination)
            XCTAssertTrue(pagination.isSuppressingProgressionForTesting)
            XCTAssertTrue(page1.isSuppressing)

            var slideTicks = 0
            (overlay as? PageSlideView)?.onClockTickForTesting = { _ in slideTicks += 1 }

            // Reduce Motion flips ON while the incoming chapter is still loading.
            reduceMotion = true
            pagination.stopActiveCurlForAccessibility()

            // Still cover and progression suppression MUST stay up while chapter 2 loads.
            XCTAssertTrue(overlay?.superview === pagination, "Cover must stay attached while chapter loads (\(transition))")
            if let slide = overlay as? PageSlideView {
                XCTAssertFalse(slide.isCoverHiddenForTesting)
            }
            XCTAssertTrue(pagination.isSuppressingProgressionForTesting)
            XCTAssertTrue(page1.isSuppressing)

            // Now let chapter 2 finish loading and painting.
            readyGate?.resume()
            let moved = await turn.value
            XCTAssertTrue(moved)
            XCTAssertEqual(slideTicks, 0, "Stopped Slide must not lift/animate a card after Reduce Motion turned on")
            XCTAssertNil(overlay?.superview, "Turn cleanup must remove the cover once chapter is ready")
            XCTAssertNil(pagination.activeOverlayForTesting)
            XCTAssertFalse(pagination.isSuppressingProgressionForTesting)
            XCTAssertFalse(page1.isSuppressing)
            pagination.removeFromSuperview()
        }
    }

    @MainActor
    func testReloadCancelRemovesCoverImmediatelyEvenAfterAccessibilityStop() async {
        let (window, pagination, delegate, _, page1) = makePaginationHarness(transition: .slide)
        _ = (window, delegate)
        var reduceMotion = false
        pagination.reduceMotionProvider = { reduceMotion }
        pagination.voiceOverProvider = { false }

        var readyGate: CheckedContinuation<Void, Never>?
        var readyEntered = false
        page1.onReadyForPresentation = {
            await withCheckedContinuation { cont in
                readyEntered = true
                readyGate = cont
            }
        }

        let turn = Task { @MainActor in
            await pagination.goToIndex(1, location: .start, options: NavigatorGoOptions(animated: true))
        }
        for _ in 0 ..< 50 where !readyEntered {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let overlay = pagination.activeOverlayForTesting
        XCTAssertNotNil(overlay)

        reduceMotion = true
        pagination.stopActiveCurlForAccessibility()
        XCTAssertTrue(overlay?.superview === pagination)

        // A reload replaces the viewport and must remove the frozen cover immediately.
        pagination.cancelActiveCurl()
        XCTAssertNil(overlay?.superview)
        XCTAssertNil(pagination.activeOverlayForTesting)

        readyGate?.resume()
        _ = await turn.value
        pagination.removeFromSuperview()
    }
}
