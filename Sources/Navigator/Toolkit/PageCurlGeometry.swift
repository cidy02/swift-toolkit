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
/// `specular` is the crest highlight; Apple shows none, so it is 0.
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
/// of that segment (held point → finger). `axis` is the cylinder's axis seen
/// from above: the line where the sheet leaves the page, the bisector shifted
/// by `π/2 · radius` along `normal`, so the rolled edge still lands on the
/// finger (`rollArc`). `clamped` means the bisector was pushed back so it
/// does not cross the spine.
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
    /// Height of a tap's arc, as a fraction of the leaf (and at most of the
    /// page). The corner rises and comes back down onto the mirror of where
    /// it started, so the turn ends with the fold on the spine.
    static let tapArc: CGFloat = 0.5
    /// Peak cylinder radius as a fraction of view width, at progress 0.5.
    /// The leaf wraps a real cylinder (`rollArc`): the roll on screen is
    /// `radius` wide, front text squeezing onto it and the back coming over
    /// the top. Apple Books' roll in the owner's recording (iPhone, 2026-11-19)
    /// is about 25–35 pt wide mid-turn, so 0.08 (32 pt at 402 pt).
    static let peakRadius: CGFloat = 0.08
    /// How much of the mirrored front shows through a one-page back, in the
    /// shader's (gamma-encoded) colour space. Apple Books' back on a black
    /// page draws white type at 57–65 of 255 (owner's recording, 1.30 s and
    /// 1.62 s, every 40 px column of the flap), so about a quarter. The old
    /// 0.04 (mix 0.96) read as a blank card.
    static let backGhostStrength: CGFloat = 0.25
    /// `1 - backGhostStrength`: how far the mirrored front is pulled into the paper.
    static let backsideMix: CGFloat = 1 - backGhostStrength
    /// Darkening where the sheet turns edge-on, at the roll's crest
    /// (`rollShade`). Apple's is gentle; 0 at the flat parts.
    static let rollCrestDarkening: CGFloat = 0.12
    /// Shadow the roll casts on the next page, at the roll's edge, and how
    /// fast it fades (view widths). Apple's is faint.
    static let rollShadowStrength: CGFloat = 0.10
    static let rollShadowWidth: CGFloat = 0.018
    /// Shadow the flat back casts on the leaf's own front along its edges.
    static let flapShadowStrength: CGFloat = 0.08
    static let flapShadowWidth: CGFloat = 0.010
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

    /// Synthetic grab for a tap. P0 is the lower outer corner. P travels to
    /// the mirror of that corner across the spine along an arc, so the fold
    /// starts as the diagonal of a corner peel and lands on the spine.
    /// Progress 0 is flat (P = P0).
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
        let t = clampProgress(progress)
        let lift = tapArc * min(leaf, height) * sin(t * .pi)
        let across = spine - sign * leaf
        return (p0, CGPoint(x: p0.x + (across - p0.x) * t, y: p0.y - lift))
    }

    /// Where the held point finishes on a commit: the mirror of P0 across
    /// the spine, so the fold lies on the spine and the leaf is flat on the
    /// other side. The spring travels there from wherever the drag left P,
    /// so a corner drag's diagonal relaxes as the page lands instead of
    /// stopping short of the spine.
    static func commitLanding(
        p0: CGPoint,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat
    ) -> CGPoint {
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let leaf = max(span.isFinite ? span : 1, 0.05)
        let spine = spineX.isFinite ? spineX : 0
        return CGPoint(x: spine - sign * leaf, y: p0.y.isFinite ? p0.y : 0)
    }

    /// How sharply the leaf runs ahead of the finger near the far edge
    /// (`fingerAim`). 3 keeps it within about 7 pt of the finger for the
    /// first quarter of the travel and about 52 pt at half (402 pt iPhone).
    static let edgeLeadPower: CGFloat = 3

    /// Held point for a finger drag that peels the leaf (not a reversed one).
    /// Early on it is P0 moved by the finger's travel, so the leaf is at the
    /// finger. As the finger nears the far screen edge, P runs ahead to the
    /// landing (`commitLanding`), so the fold keeps going to the spine: at the
    /// edge the page is turned, as in Apple Books, instead of stopping halfway
    /// with the leaf's edge under the finger. The finger's vertical offset
    /// fades out the same way, so the leaf lands flat. Points are isotropic.
    static func fingerAim(
        p0: CGPoint,
        origin: CGPoint,
        finger: CGPoint,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat
    ) -> CGPoint {
        let follow = CGPoint(x: p0.x + (finger.x - origin.x), y: p0.y + (finger.y - origin.y))
        guard follow.x.isFinite, follow.y.isFinite, origin.x.isFinite else {
            return follow
        }
        let sign: CGFloat = peelSign >= 0 ? 1 : -1
        let limitX: CGFloat = sign > 0 ? 0 : 1
        let available = (origin.x - limitX) * sign
        guard available > 0.01 else {
            return follow
        }
        let travel = (origin.x - finger.x) * sign
        let t = min(1, max(0, travel / available))
        let lead = pow(t, edgeLeadPower)
        let landing = commitLanding(p0: p0, spineX: spineX, peelSign: peelSign, span: span)
        let followAtEdge = p0.x - sign * available
        return CGPoint(
            x: follow.x + (landing.x - followAtEdge) * lead,
            y: follow.y + (p0.y - follow.y) * lead
        )
    }

    /// One page going back plays the forward curl from landed to flat.
    /// `shown` is that forward progress (1 at the start of the drag). x runs
    /// from the mirror back to P0; the finger's vertical movement tilts the
    /// leaf the way it would tilt a forward drag, faded out at both ends so
    /// the start does not pop a wedge in at the spine.
    static func reversedGrab(
        p0: CGPoint,
        fingerDY: CGFloat,
        shown: CGFloat,
        spineX: CGFloat,
        peelSign: CGFloat,
        span: CGFloat,
        pageHeight: CGFloat
    ) -> CGPoint {
        let across = commitLanding(p0: p0, spineX: spineX, peelSign: peelSign, span: span)
        let t = clampProgress(shown)
        let height = max(pageHeight.isFinite ? pageHeight : 1, 0.05)
        let pad = height * 0.35
        let dy = min(pad, max(-pad, fingerDY.isFinite ? fingerDY : 0)) * sin(t * .pi)
        return CGPoint(x: p0.x + (across.x - p0.x) * t, y: p0.y + dy)
    }

    /// Commit or cancel spring for a finger curl. A quadratic through
    /// `control`: the midpoint is a straight line, the finger's own point
    /// (a flick released before the leaf caught up) keeps the drag's angle.
    static func springGrab(from: CGPoint, control: CGPoint, to: CGPoint, u: CGFloat) -> CGPoint {
        let t = min(1, max(0, u.isFinite ? u : 1))
        let a = (1 - t) * (1 - t)
        let b = 2 * t * (1 - t)
        let c = t * t
        return CGPoint(
            x: a * from.x + b * control.x + c * to.x,
            y: a * from.y + b * control.y + c * to.y
        )
    }

    /// The held point, kept where a leaf attached along the whole spine can
    /// reach. Paper does not stretch, so P stays within |P0 − S| of each spine
    /// end S (that is also exactly when the bisector leaves both ends on the
    /// unturned side). Inside both disks P is unchanged; outside, it is the
    /// nearest point of their intersection. That moves continuously, so the
    /// fold keeps rotating instead of sliding to a stop.
    static func attachedHeldPoint(
        p0: CGPoint,
        p: CGPoint,
        spineX: CGFloat,
        pageHeight: CGFloat
    ) -> CGPoint {
        guard p.x.isFinite, p.y.isFinite, p0.x.isFinite, p0.y.isFinite else {
            return p
        }
        let height = max(pageHeight.isFinite ? pageHeight : 1, 0.05)
        let spine = spineX.isFinite ? spineX : 0
        let top = CGPoint(x: spine, y: 0)
        let bottom = CGPoint(x: spine, y: height)
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }
        let rTop = distance(p0, top)
        let rBottom = distance(p0, bottom)
        let slack: CGFloat = 1e-9
        func inside(_ q: CGPoint) -> Bool {
            distance(q, top) <= rTop + slack && distance(q, bottom) <= rBottom + slack
        }
        if inside(p) {
            return p
        }
        func project(_ q: CGPoint, onto center: CGPoint, radius: CGFloat) -> CGPoint {
            let d = distance(q, center)
            guard d > radius, d > 0 else {
                return q
            }
            return CGPoint(x: center.x + (q.x - center.x) * radius / d, y: center.y + (q.y - center.y) * radius / d)
        }
        let candidates = [
            project(p, onto: top, radius: rTop),
            project(p, onto: bottom, radius: rBottom),
        ].filter { inside($0) }
        if let best = candidates.min(by: { distance($0, p) < distance($1, p) }) {
            return best
        }
        // Both limits bind: a corner of the lens, on the circles' common chord.
        let y = (rTop * rTop - rBottom * rBottom + height * height) / (2 * height)
        let h = max(rTop * rTop - y * y, 0).squareRoot()
        let right = CGPoint(x: spine + h, y: y)
        let left = CGPoint(x: spine - h, y: y)
        return distance(right, p) <= distance(left, p) ? right : left
    }

    /// Perpendicular bisector of P0→P, with P first kept within reach of the
    /// spine (`attachedHeldPoint`). The cylinder axis is that line offset by
    /// `π/2 · radius` toward the finger. Nil when the finger has not moved.
    static func grabFold(
        p0: CGPoint,
        p: CGPoint,
        radius: CGFloat,
        spineX: CGFloat,
        pageHeight: CGFloat
    ) -> PageCurlGrabFold? {
        guard p.x.isFinite, p.y.isFinite else {
            return nil
        }
        let height = pageHeight.isFinite ? pageHeight : 1
        let spine = spineX.isFinite ? spineX : 0
        let held = attachedHeldPoint(p0: p0, p: p, spineX: spine, pageHeight: height)
        let dx = held.x - p0.x
        let dy = held.y - p0.y
        guard dx.isFinite, dy.isFinite else {
            return nil
        }
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0008 else {
            return nil
        }
        let nx = dx / len
        let ny = dy / len
        let mx = (p0.x + held.x) * 0.5
        let my = (p0.y + held.y) * 0.5
        let r = max(radius.isFinite ? radius : 0, 0)
        let lift = r * .pi / 2
        return PageCurlGrabFold(
            point: CGPoint(x: mx, y: my),
            normal: CGPoint(x: nx, y: ny),
            axis: CGPoint(x: mx + nx * lift, y: my + ny * lift),
            radius: r,
            clamped: hypot(held.x - p.x, held.y - p.y) > 1e-6
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
            /// The back over the top of the cylinder.
            case rollBack
            /// The front on the cylinder's near side, squeezed toward the crest.
            case rollFront
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
        // w: distance from the cylinder axis toward the held edge (away from
        // the finger). The sheet is flat for w < 0, wraps the cylinder over
        // 0 ... radius, and its back comes over the top toward the finger.
        let w = (fold.axis.x - iso.x) * fold.normal.x + (fold.axis.y - iso.y) * fold.normal.y
        // The point of the unturned leaf that lands here from arc length t.
        func original(_ t: CGFloat) -> CGPoint {
            CGPoint(x: iso.x - fold.normal.x * (t - w), y: iso.y - fold.normal.y * (t - w))
        }
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
        func back(_ q: CGPoint, _ region: SpreadSample.Region) -> SpreadSample {
            let sheet: SpreadSample.Sheet = realVerso ? .incoming : .outgoing
            let x: CGFloat
            if realVerso {
                let along = (q.x - spineX) * sign
                x = spineX + sign * versoAlong(orig: along, span: leafSpan, twoPage: twoPage)
            } else {
                x = q.x
            }
            return sample(sheet, x, region)
        }
        let arc = rollArc(w: w, radius: fold.radius)
        // Topmost first: the back (flat, then over the roll), then the front
        // squeezing onto the roll, then the flat page.
        if let t = arc.back {
            let q = original(t)
            if inLeaf(q) {
                return back(q, w < 0 ? .flatBack : .rollBack)
            }
        }
        if let t = arc.front {
            let q = original(t)
            if inLeaf(q) {
                return sample(.outgoing, q.x, .rollFront)
            }
        }
        if w < 0, inLeaf(iso) {
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

    /// Orthographic cylinder seen from above. `w` is the distance from the
    /// axis toward the held edge, `radius` the cylinder's. Returns the arc
    /// length from the axis of the sheet's back (on top: the roll's upper
    /// half for 0 ... radius, then flat at the cylinder's height for w < 0)
    /// and of its front (the roll's lower half, 0 ... radius only). Nil where
    /// that side does not pass over w. Flat paper short of the roll is
    /// `t = w` and is not returned. With `radius` 0 the back is the mirror
    /// across the axis, the old flat fold.
    static func rollArc(w: CGFloat, radius: CGFloat) -> (back: CGFloat?, front: CGFloat?) {
        guard w.isFinite else {
            return (nil, nil)
        }
        let r = max(radius.isFinite ? radius : 0, 0)
        if w > r {
            return (nil, nil)
        }
        if w < 0 {
            return (.pi * r - w, nil)
        }
        let theta = asin(min(1, w / max(r, 1e-9)))
        return (r * (.pi - theta), r * theta)
    }

    /// Brightness multiplier on the roll at `w` (as in `rollArc`): 1 on the
    /// flat parts, `1 - rollCrestDarkening` where the sheet is edge-on.
    /// The same for the front and the back, so both meet at the crest.
    static func rollShade(w: CGFloat, radius: CGFloat) -> CGFloat {
        let r = radius.isFinite ? radius : 0
        guard r > 0, w.isFinite, w >= 0 else {
            return 1
        }
        let sinTheta = min(1, w / r)
        return 1 - rollCrestDarkening * sinTheta * sinTheta
    }

    /// What actually plays. The policy is the gate: Reduce Motion, VoiceOver,
    /// scroll mode and `animated: false` are none, and a curl past the
    /// neighbour resource is a fade. `.curl` is then rendered, not slid.
    static func rendered(_ request: PageTransitionPolicy.Request) -> PageTransition {
        PageTransitionPolicy.rendered(PageTransitionPolicy.resolve(request))
    }

    /// Underside of a one-page leaf: the theme's own page colour, in every
    /// theme, with the mirrored text showing through (`backsideMix`). Apple
    /// Books' back on a black page is black; the type is what makes it read.
    /// The old lifted OLED black and the grey Dark card read as a second shape.
    static func backsidePaper(background: PageCurlRGB) -> PageCurlPaper {
        func channel(_ value: CGFloat) -> CGFloat {
            value.isFinite ? min(1, max(0, value)) : 1
        }
        return PageCurlPaper(
            r: channel(background.r),
            g: channel(background.g),
            b: channel(background.b),
            mix: backsideMix,
            specular: 0
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
