//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// Holds the first visible element across a column-count, column-gap, or
/// viewport change, then scrolls back to it once layout has been quiet.
/// A move or a jump drops the hold so the restore cannot undo the reader.
@MainActor
final class ReflowPositionKeeper {
    /// How long the layout has to stay quiet before the anchor is restored.
    static let quietNanoseconds: UInt64 = 150_000_000

    private var machine = ReflowAnchorMachine()
    private var anchor: Locator?
    private var task: Task<Void, Never>?
    private weak var spread: EPUBSpreadView?
    private var ticket: UInt = 0
    private var refreshGeneration: UInt = 0

    /// Last element locator taken while idle. A drag peeks the next column
    /// under the cover, so the live DOM is the wrong anchor until the peek
    /// has been reverted. This one was taken before the finger went down.
    private(set) var settledVisibleLocator: Locator?

    var isHolding: Bool {
        machine.isHolding
    }

    func noteSettledLocation(on spread: EPUBSpreadView?) {
        guard !machine.isHolding, let spread, spread.isSpreadReadyForPresentation else {
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task { @MainActor in
            let found = await spread.findFirstVisibleElementLocator()
            guard generation == self.refreshGeneration, !self.machine.isHolding, let found else {
                return
            }
            guard self.contains(found, spread: spread) else {
                return
            }
            self.settledVisibleLocator = found
        }
    }

    /// A drag or a turn started. The probe already in flight must not write
    /// the page it peeks. The locator saved before the gesture stays.
    func dropInFlightSettledProbe() {
        refreshGeneration &+= 1
    }

    /// The spread this locator was taken on is gone.
    func discardSettledAnchor() {
        refreshGeneration &+= 1
        settledVisibleLocator = nil
    }

    /// Idle locator if it is still in `spread`, otherwise `fallback` if that is.
    /// A foreign idle locator is dropped so the next spread cannot restore it.
    func resolvedAnchor(on spread: EPUBSpreadView, fallback: Locator?) -> Locator? {
        if let settled = settledVisibleLocator, !contains(settled, spread: spread) {
            settledVisibleLocator = nil
            refreshGeneration &+= 1
        }
        return ReflowSettledAnchor.choose(
            settled: settledVisibleLocator,
            fallback: fallback
        ) { self.contains($0, spread: spread) }
    }

    private func contains(_ locator: Locator, spread: EPUBSpreadView) -> Bool {
        guard let index = spread.viewModel.readingOrder.firstIndexWithHREF(locator.href) else {
            return false
        }
        return spread.spread.contains(index: index)
    }

    /// The element to restore is known already (a probe that finished, or the
    /// settled locator from before a drag). A second call in the same quiet
    /// window keeps the first anchor.
    func hold(on spread: EPUBSpreadView?, locator: Locator?) {
        guard let spread else {
            return
        }
        let locator = locator.flatMap { contains($0, spread: spread) ? $0 : nil }
            ?? resolvedAnchor(on: spread, fallback: nil)
        if machine.isHolding {
            self.spread = spread
            if anchor == nil {
                anchor = locator
            }
            return
        }
        _ = machine.beginReflow()
        self.spread = spread
        anchor = locator
        spread.setSuppressingProgressionUpdates(true)
    }

    /// The size-change probe starts before this returns, so the script is in
    /// flight against the layout that is still on screen. A hold that is
    /// already open keeps its anchor: a probe started after the reflow would
    /// photograph the snapped page.
    func hold(
        on spread: EPUBSpreadView?,
        fallback: Locator?,
        startProbe: @escaping (@escaping (Locator?) -> Void) -> Void
    ) {
        guard let spread else {
            return
        }
        let resolved = resolvedAnchor(on: spread, fallback: fallback)
        if machine.isHolding {
            self.spread = spread
            if anchor == nil {
                anchor = resolved
            }
            return
        }
        let token = machine.beginReflow()
        self.spread = spread
        anchor = resolved
        spread.setSuppressingProgressionUpdates(true)
        startProbe { [weak self] locator in
            guard let self, let spread = self.spread, self.machine.holds(token), let locator,
                  self.contains(locator, spread: spread) else {
                return
            }
            self.anchor = locator
        }
    }

    func cancelForNavigation() {
        guard machine.isHolding else {
            return
        }
        machine.userNavigated()
        ticket &+= 1
        task?.cancel()
        task = nil
        let spread = self.spread
        self.spread = nil
        anchor = nil
        spread?.setSuppressingProgressionUpdates(false)
    }

    func scheduleRestore() {
        guard machine.isHolding else {
            return
        }
        ticket &+= 1
        let ticket = ticket
        let token = machine.token
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.quietNanoseconds)
            } catch {
                return
            }
            guard ticket == self.ticket, !Task.isCancelled else {
                return
            }
            await self.restore(token: token, ticket: ticket)
        }
    }

    private func restore(token: UInt, ticket: UInt) async {
        guard machine.layoutDidQuiet(token: token) else {
            return
        }
        let spread = self.spread
        let anchor = self.anchor
        self.spread = nil
        self.anchor = nil
        if ticket != self.ticket {
            spread?.setSuppressingProgressionUpdates(false)
            return
        }
        if let spread, spread.superview != nil, let anchor {
            await spread.go(to: .locator(anchor), animated: false)
            guard ticket == self.ticket else {
                spread.setSuppressingProgressionUpdates(false)
                return
            }
            await spread.awaitNextPaint()
        }
        spread?.setSuppressingProgressionUpdates(false)
    }
}
