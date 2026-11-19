//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// What a live preference change sends to the loaded resources. A missing
/// key leaves the old inline property on `:root`; only JSON null removes it.
@MainActor
class CSSCommitTests: XCTestCase {
    private final class ScriptRecorder: EPUBNavigatorViewModelDelegate {
        var scripts: [String] = []

        func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, runScript script: String, in scope: EPUBScriptScope) {
            scripts.append(script)
        }

        func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {}

        func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {}

        /// Properties of the last `setCSSProperties` call. NSNull is a removal.
        func lastProperties() -> [String: Any]? {
            let prefix = "readium.setCSSProperties("
            guard let script = scripts.last(where: { $0.hasPrefix(prefix) }) else {
                return nil
            }
            let json = script.dropFirst(prefix.count).dropLast(2)
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        }
    }

    private var recorder = ScriptRecorder()

    private func makeViewModel(_ preferences: EPUBPreferences) -> EPUBNavigatorViewModel {
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Reflowable"),
                readingOrder: [Link(href: "chapter1.xhtml", mediaType: .xhtml)]
            )
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: publication.readingOrder,
            config: EPUBNavigatorViewController.Configuration(preferences: preferences)
        )
        recorder = ScriptRecorder()
        viewModel.delegate = recorder
        return viewModel
    }

    func testLightThemeRemovesTheNightAndSepiaAppearance() {
        for theme in [Theme.dark, .sepia] {
            let viewModel = makeViewModel(EPUBPreferences(theme: theme))
            viewModel.submitPreferences(EPUBPreferences(theme: .light))
            let properties = recorder.lastProperties()
            XCTAssertNotNil(properties, "\(theme)")
            XCTAssertTrue(properties?["--USER__appearance"] is NSNull, "\(theme) → light left \(String(describing: properties?["--USER__appearance"]))")
        }
    }

    func testJustifyOffRemovesTheAlignment() {
        let viewModel = makeViewModel(EPUBPreferences(publisherStyles: false, textAlign: .justify))
        viewModel.submitPreferences(EPUBPreferences(publisherStyles: false))
        XCTAssertTrue(recorder.lastProperties()?["--USER__textAlign"] is NSNull)
    }

    func testSetValuesAreStillSent() {
        let viewModel = makeViewModel(EPUBPreferences(theme: .light))
        viewModel.submitPreferences(EPUBPreferences(theme: .dark))
        XCTAssertEqual(recorder.lastProperties()?["--USER__appearance"] as? String, "readium-night-on")
    }

    /// The fold reports its clearance while the book is still one column
    /// (the navigator opens before the pose submits `.two`). The clearance
    /// must survive until two columns are requested.
    func testFoldClearanceReportedOnOneColumnAppliesWhenTwoArrive() {
        let viewModel = makeViewModel(EPUBPreferences(columnCount: .one))
        // The navigator's own sequence for a fold report: nothing to commit yet.
        XCTAssertFalse(viewModel.noteFoldClearance(114))
        viewModel.submitPreferences(EPUBPreferences(columnCount: .two))
        XCTAssertEqual(recorder.lastProperties()?["--RS__foldInset"] as? String, "57.00000px")
    }

    /// Vertical text pages by rows (one 100vh column); scroll is one column.
    /// Neither takes the explicit two-column count or the fold inset.
    func testVerticalTextAndScrollDoNotForceTwoColumns() {
        for preferences in [
            EPUBPreferences(columnCount: .two, verticalText: true),
            EPUBPreferences(columnCount: .two, scroll: true),
        ] {
            var css = ReadiumCSS(baseURL: HTTPURL(string: "https://readium/assets")!)
            css.update(with: EPUBSettings(preferences: preferences, defaults: EPUBDefaults(), metadata: Metadata(title: "T")))
            XCTAssertNil(css.rsProperties.colCount, "\(preferences)")
            XCTAssertNil(css.rsProperties.overrides["--RS__colWidth"] ?? nil, "\(preferences)")
        }
        var paged = ReadiumCSS(baseURL: HTTPURL(string: "https://readium/assets")!)
        paged.update(with: EPUBSettings(preferences: EPUBPreferences(columnCount: .two), defaults: EPUBDefaults(), metadata: Metadata(title: "T")))
        XCTAssertEqual(paged.rsProperties.colCount, .two)
    }

    /// Two columns end: the host's own count and width come back, not nil.
    func testEndingTwoColumnsRestoresTheHostColumns() {
        var css = ReadiumCSS(
            rsProperties: CSSRSProperties(colCount: .one, overrides: ["--RS__colWidth": "20em"]),
            baseURL: HTTPURL(string: "https://readium/assets")!
        )
        func settings(_ count: ColumnCount) -> EPUBSettings {
            EPUBSettings(preferences: EPUBPreferences(columnCount: count), defaults: EPUBDefaults(), metadata: Metadata(title: "T"))
        }
        css.update(with: settings(.two))
        XCTAssertEqual(css.rsProperties.colCount, .two)
        css.update(with: settings(.one))
        XCTAssertEqual(css.rsProperties.colCount, .one)
        XCTAssertEqual(css.rsProperties.overrides["--RS__colWidth"] ?? nil, "20em")
    }
}
