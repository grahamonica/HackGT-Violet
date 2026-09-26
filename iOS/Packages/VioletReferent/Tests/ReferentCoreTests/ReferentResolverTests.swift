import XCTest
@testable import ReferentCore

struct TestError: Error {}

/// Builds observations: `face(frame, cx, cy, h, quality, id)` puts a face in a
/// frame at time `frame * 0.1`; its crop encodes `id` so fake identifiers can
/// answer per person.
func face(_ frame: Int, cx: Double, cy: Double = 0.5, h: Double = 0.3, quality: Double = 0.8, id: String) -> FaceObservation {
  FaceObservation(
    frameIndex: frame, timestamp: Double(frame) * 0.1,
    face: DetectedFace(box: box(cx: cx, cy: cy, h: h), quality: quality, crop: Data(id.utf8)))
}

final class ReferentResolverTests: XCTestCase {
  let resolver = ReferentResolver()

  /// Plans, then answers every candidate by looking up its crop's id.
  func run(_ observations: [FaceObservation], start: Double = 0, end: Double = 1, config: ReferentConfig = ReferentConfig(),
           answer: (String) -> Result<[IdentityMatch], any Error> = { .success([IdentityMatch(userID: $0, similarity: 99.9)]) }
  ) -> (ReferentOutcome, ReferentResolver.Plan) {
    let resolver = ReferentResolver(config: config)
    let plan = resolver.plan(observations: observations, start: start, end: end)
    var results: [Int: Result<[IdentityMatch], any Error>] = [:]
    for i in plan.candidates { results[i] = answer(String(decoding: plan.observations[i].face.crop, as: UTF8.self)) }
    return (resolver.resolve(plan: plan, results: results).0, plan)
  }

  func identifiedID(_ outcome: ReferentOutcome) -> String? {
    if case .identified(let identity) = outcome { return identity.userID }
    return nil
  }

  // MARK: Failure paths

  func testNoFacesIsNoFace() {
    guard case .noFace = run([]).0 else { return XCTFail("expected noFace") }
  }

  func testAllBelowQualityIsPoorQualityWithNoCalls() {
    let (outcome, plan) = run([face(0, cx: 0.5, quality: 0.05, id: "sarah")])
    guard case .poorQuality = outcome else { return XCTFail("expected poorQuality") }
    XCTAssertTrue(plan.candidates.isEmpty)
  }

  func testNoAcceptableMatchIsNotRecognized() {
    let (outcome, _) = run([face(0, cx: 0.5, id: "x")]) { _ in .success([IdentityMatch(userID: "sarah", similarity: 40)]) }
    guard case .notRecognized = outcome else { return XCTFail("expected notRecognized") }
  }

  func testEmptyMatchesIsNotRecognized() {
    let (outcome, _) = run([face(0, cx: 0.5, id: "x")]) { _ in .success([]) }
    guard case .notRecognized = outcome else { return XCTFail("expected notRecognized") }
  }

  func testAllCallsFailingIsFailedNotNotRecognized() {
    let (outcome, _) = run([face(0, cx: 0.5, id: "x"), face(0, cx: 0.1, id: "y")]) { _ in .failure(TestError()) }
    guard case .failed = outcome else { return XCTFail("expected failed") }
  }

  func testPartialFailuresStillDecideFromSuccesses() {
    let (outcome, _) = run([face(0, cx: 0.5, id: "sarah"), face(0, cx: 0.9, h: 0.1, id: "bob")]) { id in
      id == "bob" ? .failure(TestError()) : .success([IdentityMatch(userID: id, similarity: 99)])
    }
    XCTAssertEqual(identifiedID(outcome), "sarah")
  }

  // MARK: Referent selection

  func testCentralFaceBeatsPeripheralFace() {
    let (outcome, _) = run([face(0, cx: 0.5, id: "sarah"), face(0, cx: 0.92, id: "bob")])
    XCTAssertEqual(identifiedID(outcome), "sarah")
  }

  func testEarlierCentralFaceBeatsLaterCentralFace() {
    // Sarah is centered at the wake word; the user then turns to Bob.
    let obs = [face(0, cx: 0.5, id: "sarah"), face(10, cx: 0.5, id: "bob")]
    XCTAssertEqual(identifiedID(run(obs, start: 0, end: 1).0), "sarah")
  }

