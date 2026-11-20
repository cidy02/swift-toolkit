//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import os
import QuartzCore

/// Page-curl geometry lines. Off unless the process was launched with
/// `-ReadiumCurlDebug YES`, and compiled out of release builds. The navigator
/// and the host app share a process, so the host does not forward the flag.
enum PageCurlDebug {
    static let enabled: Bool = {
        #if !DEBUG
            return false
        #endif
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-ReadiumCurlDebug"), index + 1 < args.count else {
            return false
        }
        return args[index + 1] == "YES"
    }()

    /// Full centred crease clearance, in points. Ignored unless curl debug is
    /// on. The navigator applies half of it as `--RS__foldInset` and forces two
    /// columns, so a simulator can page through the fold clearance.
    static let foldClearanceOverride: CGFloat? = {
        guard enabled else {
            return nil
        }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-ReadiumFoldClearance"), index + 1 < args.count,
              let value = Double(args[index + 1]), value.isFinite, value > 0
        else {
            return nil
        }
        return CGFloat(value)
    }()

    private static let logger = Logger(subsystem: "org.readium.navigator", category: "curl")

    static func log(_ message: String) {
        guard enabled else {
            return
        }
        logger.info("\(message, privacy: .public)")
    }
}

/// Drag latency marks (`curl-t`), in milliseconds since the touch-down that
/// started the drag. Curl debug only, so release builds never record them.
@MainActor
enum PageCurlLatency {
    private static var origin: CFTimeInterval = 0

    /// `timestamp` is the touch's own event time (the same clock as
    /// `CACurrentMediaTime`), so delivery delay is part of every later mark.
    static func touchDown(at timestamp: CFTimeInterval, x: CGFloat) {
        guard PageCurlDebug.enabled else {
            return
        }
        origin = timestamp
        trail = [(timestamp, x)]
        PageCurlDebug.log("curl-t touch-down +0.0ms delivered=+\(ms(CACurrentMediaTime() - timestamp))ms")
    }

    static func mark(_ name: String, _ extra: String = "") {
        guard PageCurlDebug.enabled, origin > 0 else {
            return
        }
        PageCurlDebug.log("curl-t \(name) +\(sinceTouchDown(CACurrentMediaTime()))ms \(extra)")
    }

    static func sinceTouchDown(_ time: CFTimeInterval) -> String {
        ms(time - origin)
    }

    /// Finger x (points, host view) per pan sample since the touch-down.
    private(set) static var trail: [(time: CFTimeInterval, x: CGFloat)] = []

    static func finger(x: CGFloat) {
        guard PageCurlDebug.enabled, trail.count < 512, x.isFinite else {
            return
        }
        trail.append((CACurrentMediaTime(), x))
    }

    static func ms(_ seconds: CFTimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}
