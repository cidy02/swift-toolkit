//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// Whole turns, frame by frame, through `spreadSample` (the shader's CPU twin).
/// A frozen fold shows as frames where nothing changes; a hard cut as one
/// frame that changes most of the screen.
class PageCurlMotionTests: XCTestCase {
    struct Page {
        var aspect: CGFloat
        var spineX: CGFloat
        var peelSign: CGFloat
        var span: CGFloat
        var twoPage: Bool

        var height: CGFloat { 1 / aspect }

        static let iPhone = Page(aspect: 402.0 / 874.0, spineX: 0, peelSign: 1, span: 1, twoPage: false)
        static let iPadTwo = Page(aspect: 744.0 / 1133.0, spineX: 0.5, peelSign: 1, span: 0.5, twoPage: true)
        static let duoTwo = Page(aspect: 951.0 / 669.0, spineX: 0.5, peelSign: 1, span: 0.5, twoPage: true)
        static let iPhoneRTL = Page(aspect: 402.0 / 874.0, spineX: 1, peelSign: -1, span: 1, twoPage: false)
    }

    /// What each sample shows: 0 the page being turned, 1 the next page,
    /// 2 a one-page back (paper). A two-page back is the next page's facing
    /// half, so it counts as the next page: once flat it is those pixels.
    private func frame(_ page: Page, progress: CGFloat, p0: CGPoint, p: CGPoint) -> [UInt16] {
        // As `PageCurlView.uniforms`.
        let radius = PageCurlGeometry.spineSafeRadius(
            PageCurlGeometry.cylinderRadius(progress: progress, span: page.span),
            p0: p0,
            p: p,
            spineX: page.spineX,
            pageHeight: page.height
        )
        var keys: [UInt16] = []
        keys.reserveCapacity(30 * 60)
        for row in 0 ..< 60 {
            for col in 0 ..< 30 {
                let s = PageCurlGeometry.spreadSample(
                    uvX: (CGFloat(col) + 0.5) / 30,
                    uvY: (CGFloat(row) + 0.5) / 60,
                    progress: progress,
                    spineX: page.spineX,
                    peelSign: page.peelSign,
                    span: page.span,
                    twoPage: page.twoPage,
                    realVerso: page.twoPage,
                    p0: p0,
                    p: p,
                    radius: radius,
                    aspect: page.aspect
                )
                switch (s.sheet, s.region) {
                case (.outgoing, .rollBack), (.outgoing, .flatBack):
                    keys.append(2)
                case (.outgoing, _):
                    keys.append(0)
                case (.incoming, _):
                    keys.append(1)
                }
            }
        }
        return keys
    }

    private func changed(_ a: [UInt16], _ b: [UInt16]) -> CGFloat {
        CGFloat(zip(a, b).filter { $0 != $1 }.count) / CGFloat(a.count)
    }

    /// Asserts a turn moves on every few frames inside `live` and never
    /// changes more than `maxStep` of the screen in one frame.
    private func assertSmooth(
        _ frames: [(progress: CGFloat, keys: [UInt16])],
        live: ClosedRange<CGFloat>,
        maxStep: CGFloat = 0.12,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var worst: (CGFloat, CGFloat) = (0, 0)
        var stillRun = 0
        var longestStill: (Int, CGFloat) = (0, 0)
        for i in 1 ..< frames.count {
            let delta = changed(frames[i - 1].keys, frames[i].keys)
            if delta > worst.0 {
                worst = (delta, frames[i].progress)
            }
            if live.contains(frames[i].progress) {
                stillRun = delta == 0 ? stillRun + 1 : 0
                if stillRun > longestStill.0 {
                    longestStill = (stillRun, frames[i].progress)
                }
            }
        }
        XCTAssertLessThanOrEqual(worst.0, maxStep, "\(label): \(Int(worst.0 * 100))% of the screen changed in one frame at progress \(worst.1)", file: file, line: line)
        XCTAssertLessThan(longestStill.0, 3, "\(label): fold still for \(longestStill.0) frames ending at progress \(longestStill.1)", file: file, line: line)
        XCTAssertTrue(frames.last?.keys.allSatisfy { $0 == 1 } ?? false, "\(label): last frame is not the next page", file: file, line: line)
    }

