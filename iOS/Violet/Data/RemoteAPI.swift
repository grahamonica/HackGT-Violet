import Foundation

enum RemoteAPIError: LocalizedError {
  case notConfigured
  case invalidResponse
  case requestFailed(Int, String)
  case invalidPhoto

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "The remote database is not configured."
    case .invalidResponse:
      "The database returned an unreadable response."
    case .requestFailed(let status, let message):
      "Database request failed (\(status)): \(message)"
    case .invalidPhoto:
      "A relationship photo could not be read."
    }
  }
}

struct RelationshipSyncBatch: Sendable {
  let people: [FamiliarPerson]
  let etag: String?
  let notModified: Bool
}

actor RemoteAPI {
  private let environment: AppEnvironment
  private let session: URLSession

  init(environment: AppEnvironment, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
  }

  func fetchRelationshipChanges(since: Date?, etag: String?) async throws -> RelationshipSyncBatch {
    var request = try request(path: environment.relationshipsPath, method: "GET")
    if let since {
      var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      components?.queryItems = [
        URLQueryItem(name: "updatedAfter", value: Self.dateString(since))
      ]
      request.url = components?.url
    }
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.invalidResponse }
    if http.statusCode == 304 {
      return RelationshipSyncBatch(people: [], etag: etag, notModified: true)
    }
    try validate(http, data: data)

    let records: [RemotePerson]
    if let array = try? Self.decoder.decode([RemotePerson].self, from: data) {
      records = array
    } else if let envelope = try? Self.decoder.decode(RelationshipEnvelope.self, from: data) {
      records = envelope.items
    } else {
      throw RemoteAPIError.invalidResponse
    }

    var people: [FamiliarPerson] = []
    for record in records {
      people.append(try await record.person(using: session))
    }
    return RelationshipSyncBatch(
      people: people,
      etag: http.value(forHTTPHeaderField: "ETag"),
      notModified: false
    )
  }

  func upload(_ person: FamiliarPerson) async throws -> (id: String?, updatedAt: Date) {
    var request = try request(path: environment.relationshipsPath, method: "POST")
    request.httpBody = try Self.encoder.encode(RemotePerson(person: person))
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.invalidResponse }
    try validate(http, data: data)

    guard !data.isEmpty,
      let saved = try? Self.decoder.decode(RemoteSaveResponse.self, from: data)
    else {
      return (nil, .now)
    }
    return (saved.id, saved.updatedAt ?? .now)
  }

  func upload(_ log: RecognitionLog) async throws {
    var request = try request(path: environment.logsPath, method: "POST")
    request.httpBody = try Self.encoder.encode(RemoteLog(log: log))
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.invalidResponse }
    try validate(http, data: data)
  }

  private func request(path: String, method: String) throws -> URLRequest {
    guard let endpoint = environment.mongoEndpoint, !environment.mongoAPIKey.isEmpty else {
      throw RemoteAPIError.notConfigured
    }
    let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let url = cleanPath.isEmpty ? endpoint : endpoint.appendingPathComponent(cleanPath)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(environment.mongoAPIKey, forHTTPHeaderField: "api-key")
    return request
  }

  private func validate(_ response: HTTPURLResponse, data: Data) throws {
    guard (200..<300).contains(response.statusCode) else {
      let message = String(data: Data(data.prefix(300)), encoding: .utf8) ?? "Unknown error"
      throw RemoteAPIError.requestFailed(response.statusCode, message)
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(dateString(date))
    }
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = parseDate(value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid ISO-8601 date"
      )
    }
    return decoder
  }()

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

private struct RelationshipEnvelope: Decodable {
  let items: [RemotePerson]

  enum CodingKeys: String, CodingKey {
    case items
    case relationships
    case documents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let items = try container.decodeIfPresent([RemotePerson].self, forKey: .items) {
      self.items = items
    } else if let relationships = try container.decodeIfPresent([RemotePerson].self, forKey: .relationships) {
      self.items = relationships
    } else {
      self.items = try container.decode([RemotePerson].self, forKey: .documents)
    }
  }
}

