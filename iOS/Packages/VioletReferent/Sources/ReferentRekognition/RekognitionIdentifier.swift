import Foundation
import ReferentCore

/// `FaceIdentifying` backed by Rekognition `SearchUsersByImage`.
///
/// A crop without a detectable face returns no matches (Rekognition reports it
/// as `InvalidParameterException`), like the dataset's `no_face` labels.
/// Throttling and 5xx errors are retried (see `RekognitionClient`).
public struct RekognitionIdentifier: FaceIdentifying {
  public var config: RekognitionConfig { client.config }
  private let client: RekognitionClient

  public init(config: RekognitionConfig, transport: any HTTPTransport = URLSessionTransport()) {
    client = RekognitionClient(config: config, transport: transport)
  }

  public func identify(crop: Data) async throws -> [IdentityMatch] {
    let response: [String: Any]
    do {
      response = try await client.call("SearchUsersByImage", [
        "CollectionId": config.collectionID,
        "Image": ["Bytes": crop.base64EncodedString()],
        "MaxUsers": config.maxUsers,
        "UserMatchThreshold": config.userMatchThreshold,
        "QualityFilter": config.qualityFilter,
      ])
    } catch RekognitionError.service(let type, let message, _)
      where type == "InvalidParameterException" && message.lowercased().contains("no face") {
      return []
    }
    return Self.parseMatches(response)
  }

  static func parseMatches(_ json: [String: Any]) -> [IdentityMatch] {
    let matches = json["UserMatches"] as? [[String: Any]] ?? []
    return matches.compactMap { match in
      guard let similarity = (match["Similarity"] as? NSNumber)?.doubleValue,
            let user = match["User"] as? [String: Any], let id = user["UserId"] as? String else { return nil }
      return IdentityMatch(userID: id, similarity: similarity)
    }
  }
}
