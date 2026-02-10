import Foundation
import CoreVideo
import CoreImage
#if canImport(UIKit)
import UIKit

final class MockFrameStream {
    private let images: [CGImage]
    private let fps: Double

    init(imageNames: [String], fps: Double = 6, bundle: Bundle = .main) {
        self.images = imageNames.compactMap { name in
            guard let image = UIImage(named: name, in: bundle, compatibleWith: nil)?.cgImage else { return nil }
            return image
        }
        self.fps = fps
    }

    func makeStream() -> AsyncStream<CVPixelBuffer> {
        let images = self.images
        let fps = max(self.fps, 1)

        return AsyncStream { continuation in
            guard !images.isEmpty else {
                continuation.finish()
                return
            }

            let queue = DispatchQueue(label: "MockFrameStream")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = 1.0 / fps
            var index = 0

            timer.setEventHandler {
                let image = images[index % images.count]
                if let buffer = Self.pixelBuffer(from: image) {
                    continuation.yield(buffer)
                }
                index += 1
            }

            continuation.onTermination = { _ in
                timer.cancel()
            }

            timer.schedule(deadline: .now(), repeating: interval)
            timer.resume()
        }
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
#endif