    private func tapFrames(_ page: Page, steps: Int = 48) -> [(progress: CGFloat, keys: [UInt16])] {
        (0 ... steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            let grab = PageCurlGeometry.tapGrab(
                progress: t, spineX: page.spineX, peelSign: page.peelSign, span: page.span, pageHeight: page.height
            )
            return (t, frame(page, progress: t, p0: grab.p0, p: grab.p))
        }
    }

    func testTapCurlTurnsTheWholeWayOnOnePagePortrait() {
        assertSmooth(tapFrames(.iPhone), live: 0.08 ... 0.92, "iPhone tap")
        assertSmooth(tapFrames(.iPhoneRTL), live: 0.08 ... 0.92, "iPhone RTL tap")
    }

    func testTapCurlTurnsTheWholeWayOnTwoPages() {
        assertSmooth(tapFrames(.iPadTwo), live: 0.08 ... 0.92, "iPad two-page tap")
        assertSmooth(tapFrames(.duoTwo), live: 0.08 ... 0.92, "Duo two-page tap")
    }

    /// Late in a tap, the top of the leaf has turned: a frozen fold left it flat.
    func testTapCurlHasTurnedTheTopOfTheLeafAtNinetyPercent() {
        for page in [Page.iPhone, .iPadTwo] {
            let grab = PageCurlGeometry.tapGrab(
                progress: 0.9, spineX: page.spineX, peelSign: page.peelSign, span: page.span, pageHeight: page.height
            )
            let keys = frame(page, progress: 0.9, p0: grab.p0, p: grab.p)
            // Top row, the leaf's outer half.
            let topLeaf = (0 ..< 30).filter { col in
                let x = (CGFloat(col) + 0.5) / 30
                return (x - page.spineX) * page.peelSign > page.span * 0.5
            }
            let stillOutgoing = topLeaf.filter { keys[$0] == 0 }.count
            XCTAssertEqual(stillOutgoing, 0, "\(page.twoPage ? "two" : "one") page: \(stillOutgoing) top samples still flat at 0.9")
        }
    }

    /// The bottom-corner drag filmed earlier: (388,780)→(170,640) on 402×874,
    /// released and sprung to the commit along the view's own path.
    func testCornerDragCommitSpringNeverFreezes() {
        let page = Page.iPhone
        let p0 = CGPoint(x: 1, y: 780.0 / 402.0)
        let p = CGPoint(x: p0.x - 218.0 / 402.0, y: p0.y - 140.0 / 402.0)
        let start: CGFloat = 218.0 / 402.0
        let landing = PageCurlGeometry.commitLanding(
            p0: p0, spineX: page.spineX, peelSign: page.peelSign, span: page.span
        )
        let control = PageCurlGeometry.mix(p, landing, 0.5)
        let steps = 40
        let frames: [(progress: CGFloat, keys: [UInt16])] = (0 ... steps).map { i in
            let u = CGFloat(i) / CGFloat(steps)
            let progress = start + (1 - start) * u
            let q = PageCurlGeometry.springGrab(from: p, control: control, to: landing, u: u)
            return (progress, frame(page, progress: progress, p0: p0, p: q))
        }
        assertSmooth(frames, live: start + 0.05 ... 0.92, "corner commit")
    }

    /// A forward drag on `page` from `start` to `end` (UV), frame by frame, as the view tracks it.
    private func dragFrames(_ page: Page, from start: CGPoint, to end: CGPoint, steps: Int = 40) -> [(progress: CGFloat, keys: [UInt16])] {
        let p0 = PageCurlGeometry.heldPoint(
            touchUV: start, spineX: page.spineX, peelSign: page.peelSign, span: page.span, aspect: page.aspect
        )
        let origin = PageCurlGeometry.fingerPoint(touchUV: start, aspect: page.aspect)
        return (0 ... steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            let uv = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            let finger = PageCurlGeometry.fingerPoint(touchUV: uv, aspect: page.aspect)
            let aim = PageCurlGeometry.fingerAim(
                p0: p0, origin: origin, finger: finger, spineX: page.spineX, peelSign: page.peelSign,
                span: page.span, pageHeight: page.height
            )
            let progress = PageCurlPanStateMachine.progress(
                translationX: (uv.x - start.x) * 1000, width: 1000, forward: true, rtl: page.peelSign < 0
            )
            return (progress, frame(page, progress: progress, p0: p0, p: aim))
        }
    }

