import Foundation

struct WakeWordDetector: Sendable {
  private(set) var lastTrigger: Date?
  let cooldown: TimeInterval

  init(cooldown: TimeInterval = 8) {
    self.cooldown = cooldown
  }

  mutating func consume(_ transcript: String, at date: Date = .now) -> Bool {
    guard Self.containsWakeWord(transcript) else { return false }
    if let lastTrigger, date.timeIntervalSince(lastTrigger) < cooldown { return false }
    lastTrigger = date
    return true
  }

  static func containsWakeWord(_ transcript: String) -> Bool {
    transcript
      .lowercased()
      .components(separatedBy: CharacterSet.letters.inverted)
      .contains("violet")
  }
}

