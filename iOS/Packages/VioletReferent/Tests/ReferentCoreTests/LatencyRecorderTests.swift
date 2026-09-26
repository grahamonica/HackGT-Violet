import XCTest
@testable import ReferentCore

final class LatencyRecorderTests: XCTestCase {
  func testReportListsMilestonesOnceAndSummarizesStages() {
    let latency = LatencyRecorder()
    latency.begin()
    latency.note("trigger", "wake word")
    latency.mark("first face found")
    latency.mark("first face found")
    latency.add("quality model (Core ML)", .milliseconds(4))
    latency.add("quality model (Core ML)", .milliseconds(8))

    let report = latency.report()
    print(report)
    let lines = report.split(separator: "\n")
    XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("[Latency] ") })
    XCTAssertTrue(lines[0].contains("Request #1 · trigger: wake word"))
    XCTAssertEqual(lines.filter { $0.contains("first face found") }.count, 1)
    let stage = lines.first { $0.contains("quality model (Core ML)") }
    XCTAssertNotNil(stage)
    XCTAssertTrue(stage!.contains("2") && stage!.contains("6.0ms") && stage!.contains("8.0ms") && stage!.contains("12.0ms"))
  }

  func testBeginStartsAFreshRequestAndNothingIsRecordedBeforeIt() {
    let latency = LatencyRecorder()
    latency.mark("too early")
    latency.begin()
    latency.mark("first request")
    latency.begin()
    let report = latency.report()
    XCTAssertTrue(report.contains("Request #2"))
    XCTAssertFalse(report.contains("too early"))
    XCTAssertFalse(report.contains("first request"))
  }

  func testPipelineRecordsItsStages() async {
    let latency = LatencyRecorder()
    latency.begin()
    let pipeline = ReferentPipeline(analyzer: FakeAnalyzer(), identifier: FakeIdentifier(), latency: latency)
    await pipeline.begin()
    await pipeline.consider(frame("ann@0.5@0.9", at: 0))
    _ = await pipeline.resolve(earliest: .zero, deadline: .seconds(2))

    let report = latency.report()
    for expected in [
      "first frame reached the pipeline", "first face found", "first Rekognition call queued",
      "first Rekognition reply", "pipeline decided", "frame analysis (total)", "Rekognition call",
    ] {
      XCTAssertTrue(report.contains(expected), "missing \(expected)")
    }
  }
}
