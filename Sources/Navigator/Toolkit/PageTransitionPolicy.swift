//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Which page transition to play for one navigation, and whether the
/// preference applies at all.
///
/// `NavigatorGoOptions.animated == false` always wins, so scrubs, VoiceOver
/// scrolls and silent seeks stay instant. Scroll mode and VoiceOver do too.
/// Under Reduce Motion, Slide falls back to Fast Fade while Curl, Fast Fade and
/// None stay instant. A jump of more than one resource never curls.
enum PageTransitionPolicy {
    /// Key in `NavigatorGoOptions.otherOptions` for a one-call override.
    /// The value is a `PageTransition` raw string (`"fade"`, …).
    static let overrideKey = "pageTransition"

    struct Request: Equatable {
        var preference: PageTransition = .slide
        var animated: Bool = false
        var reduceMotion: Bool = false
        var scrolls: Bool = false
        var voiceOverRunning: Bool = false
        /// `nil` for a turn inside the current resource.
        /// `1` for the neighbour resource, greater than 1 for a jump.
        var resourceDistance: Int?
        var overrideRaw: String?
    }

    /// The transition the caller asked for, after the gates above.
    /// `.curl` is preserved so a later renderer can take this value as-is.
    static func resolve(_ request: Request) -> PageTransition {
        guard request.animated,
              !request.scrolls,
              !request.voiceOverRunning
        else {
            return .none
        }

        let requested = request.overrideRaw.flatMap(PageTransition.init(rawValue:))
            ?? request.preference
        if request.reduceMotion {
            return requested == .slide ? .fade : .none
        }
        if requested == .curl, let distance = request.resourceDistance, distance > 1 {
            return .fade
        }
        return requested
    }

    /// What this revision can paint. `.curl` is the cylinder renderer.
    /// `resolve` already turns a non-adjacent curl into a fade.
    static func rendered(_ transition: PageTransition) -> PageTransition {
        transition
    }

    /// The preference is inactive while the publication scrolls, including
    /// when vertical text or VoiceOver has forced scroll mode.
    static func isEffective(scroll: Bool, voiceOverRunning: Bool) -> Bool {
        !scroll && !voiceOverRunning
    }
}

extension NavigatorGoOptions {
    var pageTransitionOverride: String? {
        otherOptions[PageTransitionPolicy.overrideKey]?.string
    }
}

/// Pixel comparison for "this locator is the page already on screen".
///
/// The snap matches `snapOffset` / `scrollToPosition` in the reflowable
/// paginator: `value - (value % viewportWidth)` with the sign of the
/// dividend, which is Swift's `truncatingRemainder`.
enum PageDisplacement {
    /// One CSS pixel. A seek inside this distance does not turn the page.
    static let zeroThreshold: Double = 1

    static func snapOffset(_ offset: Double, rtl: Bool, viewportWidth: Double) -> Double {
        guard viewportWidth > 0 else {
            return offset
        }
        let delta = rtl ? -1.0 : 1.0
        let value = offset + delta
        return value - value.truncatingRemainder(dividingBy: viewportWidth)
    }

    static func progressionOffset(
        progression: Double,
        documentWidth: Double,
        rtl: Bool,
        viewportWidth: Double
    ) -> Double {
        let factor = rtl ? -1.0 : 1.0
        return snapOffset(documentWidth * progression * factor, rtl: rtl, viewportWidth: viewportWidth)
    }

    static func isZero(current: Double, target: Double) -> Bool {
        abs(current - target) <= zeroThreshold
    }
}
