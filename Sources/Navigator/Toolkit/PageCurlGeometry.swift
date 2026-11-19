//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreGraphics
import Foundation

/// Where the leaf is bound, in the view. `normalizedX` is 0 at the left edge
/// and 1 at the right, for both reading directions.
///
/// Task 4 drives `progress` from the finger. Task 5 passes the fold into
/// `divisionNormalizedX`. Neither owns a second renderer.
enum PageCurlSpine: Equatable {
    case leading
    case trailing
    case center(normalizedX: CGFloat)

    var normalizedX: CGFloat {
        switch self {
        case .leading:
            return 0
        case .trailing:
            return 1
        case let .center(normalizedX):
            return normalizedX
        }
    }
}

/// Paper colour mixed into a one-page underside. `mix` is how far the mirrored
/// front is pulled toward `color` (the spec's ~78%).
struct PageCurlPaper: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    /// 0 = the mirrored front, 1 = flat paper.
    var mix: CGFloat
    var specular: CGFloat
}

struct PageCurlRGB: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
}

/// Pure curl decisions. The shader reads the numbers; it does not decide them
/// and it has no clock.
enum PageCurlGeometry {
    /// Tap-curl length. Finger tracking (Task 4) does not use this.
    static let tapDuration: TimeInterval = 0.38
    /// Vertical middle. A tap has no corner, so the axis stays vertical.
    static let tapTouchY: CGFloat = 0.5
    /// The axis stays attached to the spine. About ±24°.
    static let maxTilt: CGFloat = 0.42
    /// A vertical fold reported outside this band is clamped, not trusted.
    static let divisionRange: ClosedRange<CGFloat> = 0.35 ... 0.65

    static func clampProgress(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return 0
        }
        return min(1, max(0, value))
    }

    /// Smoothstep. Zero slope at both ends so the leaf starts and lands flat.
    static func easeInOut(_ t: CGFloat) -> CGFloat {
        let x = clampProgress(t)
        return x * x * (3 - 2 * x)
    }

    /// Cylinder radius as a fraction of the view width. Zero at the ends so
    /// the sheet closes without a ridge popping in or out.
    static func cylinderRadius(progress: CGFloat, span: CGFloat) -> CGFloat {
        let p = clampProgress(progress)
        let envelope = sin(p * .pi)
        let leaf = max(span, 0.05)
        let peak = min(0.11, leaf * 0.45)
        return peak * envelope
    }

    /// `touchY` is 0 at the top and 1 at the bottom. Mid-page is a vertical axis.
    static func tiltRadians(touchY: CGFloat) -> CGFloat {
        guard touchY.isFinite else {
            return 0
        }
        let y = min(1, max(0, touchY))
        return (y - 0.5) * (maxTilt * 2)
    }

    /// Binding for the page as it sits, ignoring which way this turn peels.
    ///
    /// One column stays a full-page edge curl even if a fold x is passed:
    /// splitting one column would cut lines in half. A horizontal fold is
    /// not a value here; the caller passes nil for it.
    static func resolveSpine(
        renderedColumns: Int,
        rtl: Bool,
        divisionNormalizedX: CGFloat?
    ) -> PageCurlSpine {
        if renderedColumns >= 2 {
            let x = divisionNormalizedX.map(clampDivision) ?? 0.5
            return .center(normalizedX: x)
        }
        return rtl ? .trailing : .leading
    }

    /// Spine for this turn. Two pages keep the centre. One page peels from the
    /// opposite edge on the way back, which is the same flip RTL applies.
    static func animationSpine(
        renderedColumns: Int,
        rtl: Bool,
        forward: Bool,
        divisionNormalizedX: CGFloat?
    ) -> PageCurlSpine {
        let binding = resolveSpine(
            renderedColumns: renderedColumns,
            rtl: rtl,
            divisionNormalizedX: divisionNormalizedX
        )
        guard renderedColumns < 2, !forward else {
            return binding
        }
        switch binding {
        case .leading:
            return .trailing
        case .trailing:
            return .leading
        case let .center(normalizedX):
            return .center(normalizedX: normalizedX)
        }
    }

    /// +1: the leaf occupies +x from the spine. -1: it occupies -x.
    static func peelSign(spine: PageCurlSpine, rtl: Bool, forward: Bool) -> CGFloat {
        switch spine {
        case .leading:
            return 1
        case .trailing:
            return -1
        case .center:
            let peelRight = rtl ? !forward : forward
            return peelRight ? 1 : -1
        }
    }

    /// Leaf width in view-widths. One page is the whole view. Two pages are
    /// the side being peeled.
    static func span(spine: PageCurlSpine, peelSign: CGFloat) -> CGFloat {
        switch spine {
        case .leading, .trailing:
            return 1
        case let .center(normalizedX):
            let width = peelSign >= 0 ? (1 - normalizedX) : normalizedX
            return min(1, max(0.05, width))
        }
    }

    static func clampDivision(_ x: CGFloat) -> CGFloat {
        guard x.isFinite else {
            return 0.5
        }
        return min(divisionRange.upperBound, max(divisionRange.lowerBound, x))
    }

    /// What actually plays. The policy is the gate: Reduce Motion, VoiceOver,
    /// scroll mode and `animated: false` are none, and a curl past the
    /// neighbour resource is a fade. `.curl` is then rendered, not slid.
    static func rendered(_ request: PageTransitionPolicy.Request) -> PageTransition {
        PageTransitionPolicy.rendered(PageTransitionPolicy.resolve(request))
    }

    /// Underside of a one-page leaf. OLED black is lifted so the sheet does
    /// not disappear into the background. `mix` stays at 78%.
    static func backsidePaper(background: PageCurlRGB) -> PageCurlPaper {
        let y = 0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b
        if y < 0.06 {
            return PageCurlPaper(r: 0.07, g: 0.07, b: 0.075, mix: 0.78, specular: 0.12)
        }
        if y < 0.28 {
            return PageCurlPaper(r: 0.20, g: 0.20, b: 0.22, mix: 0.78, specular: 0.16)
        }
        return PageCurlPaper(
            r: min(1, background.r * 0.86 + 0.08),
            g: min(1, background.g * 0.80 + 0.05),
            b: min(1, background.b * 0.70 + 0.03),
            mix: 0.78,
            specular: y > 0.7 ? 0.34 : 0.26
        )
    }
}

/// Matches `CurlUniforms` in the shader string. Field order is the contract.
struct PageCurlUniforms {
    var progress: Float = 0
    var spineX: Float = 0
    var peelSign: Float = 1
    var radius: Float = 0
    var tilt: Float = 0
    var span: Float = 1
    var realVerso: Float = 0
    var specular: Float = 0.3
    var paperR: Float = 1
    var paperG: Float = 1
    var paperB: Float = 1
    var paperMix: Float = 0.78
    var aspect: Float = 1
    var twoPage: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
}
