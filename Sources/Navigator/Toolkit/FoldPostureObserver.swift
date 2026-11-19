//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// The live fold, in the view that hosts the curl. `normalizedX` is nil when
/// there is no active vertical division (flat, cover, tabletop, or a phone).
struct FoldPostureSample: Equatable {
    var division: CGRect?
    var normalizedX: CGFloat?
    var width: CGFloat
}

/// Reads `UIHingeInteraction` and `reservedRegions(kind: .division)`. The hinge
/// callback exists because a pose change does not always resize the view, so
/// `layoutSubviews` alone can miss the activation flip. Public UIKit only.
@MainActor
final class FoldPostureObserver {
    var onChange: ((FoldPostureSample) -> Void)?

    private weak var view: UIView?
    private var installed = false
    private var last: FoldPostureSample?

    func attach(to view: UIView) {
        self.view = view
        installHingeIfNeeded()
        refresh()
    }

    func refresh() {
        guard let view else {
            return
        }
        let sample = Self.sample(in: view)
        guard sample != last else {
            return
        }
        last = sample
        onChange?(sample)
    }

    static func sample(in view: UIView) -> FoldPostureSample {
        let regions = divisionSamples(in: view)
        let frame = PageCurlGeometry.activeVerticalDivision(regions: regions, viewport: view.bounds)
        let x = frame.flatMap { PageCurlGeometry.normalizedDivisionX(of: $0, in: view.bounds) }
        return FoldPostureSample(
            division: frame,
            normalizedX: x,
            width: frame?.width ?? 0
        )
    }

    private static func divisionSamples(in view: UIView) -> [PageCurlDivisionSample] {
        guard #available(iOS 27.1, *) else {
            return []
        }
        return view.reservedRegions(kind: .division).map {
            PageCurlDivisionSample(frame: $0.frame, isActive: $0.isActive)
        }
    }

    private func installHingeIfNeeded() {
        guard !installed, let view else {
            return
        }
        guard #available(iOS 27.1, *) else {
            return
        }
        installed = true
        let interaction = UIHingeInteraction { [weak self] _, _ in
            self?.refresh()
        }
        view.addInteraction(interaction)
    }
}
