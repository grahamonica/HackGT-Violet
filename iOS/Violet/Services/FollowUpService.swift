import Foundation

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
/// `AppModel` only sees this protocol; `ChatCompletionsFollowUpService` serves any
/// OpenAI-compatible API (Grok, Muse), picked with `FOLLOW_UP_PROVIDER`.
@MainActor
protocol FollowUpAnswering: Sendable {
  /// False when the model can't be used (e.g. no API key).
  var isAvailable: Bool { get }
  /// Gets ready for a question, e.g. when "Violet" is heard.
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
    - Speak plainly and kindly, like a caring nurse: no jokes, wit, slang, or playful asides.
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

  /// The JSON the model must return. `kind` comes first so it is decided before the reply.
  static var schema: [String: Any] {
    [
      "type": "object",
      "properties": [
        "kind": ["type": "string", "enum": ["notAQuestion", "noInformation", "answer"]],
        "reply": ["type": "string", "description": "The spoken reply when kind is answer; otherwise empty."],
      ],
      "required": ["kind", "reply"],
      "additionalProperties": false,
    ]
  }
}

/// A chat-completions API with JSON-schema output, and the settings that keep it fast.
struct FollowUpProvider: Sendable {
  let name: String
  let endpoint: URL
  let model: String
  let apiKey: String
  /// Lowest reasoning the model allows ("none" for Grok; Muse always reasons, so "minimal").
  let reasoningEffort: String
  /// Output-token cap. Muse counts reasoning tokens against it, so it needs more room.
  let maxTokens: Int

  static func grok(apiKey: String, model: String?) -> FollowUpProvider {
    FollowUpProvider(
      name: "Grok", endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
      model: model ?? "grok-4.3", apiKey: apiKey, reasoningEffort: "none", maxTokens: 150)
  }

  static func muse(apiKey: String, model: String?) -> FollowUpProvider {
    FollowUpProvider(
      name: "Muse", endpoint: URL(string: "https://api.meta.ai/v1/chat/completions")!,
      model: model ?? "muse-spark-1.3", apiKey: apiKey, reasoningEffort: "minimal", maxTokens: 2000)
  }

  /// `FOLLOW_UP_PROVIDER` is `grok` (default) or `muse`; `FOLLOW_UP_MODEL` optionally
  /// overrides the model. Nil when the chosen provider's key is missing.
  static func from(_ environment: AppEnvironment) -> FollowUpProvider? {
    switch environment.followUpProvider.lowercased() {
    case "muse", "meta":
      guard !environment.metaAPIKey.isEmpty else { return nil }
      return FollowUpProvider.muse(apiKey: environment.metaAPIKey, model: environment.followUpModel)
    default:
      guard !environment.xaiAPIKey.isEmpty else { return nil }
      return FollowUpProvider.grok(apiKey: environment.xaiAPIKey, model: environment.followUpModel)
    }
  }
}

enum FollowUpServiceError: LocalizedError {
  case requestFailed(Int, String)
  case unreadableResponse

  var errorDescription: String? {
    switch self {
    case .requestFailed(let status, let message): "Follow-up request failed (\(status)): \(message)"
    case .unreadableResponse: "The follow-up response did not match the expected format."
    }
  }
}

/// `FollowUpAnswering` over an OpenAI-compatible chat-completions API. One request, no
/// retries; anything unreadable throws, and the app then says its fixed "don't know" line.
@MainActor
final class ChatCompletionsFollowUpService: FollowUpAnswering {
  let provider: FollowUpProvider
  private let session: URLSession

  init(provider: FollowUpProvider, session: URLSession = .shared) {
    self.provider = provider
    self.session = session
  }

  var isAvailable: Bool { !provider.apiKey.isEmpty }

  /// Opens the connection (DNS and TLS) while the camera runs, so the real request
  /// doesn't pay for it. The response doesn't matter.
  func prepare() {
    var request = URLRequest(url: provider.endpoint.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("models"))
    request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 5
    let session = session
    Task.detached { _ = try? await session.data(for: request) }
  }

  func answer(_ request: FollowUpRequest) async throws -> FollowUpAnswer {
    let body: [String: Any] = [
      "model": provider.model,
      "messages": [
        ["role": "system", "content": FollowUpPrompt.instructions],
        ["role": "user", "content": FollowUpPrompt.prompt(for: request)],
      ],
      "reasoning_effort": provider.reasoningEffort,
      "max_tokens": provider.maxTokens,
      "response_format": [
        "type": "json_schema",
        "json_schema": ["name": "violet_follow_up", "strict": true, "schema": FollowUpPrompt.schema],
      ],
    ]
    var urlRequest = URLRequest(url: provider.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 6
    urlRequest.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: urlRequest)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw FollowUpServiceError.requestFailed(status, String(decoding: data.prefix(300), as: UTF8.self))
    }
    return try Self.parse(data)
  }

  /// Reads `choices[0].message.content` as `{"kind": ..., "reply": ...}`.
  nonisolated static func parse(_ data: Data) throws -> FollowUpAnswer {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      let decision = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
      let kind = decision["kind"] as? String
    else { throw FollowUpServiceError.unreadableResponse }
    switch kind {
    case "notAQuestion":
      return .notAFollowUp
    case "noInformation":
      return .noInformation
    case "answer":
      // No validation loop: an empty answer counts as "don't know".
      let reply = (decision["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !reply.isEmpty else { return .noInformation }
      return .reply(FollowUpText.trimmed(reply, maxWords: FollowUpPrompt.hardWordLimit))
    default:
      throw FollowUpServiceError.unreadableResponse
    }
  }
}

enum FollowUpTiming {
  /// On a "Violet" request that could have a follow-up, the identity line starts no
  /// earlier than this after the trigger, so a quick recognition doesn't cut the
  /// question short. Slower answers aren't delayed further.
  static let minimumListening: TimeInterval = 2
  /// The model gets this long from the question; after that the follow-up is skipped.
  static let modelTimeout: Duration = .seconds(5)
  /// Once a reply is certain, a filler plays if its voice hasn't started by then.
  static let fillerDelay: Duration = .seconds(1)
  /// Limit on generating the reply's voice (it is never cached ahead).
  static let voiceTimeout: TimeInterval = 8
}
