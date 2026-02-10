import Foundation
import CoreGraphics

struct CropPlan: Sendable {
    let headerRect: CGRect
    let yAxisRect: CGRect
    let footerRect: CGRect
    let bodyRect: CGRect
}

struct CropPlanner: Sendable {
    func plan(chartBox: CGRect?, axisSide: AxisSide, frameSize: CGSize) -> CropPlan {
        _ = frameSize
        let base = chartBox ?? CGRect(x: 0.06, y: 0.12, width: 0.88, height: 0.76)
        let headerHeight = max(base.height * 0.12, 0.08)
        let footerHeight = max(base.height * 0.12, 0.08)
        let axisWidth = max(base.width * 0.12, 0.08)

        let headerY = max(0, base.minY - headerHeight)
        let headerRect = CGRect(x: base.minX, y: headerY, width: base.width, height: min(headerHeight, base.minY))

        let footerY = min(1 - footerHeight, base.maxY)
        let footerRect = CGRect(x: base.minX, y: footerY, width: base.width, height: min(footerHeight, 1 - footerY))

        let yAxisRect: CGRect
        switch axisSide {
        case .left:
            yAxisRect = CGRect(x: max(0, base.minX - axisWidth), y: base.minY, width: axisWidth, height: base.height)
        case .right:
            yAxisRect = CGRect(x: min(1 - axisWidth, base.maxX), y: base.minY, width: axisWidth, height: base.height)
        case .unknown:
            yAxisRect = CGRect(x: min(1 - axisWidth, base.maxX), y: base.minY, width: axisWidth, height: base.height)
        }

        let bodyRect = base

        return CropPlan(
            headerRect: headerRect.clampedToUnit,
            yAxisRect: yAxisRect.clampedToUnit,
            footerRect: footerRect.clampedToUnit,
            bodyRect: bodyRect.clampedToUnit
        )
    }
}

private extension CGRect {
    var clampedToUnit: CGRect {
        let x = min(max(minX, 0), 1)
        let y = min(max(minY, 0), 1)
        let w = min(max(width, 0), 1 - x)
        let h = min(max(height, 0), 1 - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
