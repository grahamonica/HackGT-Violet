import Foundation

/// Adds and removes people in the Rekognition collection that
/// `RekognitionIdentifier` searches. Build both from the same
/// `RekognitionConfig` so they always use the same collection.
///
/// Each person becomes one Rekognition *user* whose UserId is the app's person
/// ID, so a search result is the person's ID directly. Their photos are indexed
/// (Rekognition stores face vectors, not the images) and associated with the
/// user, the same scheme the quality model's training labels used.
public struct RekognitionEnroller: Sendable {
  public var config: RekognitionConfig { client.config }
  private let client: RekognitionClient

  public init(config: RekognitionConfig, transport: any HTTPTransport = URLSessionTransport()) {
    client = RekognitionClient(config: config, transport: transport)
  }

  public struct Enrollment: Sendable, Equatable {
    /// Rekognition face IDs now associated with the person.
    public let faceIDs: [String]
    /// Indices of photos in which no face was found (not enrolled).
    public let photosWithoutFace: [Int]
  }

  /// Creates the collection if it doesn't exist yet. Safe to call every launch.
  public func ensureCollection() async throws {
    do {
      _ = try await client.call("CreateCollection", ["CollectionId": config.collectionID])
    } catch RekognitionError.service(let type, _, _) where type == "ResourceAlreadyExistsException" {}
  }

  /// Enrolls a person from their photos (e.g. front, left, right), replacing
  /// any previous enrollment. The largest face in each photo is used; photos
  /// without a face are skipped and reported. Throws `noFaceInPhotos` (leaving
  /// the person unenrolled) if no photo has a face.
  @discardableResult
  public func enroll(personID: String, photos: [Data]) async throws -> Enrollment {
    try Self.validate(personID)
    try await remove(personID: personID)

    var faceIDs: [String] = []
    var withoutFace: [Int] = []
    for (i, photo) in photos.enumerated() {
      let response = try await client.call("IndexFaces", [
        "CollectionId": config.collectionID,
        "Image": ["Bytes": photo.base64EncodedString()],
        "ExternalImageId": "\(personID)_\(i)",
        "MaxFaces": 1,
        "QualityFilter": config.qualityFilter,
      ])
      let records = response["FaceRecords"] as? [[String: Any]] ?? []
      if let id = (records.first?["Face"] as? [String: Any])?["FaceId"] as? String {
        faceIDs.append(id)
      } else {
        withoutFace.append(i)
      }
    }
    guard !faceIDs.isEmpty else { throw RekognitionError.noFaceInPhotos }

    _ = try await client.call("CreateUser", ["CollectionId": config.collectionID, "UserId": personID])
    let response = try await client.call("AssociateFaces", [
      "CollectionId": config.collectionID,
      "UserId": personID,
      "FaceIds": faceIDs,
      "UserMatchThreshold": 0,
    ])
    let associated = (response["AssociatedFaces"] as? [[String: Any]] ?? []).compactMap { $0["FaceId"] as? String }
    return Enrollment(faceIDs: associated, photosWithoutFace: withoutFace)
  }

  /// Removes a person and their faces from the collection. No-op if absent.
  public func remove(personID: String) async throws {
    try Self.validate(personID)
    let faceIDs = try await faceIDs(of: personID)
    do {
      _ = try await client.call("DeleteUser", ["CollectionId": config.collectionID, "UserId": personID])
    } catch RekognitionError.service(let type, _, _)
      // Live Rekognition answers DeleteUser for an unknown UserId with InvalidParameterException,
      // not ResourceNotFoundException, so a first enrollment would otherwise always fail.
      where type == "ResourceNotFoundException" || type == "InvalidParameterException" {}
    if !faceIDs.isEmpty {
      _ = try await client.call("DeleteFaces", ["CollectionId": config.collectionID, "FaceIds": faceIDs])
    }
  }

  private func faceIDs(of personID: String) async throws -> [String] {
    var ids: [String] = []
    var token: String?
    repeat {
      var parameters: [String: Any] = ["CollectionId": config.collectionID, "UserId": personID, "MaxResults": 1000]
      if let token { parameters["NextToken"] = token }
      let response: [String: Any]
      do {
        response = try await client.call("ListFaces", parameters)
      } catch RekognitionError.service(let type, _, _) where type == "ResourceNotFoundException" {
        return []
      }
      ids += (response["Faces"] as? [[String: Any]] ?? []).compactMap { $0["FaceId"] as? String }
      token = response["NextToken"] as? String
    } while token != nil
    return ids
  }

  static func validate(_ personID: String) throws {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-:")
    guard (1...128).contains(personID.count), personID.allSatisfy(allowed.contains) else {
      throw RekognitionError.invalidPersonID(personID)
    }
  }
}
