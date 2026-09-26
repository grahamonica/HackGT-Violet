import Foundation

protocol FrameSelecting: AnyObject, Sendable {
  func reset()
  func consider(jpegData: Data)
  func selection() -> Data?
  var frameCount: Int { get }
}

/// Placeholder for the future on-device frame-quality model.
/// It deliberately retains only the first usable frame, keeping memory bounded.
final class FirstFrameSelector: FrameSelecting, @unchecked Sendable {
  private let lock = NSLock()
  private var firstFrame: Data?
  private var count = 0

  var frameCount: Int { lock.withLock { count } }

  func reset() {
    lock.withLock {
      firstFrame = nil
      count = 0
    }
  }

  func consider(jpegData: Data) {
    lock.withLock {
      count += 1
      if firstFrame == nil { firstFrame = jpegData }
    }
  }

  func selection() -> Data? {
    lock.withLock { firstFrame }
  }
}

