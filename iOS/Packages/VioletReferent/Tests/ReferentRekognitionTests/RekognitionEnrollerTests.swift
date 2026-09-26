import Foundation
import XCTest
import ReferentCore
@testable import ReferentRekognition

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fake Rekognition answering by operation (X-Amz-Target) and recording calls.
actor ScriptedTransport: HTTPTransport {
  typealias Handler = @Sendable (_ operation: String, _ body: [String: Any]) -> (Int, String)
  private let handler: Handler
  private var calls: [(operation: String, body: Data)] = []  // raw JSON: Sendable

  init(_ handler: @escaping Handler) { self.handler = handler }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let operation = request.value(forHTTPHeaderField: "X-Amz-Target")!.replacingOccurrences(of: "RekognitionService.", with: "")
    calls.append((operation, request.httpBody!))
    let (status, text) = handler(operation, Self.decode(request.httpBody!))
    return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  func operations() -> [String] { calls.map(\.operation) }

  /// `key` as a string in each request body (nil where absent).
  func strings(_ key: String) -> [String?] { calls.map { Self.decode($0.body)[key] as? String } }

  /// `key` as a string array in the first request of `operation`.
  func stringArray(_ key: String, in operation: String) -> [String]? {
    calls.first { $0.operation == operation }.flatMap { Self.decode($0.body)[key] as? [String] }
  }

  private static func decode(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}

final class RekognitionEnrollerTests: XCTestCase {
  let config = RekognitionConfig(accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1", collectionID: "violet-demo")
  static let notFound = (400, #"{"__type":"ResourceNotFoundException","Message":"not found"}"#)

  func testEnrollIndexesPhotosCreatesTheUserAndAssociatesFaces() async throws {
    let transport = ScriptedTransport { operation, body in
      switch operation {
      case "ListFaces", "DeleteUser": return Self.notFound
      case "IndexFaces":
        // The second photo has no face.
        if (body["ExternalImageId"] as? String) == "p1_1" { return (200, #"{"FaceRecords":[]}"#) }
        return (200, #"{"FaceRecords":[{"Face":{"FaceId":"face-\#(body["ExternalImageId"]!)"}}]}"#)
      case "CreateUser": return (200, "{}")
      case "AssociateFaces":
        let ids = body["FaceIds"] as! [String]
        return (200, #"{"AssociatedFaces":[\#(ids.map { #"{"FaceId":"\#($0)"}"# }.joined(separator: ","))]}"#)
      default: return (500, "{}")
      }
    }
    let result = try await RekognitionEnroller(config: config, transport: transport)
      .enroll(personID: "p1", photos: [Data([1]), Data([2]), Data([3])])

    XCTAssertEqual(result, .init(faceIDs: ["face-p1_0", "face-p1_2"], photosWithoutFace: [1]))
    let operations = await transport.operations()
    XCTAssertEqual(operations, ["ListFaces", "DeleteUser", "IndexFaces", "IndexFaces", "IndexFaces", "CreateUser", "AssociateFaces"])
    let collections = await transport.strings("CollectionId")
    XCTAssertTrue(collections.allSatisfy { $0 == "violet-demo" })
    let users = await transport.strings("UserId")
    XCTAssertEqual(users.last, "p1")
  }

  func testReEnrollingReplacesThePreviousFaces() async throws {
    let transport = ScriptedTransport { operation, _ in
      switch operation {
      case "ListFaces": return (200, #"{"Faces":[{"FaceId":"old-1"},{"FaceId":"old-2"}]}"#)
      case "DeleteUser", "DeleteFaces", "CreateUser": return (200, "{}")
      case "IndexFaces": return (200, #"{"FaceRecords":[{"Face":{"FaceId":"new"}}]}"#)
      case "AssociateFaces": return (200, #"{"AssociatedFaces":[{"FaceId":"new"}]}"#)
      default: return (500, "{}")
      }
    }
    try await RekognitionEnroller(config: config, transport: transport).enroll(personID: "p1", photos: [Data([1])])
    let deleted = await transport.stringArray("FaceIds", in: "DeleteFaces")
    XCTAssertEqual(deleted, ["old-1", "old-2"])
    let operations = await transport.operations()
    XCTAssertLessThan(operations.firstIndex(of: "DeleteFaces")!, operations.firstIndex(of: "IndexFaces")!)
  }

  func testNoFaceInAnyPhotoLeavesThePersonUnenrolled() async {
    let transport = ScriptedTransport { operation, _ in
      operation == "IndexFaces" ? (200, #"{"FaceRecords":[]}"#) : Self.notFound
    }
    do {
      try await RekognitionEnroller(config: config, transport: transport).enroll(personID: "p1", photos: [Data([1])])
      XCTFail("expected noFaceInPhotos")
    } catch RekognitionError.noFaceInPhotos {
    } catch {
      XCTFail("unexpected \(error)")
    }
    let operations = await transport.operations()
    XCTAssertFalse(operations.contains("CreateUser"))
  }

  func testEnsureCollectionToleratesAnExistingCollection() async throws {
    let transport = ScriptedTransport { _, _ in (400, #"{"__type":"ResourceAlreadyExistsException","Message":"exists"}"#) }
    try await RekognitionEnroller(config: config, transport: transport).ensureCollection()
  }

  func testInvalidPersonIDIsRejectedBeforeAnyCall() async {
    let transport = ScriptedTransport { _, _ in (200, "{}") }
    do {
      try await RekognitionEnroller(config: config, transport: transport).enroll(personID: "has space", photos: [Data([1])])
      XCTFail("expected invalidPersonID")
    } catch RekognitionError.invalidPersonID {
    } catch {
      XCTFail("unexpected \(error)")
    }
    let operations = await transport.operations()
    XCTAssertTrue(operations.isEmpty)
  }

  func testIdentifierAndEnrollerUseTheSameCollection() async throws {
    let transport = ScriptedTransport { operation, _ in
      operation == "SearchUsersByImage" ? (200, #"{"UserMatches":[]}"#) : (200, #"{"FaceRecords":[{"Face":{"FaceId":"f"}}],"AssociatedFaces":[]}"#)
    }
    _ = try await RekognitionIdentifier(config: config, transport: transport).identify(crop: Data([1]))
    try await RekognitionEnroller(config: config, transport: transport).enroll(personID: "p1", photos: [Data([1])])
    let collections = Set(await transport.strings("CollectionId").compactMap { $0 })
    XCTAssertEqual(collections, ["violet-demo"])
  }
}

/// Live round trip against AWS, on a throwaway collection: create it, enroll a
/// reference face, search with it, remove the person, delete the collection.
/// Runs only with VIOLET_REKOGNITION_LIVE=1, credentials in the package's .env,
/// and VIOLET_REFERENCE_DIR pointing at the export reference set.
final class RekognitionLiveTests: XCTestCase {
  func testEnrollSearchRemoveRoundTrip() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["VIOLET_REKOGNITION_LIVE"] == "1", let refDir = env["VIOLET_REFERENCE_DIR"] else {
      throw XCTSkip("set VIOLET_REKOGNITION_LIVE=1 and VIOLET_REFERENCE_DIR to call AWS")
    }
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var values: [String: String] = [:]
    for line in try String(contentsOf: packageDir.appendingPathComponent(".env"), encoding: .utf8).split(separator: "\n")
    where !line.hasPrefix("#") {
      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2 { values[parts[0]] = parts[1] }
    }
    guard var config = RekognitionConfig(values: values) else {
      return XCTFail("fill in AWS_REKOGNITION_* in \(packageDir.path)/.env")
    }
    config.collectionID += "-livetest"  // never touch the real collection

    let root = URL(fileURLWithPath: refDir)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cases.json"))) as! [String: Any]
    let clean = (json["cases"] as! [[String: Any]]).filter { ($0["augmentation"] as? String) == "none" }
    let first = clean[0]
    let second = try XCTUnwrap(clean.first { ($0["identity_id"] as? String) != (first["identity_id"] as? String) })
    let photo = try Data(contentsOf: root.appendingPathComponent(first["crop"] as! String))
    let other = try Data(contentsOf: root.appendingPathComponent(second["crop"] as! String))

    let enroller = RekognitionEnroller(config: config)
    let identifier = RekognitionIdentifier(config: config)
    try await enroller.ensureCollection()
    let enrollment = try await enroller.enroll(personID: "livetest-person", photos: [photo])
    XCTAssertEqual(enrollment.faceIDs.count, 1)

    let same = try await identifier.identify(crop: photo)
    let different = try await identifier.identify(crop: other)
    print("live: same photo -> \(same), other person -> \(different)")
    XCTAssertEqual(same.first?.userID, "livetest-person")
    XCTAssertGreaterThan(same.first?.similarity ?? 0, 90)
    XCTAssertLessThan(different.first?.similarity ?? 0, 80, "a different person must not be accepted")

    try await enroller.remove(personID: "livetest-person")
    let afterRemoval = try await identifier.identify(crop: photo)
    XCTAssertTrue(afterRemoval.isEmpty, "removed person must no longer match")
    _ = try? await RekognitionClient(config: config, transport: URLSessionTransport())
      .call("DeleteCollection", ["CollectionId": config.collectionID])
  }
}