    private func worstStep(_ frames: [(progress: CGFloat, keys: [UInt16])]) -> (CGFloat, CGFloat) {
        var worst: (CGFloat, CGFloat) = (0, 0)
        for i in 1 ..< frames.count {
            let delta = changed(frames[i - 1].keys, frames[i].keys)
            if delta > worst.0 {
                worst = (delta, frames[i].progress)
            }
        }
        return worst
    }

    /// Two pages, diagonal and corner drags whose held point is pulled back
    /// within the spine's reach: the fold pivots on a spine end, which leaves
    /// no room for a roll. That used to drop the radius under the shader's
    /// "flat" cut-off, so the half-turned spread snapped to the whole old
    /// spread, then cut to the whole new one at progress 0.5.
    func testTwoPageDiagonalDragsNeverSnapFlat() {
        let cases: [(Page, CGPoint, CGPoint, String)] = [
            (.iPadTwo, CGPoint(x: 0.95, y: 0.90), CGPoint(x: 0.59, y: 0.60), "iPad corner up-left"),
            (.iPadTwo, CGPoint(x: 0.95, y: 0.90), CGPoint(x: 0.02, y: 0.55), "iPad corner to the edge"),
            (.duoTwo, CGPoint(x: 0.95, y: 0.50), CGPoint(x: 0.60, y: 0.07), "Duo mid-edge up-left"),
            (.duoTwo, CGPoint(x: 0.95, y: 0.85), CGPoint(x: 0.05, y: 0.30), "Duo corner to the edge"),
            (.iPadTwo, CGPoint(x: 0.45, y: 0.50), CGPoint(x: 0.0, y: 0.50), "iPad from left of the spine"),
        ]
        for (page, start, end, label) in cases {
            let frames = dragFrames(page, from: start, to: end)
            let worst = worstStep(frames)
            XCTAssertLessThanOrEqual(worst.0, 0.12, "\(label): \(Int(worst.0 * 100))% changed in one frame at progress \(worst.1)")
        }
        // At the left edge from left of the spine, the spread is turned, not the old one.
        let atEdge = dragFrames(.iPadTwo, from: CGPoint(x: 0.45, y: 0.5), to: CGPoint(x: 0, y: 0.5)).last!.keys
        XCTAssertGreaterThan(CGFloat(atEdge.filter { $0 == 1 }.count) / CGFloat(atEdge.count), 0.9)
    }

