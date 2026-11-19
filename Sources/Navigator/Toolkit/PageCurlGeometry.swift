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

/// The fold for one grab. `point` lies on the perpendicular bisector of the
/// segment from the held point to the finger. `normal` is the unit direction
/// of that segment (held point → finger). `axis` is the bisector shifted by
/// `radius` along `normal`: the cylinder's crest. `clamped` means the bisector
/// was pushed back so it does not cross the spine.
struct PageCurlGrabFold: Equatable {
    var point: CGPoint
    var normal: CGPoint
    var axis: CGPoint
    var radius: CGFloat
    var clamped: Bool
}

/// Pure curl decisions. The shader reads the numbers; it does not decide them
/// and it has no clock.
enum PageCurlGeometry {
    /// Tap-curl length. A finger drag does not use this.
    static let tapDuration: TimeInterval = 0.38
    /// Where a tap's corner finishes, as a fraction of the page height from the top.
    /// The corner starts at the bottom and rises as it crosses.
    static let tapLift: CGFloat = 0.36
    /// Peak cylinder radius as a fraction of view width, at progress 0.5.
    /// The roll on screen is `2 * radius` wide, so 0.10 is a fifth of the page
    /// at mid-turn. 0.07 read as a thin band rather than a paper roll.
    static let peakRadius: CGFloat = 0.10
    /// How far the mirrored front is pulled into the paper. 0.78 still read as
    /// reversed type, including at 0.90, so the ghost is a light stain.
    static let backsideMix: CGFloat = 0.96
    /// Back of the leaf at the fold, as a multiple of its paper. The back is
    /// the theme's paper everywhere else; only a band next to the fold, where
    /// the sheet rolls away from the light, is darker. The previous ramp
    /// (0.74 at the fold to 0.98 by 0.45 view widths) never reached the paper
    /// on a half-page flap, so Light read as a flat mid-grey.
    static let backFoldShade: CGFloat = 0.84
    /// Width of that darker band, in view widths from the fold (about 24 pt on
    /// an iPhone).
    static let backShadeBand: CGFloat = 0.06
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

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = t.isFinite ? t : 0
        return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    /// Touch-down, projected onto the outer edge of the leaf at that height.
    /// A grab near the bottom holds the bottom corner; mid-edge holds the edge;
    /// near the top holds the top corner. `touchUV` is 0...1, origin top-left.
    /// The result is isotropic: x in view widths, y in view widths from the top.
    static func heldPoint(
        touchUV: CGPoint,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        aspect: CGFloat
    ) -> CGPoint {
        let safeAspect = max(aspect.isFinite ? aspect : 1, 0.05)
        let yUV = min(1, max(0, touchUV.y.isFinite ? touchUV.y : 1))
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let leaf = max(span.isFinite ? span : 1, 0.05)
        let spine = spineX.isFinite ? spineX : 0
        return CGPoint(x: spine + sign * leaf, y: yUV / safeAspect)
    }

    /// Current finger, same isotropic space as `heldPoint`. Not clamped: the
    /// finger can leave the page, and the fold follows it.
    static func fingerPoint(touchUV: CGPoint, aspect: CGFloat) -> CGPoint {
        let safeAspect = max(aspect.isFinite ? aspect : 1, 0.05)
        let x = touchUV.x.isFinite ? touchUV.x : 0
        let y = touchUV.y.isFinite ? touchUV.y : 0
        return CGPoint(x: x, y: y / safeAspect)
    }

    /// Synthetic grab for a tap. P0 is the lower outer corner. P moves toward
    /// the mirror of that corner across the spine, and up, so the fold is the
    /// diagonal a corner peel makes. Progress 0 is flat (P = P0).
    static func tapGrab(
        progress: CGFloat,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        pageHeight: CGFloat
    ) -> (p0: CGPoint, p: CGPoint) {
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let leaf = max(span.isFinite ? span : 1, 0.05)
        let height = max(pageHeight.isFinite ? pageHeight : 1, 0.05)
        let spine = spineX.isFinite ? spineX : 0
        let p0 = CGPoint(x: spine + sign * leaf, y: height)
        let landing = CGPoint(x: spine - sign * leaf, y: height * tapLift)
        let p = mix(p0, landing, clampProgress(progress))
        return (p0, p)
    }

