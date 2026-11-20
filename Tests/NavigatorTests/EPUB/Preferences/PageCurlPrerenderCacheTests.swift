//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import UIKit
import XCTest

/// The drag's neighbour cache. A cached page may only be shown for the
/// column, size and content generation it was taken under, and only while the
/// page on screen still looks like the one it was taken next to.
class PageCurlPrerenderCacheTests: XCTestCase {
    private let spread = NSObject()
    private let size = CGSize(width: 402, height: 874)

    private func key(offset: CGFloat = 402, generation: Int = 1, size: CGSize? = nil, spread: NSObject? = nil) -> PageCurlPageKey {
        PageCurlPageKey(
            spread: ObjectIdentifier(spread ?? self.spread),
            offsetX: offset,
            size: size ?? self.size,
            contentGeneration: generation
        )
    }

    /// A 60×120 page: white, with a dark text block whose height is `lines`.
    private func page(lines: Int, highlight: Bool = false, background: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 120), format: format).image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
            UIColor.black.setFill()
            for line in 0 ..< lines {
                context.fill(CGRect(x: 6, y: 8 + line * 6, width: 48, height: 2))
            }
            if highlight {
                UIColor.yellow.withAlphaComponent(0.4).setFill()
                context.fill(CGRect(x: 6, y: 20, width: 20, height: 6))
            }
        }
    }

    private func fingerprint(_ image: UIImage) -> PageCurlFingerprint {
        PageCurlFingerprint.of(image.cgImage!)!
    }

    func testANeighbourIsServedForItsOwnColumnAndPage() throws {
        var cache = PageCurlPrerenderCache()
        let current = page(lines: 10)
        let next = page(lines: 12)
        let previous = page(lines: 8)
        cache.store(key: key(), current: fingerprint(current), forward: next, backward: previous)

        XCTAssertTrue(try cache.neighbor(.forward, key: key(), onScreen: fingerprint(current)).get() === next)
        XCTAssertTrue(try cache.neighbor(.backward, key: key(), onScreen: fingerprint(current)).get() === previous)
    }

    func testAnyKeyChangeMisses() {
        var cache = PageCurlPrerenderCache()
        let current = page(lines: 10)
        cache.store(key: key(), current: fingerprint(current), forward: page(lines: 12), backward: nil)
        let onScreen = fingerprint(current)

        for other in [
            key(offset: 804),
            key(generation: 2),
            key(size: CGSize(width: 874, height: 402)),
            key(spread: NSObject()),
        ] {
            XCTAssertEqual(cache.neighbor(.forward, key: other, onScreen: onScreen).failure, .key)
        }
    }

    func testAChangedPageOnScreenMisses() {
        var cache = PageCurlPrerenderCache()
        let current = page(lines: 10)
        cache.store(key: key(), current: fingerprint(current), forward: page(lines: 12), backward: nil)

        // A highlight, a theme, a reflow: same key, different pixels.
        for changed in [
            page(lines: 10, highlight: true),
            page(lines: 10, background: UIColor(white: 0.1, alpha: 1)),
            page(lines: 14),
        ] {
            guard case .fingerprint = cache.neighbor(.forward, key: key(), onScreen: fingerprint(changed)).failure else {
                XCTFail("a changed page must not use the cached neighbour")
                continue
            }
        }
        // The same page drawn again matches.
        XCTAssertNotNil(try? cache.neighbor(.forward, key: key(), onScreen: fingerprint(page(lines: 10))).get())
    }

    func testNoFingerprintMeansNoHit() {
        var cache = PageCurlPrerenderCache()
        cache.store(key: key(), current: nil, forward: page(lines: 12), backward: nil)
        XCTAssertEqual(cache.neighbor(.forward, key: key(), onScreen: fingerprint(page(lines: 10))).failure, .noFingerprint)

        // The fingerprint computed later only lands under the same key.
        cache.setCurrent(fingerprint(page(lines: 10)), key: key(offset: 804))
        XCTAssertEqual(cache.neighbor(.forward, key: key(), onScreen: fingerprint(page(lines: 10))).failure, .noFingerprint)
        cache.setCurrent(fingerprint(page(lines: 10)), key: key())
        XCTAssertNotNil(try? cache.neighbor(.forward, key: key(), onScreen: fingerprint(page(lines: 10))).get())
    }

    func testSettingANeighbourOfAnotherColumnStartsOver() {
        var cache = PageCurlPrerenderCache()
        let current = fingerprint(page(lines: 10))
        cache.store(key: key(), current: current, forward: page(lines: 12), backward: page(lines: 8))

        cache.set(page(lines: 14), for: .forward, key: key(offset: 804), current: nil)
        XCTAssertEqual(cache.neighbor(.backward, key: key(offset: 804), onScreen: current).failure, .noNeighbor)
        XCTAssertEqual(cache.neighbor(.forward, key: key(), onScreen: current).failure, .key)

        // Same key: the other side survives (a cancelled drag adds what it peeked at).
        var same = PageCurlPrerenderCache()
        let previous = page(lines: 8)
        same.store(key: key(), current: current, forward: nil, backward: previous)
        same.set(page(lines: 12), for: .forward, key: key(), current: current)
        XCTAssertTrue(try same.neighbor(.backward, key: key(), onScreen: current).get() === previous)
    }

    func testInvalidateFreesEverything() {
        var cache = PageCurlPrerenderCache()
        let current = fingerprint(page(lines: 10))
        cache.store(key: key(), current: current, forward: page(lines: 12), backward: page(lines: 8))
        XCTAssertGreaterThan(cache.byteCount, 0)

        cache.invalidate()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertEqual(cache.neighbor(.forward, key: key(), onScreen: current).failure, .empty)
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
