//
//  GlassesOCRTests.swift
//  GlassesOCRTests
//
//  Created by Omar Youssef on 12/24/25.
//

import Testing
@testable import GlassesOCR

struct GlassesOCRTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func parsesLowercaseTicker() async throws {
        let parser = Parser()
        let ocr = OcrResult(
            recognizedText: "aapl 173.24 +1.2%",
            confidence: 0.9,
            observations: []
        )

        let observation = parser.parse(ocrResult: ocr)
        #expect(observation != nil)
        #expect(observation?.ticker == "AAPL")
        #expect(observation?.price == 173.24)
    }
}
