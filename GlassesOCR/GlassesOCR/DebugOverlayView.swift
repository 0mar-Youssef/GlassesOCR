import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DebugOverlayView: View {
    let image: UIImage?
    let chartBox: CGRect?
    let cropPlan: CropPlan?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    let layout = fitRect(for: image.size, in: geometry.size)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: layout.size.width, height: layout.size.height)
                        .position(x: layout.origin.x + layout.size.width / 2, y: layout.origin.y + layout.size.height / 2)

                    overlayPath(in: layout)
                        .stroke(Color.green, lineWidth: 1)

                    if let cropPlan {
                        overlayRect(cropPlan.headerRect, in: layout)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        overlayRect(cropPlan.yAxisRect, in: layout)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        overlayRect(cropPlan.footerRect, in: layout)
                            .stroke(Color.purple, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                    Text("No preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func overlayPath(in layout: CGRect) -> Path {
        guard let chartBox else { return Path() }
        let rect = denormalize(chartBox, in: layout)
        return Path(rect)
    }

    private func overlayRect(_ rect: CGRect, in layout: CGRect) -> Path {
        let rect = denormalize(rect, in: layout)
        return Path(rect)
    }

    private func denormalize(_ rect: CGRect, in layout: CGRect) -> CGRect {
        let x = layout.origin.x + rect.minX * layout.size.width
        let y = layout.origin.y + rect.minY * layout.size.height
        let w = rect.width * layout.size.width
        let h = rect.height * layout.size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func fitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / max(container.height, 1)

        if imageAspect > containerAspect {
            let width = container.width
            let height = width / imageAspect
            let y = (container.height - height) / 2
            return CGRect(x: 0, y: y, width: width, height: height)
        } else {
            let height = container.height
            let width = height * imageAspect
            let x = (container.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: height)
        }
    }
}
