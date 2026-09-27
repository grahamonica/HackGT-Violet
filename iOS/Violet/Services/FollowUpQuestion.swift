import Foundation

/// Collects what the wearer says after "Violet" from the glasses' transcripts.
///
/// The glasses send a transcript about every 0.3 s. Whether each one is the whole
/// running utterance or only the newest words isn't documented, so both are handled:
/// a transcript that extends the text so far replaces it, anything else is appended.
/// The question is whatever follows the last wake word, so a transcript that revises
/// earlier words (and repeats "Violet") still ends up with the right question.
struct QuestionCollector: Sendable {
  private(set) var heard = ""
  /// When the transcript last changed, i.e. when the wearer was last heard speaking.
  private(set) var lastWordsAt: Date?

  init(startingWith transcript: String = "", at date: Date = .now) {
    add(transcript, at: date)
  }

  mutating func add(_ transcript: String, at date: Date = .now) {
    let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    let current = heard.lowercased()
    let incoming = words.lowercased()
    if heard.isEmpty || incoming.hasPrefix(current) {
      guard words != heard else { return }
      heard = words
    } else if current.hasSuffix(incoming) {
      return  // the same words again
    } else {
      heard += " " + words
    }
    lastWordsAt = date
  }

  /// The words after the last "Violet", without surrounding punctuation.
  var question: String {
    let tokens = heard.split(whereSeparator: \.isWhitespace)
    let lastWake = tokens.lastIndex { token in
      WakeWordDetector.wakeWords.contains(token.lowercased().filter(\.isLetter))
    }
    let after = lastWake.map { tokens[tokens.index(after: $0)...] } ?? tokens[...]
    return after.joined(separator: " ")
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
  }
}

enum FollowUpText {
  /// Words that don't make a question on their own ("Violet, um, okay").
  private static let fillerWords: Set<String> = [
    "um", "uh", "er", "hmm", "mm", "oh", "hey", "hi", "ok", "okay", "please", "so", "and", "well",
  ]

  /// Cheap check before running the model: at least two real words after "Violet".
  static func mightBeQuestion(_ question: String) -> Bool {
    let words = question.lowercased()
      .components(separatedBy: CharacterSet.letters.inverted)
      .filter { !$0.isEmpty && !fillerWords.contains($0) }
    return words.count >= 2
  }

  /// Keeps a spoken reply short even if the model runs long: at most `maxWords`,
  /// ending at the last full sentence when there is one.
  static func trimmed(_ reply: String, maxWords: Int) -> String {
    let words = reply.split(whereSeparator: \.isWhitespace)
    guard words.count > maxWords else { return reply.trimmingCharacters(in: .whitespacesAndNewlines) }
    let cut = words.prefix(maxWords).joined(separator: " ")
    if let end = cut.lastIndex(where: { ".!?".contains($0) }) {
      return String(cut[...end])
    }
    return cut.trimmingCharacters(in: .punctuationCharacters) + "."
  }
}
