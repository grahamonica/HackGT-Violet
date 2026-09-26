import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rekognition settings, shared by `RekognitionIdentifier` and
/// `RekognitionEnroller`: build both from the same value so search and
/// enrollment always use the same collection.
public struct RekognitionConfig: Sendable {
  public var accessKeyID: String
  public var secretAccessKey: String
  public var sessionToken: String?
  public var region: String
  public var collectionID: String
  /// Search/index parameters; the defaults match how the quality model's training labels were made.
  public var maxUsers = 5
  public var userMatchThreshold = 0.0
  public var qualityFilter = "NONE"
  /// Attempts per call when AWS throttles or has a server error (1 = no retry).
  public var maxAttempts = 3
  public var backoffBase: Duration = .milliseconds(200)
  public var backoffMax: Duration = .seconds(1)

  public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, region: String, collectionID: String) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.region = region
    self.collectionID = collectionID
  }

  /// Reads `AWS_REKOGNITION_ACCESS_KEY_ID`, `AWS_REKOGNITION_SECRET_ACCESS_KEY`,
  /// `AWS_REKOGNITION_REGION` and `AWS_REKOGNITION_COLLECTION_ID` (optionally
  /// `AWS_REKOGNITION_SESSION_TOKEN`), e.g. from the app's baked-in secrets or a
  /// `.env`. Returns nil if a required key is missing or empty.
  public init?(values: [String: String]) {
    func value(_ key: String) -> String? {
      guard let v = values[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
      return v
    }
    guard let id = value("AWS_REKOGNITION_ACCESS_KEY_ID"), let secret = value("AWS_REKOGNITION_SECRET_ACCESS_KEY"),
          let region = value("AWS_REKOGNITION_REGION"), let collection = value("AWS_REKOGNITION_COLLECTION_ID")
    else { return nil }
    self.init(accessKeyID: id, secretAccessKey: secret, sessionToken: value("AWS_REKOGNITION_SESSION_TOKEN"),
              region: region, collectionID: collection)
  }
}

public enum RekognitionError: Error, Sendable {
  /// AWS returned an error (e.g. AccessDeniedException, ResourceNotFoundException).
  case service(type: String, message: String, status: Int)
  case invalidResponse
  /// Person IDs become Rekognition UserIds: 1-128 characters of [a-zA-Z0-9_.-:].
  case invalidPersonID(String)
  /// None of the enrollment photos contained a detectable face.
  case noFaceInPhotos
}

/// Sends a request and returns the body and response. Injectable for tests.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
  public init() {}

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    // dataTask with a continuation: works on Apple platforms and Linux alike.
    let box = TaskBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
          if let error { return continuation.resume(throwing: error) }
          guard let data, let http = response as? HTTPURLResponse else {
            return continuation.resume(throwing: RekognitionError.invalidResponse)
          }
          continuation.resume(returning: (data, http))
        }
        box.task = task
        task.resume()
      }
    } onCancel: {
      box.task?.cancel()
    }
  }

  private final class TaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
  }
}

/// Signed Rekognition JSON calls with retries: throttling
/// (`ThrottlingException`, `ProvisionedThroughputExceededException`) and 5xx
/// are retried with full-jitter exponential backoff up to `maxAttempts`;
/// other errors throw `RekognitionError.service`. Cancellation stops retries.
struct RekognitionClient: Sendable {
  let config: RekognitionConfig
  let transport: any HTTPTransport
  private let signer: SigV4Signer
  private let endpoint: URL

  init(config: RekognitionConfig, transport: any HTTPTransport) {
    self.config = config
    self.transport = transport
    self.signer = SigV4Signer(
      accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey, sessionToken: config.sessionToken,
      region: config.region, service: "rekognition")
    self.endpoint = URL(string: "https://rekognition.\(config.region).amazonaws.com/")!
  }

  /// Calls `RekognitionService.<operation>` and returns the decoded JSON response.
  func call(_ operation: String, _ parameters: [String: Any]) async throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: parameters)
    var attempt = 1
    while true {
      try Task.checkCancellation()
      let (data, response) = try await transport.send(request(operation, body: body))
      if response.statusCode == 200 {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw RekognitionError.invalidResponse
        }
        return json
      }
      let (type, message) = Self.parseError(data)
      let retryable = response.statusCode >= 500
        || type == "ThrottlingException" || type == "ProvisionedThroughputExceededException"
      guard retryable, attempt < config.maxAttempts else {
        throw RekognitionError.service(type: type, message: message, status: response.statusCode)
      }
      try await Task.sleep(for: backoff(attempt: attempt))
      attempt += 1
    }
  }

  private func request(_ operation: String, body: Data) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = body
    let headers = signer.sign(
      method: "POST",
      headers: [
        "Host": endpoint.host!,
        "Content-Type": "application/x-amz-json-1.1",
        "X-Amz-Target": "RekognitionService.\(operation)",
      ],
      body: body)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    return request
  }

  /// Full-jitter exponential backoff: random in [0, min(max, base * 2^(attempt-1))].
  private func backoff(attempt: Int) -> Duration {
    let cap = min(config.backoffMax, config.backoffBase * Int(1 << min(attempt - 1, 16)))
    return cap * Double.random(in: 0...1)
  }

  /// AWS JSON errors: {"__type": "...#ThrottlingException", "message": "..."}.
  static func parseError(_ data: Data) -> (type: String, message: String) {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let raw = json["__type"] as? String ?? "Unknown"
    let type = raw.split(separator: "#").last.map(String.init) ?? raw
    let message = (json["message"] ?? json["Message"]) as? String ?? ""
    return (type, message)
  }
}
