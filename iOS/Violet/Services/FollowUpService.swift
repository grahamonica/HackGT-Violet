import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the model gets for one follow-up: the words after "Violet" and what the app
/// knows about the person who was just identified.
struct FollowUpRequest: Sendable {
  let utterance: String
  let person: FamiliarPerson
  let today: Date
}

enum FollowUpAnswer: Sendable {
  /// The words weren't a question for Violet about this person (talking to someone
  /// else, background speech), so Violet says nothing more.
  case notAFollowUp
  /// A real question the bio and notes don't cover; Violet says a fixed line.
  case noInformation
  /// A short spoken reply, meant to be said right after the identity line.
  case reply(String)
}

/// The slow path's model. One call decides whether the utterance is a real follow-up
/// and, if so, writes the reply, so a non-question costs a single call and no speech.
/// Swap models by adding another conformance; `AppModel` only sees this protocol.
@MainActor
protocol FollowUpAnswering: Sendable {
  /// False when the model can't run on this phone right now.
  var isAvailable: Bool { get }
  /// Loads the model ahead of the question, e.g. when "Violet" is heard.
  func prepare()
  func answer(_ request: FollowUpRequest) async throws -> FollowUpAnswer
}

enum FollowUpPrompt {
  /// Spoken replies are asked to stay under this; `FollowUpText.trimmed` enforces `hardWordLimit`.
  static let wordLimit = 20
  static let hardWordLimit = 30
  /// Bio and notes are cut to this many characters each to keep the prompt small.
  static let maxFieldLength = 1500

  static let instructions = """
    You are Violet, a gentle memory aid speaking through smart glasses to a person living \
    with dementia. They just looked at someone and said "Violet", and Violet has already told \
    them who it is (name and relationship). You now see the words they said after "Violet".

    First choose the kind of response:
    - notAQuestion: the words are not a question or request to Violet about this person \
    (chatter to someone else, background speech, or words that don't ask anything).
    - noInformation: it is such a question, but the facts given don't answer it. Leave the \
    reply empty; Violet will say that it doesn't know.
    - answer: it is such a question and the facts answer it.

    Only for answer, write a warm reply of one or two short sentences, at most \
    \(wordLimit) words, to be spoken aloud:
    - Use only the facts given about this person. Never invent or guess anything.
    - Help them remember instead of telling everything: give part of the answer as a hint \
    and leave out one specific detail (such as a place, a name, or a number) for them to \
    recall. Use your judgment: if leaving something out could confuse or worry them, just say it.
    - Don't repeat the person's name and relationship; that was just said.
    - If they ask who this is, add one thing about the person from the facts.
    - Simple, everyday words. No lists, no emoji, no questions back to them.
    """

  static func prompt(for request: FollowUpRequest) -> String {
    let person = request.person
    let date = request.today.formatted(date: .complete, time: .omitted)
    return """
      Today is \(date).
      Person: \(person.name), their \(person.relation), known since \(person.yearMet).
      Bio: \(field(person.bio))
      Notes: \(field(person.notes))
      Words said after "Violet": "\(request.utterance)"
      """
  }

  private static func field(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "(none)" : String(trimmed.prefix(maxFieldLength))
  }
}

#if canImport(FoundationModels)
/// The follow-up model on the phone itself (Apple Intelligence), so the question and the
/// person's notes never leave the device for this step. Needs iOS 26 on an Apple
/// Intelligence iPhone with Apple Intelligence turned on; otherwise `isAvailable` is false
/// and Violet skips follow-ups.
@available(iOS 26.0, *)
@MainActor
final class AppleFollowUpService: FollowUpAnswering {
  /// A fresh session per request (a session keeps its conversation), created and
  /// prewarmed by `prepare()` so the model is loaded before the question arrives.
  private var session: LanguageModelSession?

  var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

  func prepare() {
    guard isAvailable else { return }
    let session = LanguageModelSession(instructions: FollowUpPrompt.instructions)
    session.prewarm()
    self.session = session
  }

  func answer(_ request: FollowUpRequest) async throws -> FollowUpAnswer {
    let session = self.session ?? LanguageModelSession(instructions: FollowUpPrompt.instructions)
    self.session = nil
    let decision = try await session.respond(
      to: FollowUpPrompt.prompt(for: request),
      generating: FollowUpDecision.self,
      options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 120)
    ).content
    switch decision.kind {
    case .notAQuestion:
      return .notAFollowUp
    case .noInformation:
      return .noInformation
    case .answer:
      // No validation loop: an empty answer counts as "don't know".
      let reply = decision.reply.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !reply.isEmpty else { return .noInformation }
      return .reply(FollowUpText.trimmed(reply, maxWords: FollowUpPrompt.hardWordLimit))
    }
  }
}

/// The model's structured answer. Properties are generated in order, so the model
/// picks `kind` before writing any reply.
@available(iOS 26.0, *)
@Generable
struct FollowUpDecision {
  var kind: FollowUpKind

  @Guide(description: "The spoken reply, at most 20 words, only when kind is answer; otherwise empty.")
  var reply: String
}

@available(iOS 26.0, *)
@Generable
enum FollowUpKind {
  /// Not a question or request to Violet about this person.
  case notAQuestion
  /// A question about this person that the given facts don't answer.
  case noInformation
  /// A question the given facts answer.
  case answer
}
#endif

enum FollowUpTiming {
  /// The model gets this long from the question; after that the follow-up is skipped.
  static let modelTimeout: Duration = .seconds(5)
  /// Once a reply is certain, a filler plays if its voice hasn't started by then.
  static let fillerDelay: Duration = .seconds(1)
  /// Limit on generating the reply's voice (it is never cached ahead).
  static let voiceTimeout: TimeInterval = 8
}
