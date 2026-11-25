//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit
import WebKit

/// Opaque bitmap of a page. The web view and the pagination view are clear,
/// so the theme colour is painted first and the snapshot is drawn on top.
/// A transparent grab would let the page underneath show through the leaf.
@MainActor
enum PageCurlSnapshotter {
    static let snapshotDeadline: TimeInterval = 1.0

    static func capture(
        of view: UIView,
        backgroundColor: UIColor,
        afterScreenUpdates: Bool = true
    ) async -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return nil
        }

        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        // WebKit can hand back a wide-gamut image. `.automatic` promotes that
        // to 16-bit pixels and doubles the texture. The curl samples 8-bit.
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        let webs = webViews(in: view)
        // `snapshotWidth` is in points. Leaving it nil captures `rect` at the
        // screen scale. Multiplying by scale here makes WebKit multiply again.
        let shot: UIImage?
        if webs.count == 1, let web = webs.first, web.bounds.width > 1, web.bounds.height > 1 {
            shot = await takeSnapshot(of: web, afterScreenUpdates: afterScreenUpdates)
        } else {
            shot = nil
        }
        switch PageCurlGeometry.captureRoute(webViewCount: webs.count, snapshotSucceeded: shot != nil) {
        case .failed:
            return nil
        case .webSnapshot:
            guard let shot, let web = webs.first else {
                return nil
            }
            let frame = web.convert(web.bounds, to: view)
            return renderer.image { context in
                backgroundColor.setFill()
                context.fill(bounds)
                shot.draw(in: frame)
            }
        case .hierarchy:
            // No single web view to snapshot (a container, or none yet).
            // `afterScreenUpdates: true` deadlocks against WebKit while this
            // task is already on the main actor. A fixed spread is one web
            // view with two iframes, so it takes the snapshot path above.
            return renderer.image { context in
                backgroundColor.setFill()
                context.fill(bounds)
                view.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
        }
    }

    private static func takeSnapshot(
        of web: WKWebView,
        afterScreenUpdates: Bool
    ) async -> UIImage? {
        // Bounded: a web process that never answers must not hold a turn (and its cover) forever.
        await ReadyResume.awaitFirst { (box: ReadyResumeBox<UIImage?>) in
            Task { @MainActor in
                try? await Task.sleep(seconds: Self.snapshotDeadline)
                box.resume(returning: nil)
            }
            let config = WKSnapshotConfiguration()
            config.rect = web.bounds
            config.afterScreenUpdates = afterScreenUpdates
            web.takeSnapshot(with: config) { image, _ in
                Task { @MainActor in
                    box.resume(returning: image)
                }
            }
        }
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let web = view as? WKWebView {
            found.append(web)
        }
        for subview in view.subviews where !(subview is any PageTurnOverlayView) {
            found.append(contentsOf: webViews(in: subview))
        }
        return found
    }
}
