import XCTest
@testable import ReferentCore

/// Frame `jpegData` is a list of "id@centerX@quality" entries separated by ";".
struct FakeAnalyzer: FaceAnalyzing {
  func analyze(_ frame: ReferentFrame) async throws -> [DetectedFace] {
    let text = String(decoding: frame.jpegData, as: UTF8.self)
    if text == "corrupt" { throw TestError() }
    return text.split(separator: ";").map { entry in
      let parts = entry.split(separator: "@").map(String.init)
      return DetectedFace(box: box(cx: Double(parts[1])!, cy: 0.5, h: 0.3), quality: Double(parts[2])!, crop: Data(parts[0].utf8))
    }
  }
}

/// Recognizes a crop as the id it encodes; "stranger" has no match.
actor FakeIdentifier: FaceIdentifying {
  private(set) var calls = 0
  func identify(crop: Data) async throws -> [IdentityMatch] {
    calls += 1
    let id = String(decoding: crop, as: UTF8.self)
    return id == "stranger" ? [] : [IdentityMatch(userID: id, similarity: 99.5)]
  }
}

func frame(_ faces: String, at t: Double) -> ReferentFrame {
  ReferentFrame(jpegData: Data(faces.utf8), timestamp: t)
}

final class ReferentPipelineTests: XCTestCase {
  func testEndToEndIdentifiesTheReferent() async {
    let identifier = FakeIdentifier()
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: identifier)
    await pipeline.consider(frame("sarah@0.5@0.9;bob@0.9@0.9", at: 0))
    await pipeline.consider(frame("sarah@0.51@0.8;bob@0.9@0.9", at: 0.1))
    await pipeline.consider(frame("", at: 0.2))
    let result = await pipeline.resolve()

    guard case .identified(let identity) = result.outcome else { return XCTFail("expected identified, got \(result.outcome)") }
    XCTAssertEqual(identity.userID, "sarah")
    XCTAssertEqual(result.diagnostics.framesConsidered, 3)
    XCTAssertEqual(result.diagnostics.facesDetected, 4)
    XCTAssertEqual(result.diagnostics.tracks, 2)
    let calls = await identifier.calls
    XCTAssertEqual(calls, 2, "one call per track, not per frame")
  }

  func testFailedAnalysisIsCountedAndSkipped() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.consider(frame("corrupt", at: 0))
    await pipeline.consider(frame("sarah@0.5@0.9", at: 0.1))
    let result = await pipeline.resolve()
    XCTAssertEqual(result.diagnostics.framesFailedAnalysis, 1)
    guard case .identified = result.outcome else { return XCTFail("expected identified") }
  }

  func testResolveResetsForTheNextCapture() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.consider(frame("sarah@0.5@0.9", at: 0))
    _ = await pipeline.resolve()
    let second = await pipeline.resolve()
    guard case .noFace = second.outcome else { return XCTFail("expected noFace after reset") }
    XCTAssertEqual(second.diagnostics.framesConsidered, 0)
  }

  func testUnknownFaceIsNotRecognized() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.consider(frame("stranger@0.5@0.9", at: 0))
    guard case .notRecognized = await pipeline.resolve().outcome else { return XCTFail("expected notRecognized") }
  }
}
