//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
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
}
