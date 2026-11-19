//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Whether a posture or size reflow still owes the reader the paragraph they
/// were on. A newer reflow replaces the hold. A move or a jump drops it.
struct ReflowAnchorMachine: Equatable {
    enum Phase: Equatable {
        case idle
        case holding(token: UInt)
    }

    private(set) var phase: Phase = .idle
    private(set) var token: UInt = 0

    var isHolding: Bool {
        if case .holding = phase {
            return true
        }
        return false
    }

    func holds(_ token: UInt) -> Bool {
        if case let .holding(held) = phase {
            return held == token
        }
        return false
    }

    /// Starts a reflow. The previous hold, if any, will not restore.
    mutating func beginReflow() -> UInt {
        token &+= 1
        phase = .holding(token: token)
        return token
    }

    /// The reader turned a page or jumped. The pending restore must not run.
    mutating func userNavigated() {
        guard isHolding else {
            return
        }
        phase = .idle
    }

    /// Layout went quiet. True once, and only for the token still held.
    mutating func layoutDidQuiet(token: UInt) -> Bool {
        guard holds(token) else {
            return false
        }
        phase = .idle
        return true
    }
}

/// The navigator events that can arrive while a reflow anchor is held.
enum ReflowAnchorNavigation: Equatable {
    case load
    case loaded
    case jump
    case jumped
    case move
    case interactiveMove
    case moved

    /// T-450: a real navigation cancels the pending restore. The matching
    /// "finished" events do not, or the curl's own `.moved` would drop the
    /// anchor the posture change just took.
    var cancelsPendingRestore: Bool {
        switch self {
        case .jump, .move, .interactiveMove:
            return true
        case .load, .loaded, .jumped, .moved:
            return false
        }
    }
}
