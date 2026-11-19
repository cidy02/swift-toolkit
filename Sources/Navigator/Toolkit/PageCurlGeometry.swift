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
/// A finger drag drives `progress`. A reported fold is `divisionNormalizedX`.
/// Neither owns a second renderer.
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
/// front is pulled toward `color` (`PageCurlGeometry.backsideMix`).
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
    /// Tap-curl length. A finger drag does not use this.
    static let tapDuration: TimeInterval = 0.38
    /// Bottom corner on a tap. 0.84 is about 16° from vertical
    /// (`tiltRadians` at `maxTilt` is the finger's extreme, about ±24°).
    /// A drag replaces this with the finger's `touchY`. Mid-page 0.5 stays vertical.
    static let tapTouchY: CGFloat = 0.84
    /// The axis stays attached to the spine. About ±24°.
    static let maxTilt: CGFloat = 0.42
    /// Peak cylinder radius as a fraction of view width, at progress 0.5.
    /// The roll on screen is `2 * radius` wide, so 0.10 is a fifth of the page
    /// at mid-turn. 0.07 read as a thin band rather than a paper roll.
    static let peakRadius: CGFloat = 0.10
    /// How far the mirrored front is pulled into the paper. 0.78 still read as
    /// reversed type, including at 0.90, so the ghost is a light stain.
    static let backsideMix: CGFloat = 0.96
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
        let peak = min(peakRadius, leaf * 0.45)
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

    /// Spine for this turn. The binding does not move. A backward one-page turn
    /// uncurls the previous page from this same spine (`playsReversed`); it does
    /// not peel the current page off the opposite edge.
    static func animationSpine(
        renderedColumns: Int,
        rtl: Bool,
        forward: Bool,
        divisionNormalizedX: CGFloat?
    ) -> PageCurlSpine {
        _ = forward
        return resolveSpine(
            renderedColumns: renderedColumns,
            rtl: rtl,
            divisionNormalizedX: divisionNormalizedX
        )
    }

    /// One page, going back: play the forward curl from 1 to 0 with the
    /// bitmaps swapped, so the previous page unrolls from the binding spine.
    /// Two pages peel the other leaf instead; that is a forward curl of that leaf.
    static func playsReversed(renderedColumns: Int, forward: Bool) -> Bool {
        renderedColumns < 2 && !forward
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

    /// How far a tilted fold leads the page edge, in `along` units (view widths).
    /// `aspect` is view width / height, the same value the shader stores.
    /// The leading corner is one `overhang` ahead of the centre fold line.
    static func tiltOverhang(tilt: CGFloat, aspect: CGFloat) -> CGFloat {
        guard tilt.isFinite else {
            return 0
        }
        let safeAspect = max(aspect.isFinite ? aspect : 1, 0.05)
        return abs(tan(tilt)) * (0.5 / safeAspect)
    }

    /// Width past the spine that a two-page turn still has to cross.
    /// A one-page leaf has none: its far edge is the spine.
    static func farSpan(twoPage: Bool, span: CGFloat) -> CGFloat {
        guard twoPage, span.isFinite else {
            return 0
        }
        return max(0, 1 - span)
    }

    /// Centre of the fold in `along` units. Starts at `span + overhang`, past
    /// the leading corner, and ends at `-far - overhang - curlWidth`, past the
    /// trailing corner, so neither corner pops on or off in one frame.
    /// `curlWidth` is `2 * cylinderRadius` (the roll's width on screen).
    static func foldCenter(
        progress: CGFloat,
        span: CGFloat,
        overhang: CGFloat,
        curlWidth: CGFloat,
        far: CGFloat
    ) -> CGFloat {
        let p = clampProgress(progress)
        let leaf = max(span.isFinite ? span : 1, 0.05)
        let lead = max(overhang.isFinite ? overhang : 0, 0)
        let roll = max(curlWidth.isFinite ? curlWidth : 0, 0)
        let beyond = max(far.isFinite ? far : 0, 0)
        let travel = leaf + beyond + 2 * lead + roll
        return (leaf + lead) - p * travel
    }

    /// Fold line at one row. `normalizedY` is 0 at the top and 1 at the bottom.
    /// Positive tilt drops the line toward the spine at the bottom.
    static func foldLine(
        fold: CGFloat,
        tilt: CGFloat,
        normalizedY: CGFloat,
        aspect: CGFloat
    ) -> CGFloat {
        guard fold.isFinite else {
            return 0
        }
        let safeAspect = max(aspect.isFinite ? aspect : 1, 0.05)
        let y = min(1, max(0, normalizedY.isFinite ? normalizedY : 0.5))
        let yOff = (y - 0.5) / safeAspect
        let angle = tilt.isFinite ? tilt : 0
        return fold - tan(angle) * yOff
    }

    /// Columns actually used. CSS `column-count` stays at the requested count
    /// when the widths do not fit; `column-width` is what WebKit honoured.
    /// A non-positive `columnWidth` means `auto` (trust the CSS count).
    static func usedColumnCount(
        cssColumnCount: Int,
        columnWidth: CGFloat,
        columnGap: CGFloat,
        innerWidth: CGFloat
    ) -> Int {
        let css = max(1, cssColumnCount)
        guard columnWidth.isFinite, columnWidth > 0, innerWidth.isFinite, innerWidth > 0 else {
            return css
        }
        let gap = (columnGap.isFinite && columnGap > 0) ? columnGap : 0
        let used = max(1, Int(floor((innerWidth + gap) / (columnWidth + gap))))
        return min(css, used)
    }

    /// Parses the column probe (`[count, width, gap, innerWidth]`) or a bare
    /// count from an older script. Anything else is one column.
    static func usedColumnCount(parsing result: Any?) -> Int {
        if let values = result as? NSArray, values.count >= 4 {
            func number(at index: Int) -> Double? {
                let value = values[index]
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                if let text = value as? String {
                    return Double(text)
                }
                return nil
            }
            guard
                let css = number(at: 0),
                let width = number(at: 1),
                let gap = number(at: 2),
                let inner = number(at: 3)
            else {
                return 1
            }
            return usedColumnCount(
                cssColumnCount: Int(css),
                columnWidth: CGFloat(width),
                columnGap: CGFloat(gap),
                innerWidth: CGFloat(inner)
            )
        }
        if let values = result as? [NSNumber], values.count >= 4 {
            return usedColumnCount(
                cssColumnCount: values[0].intValue,
                columnWidth: CGFloat(values[1].doubleValue),
                columnGap: CGFloat(values[2].doubleValue),
                innerWidth: CGFloat(values[3].doubleValue)
            )
        }
        if let values = result as? [Any], values.count >= 4 {
            func number(_ value: Any) -> Double? {
                switch value {
                case let number as NSNumber:
                    return number.doubleValue
                case let text as String:
                    return Double(text)
                default:
                    return nil
                }
            }
            guard
                let css = number(values[0]),
                let width = number(values[1]),
                let gap = number(values[2]),
                let inner = number(values[3])
            else {
                return 1
            }
            return usedColumnCount(
                cssColumnCount: Int(css),
                columnWidth: CGFloat(width),
                columnGap: CGFloat(gap),
                innerWidth: CGFloat(inner)
            )
        }
        if let number = result as? NSNumber {
            return max(1, number.intValue)
        }
        return 1
    }

    /// One web view is snapshotted on its own. A failed snapshot is a failure,
    /// not a hierarchy grab: the curl cover is already a subview and would
    /// photograph the outgoing page. Anything else is drawn as a hierarchy.
    enum CaptureRoute: Equatable {
        case webSnapshot
        case failed
        case hierarchy
    }

    static func captureRoute(webViewCount: Int, snapshotSucceeded: Bool) -> CaptureRoute {
        guard webViewCount == 1 else {
            return .hierarchy
        }
        return snapshotSucceeded ? .webSnapshot : .failed
    }

    /// A missing incoming bitmap cross-fades onto the live page. Substituting
    /// the outgoing bitmap peels the page off a copy of itself.
    enum IncomingReveal: Equatable {
        case cylinder
        case crossfade
    }

    static func incomingReveal(snapshotSucceeded: Bool) -> IncomingReveal {
        snapshotSucceeded ? .cylinder : .crossfade
    }

    /// What actually plays. The policy is the gate: Reduce Motion, VoiceOver,
    /// scroll mode and `animated: false` are none, and a curl past the
    /// neighbour resource is a fade. `.curl` is then rendered, not slid.
    static func rendered(_ request: PageTransitionPolicy.Request) -> PageTransition {
        PageTransitionPolicy.rendered(PageTransitionPolicy.resolve(request))
    }

    /// Underside of a one-page leaf. The colour is the theme's own paper.
    /// Warming a white page (the previous mix) painted a beige leaf on Light.
    /// OLED black is lifted so the sheet does not disappear. `mix` is `backsideMix`.
    static func backsidePaper(background: PageCurlRGB) -> PageCurlPaper {
        let y = 0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b
        if y < 0.06 {
            // About 7% above black.
            return PageCurlPaper(r: 0.07, g: 0.07, b: 0.075, mix: backsideMix, specular: 0.12)
        }
        if y < 0.28 {
            return PageCurlPaper(r: 0.20, g: 0.20, b: 0.22, mix: backsideMix, specular: 0.16)
        }
        let chroma = max(background.r, background.g, background.b) - min(background.r, background.g, background.b)
        // Near-neutral paper (Light): the same hue, 4% darker. Tinted paper
        // (Sepia): a little darker, still that tint, not a second beige.
        let scale: CGFloat = chroma < 0.08 ? 0.96 : 0.92
        return PageCurlPaper(
            r: min(1, background.r * scale),
            g: min(1, background.g * scale),
            b: min(1, background.b * scale),
            mix: backsideMix,
            specular: y > 0.7 ? 0.28 : 0.22
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
    var paperMix: Float = 0.96
    var aspect: Float = 1
    var twoPage: Float = 0
    /// Centre fold in `along` units. See `PageCurlGeometry.foldCenter`.
    var fold: Float = 0
    var pad1: Float = 0
}
