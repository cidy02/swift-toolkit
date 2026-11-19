//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// Represents a pointer event (e.g. touch, mouse) emitted by a navigator.
public struct PointerEvent: Equatable {
    /// Pointer causing this event.
    public var pointer: Pointer

    /// Phase of this event, e.g. up or move.
    public var phase: Phase

    /// Location of the pointer event relative to the navigator's view.
    public var location: CGPoint

    /// Key modifiers pressed alongside the pointer.
    public var modifiers: KeyModifiers

    /// The content element under the pointer, if recognized by the navigator.
    @_spi(ExperimentalTargetElement) public var targetElement: TargetElement?

    /// A content element targeted by a pointer event, paired with its
    /// on-screen frame.
    @_spi(ExperimentalTargetElement) public struct TargetElement: Equatable {
        /// Frame of the element relative to the navigator's view.
        public var frame: CGRect

        /// The content element under the pointer.
        public var content: any ContentElement

        public init(frame: CGRect, content: any ContentElement) {
            self.frame = frame
            self.content = content
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.frame == rhs.frame && lhs.content.isEqualTo(rhs.content)
        }
    }

    /// Phase of a pointer event.
    public enum Phase: Equatable, CustomStringConvertible {
        /// Fired when a pointer becomes active.
        case down

        /// Fired when a pointer changes coordinates. This event is also used if
        /// the change in pointer state cannot be reported by other events.
        case move

        /// Fired when a pointer is no longer active.
        case up

        /// Fired if the navigator cannot generate more events for this pointer,
        /// for example because the interaction was captured by the system.
        case cancel

        public var description: String {
            switch self {
            case .down: "down"
            case .move: "move"
            case .up: "up"
            case .cancel: "cancel"
            }
        }
    }
}

/// Represents a pointer device, such as a mouse or a physical touch.
public enum Pointer: Equatable, CustomStringConvertible {
    case touch(TouchPointer)
    case mouse(MousePointer)

    /// Unique identifier for this pointer.
    public var id: AnyHashable {
        switch self {
        case let .touch(pointer): pointer.id
        case let .mouse(pointer): pointer.id
        }
    }

    /// Type of the pointer.
    public var type: PointerType {
        switch self {
        case .touch: .touch
        case .mouse: .mouse
        }
    }

    public var description: String {
        switch self {
        case let .touch(pointer):
            return "touch (\(pointer.id))"
        case let .mouse(pointer):
            return "mouse (\(pointer.id)) \(pointer.buttons)"
        }
    }
}

/// Type of a pointer.
public enum PointerType: Equatable, CaseIterable {
    case touch
    case mouse
}

/// Represents a physical touch pointer.
public struct TouchPointer: Identifiable, Equatable {
    /// Unique identifier for this pointer.
    public let id: AnyHashable

    public init(id: AnyHashable) {
        self.id = id
    }
}

/// Represents a mouse pointer.
public struct MousePointer: Identifiable, Equatable {
    /// Unique identifier for this pointer.
    public let id: AnyHashable

    /// Indicates which buttons are pressed on the mouse.
    public let buttons: MouseButtons

    public init(id: AnyHashable, buttons: MouseButtons) {
        self.id = id
        self.buttons = buttons
    }
}

/// Represents a set of mouse buttons.
///
/// The values are derived from https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/buttons#value
public struct MouseButtons: OptionSet, Equatable, CustomStringConvertible {
    /// Main button, usually the left button.
    public static let main = MouseButtons(rawValue: 1 << 0)

    /// Secondary button, usually the right button.
    public static let secondary = MouseButtons(rawValue: 1 << 1)

    /// Auxiliary button, usually the wheel button or the middle button.
    public static let auxiliary = MouseButtons(rawValue: 1 << 2)

    /// 4th button (typically the "Browser Back" button).
    public static let fourth = MouseButtons(rawValue: 1 << 3)

    /// 5th button (typically the "Browser Forward" button)
    public static let fifth = MouseButtons(rawValue: 1 << 4)

    public var rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public var description: String {
        var buttons: [String] = []
        if contains(.main) {
            buttons.append("main")
        }
        if contains(.secondary) {
            buttons.append("secondary")
        }
        if contains(.auxiliary) {
            buttons.append("auxiliary")
        }
        if contains(.fourth) {
            buttons.append("fourth")
        }
        if contains(.fifth) {
            buttons.append("fifth")
        }

        guard !buttons.isEmpty else {
            return "[]"
        }

        return "[" + buttons.joined(separator: ",") + "]"
    }
}

extension PointerEvent {
    /// What a navigator that is turning or loading still delivers. A down or a
    /// move is dropped. An up or a cancel still ends the pointer's sequence, as
    /// a cancel: a tap observer that saw the down resets instead of waiting
    /// forever for an up, and nothing activates mid-turn. Dropping the up of a
    /// finger curl's touch left every tap observer `.failed` on that pointer.
    func deliveredWhileNavigatorBusy() -> PointerEvent? {
        switch phase {
        case .down, .move:
            return nil
        case .up, .cancel:
            var event = self
            event.phase = .cancel
            return event
        }
    }
}

/// Pointer sequences the observers saw start and have not seen end. The web
/// view drops a pointer's up when it lands on a decoration, and a reload
/// drops it with the page, so the observers can wait forever on a down. When
/// the navigator leaves idle (a turn, a load, a jump) each open sequence is
/// ended with a cancel.
struct OpenPointerSequences {
    private var open: [AnyHashable: PointerEvent] = [:]

    var isEmpty: Bool {
        open.isEmpty
    }

    mutating func note(_ event: PointerEvent) {
        switch event.phase {
        case .down:
            open[event.pointer.id] = event
        case .move:
            if open[event.pointer.id] != nil {
                open[event.pointer.id] = event
            }
        case .up, .cancel:
            open.removeValue(forKey: event.pointer.id)
        }
    }

    /// One cancel per open sequence, and forgets them.
    mutating func cancelAll() -> [PointerEvent] {
        let events = open.values.map { event -> PointerEvent in
            var cancel = event
            cancel.phase = .cancel
            return cancel
        }
        open.removeAll()
        return events
    }
}