  func testRekognitionResultNotLocalQualityPicksTheWinner() {
    // Bob's crop is sharper, but Sarah is the centered face; quality only gates.
    let obs = [face(0, cx: 0.5, quality: 0.3, id: "sarah"), face(0, cx: 0.85, quality: 0.99, id: "bob")]
    XCTAssertEqual(identifiedID(run(obs).0), "sarah")
  }

  func testEquallyPlausibleFacesAreAmbiguous() {
    let (outcome, _) = run([face(0, cx: 0.45, id: "sarah"), face(0, cx: 0.55, id: "bob")])
    guard case .ambiguous(let candidates) = outcome else { return XCTFail("expected ambiguous") }
    XCTAssertEqual(Set(candidates.map(\.userID)), ["sarah", "bob"])
  }

  func testMatchBelowSimilarityThresholdDoesNotCount() {
    // The central face only weakly matches anyone; the accepted match wins.
    let obs = [face(0, cx: 0.5, id: "weak"), face(0, cx: 0.8, id: "bob")]
    let (outcome, _) = run(obs) { id in .success([IdentityMatch(userID: id, similarity: id == "weak" ? 60 : 99)]) }
    XCTAssertEqual(identifiedID(outcome), "bob")
  }

  func testAgreementAcrossTracksBreaksATie() {
    // Sarah and Bob are placed symmetrically; a second, separate sighting of Sarah decides it.
    var config = ReferentConfig()
    config.ambiguityMargin = 0
    let obs = [face(0, cx: 0.42, id: "sarah"), face(0, cx: 0.58, id: "bob"), face(5, cx: 0.9, cy: 0.1, id: "sarah")]
    let (outcome, plan) = run(obs, config: config)
    XCTAssertEqual(plan.trackReferentScores[plan.trackIDs[0]], plan.trackReferentScores[plan.trackIDs[1]], accuracy: 1e-9)
    XCTAssertEqual(identifiedID(outcome), "sarah")
  }

  // MARK: Tracking and call budget

  func testSameFaceAcrossFramesIsOneTrackAndOneCall() {
    let obs = (0..<10).map { face($0, cx: 0.5 + Double($0) * 0.005, quality: 0.5 + Double($0) * 0.01, id: "sarah") }
    let (_, plan) = run(obs)
    XCTAssertEqual(plan.trackReferentScores.count, 1)
    XCTAssertEqual(plan.candidates.count, 1)
    XCTAssertEqual(plan.candidates.first, 9, "the track's best-quality crop is sent")
  }

  func testGapLongerThanMaxGapStartsANewTrack() {
    let obs = [face(0, cx: 0.5, id: "a"), face(20, cx: 0.5, id: "a")]  // 2 s apart
    XCTAssertEqual(Set(run(obs).1.trackIDs).count, 2)
  }

  func testCallCapKeepsTheLikelyReferent() {
    // Many sharp background faces must not crowd out the central, blurrier one.
    var config = ReferentConfig()
    config.maxIdentificationCalls = 2
    var obs = [face(0, cx: 0.5, quality: 0.2, id: "sarah")]
    for (i, x) in [0.05, 0.2, 0.8, 0.95].enumerated() { obs.append(face(0, cx: x, h: 0.1, quality: 0.95, id: "bg\(i)")) }
    let (outcome, plan) = run(obs, config: config)
    XCTAssertEqual(plan.candidates.count, 2)
    XCTAssertEqual(identifiedID(outcome), "sarah")
  }

  func testEveryTrackGetsOneCropBeforeAnyGetsASecond() {
    var config = ReferentConfig()
    config.cropsPerTrack = 2
    config.maxIdentificationCalls = 3
    let obs = [face(0, cx: 0.3, id: "a"), face(1, cx: 0.3, id: "a"), face(0, cx: 0.7, id: "b"), face(1, cx: 0.7, id: "b")]
    let plan = run(obs, config: config).1
    let tracks = plan.candidates.map { plan.trackIDs[$0] }
    XCTAssertEqual(tracks.count, 3)
    XCTAssertEqual(Set(tracks.prefix(2)).count, 2)
  }
}
