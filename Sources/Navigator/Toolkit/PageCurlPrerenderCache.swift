//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// What is on screen when a page bitmap was taken. A cached neighbour is only
/// used under the same key: same spread, same column, same size, and no
/// settings, decoration, posture or reload change since (`contentGeneration`).
struct PageCurlPageKey: Equatable {
    var spread: ObjectIdentifier
    var offsetX: Int
    var width: Int
    var height: Int
    var contentGeneration: Int

    init(spread: ObjectIdentifier, offsetX: CGFloat, size: CGSize, contentGeneration: Int) {
        self.spread = spread
        self.offsetX = Self.rounded(offsetX)
        width = Self.rounded(size.width)
        height = Self.rounded(size.height)
        self.contentGeneration = contentGeneration
    }

    private static func rounded(_ value: CGFloat) -> Int {
        value.isFinite ? Int(value.rounded()) : Int.min
    }
}

/// A coarse, averaged thumbnail of a page bitmap. Two snapshots of the same
/// column match; a highlight, a theme or a reflow does not.
struct PageCurlFingerprint: Equatable {
    static let columns = 24
    static let rows = 48
    /// Largest per-channel difference, in 0–255 levels, that still counts as
    /// the same page. Averaging over a cell hides antialiasing jitter.
    static let tolerance = 6

    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Off the main actor: drawing a full-screen bitmap into the thumbnail
    /// takes a few milliseconds.
    static func of(_ image: CGImage) -> PageCurlFingerprint? {
        let width = columns
        let height = rows
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? PageCurlFingerprint(bytes: pixels) : nil
    }

    /// Largest per-channel difference, or nil when the shapes differ.
    func distance(to other: PageCurlFingerprint) -> Int? {
        guard bytes.count == other.bytes.count, !bytes.isEmpty else {
            return nil
        }
        var largest = 0
        for index in bytes.indices where index % 4 != 3 {
            largest = max(largest, abs(Int(bytes[index]) - Int(other.bytes[index])))
        }
        return largest
    }

    func matches(_ other: PageCurlFingerprint) -> Bool {
        guard let distance = distance(to: other) else {
            return false
        }
        return distance <= Self.tolerance
    }
}

/// Bitmaps of the columns either side of the page on screen, taken while the
/// previous turn's leaf was still covering the web view. A drag that finds
/// its neighbour here arms without scrolling, painting or snapshotting first.
///
/// Holds at most two page bitmaps. Anything that may change what is on
/// screen calls `invalidate`, and the navigator drops it all when the reader
/// closes or goes to the background.
struct PageCurlPrerenderCache {
    enum Miss: Error, Equatable {
        case empty
        case key
        case noNeighbor
        case noFingerprint
        case fingerprint(Int?)
    }

    private(set) var key: PageCurlPageKey?
    private(set) var current: PageCurlFingerprint?
    private var forward: UIImage?
    private var backward: UIImage?

    var isEmpty: Bool {
        forward == nil && backward == nil
    }

    var byteCount: Int {
        [forward, backward].compactMap { $0?.cgImage }.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    /// Replaces everything: the page now on screen and what lies either side.
    mutating func store(
        key: PageCurlPageKey,
        current: PageCurlFingerprint?,
        forward: UIImage?,
        backward: UIImage?
    ) {
        self.key = key
        self.current = current
        self.forward = forward
        self.backward = backward
    }

    /// Adds one neighbour of the page under `key`. A different key starts over,
    /// so a neighbour of another column can never survive.
    mutating func set(_ image: UIImage, for direction: PageCurlTurnDirection, key: PageCurlPageKey, current: PageCurlFingerprint?) {
        if self.key != key {
            store(key: key, current: current, forward: nil, backward: nil)
        } else if self.current == nil {
            self.current = current
        }
        switch direction {
        case .forward:
            forward = image
        case .backward:
            backward = image
        }
    }

    /// The neighbour, if it was taken under `key` and the page on screen
    /// still looks like the one it was taken next to.
    func neighbor(
        _ direction: PageCurlTurnDirection,
        key: PageCurlPageKey,
        onScreen: PageCurlFingerprint?
    ) -> Result<UIImage, Miss> {
        guard let stored = self.key else {
            return .failure(.empty)
        }
        guard stored == key else {
            return .failure(.key)
        }
        let image: UIImage?
        switch direction {
        case .forward:
            image = forward
        case .backward:
            image = backward
        }
        guard let image else {
            return .failure(.noNeighbor)
        }
        guard let current, let onScreen else {
            return .failure(.noFingerprint)
        }
        guard current.matches(onScreen) else {
            return .failure(.fingerprint(current.distance(to: onScreen)))
        }
        return .success(image)
    }

    /// The fingerprint arrives after the store (it is computed off the main
    /// actor). It only applies while the key is unchanged.
    mutating func setCurrent(_ fingerprint: PageCurlFingerprint, key: PageCurlPageKey) {
        guard self.key == key else {
            return
        }
        current = fingerprint
    }

    mutating func invalidate() {
        key = nil
        current = nil
        forward = nil
        backward = nil
    }
}
