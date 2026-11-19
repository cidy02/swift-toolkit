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
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        let webs = webViews(in: view)
        if webs.count == 1, let web = webs.first, web.bounds.width > 1, web.bounds.height > 1,
           let shot = await takeSnapshot(of: web, scale: scale, afterScreenUpdates: afterScreenUpdates)
        {
            let frame = web.convert(web.bounds, to: view)
            return renderer.image { context in
                backgroundColor.setFill()
                context.fill(bounds)
                shot.draw(in: frame)
            }
        }

        // A fixed double spread has two web views. One snapshot would drop a
        // page. `afterScreenUpdates: false` — true deadlocks against WebKit
        // while this task is already on the main actor.
        let image = renderer.image { context in
            backgroundColor.setFill()
            context.fill(bounds)
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return image
    }

    private static func takeSnapshot(
        of web: WKWebView,
        scale: CGFloat,
        afterScreenUpdates: Bool
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = web.bounds
            config.afterScreenUpdates = afterScreenUpdates
            let width = web.bounds.width * scale
            if width > 1 {
                config.snapshotWidth = NSNumber(value: Double(width))
            }
            web.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let web = view as? WKWebView {
            found.append(web)
        }
        for subview in view.subviews where !(subview is PageCurlView) {
            found.append(contentsOf: webViews(in: subview))
        }
        return found
    }
}
