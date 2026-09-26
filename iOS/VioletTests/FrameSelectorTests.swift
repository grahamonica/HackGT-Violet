import XCTest
@testable import Violet

final class FrameSelectorTests: XCTestCase {
  func testFirstFrameWinsAndCountTracksAllFrames() {
    let selector = FirstFrameSelector()
    selector.consider(jpegData: Data([1]))
    selector.consider(jpegData: Data([2]))
    selector.consider(jpegData: Data([3]))

    XCTAssertEqual(selector.selection(), Data([1]))
    XCTAssertEqual(selector.frameCount, 3)
  }

  func testResetClearsSelection() {
    let selector = FirstFrameSelector()
    selector.consider(jpegData: Data([1]))
    selector.reset()

    XCTAssertNil(selector.selection())
    XCTAssertEqual(selector.frameCount, 0)
  }
}
