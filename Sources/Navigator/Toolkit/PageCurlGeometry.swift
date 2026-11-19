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

    /// One rendered column is an edge curl, even if a fold x is passed.
    /// Two columns use that x, or the centre when the device is flat.
    static func resolve(
        renderedColumns: Int,
        rtl: Bool,
        divisionNormalizedX: CGFloat?
    ) -> PageCurlSpine {
        PageCurlGeometry.resolveSpine(
            renderedColumns: renderedColumns,
            rtl: rtl,
            divisionNormalizedX: divisionNormalizedX
        )
    }

    /// Same decision from the live reserved regions. A horizontal fold is not
    /// a division here, so it cannot pin the spine.
    static func resolve(
        renderedColumns: Int,
        rtl: Bool,
        regions: [PageCurlDivisionSample],
        viewport: CGRect
    ) -> PageCurlSpine {
        let frame = PageCurlGeometry.activeVerticalDivision(regions: regions, viewport: viewport)
        let x = frame.flatMap { PageCurlGeometry.normalizedDivisionX(of: $0, in: viewport) }
        return resolve(renderedColumns: renderedColumns, rtl: rtl, divisionNormalizedX: x)
    }
}

extension PageCurlSpine: CustomStringConvertible {
    var description: String {
        switch self {
        case .leading:
            return "leading"
        case .trailing:
            return "trailing"
        case let .center(normalizedX):
            return String(format: "center %.3f", normalizedX)
        }
    }
}

/// One `.division` region as Readium sees it. `frame` is in the viewport's
/// coordinates. Inactive and horizontal regions are not a book split.
struct PageCurlDivisionSample: Equatable {
    var frame: CGRect
    var isActive: Bool
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

    /// The active vertical fold, or nil. Height >= width is a vertical split.
    /// A wider-than-tall region is tabletop.
    /// A zero-width crease still counts: its midX is the hinge.
    static func activeVerticalDivision(
        regions: [PageCurlDivisionSample],
        viewport: CGRect
    ) -> CGRect? {
        guard viewport.width > 1, viewport.height > 1 else {
            return nil
        }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for region in regions where region.isActive {
            let frame = region.frame
            guard frame.height >= frame.width, frame.height > 0, frame.midX.isFinite else {
                continue
            }
            guard frame.maxY > viewport.minY, frame.minY < viewport.maxY else {
                continue
            }
            guard frame.midX >= viewport.minX, frame.midX <= viewport.maxX else {
                continue
            }
            let overlapHeight = min(frame.maxY, viewport.maxY) - max(frame.minY, viewport.minY)
            let area = max(frame.width, 0.01) * overlapHeight
            if area > bestArea {
                bestArea = area
                best = frame
            }
        }
        return best
    }

    /// Fold midX as a fraction of the viewport width. 0 is the left edge.
    /// Clamping happens in `resolveSpine`, not here.
    static func normalizedDivisionX(of frame: CGRect, in viewport: CGRect) -> CGFloat? {
        guard viewport.width > 1, frame.midX.isFinite else {
            return nil
        }
        return (frame.midX - viewport.minX) / viewport.width
    }