    /// Down at the right edge mid-height, out to 40% of the
    /// width, then back to 5 pt from the right edge 150 pt lower, held, released. The curl follows the
    /// finger's travel away from the edge, so it shrinks to flat on the way back; the vertical offset
    /// only tilts it. The release (a cancel) springs from what is on screen, with no frame that cuts.
    func testFingerBackAtTheStartEdgeFlattensTheLeafAndTheCancelDoesNotCut() {
        let page = Page.iPhone
        let w: CGFloat = 402
        let origin = CGPoint(x: 397 / w, y: 437 / w)
        let p0 = PageCurlGeometry.heldPoint(
            touchUV: CGPoint(x: 397 / w, y: 437.0 / 874), spineX: page.spineX, peelSign: page.peelSign,
            span: page.span, aspect: page.aspect
        )
        func state(_ x: CGFloat, _ y: CGFloat) -> (progress: CGFloat, p: CGPoint) {
            let finger = CGPoint(x: x / w, y: y / w)
            let p = PageCurlGeometry.fingerAim(
                p0: p0, origin: origin, finger: finger, spineX: page.spineX, peelSign: page.peelSign, span: page.span,
                pageHeight: page.height
            )
            let progress = PageCurlPanStateMachine.progress(translationX: x - 397, width: w, forward: true, rtl: false)
            return (progress, p)
        }
        func leafShare(_ keys: [UInt16]) -> CGFloat {
            CGFloat(keys.filter { $0 != 0 }.count) / CGFloat(keys.count)
        }
        var frames: [(progress: CGFloat, keys: [UInt16])] = []
        for k in 0 ... 30 {
            let s = state(397 - 236 * CGFloat(k) / 30, 437)
            frames.append((s.progress, frame(page, progress: s.progress, p0: p0, p: s.p)))
        }
        XCTAssertGreaterThan(leafShare(frames.last!.keys), 0.2, "out at 40%: a real curl")
        for k in 1 ... 40 {
            let t = CGFloat(k) / 40
            let s = state(161 + (392 - 161) * t, 437 + 150 * t)
            frames.append((s.progress, frame(page, progress: s.progress, p0: p0, p: s.p)))
        }
        XCTAssertLessThan(leafShare(frames.last!.keys), 0.03, "back at the edge, 150 pt lower: flat")
        XCTAssertGreaterThan(leafShare(frames.last!.keys), 0, "still a sliver, not a cut")
        XCTAssertLessThanOrEqual(worstStep(frames).0, 0.12, "the way back has no jump")

        // The cancel spring, as `PageCurlView.finishInteractive` runs it: from the progress and the held
        // point on screen (kept in reach), along the quadratic to P0, landing as the view does. Released
        // on the way back (a curl on screen) and at the edge.
        for (x, y) in [(CGFloat(373), CGFloat(572)), (392, 587)] {
            let release = state(x, y)
            let onScreen = frame(page, progress: release.progress, p0: p0, p: release.p)
            if x < 380 {
                XCTAssertGreaterThan(leafShare(onScreen), 0.02, "released at \(x): a curl on screen")
            }
            let from = release.progress
            let pFrom = PageCurlGeometry.attachedHeldPoint(p0: p0, p: release.p, spineX: page.spineX, pageHeight: page.height)
            let control = PageCurlGeometry.mix(pFrom, p0, 0.5)
            var spring: [(progress: CGFloat, keys: [UInt16])] = [(from, onScreen)]
            var landed = false
            var i = 0
            while !landed {
                i += 1
                let elapsed = Double(i) / 60
                var progress = PageCurlPanStateMachine.springProgress(
                    elapsed: elapsed, from: from, velocity: 0, target: 0,
                    omega: PageCurlPanStateMachine.omega(progressVelocity: 0)
                )
                if abs(progress) < 0.004 || elapsed > 0.7 {
                    progress = 0
                    landed = true
                }
                let u = from > 0.000_1 ? min(1, max(0, (progress - from) / (0 - from))) : 1
                let q = PageCurlGeometry.springGrab(from: pFrom, control: control, to: p0, u: u)
                spring.append((progress, frame(page, progress: progress, p0: p0, p: q)))
            }
            XCTAssertEqual(
                frame(page, progress: from, p0: p0, p: PageCurlGeometry.springGrab(from: pFrom, control: control, to: p0, u: 0)),
                onScreen,
                "released at \(x): the spring's first frame is the frame on screen"
            )
            let worst = worstStep(spring)
            XCTAssertLessThanOrEqual(worst.0, 0.12, "released at \(x): \(Int(worst.0 * 100))% changed in one spring frame")
            XCTAssertTrue(spring.last!.keys.allSatisfy { $0 == 0 }, "released at \(x): the cancel lands flat")
        }
    }

