import Foundation
import MongoKitten
import dnssd

enum RemoteAPIError: LocalizedError {
  case notConfigured
  case serverLookupFailed(String)
  case writeRejected(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "The remote database is not configured."
    case .serverLookupFailed(let name):
      "Could not look up the database servers for \(name)."
    case .writeRejected(let message):
      "The database rejected the change: \(message)"
    }
  }
}

/// Talks to MongoDB Atlas directly through `MONGO_URI`, using the same database, collections,
/// and camelCase fields as the provider portal.
actor RemoteAPI {
  private let environment: AppEnvironment
  private var connection: Task<MongoCluster, Error>?

  init(environment: AppEnvironment) {
    self.environment = environment
  }

  /// Relationships updated after `since`, or every relationship when `since` is nil.
  func fetchRelationshipChanges(since: Date?) async throws -> [FamiliarPerson] {
    let filter: Document = since.map { ["updatedAt": ["$gt": $0] as Document] } ?? [:]
    let documents = try await run { database in
      try await database[self.environment.relationshipsPath].find(filter).drain()
    }
    // Skip unreadable records so one bad document cannot block the rest of the sync.
    return documents.compactMap(Self.person(from:))
  }

  /// IDs of every relationship still in the database, so people deleted from the portal can be
  /// dropped from the local cache.
  func fetchRelationshipIDs() async throws -> Set<String> {
    let documents = try await run { database in
      try await database[self.environment.relationshipsPath].find()
        .project(["_id": 1] as Document).drain()
    }
    return Set(documents.compactMap { ($0["_id"] as? ObjectId)?.hexString ?? $0["_id"] as? String })
  }

  func upload(_ person: FamiliarPerson) async throws -> (id: String, updatedAt: Date) {
    let id = ObjectId()
    let now = Date()
    try await insert(
      [
        "_id": id,
        "name": person.name,
        "frontPhoto": person.frontPhoto.base64EncodedString(),
        "leftPhoto": person.leftPhoto.base64EncodedString(),
        "rightPhoto": person.rightPhoto.base64EncodedString(),
        "relation": person.relation,
        "bio": person.bio,
        "notes": person.notes,
        "yearMet": person.yearMet,
        "createdAt": now,
        "updatedAt": now,
      ],
      into: environment.relationshipsPath
    )
    return (id.hexString, now)
  }

  func upload(_ log: RecognitionLog) async throws {
    try await insert(
      ["timestamp": log.timestamp, "identifiedPerson": log.identifiedPerson],
      into: environment.logsPath
    )
  }

  /// Closes the connection while the app is in the background; the next call reconnects.
  func disconnect() async {
    let connection = self.connection
    self.connection = nil
    if let cluster = try? await connection?.value {
      await cluster.disconnect()
    }
  }

  private func insert(_ document: Document, into collection: String) async throws {
    let reply = try await run { database in
      try await database[collection].insert(document)
    }
    // Validation failures come back as `ok: 1` with write errors instead of throwing.
    guard reply.insertCount == 1 else {
      throw RemoteAPIError.writeRejected(
        reply.writeErrors?.first?.message ?? "Nothing was inserted."
      )
    }
  }

  private func run<Value: Sendable>(
    _ operation: (MongoDatabase) async throws -> Value
  ) async throws -> Value {
    let database = try await database()
    do {
      return try await operation(database)
    } catch {
      // Drop a connection that may have gone stale; the next one-minute sync reconnects.
      await disconnect()
      throw error
    }
  }

  private func database() async throws -> MongoDatabase {
    guard environment.mongoIsConfigured else { throw RemoteAPIError.notConfigured }
    let connection =
      self.connection
      ?? Task { [uri = environment.mongoURI] in
        try await MongoCluster(connectingTo: Self.connectionSettings(for: uri))
      }
    self.connection = connection
    do {
      return try await connection.value[environment.mongoDatabase]
    } catch {
      if self.connection == connection { self.connection = nil }
      throw error
    }
  }

  /// MongoKitten resolves `mongodb+srv://` hosts by reading /etc/resolv.conf, which iOS apps
  /// cannot rely on, so the seed list is resolved here with the system resolver instead.
  private static func connectionSettings(for uri: String) async throws -> ConnectionSettings {
    let parsed = try ConnectionSettings(uri)
    guard parsed.isSRV, parsed.dnsServer == nil, let seed = parsed.hosts.first else {
      return parsed
    }
    var settings = ConnectionSettings(
      authentication: parsed.authentication,
      authenticationSource: parsed.authenticationSource,
      hosts: try await SRVLookup.hosts(for: "_mongodb._tcp.\(seed.hostname)"),
      targetDatabase: parsed.targetDatabase,
      useSSL: parsed.useSSL,
      verifySSLCertificates: parsed.verifySSLCertificates,
      maximumNumberOfConnections: parsed.maximumNumberOfConnections,
      connectTimeout: parsed.connectTimeout,
      socketTimeout: parsed.socketTimeout,
      applicationName: parsed.applicationName
    )
    settings.sslCaCertificatePath = parsed.sslCaCertificatePath
    settings.queryParameters = parsed.queryParameters
    return settings
  }

  private static func person(from document: Document) -> FamiliarPerson? {
    guard let id = (document["_id"] as? ObjectId)?.hexString ?? document["_id"] as? String,
      let name = document["name"] as? String,
      let front = photo(document["frontPhoto"] ?? document["front_photo"]),
      let left = photo(document["leftPhoto"] ?? document["left_photo"]),
      let right = photo(document["rightPhoto"] ?? document["right_photo"]),
      let relation = document["relation"] as? String
    else {
      return nil
    }
    return FamiliarPerson(
      id: id,
      name: name,
      frontPhoto: front,
      leftPhoto: left,
      rightPhoto: right,
      relation: relation,
      bio: document["bio"] as? String ?? "",
      // Missing on documents written before notes existed.
      notes: document["notes"] as? String ?? "",
      yearMet: integer(document["yearMet"] ?? document["year_met"])
        ?? Calendar.current.component(.year, from: .now),
      updatedAt: (document["updatedAt"] ?? document["updated_at"]) as? Date ?? .distantPast,
      needsUpload: false
    )
  }

  private static func photo(_ value: Primitive?) -> Data? {
    guard var base64 = value as? String else { return nil }
    if base64.hasPrefix("data:"), let comma = base64.firstIndex(of: ",") {
      base64 = String(base64[base64.index(after: comma)...])
    }
    return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
  }

  /// The portal's Node driver stores whole numbers as int32; accept any BSON number.
  private static func integer(_ value: Primitive?) -> Int? {
    switch value {
    case let value as Int: value
    case let value as Int32: Int(value)
    case let value as Double: Int(value)
    default: nil
    }
  }
}

