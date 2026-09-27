import Foundation

enum AppLimits {
  static let maximumPeople = 10
}

struct FamiliarPerson: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var frontPhoto: Data
  var leftPhoto: Data
  var rightPhoto: Data
  var relation: String
  var bio: String
  /// Optional recent news the follow-up answer can hint at; empty when none.
  var notes: String
  var yearMet: Int
  var updatedAt: Date
  var needsUpload: Bool

  init(
    id: String = UUID().uuidString,
    name: String,
    frontPhoto: Data,
    leftPhoto: Data,
    rightPhoto: Data,
    relation: String,
    bio: String,
    notes: String = "",
    yearMet: Int,
    updatedAt: Date = .now,
    needsUpload: Bool = true
  ) {
    self.id = id
    self.name = name
    self.frontPhoto = frontPhoto
    self.leftPhoto = leftPhoto
    self.rightPhoto = rightPhoto
    self.relation = relation
    self.bio = bio
    self.notes = notes
    self.yearMet = yearMet
    self.updatedAt = updatedAt
    self.needsUpload = needsUpload
  }
}

extension FamiliarPerson {
  /// People cached on the phone before notes existed have no `notes` key; they load with none.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      name: try container.decode(String.self, forKey: .name),
      frontPhoto: try container.decode(Data.self, forKey: .frontPhoto),
      leftPhoto: try container.decode(Data.self, forKey: .leftPhoto),
      rightPhoto: try container.decode(Data.self, forKey: .rightPhoto),
      relation: try container.decode(String.self, forKey: .relation),
      bio: try container.decode(String.self, forKey: .bio),
      notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? "",
      yearMet: try container.decode(Int.self, forKey: .yearMet),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt),
      needsUpload: try container.decode(Bool.self, forKey: .needsUpload)
    )
  }
}

struct RecognitionLog: Codable, Identifiable, Hashable, Sendable {
  var id: UUID
  var timestamp: Date
  var identifiedPerson: String
  var needsUpload: Bool

  init(
    id: UUID = UUID(),
    timestamp: Date,
    identifiedPerson: String,
    needsUpload: Bool = true
  ) {
    self.id = id
    self.timestamp = timestamp
    self.identifiedPerson = identifiedPerson
    self.needsUpload = needsUpload
  }
}

struct RelationshipDraft: Sendable {
  let name: String
  let frontPhoto: Data
  let leftPhoto: Data
  let rightPhoto: Data
  let relation: String
  let bio: String
  let notes: String
  let yearMet: Int

  func makePerson() -> FamiliarPerson {
    FamiliarPerson(
      name: name,
      frontPhoto: frontPhoto,
      leftPhoto: leftPhoto,
      rightPhoto: rightPhoto,
      relation: relation,
      bio: bio,
      notes: notes,
      yearMet: yearMet
    )
  }
}

enum MatchLikelihood: String, Codable, Sendable {
  case highlyLikely = "HIGHLY_LIKELY"
  case notHighlyLikely = "NOT_HIGHLY_LIKELY"
}

struct RecognitionDecision: Codable, Sendable {
  let likelihood: MatchLikelihood
  let personID: String?
}

struct LocalCache: Codable, Sendable {
  var people: [FamiliarPerson]
  var logs: [RecognitionLog]
  var lastRelationshipSync: Date?

  static let empty = LocalCache(people: [], logs: [], lastRelationshipSync: nil)
}