private struct RemotePerson: Codable {
  let id: String?
  let name: String
  let frontPhoto: String
  let leftPhoto: String
  let rightPhoto: String
  let relation: String
  let bio: String
  let yearMet: Int
  let updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case mongoID = "_id"
    case name
    case frontPhoto = "front_photo"
    case frontPhotoLegacy = "frontPhoto"
    case leftPhoto = "left_photo"
    case leftPhotoLegacy = "leftPhoto"
    case rightPhoto = "right_photo"
    case rightPhotoLegacy = "rightPhoto"
    case relation
    case bio
    case yearMet = "year_met"
    case yearMetLegacy = "yearMet"
    case updatedAt = "updated_at"
    case updatedAtLegacy = "updatedAt"
  }

  init(person: FamiliarPerson) {
    id = person.id
    name = person.name
    frontPhoto = person.frontPhoto.base64EncodedString()
    leftPhoto = person.leftPhoto.base64EncodedString()
    rightPhoto = person.rightPhoto.base64EncodedString()
    relation = person.relation
    bio = person.bio
    yearMet = person.yearMet
    updatedAt = person.updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
      ?? container.decodeIfPresent(String.self, forKey: .mongoID)
    name = try container.decode(String.self, forKey: .name)
    frontPhoto = try container.decodeIfPresent(String.self, forKey: .frontPhoto)
      ?? container.decode(String.self, forKey: .frontPhotoLegacy)
    leftPhoto = try container.decodeIfPresent(String.self, forKey: .leftPhoto)
      ?? container.decode(String.self, forKey: .leftPhotoLegacy)
    rightPhoto = try container.decodeIfPresent(String.self, forKey: .rightPhoto)
      ?? container.decode(String.self, forKey: .rightPhotoLegacy)
    relation = try container.decode(String.self, forKey: .relation)
    bio = try container.decodeIfPresent(String.self, forKey: .bio) ?? ""
    yearMet = try container.decodeIfPresent(Int.self, forKey: .yearMet)
      ?? container.decode(Int.self, forKey: .yearMetLegacy)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
      ?? container.decodeIfPresent(Date.self, forKey: .updatedAtLegacy)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(frontPhoto, forKey: .frontPhoto)
    try container.encode(leftPhoto, forKey: .leftPhoto)
    try container.encode(rightPhoto, forKey: .rightPhoto)
    try container.encode(relation, forKey: .relation)
    try container.encode(bio, forKey: .bio)
    try container.encode(yearMet, forKey: .yearMet)
  }

  func person(using session: URLSession) async throws -> FamiliarPerson {
    guard let front = await Self.photoData(frontPhoto, using: session),
      let left = await Self.photoData(leftPhoto, using: session),
      let right = await Self.photoData(rightPhoto, using: session)
    else {
      throw RemoteAPIError.invalidPhoto
    }
    return FamiliarPerson(
      id: id ?? UUID().uuidString,
      name: name,
      frontPhoto: front,
      leftPhoto: left,
      rightPhoto: right,
      relation: relation,
      bio: bio,
      yearMet: yearMet,
      updatedAt: updatedAt ?? .distantPast,
      needsUpload: false
    )
  }

  private static func photoData(_ value: String, using session: URLSession) async -> Data? {
    if let decoded = Data(base64Encoded: value) { return decoded }
    guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased()) else {
      return nil
    }
    return try? await session.data(from: url).0
  }
}

private struct RemoteSaveResponse: Decodable {
  let id: String?
  let updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case mongoID = "_id"
    case insertedID = "insertedId"
    case updatedAt = "updated_at"
    case updatedAtLegacy = "updatedAt"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
      ?? container.decodeIfPresent(String.self, forKey: .mongoID)
      ?? container.decodeIfPresent(String.self, forKey: .insertedID)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
      ?? container.decodeIfPresent(Date.self, forKey: .updatedAtLegacy)
  }
}

private struct RemoteLog: Encodable {
  let timestamp: Date
  let identifiedPerson: String

  init(log: RecognitionLog) {
    timestamp = log.timestamp
    identifiedPerson = log.identifiedPerson
  }

  enum CodingKeys: String, CodingKey {
    case timestamp
    case identifiedPerson = "identified_person"
  }
}
