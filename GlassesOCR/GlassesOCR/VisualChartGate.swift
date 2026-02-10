import Foundation
import Vision
import CoreGraphics

enum AxisSide: String, Sendable {
    case left
    case right
    case unknown
}

struct ChartGateResult: Sendable {
    let isChart: Bool
    let confidence: Double
    let chartBox: CGRect?
    let axisSide: AxisSide
    let signals: [String: Double]
}

final class VisualChartGate: Sendable {
    private let minConfidence: Double

    init(minConfidence: Double = 0.55) {
        self.minConfidence = minConfidence
    }

    func evaluate(snapshot: FrameSnapshot) async -> ChartGateResult {
        let lowSignals = computeLowResSignals(snapshot: snapshot)
        let textSignals = await computeTextSignals(snapshot: snapshot)

        let wickDensity = lowSignals["wick"] ?? 0
        let grid = lowSignals["grid"] ?? 0
        let ink = lowSignals["ink"] ?? 0
        let axis = textSignals["axis"] ?? 0
        let textPenalty = textSignals["textPenalty"] ?? 0
        let linePenalty = lowSignals["linePenalty"] ?? 0

        var confidence = 0.35 * wickDensity + 0.20 * grid + 0.25 * ink + 0.20 * axis
        confidence -= (textPenalty + linePenalty)
        confidence = min(max(confidence, 0), 1)

        let axisSide: AxisSide
        if let left = textSignals["axisLeft"], let right = textSignals["axisRight"], abs(left - right) > 0.15 {
            axisSide = left > right ? .left : .right
        } else {
            axisSide = .unknown
        }

        let chartBox = defaultChartBox(axisSide: axisSide)
        let isChart = confidence >= minConfidence

        var signals = lowSignals
        signals.merge(textSignals) { _, new in new }
        signals["confidence"] = confidence

        return ChartGateResult(
            isChart: isChart,
            confidence: confidence,
            chartBox: chartBox,
            axisSide: axisSide,
            signals: signals
        )
    }

    // MARK: - Low-res signals

    private func computeLowResSignals(snapshot: FrameSnapshot) -> [String: Double] {
        var wickDensity: Double = 0
        var gridScore: Double = 0
        var inkRatio: Double = 0
        var linePenalty: Double = 0

        snapshot.withLowResGrayBytes { buffer, width, height in
            guard width > 1, height > 1 else { return }

            var verticalEdges: Double = 0
            var horizontalEdges: Double = 0
            var darkCount: Double = 0
            let total = Double(width * height)

            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    let idx = row + x
                    let value = Double(buffer[idx]) / 255.0
                    if value < 0.65 { darkCount += 1 }
                    if x > 0 {
                        let left = Double(buffer[idx - 1]) / 255.0
                        verticalEdges += abs(value - left)
                    }
                    if y > 0 {
                        let up = Double(buffer[idx - width]) / 255.0
                        horizontalEdges += abs(value - up)
                    }
                }
            }

            let normFactor = total
            let vEdge = min(verticalEdges / normFactor, 1)
            let hEdge = min(horizontalEdges / normFactor, 1)

            wickDensity = min(vEdge * 2.0, 1.0)
            inkRatio = min(darkCount / total / 0.35, 1.0)

            let ratio = hEdge > 0 ? vEdge / hEdge : 0
            linePenalty = ratio < 0.6 ? 0.15 : 0

            // Grid score via row/column projection variance
            var rowSums = [Double](repeating: 0, count: height)
            var colSums = [Double](repeating: 0, count: width)
            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    let value = Double(buffer[row + x]) / 255.0
                    rowSums[y] += (1 - value)
                    colSums[x] += (1 - value)
                }
            }
            let rowVar = variance(of: rowSums)
            let colVar = variance(of: colSums)
            gridScore = min(((rowVar + colVar) * 1.4), 1.0)
        }

        return [
            "wick": wickDensity,
            "grid": gridScore,
            "ink": inkRatio,
            "linePenalty": linePenalty
        ]
    }

    private func variance(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return min(variance / max(mean * mean, 1e-6), 1.0)
    }

    // MARK: - Text signals

    private func computeTextSignals(snapshot: FrameSnapshot) async -> [String: Double] {
        guard let cgImage = snapshot.midResCGImage() else { return [:] }

        return await withCheckedContinuation { continuation in
            let request = VNDetectTextRectanglesRequest { request, _ in
                guard let results = request.results as? [VNTextObservation], !results.isEmpty else {
                    continuation.resume(returning: ["axis": 0, "textPenalty": 0, "axisLeft": 0, "axisRight": 0])
                    return
                }

                var leftCount: Double = 0
                var rightCount: Double = 0
                var centerCount: Double = 0

                for observation in results {
                    let box = observation.boundingBox
                    let midX = box.midX
                    if midX < 0.20 {
                        leftCount += 1
                    } else if midX > 0.80 {
                        rightCount += 1
                    } else {
                        centerCount += 1
                    }
                }

                let total = max(leftCount + rightCount + centerCount, 1)
                let axisScore = min((leftCount + rightCount) / 8.0, 1.0)
                let textPenalty = centerCount / total > 0.6 ? 0.18 : 0

                continuation.resume(returning: [
                    "axis": axisScore,
                    "textPenalty": textPenalty,
                    "axisLeft": min(leftCount / 6.0, 1.0),
                    "axisRight": min(rightCount / 6.0, 1.0)
                ])
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: ["axis": 0, "textPenalty": 0, "axisLeft": 0, "axisRight": 0])
                }
            }
        }
    }

    private func defaultChartBox(axisSide: AxisSide) -> CGRect {
        let top: CGFloat = 0.12
        let bottom: CGFloat = 0.12
        let left: CGFloat = axisSide == .left ? 0.16 : 0.06
        let right: CGFloat = axisSide == .right ? 0.16 : 0.06
        return CGRect(
            x: left,
            y: top,
            width: max(0.05, 1 - left - right),
            height: max(0.05, 1 - top - bottom)
        )
    }
}
