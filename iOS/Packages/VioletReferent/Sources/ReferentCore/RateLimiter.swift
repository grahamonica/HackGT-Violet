import Foundation

/// Allows at most `limit` acquisitions in any sliding window of `window`.
/// Callers over the limit wait for a slot; waiting ends early if the calling
/// task is cancelled.
public actor RateLimiter {
  public let limit: Int
  public let window: Duration
  private let clock = ContinuousClock()
  private var recent: [ContinuousClock.Instant] = []  // grant times inside the window, oldest first

  public init(limit: Int, per window: Duration = .seconds(1)) {
    self.limit = max(1, limit)
    self.window = window
  }

  /// Waits until a slot is free, then takes it. Returns false if cancelled while waiting.
  @discardableResult
  public func acquire() async -> Bool {
    while true {
      if Task.isCancelled { return false }
      let now = clock.now
      recent.removeAll { now - $0 >= window }
      if recent.count < limit {
        recent.append(now)
        return true
      }
      // Sleep until the oldest grant leaves the window, then re-check (another
      // caller may have taken the slot meanwhile).
      do { try await clock.sleep(until: recent[0] + window) } catch { return false }
    }
  }
}
