//
//  GlassesOCRTests.swift
//  GlassesOCRTests
//
//  Created by Omar Youssef on 12/24/25.
//

import Testing
import CoreGraphics
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

    @Test func cropPlannerClampsRects() async throws {
        let planner = CropPlanner()
        let plan = planner.plan(
            chartBox: CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6),
            axisSide: .right,
            frameSize: CGSize(width: 1920, height: 1080)
        )
        #expect(plan.headerRect.minY >= 0)
        #expect(plan.footerRect.maxY <= 1)
        #expect(plan.yAxisRect.maxX <= 1)
        #expect(plan.bodyRect.minX >= 0)
    }

}
