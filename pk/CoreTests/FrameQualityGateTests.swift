import XCTest
@testable import FaceIDCore

final class FrameQualityGateTests: XCTestCase {
    let good = FrameFacts(sizableFaceCount: 1, hasFullLandmarks: true, yaw: 0.05, pitch: -0.1, quality: 0.6)

    func testGoodFrameUsed() { XCTAssertEqual(FrameQualityGate.evaluate(good), .use) }

    func testNoFace() {
        var f = good; f.sizableFaceCount = 0
        XCTAssertEqual(FrameQualityGate.evaluate(f), .skip(.noFace))
    }

    func testTwoPeopleRefused() {
        var f = good; f.sizableFaceCount = 2
        XCTAssertEqual(FrameQualityGate.evaluate(f), .refuseMultipleFaces)
    }

    func testPartialFaceSkipped() {
        var f = good; f.hasFullLandmarks = false
        XCTAssertEqual(FrameQualityGate.evaluate(f), .skip(.partialFace))
    }

    func testTurnedAwaySkipped() {
        var f = good; f.yaw = 30 * .pi / 180
        XCTAssertEqual(FrameQualityGate.evaluate(f), .skip(.turnedAway))
        f = good; f.pitch = -28 * .pi / 180
        XCTAssertEqual(FrameQualityGate.evaluate(f), .skip(.turnedAway))
        f = good; f.yaw = 20 * .pi / 180
        XCTAssertEqual(FrameQualityGate.evaluate(f), .use)
    }

    func testDarkOrBlurrySkipped() {
        var f = good; f.quality = 0.1
        XCTAssertEqual(FrameQualityGate.evaluate(f), .skip(.lowQuality))
    }

    func testUnknownPoseAndQualityAllowed() {
        var f = good; f.yaw = nil; f.pitch = nil; f.quality = nil
        XCTAssertEqual(FrameQualityGate.evaluate(f), .use)
    }
}
