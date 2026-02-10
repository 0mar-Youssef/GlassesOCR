import Foundation
import CoreGraphics

final class ChartStabilizer {
    private var lastBox: CGRect?
    private var lastConfidence: Double = 0
    private let alpha: Double

    init(alpha: Double = 0.35) {
        self.alpha = min(max(alpha, 0.05), 0.95)
    }

    func stabilize(result: ChartGateResult) -> ChartGateResult {
        let smoothedConf = alpha * result.confidence + (1 - alpha) * lastConfidence
        lastConfidence = smoothedConf

        var smoothedBox = result.chartBox
        if let box = result.chartBox {
            if let last = lastBox {
                smoothedBox = interpolate(from: last, to: box, alpha: alpha)
            }
            lastBox = smoothedBox
        }

        return ChartGateResult(
            isChart: smoothedConf >= 0.55,
            confidence: smoothedConf,
            chartBox: smoothedBox,
            axisSide: result.axisSide,
            signals: result.signals
        )
    }

    private func interpolate(from a: CGRect, to b: CGRect, alpha: Double) -> CGRect {
        let lerp = { (x: CGFloat, y: CGFloat) -> CGFloat in
            CGFloat(alpha) * y + CGFloat(1 - alpha) * x
        }
        return CGRect(
            x: lerp(a.minX, b.minX),
            y: lerp(a.minY, b.minY),
            width: lerp(a.width, b.width),
            height: lerp(a.height, b.height)
        )
    }
}
