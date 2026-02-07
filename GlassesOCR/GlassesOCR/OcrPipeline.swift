@preconcurrency import Vision
//  OcrPipeline.swift
//  GlassesOCR
//
//  Runs Apple Vision text recognition on frames.
//

import Foundation
import Vision
import CoreVideo

#if canImport(UIKit)
import UIKit
#endif

// MARK: - OCR Result

/// Result from OCR text recognition.
/// Uses @unchecked Sendable because VNRecognizedTextObservation isn't Sendable,
/// but we treat the data as effectively immutable after creation.
struct OcrResult: @unchecked Sendable {
    let recognizedText: String
    let confidence: Double
    let observations: [VNRecognizedTextObservation]
    
    static let empty = OcrResult(recognizedText: "", confidence: 0, observations: [])
}

// MARK: - OcrPipeline

final class OcrPipeline: Sendable {
    
    // MARK: Configuration
    
    /// Minimum confidence threshold for text recognition
    private let minimumConfidence: Float = 0.3
    
    /// Recognition level (fast vs accurate)
    private let recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    
    // MARK: - Public Interface
    
    /// Performs OCR on a CVPixelBuffer and returns recognized text with confidence.
    func recognizeText(in pixelBuffer: CVPixelBuffer) async -> OcrResult {
        await withCheckedContinuation { continuation in
            performRecognition(pixelBuffer: pixelBuffer) { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Performs OCR on a UIImage and returns recognized text with confidence.
    func recognizeText(in image: UIImage) async -> OcrResult {
        guard let cgImage = image.cgImage else {
            return .empty
        }
        
        return await withCheckedContinuation { continuation in
            performRecognition(cgImage: cgImage) { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    // MARK: - Private Implementation
    
    private func performRecognition(pixelBuffer: CVPixelBuffer, completion: @escaping @Sendable (OcrResult) -> Void) {
        let request = createTextRecognitionRequest(completion: completion)
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("[OcrPipeline] Recognition failed: \(error.localizedDescription)")
                completion(.empty)
            }
        }
    }
    
    private func performRecognition(cgImage: CGImage, completion: @escaping @Sendable (OcrResult) -> Void) {
        let request = createTextRecognitionRequest(completion: completion)
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("[OcrPipeline] Recognition failed: \(error.localizedDescription)")
                completion(.empty)
            }
        }
    }
    
    private func createTextRecognitionRequest(completion: @escaping @Sendable (OcrResult) -> Void) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else {
                completion(.empty)
                return
            }
            
            if let error = error {
                print("[OcrPipeline] Request error: \(error.localizedDescription)")
                completion(.empty)
                return
            }
            
            let result = self.processObservations(request.results as? [VNRecognizedTextObservation])
            completion(result)
        }
        
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        
        return request
    }
    
    private func processObservations(_ observations: [VNRecognizedTextObservation]?) -> OcrResult {
        guard let observations = observations, !observations.isEmpty else {
            return .empty
        }
        
        var allText: [String] = []
        var totalConfidence: Float = 0
        var count: Float = 0
        
        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            
            // Filter by confidence
            guard topCandidate.confidence >= minimumConfidence else { continue }
            
            allText.append(topCandidate.string)
            totalConfidence += topCandidate.confidence
            count += 1
        }
        
        let averageConfidence = count > 0 ? Double(totalConfidence / count) : 0
        let combinedText = allText.joined(separator: " ")
        
        return OcrResult(
            recognizedText: combinedText,
            confidence: averageConfidence,
            observations: observations
        )
    }
}
