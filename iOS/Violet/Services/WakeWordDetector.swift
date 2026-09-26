import Foundation

struct WakeWordDetector: Sendable {
  private(set) var lastTrigger: Date?
  let cooldown: TimeInterval

  /// Only de-duplicates one utterance (the partial and final transcripts both contain
  /// "Violet"); triggers during a request are ignored by `GlassesManager`.
  init(cooldown: TimeInterval = 2) {
    self.cooldown = cooldown
  }

  mutating func consume(_ transcript: String, at date: Date = .now) -> Bool {
    guard Self.containsWakeWord(transcript) else { return false }
    if let lastTrigger, date.timeIntervalSince(lastTrigger) < cooldown { return false }
    lastTrigger = date
    return true
  }

  /// "Violet" plus what the glasses' transcription has turned it into on real hardware.
  static let wakeWords: Set<String> = ["violet", "vista"]

  static func containsWakeWord(_ transcript: String) -> Bool {
    !wakeWords.isDisjoint(
      with: transcript
        .lowercased()
        .components(separatedBy: CharacterSet.letters.inverted)
    )
  }
}