    /// The vertical offset only tilts the fold. A finger anywhere on the start edge is a flat leaf.
    func testVerticalOffsetAloneDoesNotCurlTheLeaf() {
        let p0 = CGPoint(x: 1, y: 1.0)
        for dy in [CGFloat(-0.6), -0.2, 0.2, 0.6] {
            for back in [CGFloat(0), 0.01] {
                let aim = PageCurlGeometry.fingerAim(
                    p0: p0, origin: CGPoint(x: 0.98, y: 1.0), finger: CGPoint(x: 0.98 + back, y: 1.0 + dy),
                    spineX: 0, peelSign: 1, span: 1, pageHeight: 2.0
                )
                XCTAssertEqual(aim.x, p0.x, accuracy: 0.000_1, "dy \(dy) back \(back)")
                XCTAssertEqual(aim.y, p0.y, accuracy: 0.000_1, "dy \(dy) back \(back)")
            }
        }
        // Out 0.2 and 0.6 down: the tilt is bounded by the travel, the curl is still there.
        let tilted = PageCurlGeometry.fingerAim(
            p0: p0, origin: CGPoint(x: 0.98, y: 1.0), finger: CGPoint(x: 0.78, y: 1.6), spineX: 0, peelSign: 1, span: 1,
            pageHeight: 2.0
        )
        XCTAssertLessThan(tilted.x, 0.85)
        XCTAssertGreaterThan(tilted.y, p0.y)
        XCTAssertLessThanOrEqual(tilted.y - p0.y, (p0.x - tilted.x) * PageCurlGeometry.maxFingerTilt + 0.000_1)
        // A bottom-corner grab lifted up and in keeps its corner angle (45° cap only).
        let corner = PageCurlGeometry.fingerAim(
            p0: CGPoint(x: 1, y: 2.0), origin: CGPoint(x: 0.97, y: 1.95), finger: CGPoint(x: 0.6, y: 1.65),
            spineX: 0, peelSign: 1, span: 1, pageHeight: 2.0
        )
        XCTAssertEqual(corner.y, 1.717, accuracy: 0.005) // the finger's 0.3, less the far-edge fade
        // A thumb on the bottom corner, above the home indicator (y 780 of 874 on a 402 pt phone):
        // 40 pt in and 40 pt up is already a 45° lift.
        let w: CGFloat = 402
        let thumb = PageCurlGeometry.fingerAim(
            p0: CGPoint(x: 1, y: 780 / w), origin: CGPoint(x: 390 / w, y: 780 / w),
            finger: CGPoint(x: 350 / w, y: 740 / w), spineX: 0, peelSign: 1, span: 1, pageHeight: 874 / w
        )
        XCTAssertEqual((780 / w - thumb.y) * w, 40, accuracy: 1.5)
        // Mid-edge, 100 pt in and 100 pt up: most of the tilt is kept.
        let mid = PageCurlGeometry.fingerAim(
            p0: CGPoint(x: 1, y: 437 / w), origin: CGPoint(x: 390 / w, y: 437 / w),
            finger: CGPoint(x: 290 / w, y: 337 / w), spineX: 0, peelSign: 1, span: 1, pageHeight: 874 / w
        )
        XCTAssertGreaterThan((437 / w - mid.y) * w, 60)
        // Starting at the far edge (no lead): still never behind P0, still flat at the start.
        let farEdge = PageCurlGeometry.fingerAim(
            p0: CGPoint(x: 1, y: 1), origin: CGPoint(x: 0.005, y: 1), finger: CGPoint(x: 0.02, y: 1.3),
            spineX: 0, peelSign: 1, span: 1, pageHeight: 2
        )
        XCTAssertEqual(farEdge.x, 1, accuracy: 0.000_1)
        XCTAssertEqual(farEdge.y, 1, accuracy: 0.000_1)
    }

    /// A flick released before the leaf caught the finger springs through the
    /// finger's point, so the corner still rises the way the drag went.
    func testFlickSpringKeepsTheDragAngle() {
        let p0 = CGPoint(x: 1, y: 1.2)
        let aim = CGPoint(x: 0.7, y: 1.0)
        let landing = PageCurlGeometry.commitLanding(p0: p0, spineX: 0, peelSign: 1, span: 1)
        let early = PageCurlGeometry.springGrab(from: p0, control: aim, to: landing, u: 0.2)
        let fold = try? XCTUnwrap(PageCurlGeometry.grabFold(p0: p0, p: early, radius: 0.05, spineX: 0, pageHeight: 2))
        XCTAssertLessThan(fold?.normal.y ?? 0, -0.2)
        let end = PageCurlGeometry.springGrab(from: p0, control: aim, to: landing, u: 1)
        XCTAssertEqual(end.x, landing.x, accuracy: 0.0001)
        XCTAssertEqual(end.y, landing.y, accuracy: 0.0001)
        // A straight control is the old straight path.
        let mid = PageCurlGeometry.springGrab(from: p0, control: PageCurlGeometry.mix(p0, landing, 0.5), to: landing, u: 0.3)
        XCTAssertEqual(mid.x, PageCurlGeometry.mix(p0, landing, 0.3).x, accuracy: 0.0001)
    }

