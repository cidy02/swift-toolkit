//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreGraphics
import Foundation

/// Visual layout for one frame of the lifted-card Slide transition.
/// All values are in host-view points.
struct PageSlideFrame: Equatable {
    /// Moving card frame in host coordinates.
    var cardFrame: CGRect
    /// Origin of the full-page snapshot inside the card's clipped view.
    /// `(0, 0)` on one page; `(-homeRect.minX, 0)` on the right half of a spread.
    var cardImageOrigin: CGPoint
    /// Clipped rect of the complementary half in a two-page spread, or nil on
    /// one page. Forward: shrinks the unturned outgoing half as the exiting card
    /// sweeps past the spine. Backward: grows the incoming complementary half
    /// behind the entering card's spine edge.
    var staticHalfClipFrame: CGRect?
    /// Origin of the full-page snapshot (`outgoing` forward, `incoming` backward)
    /// inside `staticHalfClipFrame`.
    var staticHalfImageOrigin: CGPoint
    /// True for a backward turn (one page or two pages): the previous page
    /// enters as the lifted card over the still current spread.
    var usesIncomingAsCard: Bool
    /// Animated continuous corner radius of the lifted card.
    var cornerRadius: CGFloat
    /// Whether the card's left corners (top-left, bottom-left) are rounded.
    var roundsLeadingCorners: Bool
    /// Whether the card's right corners (top-right, bottom-right) are rounded.
    var roundsTrailingCorners: Bool
    /// Lift envelope (`0...1`): rises over the first few points of drag and
    /// eases out on settle.
    var lift: CGFloat
    /// White elevation wash over the card in dark themes (`0` in light themes).
    var elevationTintAlpha: CGFloat
    /// Subtle edge rim alpha (`0` at rest). White on dark themes, black on light.
    var rimAlpha: CGFloat
    /// True when the page background is dark (OLED / Dark / dark custom paper).
    var isDarkTheme: Bool
    /// Drop-shadow opacity on the lifted card (`0` at both ends to prevent pops).
    var shadowOpacity: Float
    /// Horizontal shadow offset toward the uncovered page underneath.
    var shadowOffsetX: CGFloat
    /// Drop-shadow blur radius.
    var shadowRadius: CGFloat
}

/// Pure geometry and appearance math for the Apple Books–style Slide transition.
/// The view applies these numbers directly to Core Animation layers.
enum PageSlideGeometry {
    /// Tap / key / page-turner card slide length (matches historical slide).
    static let tapDuration: TimeInterval = 0.30
    /// Horizontal travel (points) over which corners ramp to the full display radius.
    static let cornerRampPoints: CGFloat = 12
    /// Horizontal travel (points) over which elevation tint and shadow reach full
    /// strength. Capped at a quarter of the travel width on narrow views.
    static let liftRampPoints: CGFloat = 64
    /// Fraction of travel near off-screen exit/entry over which the exterior
    /// shadow fades to 0 so the shadow band never pops when the overlay tears down.
    static let shadowExitFadeFraction: CGFloat = 0.08
    /// Rec. 709 relative luminance threshold separating dark and light themes.
    static let darkLuminanceThreshold: CGFloat = 0.35
    /// Peak white overlay alpha in dark themes (~#000000 → #1C1C1D, #16161A → #2F2F34).
    static let darkElevationTintMax: CGFloat = 0.115
    /// Peak hairline rim alpha around the lifted card.
    static let darkRimMaxAlpha: CGFloat = 0.08
    static let lightRimMaxAlpha: CGFloat = 0.06
    /// Peak drop-shadow opacity and radius.
    static let lightShadowMaxOpacity: Float = 0.22
    static let darkShadowMaxOpacity: Float = 0.35
    static let lightShadowRadius: CGFloat = 16
    static let darkShadowRadius: CGFloat = 14
    /// Horizontal shadow bias on a single-page card, pointing into the uncovered side.
    static let singlePageShadowOffsetX: CGFloat = 6
    /// Fallback display corner radii when iOS 26 `effectiveRadius(corner:)` is
    /// unavailable (iOS < 26 or offscreen views without a window).
    static let fallbackPhoneCornerRadius: CGFloat = 55
    static let fallbackPadCornerRadius: CGFloat = 18

