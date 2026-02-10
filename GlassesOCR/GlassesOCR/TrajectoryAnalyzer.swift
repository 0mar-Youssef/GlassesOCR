import Foundation
import CoreGraphics

struct TrajectoryResult: Sendable {
    let trajectory: Trajectory
    let slopeMetric: Double?
    let confidence: Double
}

struct TrajectoryAnalyzer: Sendable {
    func analyze(image: CGImage, priceRange: ClosedRange<Double>) -> TrajectoryResult {
        guard let gray = GrayscaleBuffer(cgImage: image) else {
            return TrajectoryResult(trajectory: .unknown, slopeMetric: nil, confidence: 0)
        }

        let width = gray.width
        let height = gray.height
        guard width > 10, height > 10 else {
            return TrajectoryResult(trajectory: .unknown, slopeMetric: nil, confidence: 0)
        }

        let sampleCount = 32
        let step = max(1, width / sampleCount)
        var samples: [(x: Double, price: Double)] = []

        for x in stride(from: 0, to: width, by: step) {
            var weightSum: Double = 0
            var weightedY: Double = 0
            for y in 0..<height {
                let value = Double(gray[y, x]) / 255.0
                let darkness = max(0, 1 - value)
                if darkness > 0.2 {
                    weightSum += darkness
                    weightedY += Double(y) * darkness
                }
            }
            guard weightSum > 0 else { continue }
            let avgY = weightedY / weightSum
            let price = priceAt(y: avgY, height: Double(height), range: priceRange)
            samples.append((x: Double(x), price: price))
        }

        guard samples.count >= 8 else {
            return TrajectoryResult(trajectory: .unknown, slopeMetric: nil, confidence: 0.2)
        }

        let slope = linearRegressionSlope(samples)
        let normalizedSlope = normalizeSlope(slope: slope, range: priceRange, width: Double(width))

        let residual = regressionResidual(samples, slope: slope)
        let volatility = min(residual / max(priceRange.upperBound - priceRange.lowerBound, 1e-6) * 3.0, 1.0)

        let trajectory: Trajectory
        let threshold = 0.12
        if abs(normalizedSlope) <= threshold {
            trajectory = volatility > 0.55 ? .volatile : .flat
        } else if normalizedSlope > threshold {
            trajectory = .up
        } else {
            trajectory = .down
        }

        let confidence = min(max(0.4 + (1 - volatility) * 0.4 + min(abs(normalizedSlope), 1) * 0.2, 0), 1)

        return TrajectoryResult(trajectory: trajectory, slopeMetric: normalizedSlope, confidence: confidence)
    }

    private func priceAt(y: Double, height: Double, range: ClosedRange<Double>) -> Double {
        let ratio = y / max(height, 1)
        return range.upperBound - ratio * (range.upperBound - range.lowerBound)
    }

    private func linearRegressionSlope(_ samples: [(x: Double, price: Double)]) -> Double {
        let n = Double(samples.count)
        let sumX = samples.reduce(0) { $0 + $1.x }
        let sumY = samples.reduce(0) { $0 + $1.price }
        let sumXY = samples.reduce(0) { $0 + $1.x * $1.price }
        let sumXX = samples.reduce(0) { $0 + $1.x * $1.x }
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-6 else { return 0 }
        return (n * sumXY - sumX * sumY) / denom
    }

    private func regressionResidual(_ samples: [(x: Double, price: Double)], slope: Double) -> Double {
        let meanX = samples.reduce(0) { $0 + $1.x } / Double(samples.count)
        let meanY = samples.reduce(0) { $0 + $1.price } / Double(samples.count)
        let intercept = meanY - slope * meanX
        let residuals = samples.map { abs(($0.x * slope + intercept) - $0.price) }
        return residuals.reduce(0, +) / Double(samples.count)
    }

    private func normalizeSlope(slope: Double, range: ClosedRange<Double>, width: Double) -> Double {
        let rangeSpan = max(range.upperBound - range.lowerBound, 1e-6)
        let expectedPerPixel = rangeSpan / max(width, 1)
        let normalized = slope / expectedPerPixel
        return max(min(normalized / 5.0, 1), -1)
    }
}

private struct GrayscaleBuffer {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width
        self.height = height
        self.data = buffer
    }

    subscript(_ y: Int, _ x: Int) -> UInt8 {
        data[y * width + x]
    }
}