/// A one-shot SRV query through the system DNS resolver (dnssd).
private final class SRVLookup: @unchecked Sendable {
  // Every stored property is only touched on `queue`, which is also the dnssd callback queue.
  private let queue = DispatchQueue(label: "com.violet.patient.srv-lookup")
  private var service: DNSServiceRef?
  private var hosts: [ConnectionSettings.Host] = []
  private var continuation: CheckedContinuation<[ConnectionSettings.Host], Error>?

  static func hosts(for name: String, timeout: TimeInterval = 10) async throws
    -> [ConnectionSettings.Host]
  {
    try await SRVLookup().run(name: name, timeout: timeout)
  }

  private func run(name: String, timeout: TimeInterval) async throws -> [ConnectionSettings.Host] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.continuation = continuation
        // Balanced by the release in `finish`, which runs exactly once.
        let context = Unmanaged.passRetained(self).toOpaque()
        var service: DNSServiceRef?
        let status = DNSServiceQueryRecord(
          &service,
          0,
          0,
          name,
          UInt16(kDNSServiceType_SRV),
          UInt16(kDNSServiceClass_IN),
          { _, flags, _, status, _, _, _, length, data, _, context in
            guard let context else { return }
            Unmanaged<SRVLookup>.fromOpaque(context).takeUnretainedValue()
              .receive(flags: flags, status: status, data: data, length: length)
          },
          context
        )
        guard status == kDNSServiceErr_NoError, let service else {
          self.finish(.failure(RemoteAPIError.serverLookupFailed(name)))
          return
        }
        self.service = service
        DNSServiceSetDispatchQueue(service, self.queue)
        self.queue.asyncAfter(deadline: .now() + timeout) {
          self.finish(.failure(RemoteAPIError.serverLookupFailed(name)))
        }
      }
    }
  }

  private func receive(
    flags: DNSServiceFlags,
    status: DNSServiceErrorType,
    data: UnsafeRawPointer?,
    length: UInt16
  ) {
    guard status == kDNSServiceErr_NoError else {
      finish(.failure(RemoteAPIError.serverLookupFailed("SRV status \(status)")))
      return
    }
    if flags & kDNSServiceFlagsAdd != 0, let data,
      let host = Self.host(fromSRV: UnsafeRawBufferPointer(start: data, count: Int(length)))
    {
      hosts.append(host)
    }
    if flags & kDNSServiceFlagsMoreComing == 0, !hosts.isEmpty {
      finish(.success(hosts))
    }
  }

  private func finish(_ result: Result<[ConnectionSettings.Host], Error>) {
    guard let continuation else { return }
    self.continuation = nil
    if let service {
      DNSServiceRefDeallocate(service)
      self.service = nil
    }
    Unmanaged.passUnretained(self).release()
    continuation.resume(with: result)
  }

  /// SRV record data (RFC 2782): priority, weight, and port, then the uncompressed target name.
  private static func host(fromSRV record: UnsafeRawBufferPointer) -> ConnectionSettings.Host? {
    guard record.count > 7 else { return nil }
    let port = Int(record[4]) << 8 | Int(record[5])
    var labels: [String] = []
    var index = 6
    while index < record.count {
      let length = Int(record[index])
      index += 1
      if length == 0 { break }
      guard index + length <= record.count else { return nil }
      labels.append(String(decoding: record[index..<(index + length)], as: UTF8.self))
      index += length
    }
    guard !labels.isEmpty else { return nil }
    return ConnectionSettings.Host(hostname: labels.joined(separator: "."), port: port)
  }
}
