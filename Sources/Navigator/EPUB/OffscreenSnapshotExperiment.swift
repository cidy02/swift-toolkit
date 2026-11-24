// BUG-14 experiment only (branch kudos/bug14-offscreen). Not for merge.
import UIKit
import WebKit

@MainActor
enum OffscreenSnapshotExperiment {
    static var ran = false
    static let out = "/Users/cidy02/kudos-redesign-work/out/bug14/offscreen-app"

    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-ReadiumOffscreenExperiment"), i + 1 < args.count else { return false }
        return args[i + 1] == "YES"
    }

    static func snap(_ web: WKWebView, rect: CGRect, after: Bool, width: CGFloat? = nil) async -> UIImage? {
        await withCheckedContinuation { c in
            let cfg = WKSnapshotConfiguration()
            cfg.rect = rect
            cfg.afterScreenUpdates = after
            if let width { cfg.snapshotWidth = NSNumber(value: Double(width)) }
            web.takeSnapshot(with: cfg) { image, error in
                if let error { PageCurlDebug.log("EXP snapshot error \(error)") }
                c.resume(returning: image)
            }
        }
    }

    static func save(_ image: UIImage?, _ name: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        if let data = image?.pngData() { try? data.write(to: URL(fileURLWithPath: "\(out)/\(name).png")) }
    }

    static func run(spread: EPUBReflowableSpreadView, state: @escaping (String) -> String) async {
        guard !ran else { return }
        ran = true
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let web = spread.webView
        let w = web.bounds.width, h = web.bounds.height
        PageCurlDebug.log("EXP begin web=\(web.bounds) \(state("before"))")
        let visible = await snap(web, rect: web.bounds, after: true)
        save(visible, "0-visible")
        var shots: [(String, UIImage?)] = []
        let variants: [(String, CGRect)] = [
            ("right", CGRect(x: w, y: 0, width: w, height: h)),
            ("left", CGRect(x: -w, y: 0, width: w, height: h)),
            ("wide", CGRect(x: 0, y: 0, width: 2 * w, height: h)),
        ]
        for (name, rect) in variants {
            for after in [false, true] {
                let t0 = CACurrentMediaTime()
                let img = await snap(web, rect: rect, after: after)
                PageCurlDebug.log("EXP \(name) after=\(after) took=\(Int((CACurrentMediaTime() - t0) * 1000))ms size=\(String(describing: img?.size)) \(state("during"))")
                save(img, "1-\(name)-after\(after)")
                shots.append(("\(name)-\(after)", img))
            }
        }
        PageCurlDebug.log("EXP snapshots done \(state("after-snapshots"))")
        let truth = await spread.prepareCurlIncoming(direction: .right, background: .white)
        PageCurlDebug.log("EXP real turn \(state("during-real-turn"))")
        save(truth, "2-truth-prepareCurlIncoming")
        await spread.revertCurlIncoming()
        try? await Task.sleep(nanoseconds: 600_000_000)
        PageCurlDebug.log("EXP reverted \(state("after-revert"))")
        func fp(_ i: UIImage?) -> PageCurlFingerprint? { i?.cgImage.flatMap { PageCurlFingerprint.of($0) } }
        let t = fp(truth), v = fp(visible)
        PageCurlDebug.log("EXP truth-vs-visible=\(String(describing: v.flatMap { t?.distance(to: $0) }))")
        for (name, img) in shots {
            PageCurlDebug.log("EXP \(name): vs truth=\(String(describing: fp(img).flatMap { t?.distance(to: $0) })) vs visible=\(String(describing: fp(img).flatMap { v?.distance(to: $0) }))")
        }
    }
}