    /// Column gap that keeps text out of the crease. CSS centres the gap, so
    /// an off-centre fold needs a wider gap than the fold itself or the inner
    /// edge of a column still sits under the hinge. No fold keeps `defaultGap`.
    static func columnGapClearingFold(
        defaultGap: CGFloat,
        foldFrame: CGRect?,
        viewport: CGRect
    ) -> CGFloat {
        let base = (defaultGap.isFinite && defaultGap > 0) ? defaultGap : 0
        guard
            let fold = foldFrame,
            viewport.width > 1,
            fold.width.isFinite,
            fold.width > 0,
            fold.minX.isFinite,
            fold.maxX.isFinite
        else {
            return base
        }
        let left = max(0, fold.minX - viewport.minX)
        let right = min(viewport.width, fold.maxX - viewport.minX)
        guard right > left else {
            return base
        }
        let coverLeft = viewport.width - 2 * left
        let coverRight = 2 * right - viewport.width
        return max(base, fold.width, coverLeft, coverRight)
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

    /// Points to scroll so `offset` lands on `target`. Zero when the column is
    /// already there. A second relative page step skips a column when the
    /// offset is only a few points off the target.
    static func curlColumnCorrection(offset: CGFloat, target: CGFloat, slop: CGFloat = 2) -> CGFloat {
        guard offset.isFinite, target.isFinite else {
            return 0
        }
        let drift = target - offset
        let band = slop.isFinite ? max(0, slop) : 2
        if abs(drift) <= band {
            return 0
        }
        return drift
    }

    /// Tilt the shader should use. A reversed one-page uncurl runs progress
    /// backwards, so the same tilt sign would lift the opposite corner.
    static func displayedTilt(touchY: CGFloat, reversed: Bool) -> CGFloat {
        let raw = tiltRadians(touchY: touchY)
        return reversed ? -raw : raw
    }

    /// Verso position in `along` units. Two pages scale the leaf onto the far
    /// half so an off-centre spine does not sample past that half.
    static func versoAlong(orig: CGFloat, span: CGFloat, twoPage: Bool) -> CGFloat {
        let leaf = max(span.isFinite ? span : 0.05, 0.05)
        guard twoPage else {
            return -orig
        }
        let far = max(1 - leaf, 0)
        return -orig * (far / leaf)
    }

    /// Which bitmap a pixel samples. The shader's roll branch matches this.
    /// `x` is unclamped: a value outside 0...1 is a hole, not a clamped edge.
    struct SpreadSample: Equatable {
        enum Sheet: Equatable {
            case outgoing
            case incoming
        }

        enum Region: Equatable {
            case flatOutgoing
            case flatIncoming
            case rollFront
            case rollBack
            case offLeaf
        }

        var sheet: Sheet
        var x: CGFloat
        var region: Region
    }

    static func spreadSample(
        uvX: CGFloat,
        uvY: CGFloat,
        progress: CGFloat,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        twoPage: Bool,
        realVerso: Bool,
        tilt: CGFloat,
        aspect: CGFloat
    ) -> SpreadSample {
        let u = min(1, max(0, uvX.isFinite ? uvX : 0))
        let v = min(1, max(0, uvY.isFinite ? uvY : 0.5))
        let shown = clampProgress(progress)
        func sample(
            _ sheet: SpreadSample.Sheet,
            _ x: CGFloat,
            _ region: SpreadSample.Region
        ) -> SpreadSample {
            SpreadSample(sheet: sheet, x: x, region: region)
        }
        if shown <= 0.001 {
            return sample(.outgoing, u, .flatOutgoing)
        }
        if shown >= 0.999 {
            return sample(.incoming, u, .flatIncoming)
        }
        let leafSpan = max(span.isFinite ? span : 0.05, 0.05)
        let radius = cylinderRadius(progress: shown, span: leafSpan)
        if radius < 0.0001 {
            return shown > 0.5
                ? sample(.incoming, u, .flatIncoming)
                : sample(.outgoing, u, .flatOutgoing)
        }
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let along = (u - spineX) * sign
        let centre = foldCenter(
            progress: shown,
            span: leafSpan,
            overhang: tiltOverhang(tilt: tilt, aspect: aspect),
            curlWidth: radius * 2,
            far: farSpan(twoPage: twoPage, span: leafSpan)
        )
        let line = foldLine(fold: centre, tilt: tilt, normalizedY: v, aspect: aspect)
        let dist = along - line
        if dist <= 0 {
            return sample(.outgoing, u, .flatOutgoing)
        }
        let curlWidth = 2 * radius
        if dist >= curlWidth {
            return sample(.incoming, u, .flatIncoming)
        }
        let t = dist / curlWidth
        let orig = line + t * .pi * radius
        if orig > leafSpan {
            return sample(.incoming, u, .offLeaf)
        }
        func leafX(_ leaf: CGFloat) -> CGFloat {
            spineX + sign * leaf
        }
        // The leaf has crossed the spine. Lay the verso down on the far half.
        // The static half stays flat behind it, and the near incoming half is
        // not wrapped onto the back of the roll.
        if twoPage, orig < 0 {
            let region: SpreadSample.Region = t < 0.5 ? .rollFront : .rollBack
            return sample(.incoming, leafX(orig), region)
        }
        if t < 0.5 {
            return sample(.outgoing, leafX(orig), .rollFront)
        }
        let backLeaf = realVerso
            ? versoAlong(orig: orig, span: leafSpan, twoPage: twoPage)
            : (leafSpan - orig)
        let sheet: SpreadSample.Sheet = realVerso ? .incoming : .outgoing
        return sample(sheet, leafX(backLeaf), .rollBack)
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