    /// One page, going back: the finger moves right. Dragging up and right
    /// tilts the leaf up, like a forward drag, and the tilt does not depend
    /// on a horizontal threshold. The start does not pop a wedge in.
    func testReversedDragTiltFollowsTheFinger() {
        let page = Page.iPhone
        let p0 = CGPoint(x: 1, y: 1.4)
        func grab(dy: CGFloat, shown: CGFloat) -> CGPoint {
            PageCurlGeometry.reversedGrab(
                p0: p0, fingerDY: dy, shown: shown,
                spineX: page.spineX, peelSign: page.peelSign, span: page.span, pageHeight: page.height
            )
        }
        XCTAssertLessThan(grab(dy: -0.10, shown: 0.5).y, p0.y)
        XCTAssertGreaterThan(grab(dy: 0.10, shown: 0.5).y, p0.y)
        XCTAssertEqual(grab(dy: -0.1, shown: 1).x, -1, accuracy: 0.0001)
        XCTAssertEqual(grab(dy: -0.1, shown: 0).x, 1, accuracy: 0.0001)
        // 5 pt of drift right after the drag starts.
        let drift: CGFloat = 5.0 / 402.0
        let still = frame(page, progress: 0.97, p0: p0, p: grab(dy: 0, shown: 0.97))
        let drifted = frame(page, progress: 0.97, p0: p0, p: grab(dy: -drift, shown: 0.97))
        XCTAssertLessThan(changed(still, drifted), 0.02)
        // The whole uncurl, finger 60 pt up, is smooth.
        let steps = 40
        let frames: [(progress: CGFloat, keys: [UInt16])] = (0 ... steps).map { i in
            let shown = 1 - CGFloat(i) / CGFloat(steps)
            return (CGFloat(i) / CGFloat(steps), frame(page, progress: shown, p0: p0, p: grab(dy: -60.0 / 402.0, shown: shown)))
        }
        var worst: CGFloat = 0
        for i in 1 ..< frames.count {
            worst = max(worst, changed(frames[i - 1].keys, frames[i].keys))
        }
        XCTAssertLessThanOrEqual(worst, 0.12)
    }

    /// Paper does not stretch: wherever the finger goes, the held point stays
    /// within reach of both spine ends, and inside that reach it is untouched.
    func testHeldPointStaysWithinReachOfTheSpine() {
        let p0 = CGPoint(x: 1, y: 2)
        let inside = CGPoint(x: 0.4, y: 1.5)
        XCTAssertEqual(PageCurlGeometry.attachedHeldPoint(p0: p0, p: inside, spineX: 0, pageHeight: 2.17), inside)
        let rTop = hypot(p0.x, p0.y)
        let rBottom = hypot(p0.x, 2.17 - p0.y)
        var last: CGPoint?
        for i in 0 ... 60 {
            let a = CGFloat(i) / 60 * 2 * .pi
            let finger = CGPoint(x: 0.2 + 1.5 * cos(a), y: 1.2 + 1.5 * sin(a))
            let held = PageCurlGeometry.attachedHeldPoint(p0: p0, p: finger, spineX: 0, pageHeight: 2.17)
            XCTAssertLessThanOrEqual(hypot(held.x, held.y), rTop + 0.0001)
            XCTAssertLessThanOrEqual(hypot(held.x, held.y - 2.17), rBottom + 0.0001)
            if let last {
                XCTAssertLessThan(hypot(held.x - last.x, held.y - last.y), 0.3)
            }
            last = held
        }
    }
}
