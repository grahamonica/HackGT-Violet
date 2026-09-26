import XCTest
@testable import ReferentCore

final class RateLimiterTests: XCTestCase {
  func testNeverExceedsTheLimitInAnyWindow() async {
    let limiter = RateLimiter(limit: 3, per: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    var grants: [Duration] = []
    for _ in 0..<7 {
      await limiter.acquire()
      grants.append(clock.now - start)
    }
    // 3 immediately, 3 after one window, 1 after two windows.
    XCTAssertGreaterThanOrEqual(grants[6], .milliseconds(390))
    for (i, t) in grants.enumerated() {
      let inWindow = grants[i...].filter { $0 - t < .milliseconds(200) }.count
      XCTAssertLessThanOrEqual(inWindow, 3, "more than 3 grants within 200 ms starting at grant \(i)")
    }
  }

  func testConcurrentCallersShareTheLimit() async {
    let limiter = RateLimiter(limit: 2, per: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    let times = await withTaskGroup(of: Duration.self) { group in
      for _ in 0..<4 { group.addTask { await limiter.acquire(); return clock.now - start } }
      return await group.reduce(into: []) { $0.append($1) }.sorted()
    }
    XCTAssertLessThan(times[1], .milliseconds(100))
    XCTAssertGreaterThanOrEqual(times[2], .milliseconds(190))
  }

  func testCancelledWaiterGivesUp() async {
    let limiter = RateLimiter(limit: 1, per: .seconds(10))
    await limiter.acquire()
    let waiter = Task { await limiter.acquire() }
    try? await Task.sleep(for: .milliseconds(50))
    waiter.cancel()
    let granted = await waiter.value
    XCTAssertFalse(granted)
  }

  func testPipelineRespectsTheRateLimit() async {
    var config = ReferentConfig()
    config.maxIdentificationsPerSecond = 2
    let identifier = FakeIdentifier(delay: .milliseconds(1))
    let pipeline = ReferentPipeline(config: config, analyzer: FakeAnalyzer(), identifier: identifier)
    await pipeline.begin()
    await pipeline.consider(frame("a@0.2@0.9;b@0.4@0.9;c@0.6@0.9;d@0.8@0.9", at: 0))
    let start = ContinuousClock.now
    _ = await pipeline.resolve()
    let calls = await identifier.calls
    XCTAssertEqual(calls, 4)
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(950), "4 calls at 2/s need about a second")
  }
}