    /// Cubic ease-out for tap/key turns: lifts promptly and settles softly.
    static func tapEaseOut(_ t: CGFloat) -> CGFloat {
        let u = 1 - PageCurlGeometry.clampProgress(t)
        return 1 - u * u * u
    }

    /// Slide plays every backward turn reversed — the previous page (or the
    /// previous spread's entering half) comes in as the lifted card over the
    /// still current spread, on both one page and two pages. Curl keeps
    /// `PageCurlGeometry.playsReversed` untouched.
    static func playsReversed(forward: Bool) -> Bool {
        !forward
    }

    /// +1 when the lifted card's home is on the +x side (LTR: full page or right
    /// half) and moves toward -x as `cardOffset` grows; -1 in RTL.
    static func peelSign(rtl: Bool) -> CGFloat {
        rtl ? -1 : 1
    }

    static func isDark(background: PageCurlRGB) -> Bool {
        let r = clampUnit(background.r)
        let g = clampUnit(background.g)
        let b = clampUnit(background.b)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < darkLuminanceThreshold
    }

    /// Resolves the display corner radius from UIKit's public `UICornerConfiguration`
    /// effective radius when available, falling back by device class.
    static func displayCornerRadius(
        effectiveRadius: CGFloat?,
        isPad: Bool,
        hasBottomSafeArea: Bool
    ) -> CGFloat {
        if let effectiveRadius, effectiveRadius.isFinite, effectiveRadius > 0 {
            return effectiveRadius
        }
        if isPad {
            return fallbackPadCornerRadius
        }
        return hasBottomSafeArea ? fallbackPhoneCornerRadius : 0
    }

    /// Smoothly ramps `0 → 1` over `cornerRampPoints` of displacement from home.
    static func cornerFactor(displacement: CGFloat) -> CGFloat {
        guard displacement.isFinite, displacement > 0, cornerRampPoints > 0 else {
            return 0
        }
        return PageCurlGeometry.easeInOut(displacement / cornerRampPoints)
    }

    /// Quadratic ease-out lift (`0 → 1`) over the first `min(liftRampPoints, travelWidth * 0.25)`
    /// points of displacement so the lift is visible within the first few points of drag.
    static func liftStrength(displacement: CGFloat, travelWidth: CGFloat) -> CGFloat {
        guard displacement.isFinite, displacement > 0, travelWidth.isFinite, travelWidth > 1 else {
            return 0
        }
        let ramp = max(1, min(liftRampPoints, travelWidth * 0.25))
        let t = PageCurlGeometry.clampProgress(displacement / ramp)
        let inv = 1 - t
        return 1 - inv * inv
    }

