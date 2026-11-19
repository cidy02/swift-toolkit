//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// Shared slide and cross-dissolve for turns inside one resource and across
/// resources. A curl renderer plugs into `PageTransitionPolicy.rendered`.
@MainActor
enum PageTransitionAnimator {
    /// Historical `PaginationView` slide.
    static let slideDuration: TimeInterval = 0.3
    /// Cross-dissolve. Not a dip to blank.
    static let fadeDuration: TimeInterval = 0.18
    /// Cap so a stalled spread cannot leave the navigator in `.moving`.
    static let readinessTimeout: TimeInterval = 0.5
    /// Two animation frames, plus a little slack, for one paint.
    static let paintTimeout: TimeInterval = 0.25

    /// Snapshot of `view` composited on an opaque canvas.
    ///
    /// The web view and the pagination view are clear, so a bare snapshot
    /// would let the incoming page show through the outgoing one.
    static func makeCover(of view: UIView, backgroundColor: UIColor) -> UIView {
        let cover = UIView(frame: view.bounds)
        cover.backgroundColor = backgroundColor
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.isAccessibilityElement = false
        cover.accessibilityElementsHidden = true

        if let snapshot = view.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = cover.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isAccessibilityElement = false
            snapshot.accessibilityElementsHidden = true
            cover.addSubview(snapshot)
        }
        return cover
    }

    static func fade(_ view: UIView, to alpha: CGFloat, duration: TimeInterval) async {
        guard duration > 0 else {
            view.alpha = alpha
            return
        }
        await withCheckedContinuation { continuation in
            UIView.animate(
                withDuration: duration,
                animations: { view.alpha = alpha },
                completion: { _ in continuation.resume() }
            )
        }
    }
}
