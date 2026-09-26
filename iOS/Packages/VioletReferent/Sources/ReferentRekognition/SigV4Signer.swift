import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto: same API as CryptoKit, used on Linux
#endif

/// AWS Signature Version 4 request signing (the scheme every AWS API uses).
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
public struct SigV4Signer: Sendable {
  public let accessKeyID: String
  public let secretAccessKey: String
  /// Set for temporary credentials (e.g. Cognito); sent as X-Amz-Security-Token.
  public let sessionToken: String?
  public let region: String
  public let service: String

  public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, region: String, service: String) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.region = region
    self.service = service
  }

  /// Returns `headers` plus `X-Amz-Date`, the session token if any, and
  /// `Authorization`. `headers` must include `Host`; `query` must already be
  /// in canonical (sorted, URI-encoded) form.
  public func sign(
    method: String, path: String = "/", query: String = "", headers: [String: String], body: Data, date: Date = Date()
  ) -> [String: String] {
    let amzDate = Self.timestamp(date, format: "yyyyMMdd'T'HHmmss'Z'")
    let day = String(amzDate.prefix(8))
    var all = headers
    all["X-Amz-Date"] = amzDate
    if let sessionToken { all["X-Amz-Security-Token"] = sessionToken }

    let canonicalHeaders = all
      .map { (key: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)) }
      .sorted { $0.key < $1.key }
    let signedHeaders = canonicalHeaders.map(\.key).joined(separator: ";")
    let canonicalRequest = [
      method,
      path,
      query,
      canonicalHeaders.map { "\($0.key):\($0.value)\n" }.joined(),
      signedHeaders,
      Self.hex(SHA256.hash(data: body)),
    ].joined(separator: "\n")

    let scope = "\(day)/\(region)/\(service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      scope,
      Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
    ].joined(separator: "\n")

    var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
    for part in [day, region, service, "aws4_request"] {
      key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
    }
    let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

    all["Authorization"] =
      "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    return all
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func timestamp(_ date: Date, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}
