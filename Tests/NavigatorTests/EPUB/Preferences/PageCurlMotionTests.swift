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
        let radius = PageCurlGeometry.cylinderRadius(progress: progress, span: page.span)
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
