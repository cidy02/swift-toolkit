//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import os

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
