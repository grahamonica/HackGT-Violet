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

/// Recognizes a crop as the id it encodes. "stranger" has no match; ids
/// starting with "slow" take `slowDelay`; "hang" never returns (ignores cancellation).
actor FakeIdentifier: FaceIdentifying {
  let delay: Duration
  let slowDelay: Duration
  private(set) var calls = 0
  private(set) var maxConcurrent = 0
  private var current = 0

  init(delay: Duration = .milliseconds(10), slowDelay: Duration = .seconds(10)) {
    self.delay = delay
    self.slowDelay = slowDelay
  }

  func identify(crop: Data) async throws -> [IdentityMatch] {
    calls += 1
    current += 1
    maxConcurrent = max(maxConcurrent, current)
    defer { current -= 1 }
    let id = String(decoding: crop, as: UTF8.self)
    if id == "hang" {
      while true { try? await Task.sleep(for: .seconds(60)) }
    }
    try await Task.sleep(for: id.hasPrefix("slow") ? slowDelay : delay)
    return id == "stranger" ? [] : [IdentityMatch(userID: id, similarity: 99.5)]
  }
}

func frame(_ faces: String, at t: Double) -> ReferentFrame {
  ReferentFrame(jpegData: Data(faces.utf8), timestamp: t)
}

final class ReferentPipelineTests: XCTestCase {
  func seconds(_ block: () async -> Void) async -> Double {
    let start = ContinuousClock.now
    await block()
    let c = (ContinuousClock.now - start).components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }

  // MARK: Capture boundaries and basics

