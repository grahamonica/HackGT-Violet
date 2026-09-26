import Foundation

actor LocalStore {
  private let fileURL: URL
  private var cache: LocalCache?

  init(fileManager: FileManager = .default) {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Violet", isDirectory: true)
    try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("cache.json")
  }

  func load() -> LocalCache {
    if let cache { return cache }
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? Self.decoder.decode(LocalCache.self, from: data)
    else {
      cache = .empty
      return .empty
    }
    cache = decoded
    return decoded
  }

  @discardableResult
  func upsert(_ person: FamiliarPerson) throws -> LocalCache {
    var value = load()
    if let index = value.people.firstIndex(where: { $0.id == person.id }) {
      value.people[index] = person
    } else {
      value.people.append(person)
    }
    value.people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    try save(value)
    return value
  }

  @discardableResult
  func mergeRemote(_ people: [FamiliarPerson], syncedAt: Date, etag: String?) throws -> LocalCache {
    var value = load()
    for person in people {
      if let index = value.people.firstIndex(where: { $0.id == person.id }) {
        guard !value.people[index].needsUpload,
          person.updatedAt >= value.people[index].updatedAt
        else { continue }
        value.people[index] = person
      } else {
        value.people.append(person)
      }
    }
    value.people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    value.lastRelationshipSync = syncedAt
    if let etag { value.relationshipETag = etag }
    try save(value)
    return value
  }

  @discardableResult
  func markPersonUploaded(id: String, serverID: String?, updatedAt: Date) throws -> LocalCache {
    var value = load()
    guard let index = value.people.firstIndex(where: { $0.id == id }) else { return value }
    value.people[index].id = serverID ?? id
    value.people[index].needsUpload = false
    value.people[index].updatedAt = updatedAt
    try save(value)
    return value
  }

  @discardableResult
  func append(_ log: RecognitionLog) throws -> LocalCache {
    var value = load()
    value.logs.append(log)
    try save(value)
    return value
  }

  @discardableResult
  func markLogUploaded(id: UUID) throws -> LocalCache {
    var value = load()
    if let index = value.logs.firstIndex(where: { $0.id == id }) {
      value.logs[index].needsUpload = false
    }
    try save(value)
    return value
  }

  private func save(_ value: LocalCache) throws {
    let data = try Self.encoder.encode(value)
    try data.write(to: fileURL, options: .atomic)
    cache = value
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
