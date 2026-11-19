//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// A finger curl's own touch goes down while the navigator is idle and comes
/// up while it is `.interactiveMoving`. Edge taps died after the first
/// committed drag because that up never reached the tap observers.
@MainActor
class PointerBusyDeliveryTests: XCTestCase {
    private func event(_ id: Int, _ phase: PointerEvent.Phase, x: CGFloat = 370) -> PointerEvent {
        PointerEvent(
            pointer: .touch(TouchPointer(id: id)),
            phase: phase,
            location: CGPoint(x: x, y: 440),
            modifiers: []
        )
    }

    /// The navigator's filter: everything while idle, else the busy rule.
    private func deliver(_ event: PointerEvent, busy: Bool, to observer: ActivatePointerObserver) async {
        let delivered = busy ? event.deliveredWhileNavigatorBusy() : event
        if let delivered {
            _ = await observer.didReceive(delivered)
        }
    }

    private func tapObserver(counting taps: @escaping () -> Void) -> ActivatePointerObserver {
        .tap { _ in
            taps()
            return true
        }
    }

    func testDownAndMoveAreDroppedWhileBusy() {
        XCTAssertNil(event(1, .down).deliveredWhileNavigatorBusy())
        XCTAssertNil(event(1, .move).deliveredWhileNavigatorBusy())
    }

    func testUpAndCancelEndTheSequenceAsACancelWhileBusy() {
        XCTAssertEqual(event(1, .up).deliveredWhileNavigatorBusy()?.phase, .cancel)
        XCTAssertEqual(event(1, .cancel).deliveredWhileNavigatorBusy()?.phase, .cancel)
        XCTAssertEqual(event(1, .up).deliveredWhileNavigatorBusy()?.pointer.id, AnyHashable(1))
    }

    func testTapStillActivatesAfterADragWhoseUpLandedWhileBusy() async {
        var taps = 0
        let observer = tapObserver { taps += 1 }
        // The drag: down and the first moves while idle, the pan then begins.
        await deliver(event(1, .down, x: 388), busy: false, to: observer)
        await deliver(event(1, .move, x: 360), busy: false, to: observer)
        await deliver(event(1, .move, x: 120), busy: true, to: observer)
        await deliver(event(1, .up, x: 90), busy: true, to: observer)
        XCTAssertEqual(taps, 0)
        // Back to idle: an edge tap.
        await deliver(event(2, .down, x: 28), busy: false, to: observer)
        await deliver(event(2, .up, x: 28), busy: false, to: observer)
        XCTAssertEqual(taps, 1)
    }

    func testDroppingTheUpLeavesTheTapObserverStuck() async {
        // The old filter dropped every event while busy.
        var taps = 0
        let observer = tapObserver { taps += 1 }
        _ = await observer.didReceive(event(1, .down, x: 388))
        _ = await observer.didReceive(event(1, .move, x: 360))
        // up while `.interactiveMoving`: dropped.
        _ = await observer.didReceive(event(2, .down, x: 28))
        _ = await observer.didReceive(event(2, .up, x: 28))
        XCTAssertEqual(taps, 0)
    }

    func testAnUpThatLandsMidTurnDoesNotActivate() async {
        var taps = 0
        let observer = tapObserver { taps += 1 }
        await deliver(event(1, .down), busy: false, to: observer)
        await deliver(event(1, .up), busy: true, to: observer)
        XCTAssertEqual(taps, 0)
        await deliver(event(2, .down), busy: false, to: observer)
        await deliver(event(2, .up), busy: false, to: observer)
        XCTAssertEqual(taps, 1)
    }
}