  func testEndToEndIdentifiesTheReferentWithOneCallPerPerson() async {
    let identifier = FakeIdentifier()
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: identifier)
    await pipeline.begin()
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
    XCTAssertEqual(calls, 2, "one call per person, not per frame")
  }

  func testFramesOutsideACaptureAreIgnored() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.consider(frame("bob@0.5@0.9", at: 0))  // before begin()
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.5@0.9", at: 1))
    let result = await pipeline.resolve()
    await pipeline.consider(frame("bob@0.5@0.9", at: 2))  // after resolve
    guard case .identified(let identity) = result.outcome else { return XCTFail("expected identified") }
    XCTAssertEqual(identity.userID, "sarah")
    guard case .noFace = await pipeline.resolve().outcome else { return XCTFail("late frame must be ignored") }
  }

  func testFailedAnalysisIsCountedAndSkipped() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("corrupt", at: 0))
    await pipeline.consider(frame("sarah@0.5@0.9", at: 0.1))
    let result = await pipeline.resolve()
    XCTAssertEqual(result.diagnostics.framesFailedAnalysis, 1)
    guard case .identified = result.outcome else { return XCTFail("expected identified") }
  }

  func testUnknownFaceIsNotRecognized() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("stranger@0.5@0.9", at: 0))
    guard case .notRecognized = await pipeline.resolve().outcome else { return XCTFail("expected notRecognized") }
  }

  // MARK: Early answer and deadline

  func testConfidentAnswerReturnsEarly() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.5@0.9", at: 0))
    var result: ReferentResult?
    let elapsed = await seconds { result = await pipeline.resolve(earliest: .milliseconds(50), deadline: .seconds(3)) }
    guard case .identified = result?.outcome else { return XCTFail("expected identified") }
    XCTAssertTrue(result!.diagnostics.answeredEarly)
    XCTAssertLessThan(elapsed, 1.0)
  }

  func testNoAnswerBeforeEarliest() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.5@0.9", at: 0))
    let elapsed = await seconds { _ = await pipeline.resolve(earliest: .milliseconds(300), deadline: .seconds(3)) }
    XCTAssertGreaterThanOrEqual(elapsed, 0.29)
  }

  func testUnconfidentCaptureKeepsWorkingUntilADecisiveFrameArrives() async {
    // Sarah and Bob are equally placed: ambiguous, so it keeps capturing. A
    // later, separate sighting of Sarah adds agreement and settles it early.
    var config = ReferentConfig()
    config.ambiguityMargin = 0.02
    let pipeline = ReferentPipeline(config: config, analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.45@0.9;bob@0.55@0.9", at: 0))
    let resolution = Task { await pipeline.resolve(earliest: .milliseconds(50), deadline: .seconds(3)) }
    try? await Task.sleep(for: .milliseconds(400))
    await pipeline.consider(frame("sarah@0.85@0.9", at: 1))  // new track (1 s gap), same person
    let result = await resolution.value
    guard case .identified(let identity) = result.outcome else { return XCTFail("expected identified, got \(result.outcome)") }
    XCTAssertEqual(identity.userID, "sarah")
    XCTAssertTrue(result.diagnostics.answeredEarly)
    XCTAssertGreaterThan(result.diagnostics.secondsToAnswer, 0.35)
    XCTAssertLessThan(result.diagnostics.secondsToAnswer, 2.0)
  }

  func testAmbiguousCaptureAnswersAtTheDeadline() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.45@0.9;bob@0.55@0.9", at: 0))
    let result = await pipeline.resolve(earliest: .milliseconds(50), deadline: .milliseconds(500))
    guard case .ambiguous = result.outcome else { return XCTFail("expected ambiguous, got \(result.outcome)") }
    XCTAssertFalse(result.diagnostics.answeredEarly)
    XCTAssertEqual(result.diagnostics.secondsToAnswer, 0.5, accuracy: 0.3)
  }

  func testDeadlineIsHardEvenWhenTheNetworkIsSlow() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("slow-sarah@0.5@0.9", at: 0))
    var result: ReferentResult?
    let elapsed = await seconds { result = await pipeline.resolve(earliest: .milliseconds(50), deadline: .milliseconds(400)) }
    XCTAssertLessThan(elapsed, 1.0)
    guard case .failed(let error) = result?.outcome, case .identificationTimedOut = error as? ReferentError else {
      return XCTFail("expected timeout, got \(String(describing: result?.outcome))")
    }
  }

  func testBackgroundFacesDoNotDelayAConfidentAnswer() async {
    // Sarah is centered and answers fast; a slow lookup of a corner face must not hold the answer.
    var config = ReferentConfig()
    config.maxConcurrentIdentifications = 4
    let pipeline = ReferentPipeline(config: config, analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.5@0.9;slow-bob@0.97@0.9", at: 0))
    var result: ReferentResult?
    let elapsed = await seconds { result = await pipeline.resolve(earliest: .milliseconds(50), deadline: .seconds(3)) }
    guard case .identified(let identity) = result?.outcome else { return XCTFail("expected identified") }
    XCTAssertEqual(identity.userID, "sarah")
    XCTAssertLessThan(elapsed, 1.0)
  }

  // MARK: Rate and time limits

  func testHungCallTimesOutInsteadOfBlocking() async {
    var config = ReferentConfig()
    config.identificationTimeout = .milliseconds(200)
    let pipeline = ReferentPipeline(config: config, analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("hang@0.5@0.9", at: 0))
    var result: ReferentResult?
    let elapsed = await seconds { result = await pipeline.resolve() }
    XCTAssertLessThan(elapsed, 1.5)
    guard case .failed = result?.outcome else { return XCTFail("expected failed") }
  }

  func testConcurrentCallsAreCapped() async {
    var config = ReferentConfig()
    config.maxConcurrentIdentifications = 2
    let identifier = FakeIdentifier(delay: .milliseconds(100))
    let pipeline = ReferentPipeline(config: config, analyzer: FakeAnalyzer(), identifier: identifier)
    await pipeline.begin()
    await pipeline.consider(frame("a@0.1@0.9;b@0.3@0.9;c@0.5@0.9;d@0.7@0.9;e@0.9@0.9", at: 0))
    _ = await pipeline.resolve()
    let (calls, peak) = (await identifier.calls, await identifier.maxConcurrent)
    XCTAssertEqual(calls, 5)
    XCTAssertEqual(peak, 2)
  }

  func testResolveResetsForTheNextCapture() async {
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier())
    await pipeline.begin()
    await pipeline.consider(frame("sarah@0.5@0.9", at: 0))
    _ = await pipeline.resolve()
    let second = await pipeline.resolve()
    guard case .noFace = second.outcome else { return XCTFail("expected noFace after reset") }
    XCTAssertEqual(second.diagnostics.framesConsidered, 0)
  }
}
