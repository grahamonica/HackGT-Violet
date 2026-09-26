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
    self.yearMet = yearMet
    self.updatedAt = updatedAt
    self.needsUpload = needsUpload
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
  let yearMet: Int

  func makePerson() -> FamiliarPerson {
    FamiliarPerson(
      name: name,
      frontPhoto: frontPhoto,
      leftPhoto: leftPhoto,
      rightPhoto: rightPhoto,
      relation: relation,
      bio: bio,
      yearMet: yearMet
    )
  }
}

struct LocalCache: Codable, Sendable {
  var people: [FamiliarPerson]
  var logs: [RecognitionLog]
  var lastRelationshipSync: Date?

  static let empty = LocalCache(people: [], logs: [], lastRelationshipSync: nil)
}
