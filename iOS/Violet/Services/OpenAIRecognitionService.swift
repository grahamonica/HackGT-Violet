import Foundation

enum RecognitionServiceError: LocalizedError {
  case notConfigured
  case invalidResponse
  case requestFailed(Int, String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "OpenAI is not configured."
    case .invalidResponse:
      "The recognition response could not be read."
    case .requestFailed(let status, let message):
      "Recognition request failed (\(status)): \(message)"
    }
  }
}

protocol PersonRecognizing: Sendable {
  func recognize(candidate: Data, among people: [FamiliarPerson]) async throws -> RecognitionDecision
}

actor OpenAIRecognitionService: PersonRecognizing {
  private let environment: AppEnvironment
  private let session: URLSession

  init(environment: AppEnvironment, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
  }

  func recognize(candidate: Data, among people: [FamiliarPerson]) async throws -> RecognitionDecision {
    guard environment.openAIIsConfigured else { throw RecognitionServiceError.notConfigured }
    guard !people.isEmpty else {
      return RecognitionDecision(likelihood: .notHighlyLikely, personID: nil)
    }

    var content: [[String: Any]] = [
      [
        "type": "input_text",
        "text": "Candidate image follows. Only match it when the same person is unmistakable."
      ],
      imagePart(candidate)
    ]

    for person in people {
      content.append([
        "type": "input_text",
        "text": "Reference person ID \(person.id), name \(person.name). Front, left, and right views follow."
      ])
      content.append(imagePart(person.frontPhoto))
      content.append(imagePart(person.leftPhoto))
      content.append(imagePart(person.rightPhoto))
    }

    let schema: [String: Any] = [
      "type": "object",
      "properties": [
        "likelihood": [
          "type": "string",
          "enum": [MatchLikelihood.highlyLikely.rawValue, MatchLikelihood.notHighlyLikely.rawValue]
        ],
        "personID": ["type": ["string", "null"]]
      ],
      "required": ["likelihood", "personID"],
      "additionalProperties": false
    ]

    let body: [String: Any] = [
      "model": environment.openAIModel,
      "store": false,
      "max_output_tokens": 120,
      "input": [
        [
          "role": "system",
          "content": [
            [
              "type": "input_text",
              "text": "Compare the candidate only with the provided private reference set. Return HIGHLY_LIKELY only when visual evidence is exceptionally strong. Otherwise return NOT_HIGHLY_LIKELY and null. Never guess, and return only the schema."
            ]
          ]
        ],
        ["role": "user", "content": content]
      ],
      "text": [
        "format": [
          "type": "json_schema",
          "name": "violet_person_match",
          "strict": true,
          "schema": schema
        ]
      ]
    ]

    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("Bearer \(environment.openAIKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw RecognitionServiceError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let message = String(data: Data(data.prefix(300)), encoding: .utf8) ?? "Unknown error"
      throw RecognitionServiceError.requestFailed(http.statusCode, message)
    }

    let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
    guard let outputText = apiResponse.output
      .flatMap(\.content)
      .first(where: { $0.type == "output_text" })?
      .text,
      let resultData = outputText.data(using: .utf8),
      let decision = try? JSONDecoder().decode(RecognitionDecision.self, from: resultData)
    else {
      throw RecognitionServiceError.invalidResponse
    }

    let validIDs = Set(people.map(\.id))
    guard decision.likelihood == .highlyLikely,
      let personID = decision.personID,
      validIDs.contains(personID)
    else {
      return RecognitionDecision(likelihood: .notHighlyLikely, personID: nil)
    }
    return decision
  }

  private func imagePart(_ data: Data) -> [String: Any] {
    [
      "type": "input_image",
      "image_url": "data:image/jpeg;base64,\(data.base64EncodedString())",
      "detail": "high"
    ]
  }
}

private struct OpenAIResponse: Decodable {
  struct Output: Decodable {
    let content: [Content]

    enum CodingKeys: String, CodingKey { case content }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      content = try container.decodeIfPresent([Content].self, forKey: .content) ?? []
    }
  }

  struct Content: Decodable {
    let type: String
    let text: String?
  }

  let output: [Output]
}

