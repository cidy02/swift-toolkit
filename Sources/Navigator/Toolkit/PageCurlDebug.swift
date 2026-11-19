//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import os

/// Pose lines for a Duo check. Off unless the process was launched with
/// `-ReadiumCurlDebug YES`. The navigator and the host app share a process,
/// so the host does not forward the flag.
enum PageCurlDebug {
    static let enabled: Bool = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-ReadiumCurlDebug"), index + 1 < args.count else {
            return false
        }
        return args[index + 1] == "YES"
    }()

    private static let logger = Logger(subsystem: "org.readium.navigator", category: "curl")

    static func log(_ message: String) {
        guard enabled else {
            return
        }
        logger.info("\(message, privacy: .public)")
    }
}