    /// Where the held point should finish on a commit, continuing the drag's
    /// own direction until it has crossed the spine. A straight drag stays at
    /// its height. A corner drag keeps its diagonal.
    static func commitLanding(
        p0: CGPoint,
        p: CGPoint,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        pageHeight: CGFloat
    ) -> CGPoint {
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let leaf = max(span.isFinite ? span : 1, 0.05)
        let spine = spineX.isFinite ? spineX : 0
        let across = spine - sign * leaf
        let height = max(pageHeight.isFinite ? pageHeight : 1, 0.05)
        let xDelta = p.x - p0.x
        let travelX = across - p0.x
        if !xDelta.isFinite || !travelX.isFinite || abs(xDelta) < 0.02 || abs(travelX) < 0.02 {
            return CGPoint(x: across, y: height * tapLift)
        }
        let scale = travelX / xDelta
        var y = p0.y + (p.y - p0.y) * scale
        if !y.isFinite {
            y = height * tapLift
        }
        let pad = height * 0.35
        y = min(height + pad, max(-pad, y))
        return CGPoint(x: across, y: y)
    }

    /// Perpendicular bisector of P0→P, then pushed so the spine segment stays
    /// on the unturned side. The cylinder axis is that line offset by `radius`
    /// toward the finger. Nil when the finger has not moved.
    static func grabFold(
        p0: CGPoint,
        p: CGPoint,
        radius: CGFloat,
        spineX: CGFloat,
        pageHeight: CGFloat
    ) -> PageCurlGrabFold? {
        let dx = p.x - p0.x
        let dy = p.y - p0.y
        guard dx.isFinite, dy.isFinite else {
            return nil
        }
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0008 else {
            return nil
        }
        let nx = dx / len
        let ny = dy / len
        var mx = (p0.x + p.x) * 0.5
        var my = (p0.y + p.y) * 0.5
        let height = pageHeight.isFinite ? pageHeight : 1
        let spine = spineX.isFinite ? spineX : 0
        let sTop = (spine - mx) * nx + (0 - my) * ny
        let sBot = (spine - mx) * nx + (height - my) * ny
        let minS = min(sTop, sBot)
        let clamped = minS < 0
        if clamped {
            mx += nx * minS
            my += ny * minS
        }
        let r = max(radius.isFinite ? radius : 0, 0)
        return PageCurlGrabFold(
            point: CGPoint(x: mx, y: my),
            normal: CGPoint(x: nx, y: ny),
            axis: CGPoint(x: mx + nx * r, y: my + ny * r),
            radius: r,
            clamped: clamped
        )
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
            // A hinge exactly on the window edge is the other screen, not a
            // crease through this page. Inclusive edges treated that as a fold
            // and asked for a clearance as wide as the viewport.
            guard frame.midX > viewport.minX, frame.midX < viewport.maxX else {
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

    /// Centred clearance that keeps text out of the crease. The value is the
    /// empty band around the middle of the page, applied as cloned column
    /// padding (`foldInsetLength`), not as `column-gap`. A column gap is also
    /// inserted after the last column, and the paginator strides by the
    /// viewport width, so every later page drifts by one gap. No fold keeps
    /// `defaultGap`. Wider than `maxFoldClearanceFraction` of the viewport is
    /// clamped: cloned padding of that size would leave no text.
    static let maxFoldClearanceFraction: CGFloat = 0.30

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
        let raw = max(base, fold.width, coverLeft, coverRight)
        let cap = max(base, viewport.width * maxFoldClearanceFraction)
        return min(raw, cap)
    }

    /// Padding on each side of a column. Two of these meet at the centre and
    /// clear `clearance`. `nil` when there is nothing to inset.
    static func foldInsetLength(clearance: CGFloat) -> String? {
        guard clearance.isFinite, clearance > 0.5 else {
            return nil
        }
        return String(format: "%.5fpx", clearance / 2)
    }

    /// Installed in every reflowable resource. Inert until `--RS__foldInset`
    /// is set on the root. The gap is forced to 0 for the same reason
    /// `columnGapClearingFold` is not written into `--RS__colGap`.
    static let foldInsetRules = """
    :root[style*="--RS__foldInset"] { -webkit-column-gap: 0px !important; column-gap: 0px !important; }
    :root[style*="--RS__foldInset"] body { -webkit-box-decoration-break: clone !important; box-decoration-break: clone !important; padding-left: max(var(--RS__pageGutter, 0px) * var(--USER__pageMargins, 1), var(--RS__foldInset)) !important; padding-right: max(var(--RS__pageGutter, 0px) * var(--USER__pageMargins, 1), var(--RS__foldInset)) !important; }
    """

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

    /// Which bitmap a pixel samples. The shader's flap branch matches this.
    /// `x` is unclamped. The shader clamps it when sampling; a flap pixel is
    /// never a hole onto the next page.
    struct SpreadSample: Equatable {
        enum Sheet: Equatable {
            case outgoing
            case incoming
        }

        enum Region: Equatable {
            case flatOutgoing
            case flatIncoming
            /// Cylinder band: the back, between the fold and the axis's far side.
            case rollBack
            /// Flat back of the leaf, from the cylinder out to the moved edge.
            case flatBack
        }

        var sheet: Sheet
        var x: CGFloat
        var region: Region
    }

    /// `p0` and `p` are isotropic (x in view widths, y in view widths from the
    /// top), the same space as `grabFold`. `radius` is the cylinder radius in
    /// that space. One page's back samples the outgoing sheet at the reflected
    /// point (the mirror). Two pages sample the incoming facing half, not mirrored.
    static func spreadSample(
        uvX: CGFloat,
        uvY: CGFloat,
        progress: CGFloat,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        twoPage: Bool,
        realVerso: Bool,
        p0: CGPoint,
        p: CGPoint,
        radius: CGFloat,
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
        // A vanishing cylinder is a hard crease. Stay flat until the roll exists.
        if radius.isFinite, radius < 0.004 {
            return shown > 0.5
                ? sample(.incoming, u, .flatIncoming)
                : sample(.outgoing, u, .flatOutgoing)
        }
        let safeAspect = max(aspect.isFinite ? aspect : 1, 0.05)
        let pageH = 1 / safeAspect
        let leafSpan = max(span.isFinite ? span : 0.05, 0.05)
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let iso = CGPoint(x: u, y: v / safeAspect)
        guard let fold = grabFold(
            p0: p0,
            p: p,
            radius: radius,
            spineX: spineX,
            pageHeight: pageH
        ) else {
            return shown > 0.5
                ? sample(.incoming, u, .flatIncoming)
                : sample(.outgoing, u, .flatOutgoing)
        }
        let s = (iso.x - fold.point.x) * fold.normal.x + (iso.y - fold.point.y) * fold.normal.y
        let pre = CGPoint(
            x: iso.x - 2 * s * fold.normal.x,
            y: iso.y - 2 * s * fold.normal.y
        )
        func inLeaf(_ q: CGPoint) -> Bool {
            let along = (q.x - spineX) * sign
            if along < -0.004 || along > leafSpan + 0.004 {
                return false
            }
            if q.y < -0.004 || q.y > pageH + 0.004 {
                return false
            }
            return true
        }
        // The flap is the reflection of the peeled part of the leaf. It lies on
        // the finger's side of the fold, over the page, out to the moved edge.
        if s > 0, inLeaf(pre) {
            let sheet: SpreadSample.Sheet = realVerso ? .incoming : .outgoing
            let x: CGFloat
            if realVerso {
                let along = (pre.x - spineX) * sign
                x = spineX + sign * versoAlong(orig: along, span: leafSpan, twoPage: twoPage)
            } else {
                x = pre.x
            }
            let region: SpreadSample.Region = s < fold.radius * 2 ? .rollBack : .flatBack
            return sample(sheet, x, region)
        }
        if inLeaf(iso), s >= 0 {
            return sample(.outgoing, u, .flatOutgoing)
        }
        // The other page of a spread stays put. The fold is not allowed to
        // cross the spine, so this half is not peeled.
        if twoPage {
            let along = (iso.x - spineX) * sign
            if along < -0.004, iso.x >= -0.02, iso.x <= 1.02, iso.y >= -0.02, iso.y <= pageH + 0.02 {
                return sample(.outgoing, u, .flatOutgoing)
            }
        }
        return sample(.incoming, u, .flatIncoming)
    }

    /// What actually plays. The policy is the gate: Reduce Motion, VoiceOver,
    /// scroll mode and `animated: false` are none, and a curl past the
    /// neighbour resource is a fade. `.curl` is then rendered, not slid.
    static func rendered(_ request: PageTransitionPolicy.Request) -> PageTransition {
        PageTransitionPolicy.rendered(PageTransitionPolicy.resolve(request))
    }

    /// Multiplier on the back's colour at `distance` (view widths) from the
    /// fold, toward the moved edge. Matches the shader's `shade`.
    static func backShade(distanceFromFold distance: CGFloat) -> CGFloat {
        let d = distance.isFinite ? max(0, distance) : 0
        let t = min(1, d / max(backShadeBand, 0.0001))
        let smooth = t * t * (3 - 2 * t)
        return backFoldShade + (1 - backFoldShade) * smooth
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
/// `p0` / `p` are isotropic page points: x in view widths, y in view widths
/// from the top. The shader rebuilds the bisector from them.
struct PageCurlUniforms {
    var progress: Float = 0
    var spineX: Float = 0
    var peelSign: Float = 1
    var radius: Float = 0
    var p0x: Float = 1
    var p0y: Float = 1
    var px: Float = 1
    var py: Float = 1
    var span: Float = 1
    var realVerso: Float = 0
    var specular: Float = 0.3
    var paperR: Float = 1
    var paperG: Float = 1
    var paperB: Float = 1
    var paperMix: Float = 0.96
    var aspect: Float = 1
}
