//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

class ReflowAnchorTests: XCTestCase {
    func testANewerReflowReplacesTheHoldAndOnlyThatTokenRestores() {
        var machine = ReflowAnchorMachine()
        XCTAssertFalse(machine.isHolding)
        let first = machine.beginReflow()
        XCTAssertTrue(machine.holds(first))
        let second = machine.beginReflow()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(machine.holds(first))
        XCTAssertTrue(machine.holds(second))
        XCTAssertFalse(machine.layoutDidQuiet(token: first))
        XCTAssertTrue(machine.isHolding)
        XCTAssertTrue(machine.layoutDidQuiet(token: second))
        XCTAssertFalse(machine.isHolding)
        XCTAssertFalse(machine.layoutDidQuiet(token: second))
    }

    func testUserNavigationDropsAHoldAndDoesNothingWhenIdle() {
        var machine = ReflowAnchorMachine()
        machine.userNavigated()
        XCTAssertFalse(machine.isHolding)
        let token = machine.beginReflow()
        machine.userNavigated()
        XCTAssertFalse(machine.holds(token))
        XCTAssertFalse(machine.layoutDidQuiet(token: token))
    }

    /// The curl's own `.moved` must not cancel the restore that a
    /// posture change is waiting to run. A move or a jump does.
    func testOnlyAMoveOrAJumpCancelsThePendingRestore() {
        XCTAssertTrue(ReflowAnchorNavigation.jump.cancelsPendingRestore)
        XCTAssertTrue(ReflowAnchorNavigation.move.cancelsPendingRestore)
        XCTAssertTrue(ReflowAnchorNavigation.interactiveMove.cancelsPendingRestore)
        XCTAssertFalse(ReflowAnchorNavigation.load.cancelsPendingRestore)
        XCTAssertFalse(ReflowAnchorNavigation.loaded.cancelsPendingRestore)
        XCTAssertFalse(ReflowAnchorNavigation.jumped.cancelsPendingRestore)
        XCTAssertFalse(ReflowAnchorNavigation.moved.cancelsPendingRestore)
    }

    func testSettledAnchorIsDroppedWhenItBelongsToAnotherSpread() {
        XCTAssertEqual(
            ReflowSettledAnchor.choose(settled: "chap1", fallback: "chap2") { $0 == "chap2" },
            "chap2"
        )
        XCTAssertEqual(
            ReflowSettledAnchor.choose(settled: "chap2", fallback: "chap1") { $0 == "chap2" },
            "chap2"
        )
        XCTAssertNil(ReflowSettledAnchor.choose(settled: "chap1", fallback: "chap3") { $0 == "chap2" })
        XCTAssertNil(ReflowSettledAnchor.choose(settled: nil, fallback: nil) { _ in true })
    }
}
