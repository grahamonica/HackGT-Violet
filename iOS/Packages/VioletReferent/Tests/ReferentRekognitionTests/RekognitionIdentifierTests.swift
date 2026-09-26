import Foundation
import XCTest
import ReferentCore
@testable import ReferentRekognition

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SigV4SignerTests: XCTestCase {
  /// AWS's published SigV4 test suite case "get-vanilla".
  func testMatchesAWSTestVector() {
    let signer = SigV4Signer(
      accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1", service: "service")
    let headers = signer.sign(
      method: "GET", headers: ["Host": "example.amazonaws.com"], body: Data(),
      date: Date(timeIntervalSince1970: 1_440_938_160))  // 2015-08-30T12:36:00Z
    XCTAssertEqual(headers["X-Amz-Date"], "20150830T123600Z")
    XCTAssertEqual(
      headers["Authorization"],
      "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
  }

  func testSessionTokenIsSigned() {
    let signer = SigV4Signer(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "TOKEN", region: "us-east-1", service: "rekognition")
    let headers = signer.sign(method: "POST", headers: ["Host": "h"], body: Data("{}".utf8))
    XCTAssertEqual(headers["X-Amz-Security-Token"], "TOKEN")
    XCTAssertTrue(headers["Authorization"]!.contains("SignedHeaders=host;x-amz-date;x-amz-security-token"))
  }
}

/// Replays canned (status, body) responses and records requests.
actor FakeTransport: HTTPTransport {
  private var responses: [(Int, String)]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [(Int, String)]) { self.responses = responses }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let (status, body) = responses.removeFirst()
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

final class RekognitionIdentifierTests: XCTestCase {
  func config() -> RekognitionConfig {
    var config = RekognitionConfig(accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1", collectionID: "violet")
    config.backoffBase = .milliseconds(1)
    config.backoffMax = .milliseconds(5)
    return config
  }

  let matchBody = """
    {"UserMatches":[{"Similarity":99.2,"User":{"UserId":"sarah","UserStatus":"ACTIVE"}},
                    {"Similarity":12.5,"User":{"UserId":"bob","UserStatus":"ACTIVE"}}]}
    """
  let throttle = (400, #"{"__type":"com.amazonaws.rekognition#ThrottlingException","message":"Rate exceeded"}"#)

  func testParsesMatchesAndSendsASignedSearchRequest() async throws {
    let transport = FakeTransport([(200, matchBody)])
    let matches = try await RekognitionIdentifier(config: config(), transport: transport).identify(crop: Data([1, 2, 3]))
    XCTAssertEqual(matches, [IdentityMatch(userID: "sarah", similarity: 99.2), IdentityMatch(userID: "bob", similarity: 12.5)])

    let request = await transport.requests[0]
    XCTAssertEqual(request.url?.absoluteString, "https://rekognition.us-east-1.amazonaws.com/")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Target"), "RekognitionService.SearchUsersByImage")
    XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/"))
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    XCTAssertEqual(body["CollectionId"] as? String, "violet")
    XCTAssertEqual((body["Image"] as? [String: Any])?["Bytes"] as? String, Data([1, 2, 3]).base64EncodedString())
    XCTAssertEqual(body["MaxUsers"] as? Int, 5)
    XCTAssertEqual(body["QualityFilter"] as? String, "NONE")
  }

  func testNoFaceInCropIsNoMatch() async throws {
    let noFace = (400, #"{"__type":"InvalidParameterException","Message":"There are no faces in the image. Should be at least 1."}"#)
    let matches = try await RekognitionIdentifier(config: config(), transport: FakeTransport([noFace])).identify(crop: Data())
    XCTAssertEqual(matches, [])
  }

  func testThrottlingIsRetriedThenSucceeds() async throws {
    let transport = FakeTransport([throttle, (503, "{}"), (200, matchBody)])
    let matches = try await RekognitionIdentifier(config: config(), transport: transport).identify(crop: Data())
    XCTAssertEqual(matches.first?.userID, "sarah")
    let attempts = await transport.requests.count
    XCTAssertEqual(attempts, 3)
  }

  func testGivesUpAfterMaxAttempts() async {
    let transport = FakeTransport([throttle, throttle, throttle, throttle])
    do {
      _ = try await RekognitionIdentifier(config: config(), transport: transport).identify(crop: Data())
      XCTFail("expected an error")
    } catch RekognitionError.service(let type, _, let status) {
      XCTAssertEqual(type, "ThrottlingException")
      XCTAssertEqual(status, 400)
    } catch {
      XCTFail("unexpected \(error)")
    }
    let attempts = await transport.requests.count
    XCTAssertEqual(attempts, 3)
  }

  func testOtherErrorsAreNotRetried() async {
    let denied = (400, #"{"__type":"AccessDeniedException","Message":"not authorized"}"#)
    let transport = FakeTransport([denied])
    do {
      _ = try await RekognitionIdentifier(config: config(), transport: transport).identify(crop: Data())
      XCTFail("expected an error")
    } catch RekognitionError.service(let type, _, _) {
      XCTAssertEqual(type, "AccessDeniedException")
    } catch {
      XCTFail("unexpected \(error)")
    }
    let attempts = await transport.requests.count
    XCTAssertEqual(attempts, 1)
  }

  func testConfigFromValuesNeedsAllKeys() {
    let full = [
      "AWS_REKOGNITION_ACCESS_KEY_ID": "AK", "AWS_REKOGNITION_SECRET_ACCESS_KEY": "SK",
      "AWS_REKOGNITION_REGION": "us-east-1", "AWS_REKOGNITION_COLLECTION_ID": "c",
    ]
    XCTAssertEqual(RekognitionConfig(values: full)?.collectionID, "c")
    var missing = full
    missing["AWS_REKOGNITION_SECRET_ACCESS_KEY"] = ""
    XCTAssertNil(RekognitionConfig(values: missing))
  }
}
