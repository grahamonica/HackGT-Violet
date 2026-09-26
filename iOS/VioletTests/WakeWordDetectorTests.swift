import XCTest

final class WakeWordDetectorTests: XCTestCase {
  func testFindsWholeWakeWordIgnoringCaseAndPunctuation() {
    XCTAssertTrue(WakeWordDetector.containsWakeWord("Hey, VIOLET!"))
    XCTAssertFalse(WakeWordDetector.containsWakeWord("violets are purple"))
    // The glasses have transcribed "Violet" as "Vista".
    XCTAssertTrue(WakeWordDetector.containsWakeWord("The Vista."))
  }

  func testCooldownSuppressesPartialAndFinalDuplicate() {
    var detector = WakeWordDetector(cooldown: 8)
    let start = Date(timeIntervalSince1970: 100)
    XCTAssertTrue(detector.consume("Violet", at: start))
    XCTAssertFalse(detector.consume("Violet please", at: start.addingTimeInterval(1)))
    XCTAssertTrue(detector.consume("Violet", at: start.addingTimeInterval(9)))
  }
}
