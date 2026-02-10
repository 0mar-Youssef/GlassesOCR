import Foundation
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Immutable, Sendable snapshot of a frame for multi-stage processing.
/// Stores low-res grayscale data for gating/tracking, a mid-res JPEG for color/trajectory,
/// and a full-res lossless PNG for OCR crops.
struct FrameSnapshot: Sendable {
    let capturedAt: Date
    let width: Int
    let height: Int

    let lowResGray: Data
    let lowResSize: CGSize

    let midResJPEG: Data
    let midResSize: CGSize

    let fullResPNG: Data

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init?(pixelBuffer: CVPixelBuffer, capturedAt: Date = Date()) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        self.capturedAt = capturedAt
        self.width = width
        self.height = height

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Low-res grayscale (256px wide)
        let lowTargetWidth: CGFloat = 256
        let lowScale = lowTargetWidth / CGFloat(width)
        let lowTargetHeight = max(1, Int((CGFloat(height) * lowScale).rounded()))
        let lowSize = CGSize(width: Int(lowTargetWidth), height: lowTargetHeight)

        guard let lowResGray = FrameSnapshot.renderGrayData(
            from: ciImage,
            targetSize: lowSize,
            context: FrameSnapshot.ciContext
        ) else { return nil }

        self.lowResGray = lowResGray
        self.lowResSize = lowSize

        // Mid-res color (512px wide) for trajectory/color analysis
        let midTargetWidth: CGFloat = 512
        let midScale = midTargetWidth / CGFloat(width)
        let midTargetHeight = max(1, Int((CGFloat(height) * midScale).rounded()))
        let midSize = CGSize(width: Int(midTargetWidth), height: midTargetHeight)

        guard let midResJPEG = FrameSnapshot.renderJPEGData(
            from: ciImage,
            targetSize: midSize,
            context: FrameSnapshot.ciContext,
            quality: 0.75
        ) else { return nil }

        self.midResJPEG = midResJPEG
        self.midResSize = midSize

        // Full-res lossless PNG for OCR crops
        guard let fullResPNG = FrameSnapshot.renderPNGData(
            from: ciImage,
            context: FrameSnapshot.ciContext
        ) else { return nil }

        self.fullResPNG = fullResPNG
    }

    // MARK: - Image Decoding

    func fullResCGImage() -> CGImage? {
        FrameSnapshot.decodeImage(from: fullResPNG)
    }

    func midResCGImage() -> CGImage? {
        FrameSnapshot.decodeImage(from: midResJPEG)
    }

    func midResUIImage() -> UIImage? {
        #if canImport(UIKit)
        guard let cgImage = midResCGImage() else { return nil }
        return UIImage(cgImage: cgImage)
        #else
        return nil
        #endif
    }

    func withLowResGrayBytes<R>(_ body: (UnsafeBufferPointer<UInt8>, Int, Int) -> R) -> R {
        lowResGray.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            return body(buffer, Int(lowResSize.width), Int(lowResSize.height))
        }
    }

    // MARK: - Cropping

    func cropFullRes(normalizedRect: CGRect) -> CGImage? {
        guard let cgImage = fullResCGImage() else { return nil }
        let pixelRect = FrameSnapshot.denormalize(rect: normalizedRect, size: CGSize(width: width, height: height))
        return cgImage.cropping(to: pixelRect.integral)
    }

    func cropMidRes(normalizedRect: CGRect) -> CGImage? {
        guard let cgImage = midResCGImage() else { return nil }
        let pixelRect = FrameSnapshot.denormalize(rect: normalizedRect, size: midResSize)
        return cgImage.cropping(to: pixelRect.integral)
    }

    func thumbnailJPEG(normalizedRect: CGRect, targetWidth: CGFloat = 320, quality: CGFloat = 0.6) -> Data? {
        guard let cropped = cropFullRes(normalizedRect: normalizedRect) else { return nil }
        let ciImage = CIImage(cgImage: cropped)
        let scale = targetWidth / CGFloat(cropped.width)
        let targetHeight = max(1, Int((CGFloat(cropped.height) * scale).rounded()))
        let targetSize = CGSize(width: Int(targetWidth), height: targetHeight)
        return FrameSnapshot.renderJPEGData(from: ciImage, targetSize: targetSize, context: FrameSnapshot.ciContext, quality: quality)
    }

    // MARK: - Helpers

    private static func denormalize(rect: CGRect, size: CGSize) -> CGRect {
        // Normalized rect is top-left origin, unit size
        let x = rect.minX * size.width
        let y = rect.minY * size.height
        let w = rect.width * size.width
        let h = rect.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func decodeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func renderGrayData(from image: CIImage, targetSize: CGSize, context: CIContext) -> Data? {
        let scaleX = targetSize.width / image.extent.width
        let scaleY = targetSize.height / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let gray = scaled.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attrs as CFDictionary,
            &buffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        context.render(gray, to: pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var packed = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let src = base.advanced(by: row * bytesPerRow)
            memcpy(&packed[row * width], src, width)
        }
        return Data(packed)
    }

    private static func renderJPEGData(from image: CIImage, targetSize: CGSize, context: CIContext, quality: CGFloat) -> Data? {
        let scaleX = targetSize.width / image.extent.width
        let scaleY = targetSize.height / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return context.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }

    private static func renderPNGData(from image: CIImage, context: CIContext) -> Data? {
        return context.pngRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
    }
}
