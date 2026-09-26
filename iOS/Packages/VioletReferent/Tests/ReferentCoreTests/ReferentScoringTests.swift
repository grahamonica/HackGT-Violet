import XCTest
@testable import ReferentCore

final class ReferentScoringTests: XCTestCase {
  func testTemporalWeightRunsFromOneToFloor() {
    let w = { (t: Double) in ReferentScoring.temporalWeight(timestamp: t, start: 10, end: 15, floor: 0.3) }
    XCTAssertEqual(w(10), 1.0, accuracy: 1e-9)
    XCTAssertEqual(w(12.5), 0.65, accuracy: 1e-9)
    XCTAssertEqual(w(15), 0.3, accuracy: 1e-9)
  }

  func testTemporalWeightIsIndependentOfBufferLength() {
    // The same relative position gets the same weight in a short and a long capture.
    let short = ReferentScoring.temporalWeight(timestamp: 1, start: 0, end: 4, floor: 0.2)
    let long = ReferentScoring.temporalWeight(timestamp: 7.5, start: 0, end: 30, floor: 0.2)
    XCTAssertEqual(short, long, accuracy: 1e-9)
  }

  func testSingleFrameCaptureHasFullWeight() {
    XCTAssertEqual(ReferentScoring.temporalWeight(timestamp: 3, start: 3, end: 3, floor: 0.3), 1.0)
  }

  func testCentralityFallsOffFromCenter() {
    let center = ReferentScoring.centrality(box(cx: 0.5, cy: 0.5, h: 0.2), sigma: 0.35)
    let off = ReferentScoring.centrality(box(cx: 0.7, cy: 0.5, h: 0.2), sigma: 0.35)
    let corner = ReferentScoring.centrality(box(cx: 0.95, cy: 0.95, h: 0.1), sigma: 0.35)
    XCTAssertEqual(center, 1.0, accuracy: 1e-9)
    XCTAssertLessThan(off, center)
    XCTAssertLessThan(corner, 0.01)
  }

  func testLargeSlightlyOffCenterFaceBeatsTinyCenteredFace() {
    let config = ReferentConfig()
    let conversational = ReferentScoring.geometry(box(cx: 0.62, cy: 0.5, h: 0.35), config: config)
    let background = ReferentScoring.geometry(box(cx: 0.5, cy: 0.5, h: 0.04), config: config)
    XCTAssertGreaterThan(conversational, background)
  }

  func testCentralityDominatesSize() {
    // A big face near the edge should not beat a normal-sized centered face.
    let config = ReferentConfig()
    let edge = ReferentScoring.geometry(box(cx: 0.9, cy: 0.5, h: 0.5), config: config)
    let centered = ReferentScoring.geometry(box(cx: 0.5, cy: 0.5, h: 0.15), config: config)
    XCTAssertGreaterThan(centered, edge)
  }
}

func box(cx: Double, cy: Double, h: Double, w: Double? = nil) -> NormalizedRect {
  let width = w ?? h * 0.75
  return NormalizedRect(x: cx - width / 2, y: cy - h / 2, width: width, height: h)
}