    /// Computes the complete lifted-card layout for `progress` in `0...1`.
    ///
    /// - One page (`spine == .leading` or `.trailing`):
    ///   - Forward (`reversed == false`): outgoing page lifts and slides off toward
    ///     the leading edge (`-W` LTR, `+W` RTL) over the still incoming page.
    ///   - Backward (`reversed == true`): previous (incoming) page enters from the
    ///     leading edge as the lifted card over the still current (outgoing) page.
    /// - Two pages (`spine == .center(s)`):
    ///   - Forward (`reversed == false`): the trailing half of the outgoing
    ///     spread (right page in LTR, left page in RTL) lifts and slides across
    ///     the still incoming spread; the unturned outgoing half stays clipped
    ///     until the moving card sweeps over it.
    ///   - Backward (`reversed == true`): the entering half of the previous
    ///     spread (right page from the left edge in LTR, left page from the
    ///     right edge in RTL) slides in as the lifted card over the still
    ///     current spread, revealing the other half of the previous spread
    ///     behind its spine edge until progress `1` lands on the full previous
    ///     spread.
    ///   - Outer corners match the display corner radius; the spine edge stays
    ///     square (`0` radius) so the binding seam meets cleanly at rest.
    static func layout(
        progress: CGFloat,
        bounds: CGRect,
        spine: PageCurlSpine,
        peelSign: CGFloat,
        reversed: Bool,
        displayCornerRadius: CGFloat,
        background: PageCurlRGB
    ) -> PageSlideFrame {
        let width = max(bounds.width.isFinite ? bounds.width : 0, 0)
        let height = max(bounds.height.isFinite ? bounds.height : 0, 0)
        let p = PageCurlGeometry.clampProgress(progress)
        let moveSign: CGFloat = peelSign >= 0 ? -1 : 1
        let cardOffset = reversed ? (1 - p) : p
        let displacement = cardOffset * width

        let isTwoPage: Bool
        let homeRect: CGRect
        let roundsLeading: Bool
        let roundsTrailing: Bool
        let spineX: CGFloat

        switch spine {
        case .leading, .trailing:
            isTwoPage = false
            spineX = spine.normalizedX * width
            homeRect = CGRect(x: 0, y: 0, width: width, height: height)
            roundsLeading = true
            roundsTrailing = true
        case let .center(normalizedX):
            isTwoPage = true
            let clamped = PageCurlGeometry.clampDivision(normalizedX)
            spineX = clamped * width
            if peelSign >= 0 {
                homeRect = CGRect(x: spineX, y: 0, width: max(0, width - spineX), height: height)
                roundsLeading = false
                roundsTrailing = true
            } else {
                homeRect = CGRect(x: 0, y: 0, width: spineX, height: height)
                roundsLeading = true
                roundsTrailing = false
            }
        }

        let cardFrame = homeRect.offsetBy(dx: moveSign * displacement, dy: 0)

        let staticClip: CGRect?
        let staticOrigin: CGPoint
        if isTwoPage {
            if peelSign >= 0 {
                // Right half sliding left: keep outgoing left half up to the card's left edge.
                let clipWidth = max(0, min(spineX, cardFrame.minX))
                staticClip = CGRect(x: 0, y: 0, width: clipWidth, height: height)
                staticOrigin = .zero
            } else {
                // Left half sliding right: keep outgoing right half past the card's right edge.
                let clipMinX = min(width, max(spineX, cardFrame.maxX))
                let clipWidth = max(0, width - clipMinX)
                staticClip = CGRect(x: clipMinX, y: 0, width: clipWidth, height: height)
                staticOrigin = CGPoint(x: -clipMinX, y: 0)
            }
        } else {
            staticClip = nil
            staticOrigin = .zero
        }

        let safeRadius = displayCornerRadius.isFinite ? max(0, displayCornerRadius) : 0
        let maxAllowedRadius = min(cardFrame.width, cardFrame.height) * 0.45
        let targetRadius = min(safeRadius, maxAllowedRadius)
        let cornerRadius = targetRadius * cornerFactor(displacement: displacement)

        let lift = liftStrength(displacement: displacement, travelWidth: width)
        let dark = isDark(background: background)
        let elevationTintAlpha = dark ? darkElevationTintMax * lift : 0
        let rimAlpha = (dark ? darkRimMaxAlpha : lightRimMaxAlpha) * lift

        // Taper exterior shadow near cardOffset == 1 so the shadow blur never
        // pops off screen when the card finishes exiting or begins entering.
        let exitEdgeFade = shadowExitFadeFraction > 0
            ? PageCurlGeometry.easeInOut((1 - cardOffset) / shadowExitFadeFraction)
            : 1
        let baseShadow = dark ? darkShadowMaxOpacity : lightShadowMaxOpacity
        let shadowOpacity = baseShadow * Float(lift * exitEdgeFade)
        let shadowRadius = dark ? darkShadowRadius : lightShadowRadius
        let shadowOffsetX: CGFloat
        if isTwoPage {
            shadowOffsetX = 0
        } else {
            // Card moves toward `moveSign`; shadow falls on the opposite (uncovered) edge.
            shadowOffsetX = -moveSign * singlePageShadowOffsetX
        }

        return PageSlideFrame(
            cardFrame: cardFrame,
            cardImageOrigin: CGPoint(x: -homeRect.minX, y: 0),
            staticHalfClipFrame: staticClip,
            staticHalfImageOrigin: staticOrigin,
            usesIncomingAsCard: reversed,
            cornerRadius: cornerRadius,
            roundsLeadingCorners: roundsLeading,
            roundsTrailingCorners: roundsTrailing,
            lift: lift,
            elevationTintAlpha: elevationTintAlpha,
            rimAlpha: rimAlpha,
            isDarkTheme: dark,
            shadowOpacity: shadowOpacity,
            shadowOffsetX: shadowOffsetX,
            shadowRadius: shadowRadius
        )
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1, max(0, value)) : 1
    }
}
