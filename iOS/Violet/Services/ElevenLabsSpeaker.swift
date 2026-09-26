import AVFoundation
import CryptoKit
import Foundation

enum SpeechServiceError: LocalizedError {
  case notConfigured
  case invalidResponse
  case requestFailed(Int)

  var errorDescription: String? {
    switch self {
    case .notConfigured: "ElevenLabs is not configured."
    case .invalidResponse: "The spoken response could not be played."
    case .requestFailed(let status): "Speech request failed (\(status))."
    }
  }
}

/// Speaks through ElevenLabs. Audio is cached on disk by voice, model and text, so
/// sentences prepared ahead with `prefetch` play without a network round trip.
@MainActor
final class ElevenLabsSpeaker: NSObject {
  private static let modelID = "eleven_multilingual_v2"

  private let environment: AppEnvironment
  private let session: URLSession
  private let cacheDirectory: URL
  private var player: AVAudioPlayer?
  private var inFlight: [String: Task<Data, Error>] = [:]

  init(environment: AppEnvironment, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
    self.cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("violet-speech", isDirectory: true)
  }

  func speak(_ text: String) async throws {
    let data = try await audio(for: text)
    try play(data)
  }

  /// Generates and caches any of these sentences that aren't cached yet.
  func prefetch(_ texts: [String]) async {
    for text in Set(texts) {
      do {
        _ = try await audio(for: text)
      } catch {
        violetTrace("speech prefetch failed for \"\(text)\": \(error)")
      }
    }
  }

  private func audio(for text: String) async throws -> Data {
    let file = cacheURL(for: text)
    if let cached = try? Data(contentsOf: file) { return cached }
    if let pending = inFlight[text] { return try await pending.value }

    let task = Task { try await self.synthesize(text) }
    inFlight[text] = task
    defer { inFlight[text] = nil }
    let data = try await task.value
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
    return data
  }

  private func cacheURL(for text: String) -> URL {
    let key = "\(environment.elevenLabsVoiceID)|\(Self.modelID)|\(text)"
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return cacheDirectory.appendingPathComponent("\(digest).mp3")
  }

  private func synthesize(_ text: String) async throws -> Data {
    guard environment.elevenLabsIsConfigured else { throw SpeechServiceError.notConfigured }
    let escapedVoiceID = environment.elevenLabsVoiceID.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed
    ) ?? environment.elevenLabsVoiceID
    var components = URLComponents(
      string: "https://api.elevenlabs.io/v1/text-to-speech/\(escapedVoiceID)/stream"
    )!
    components.queryItems = [
      URLQueryItem(name: "output_format", value: "mp3_44100_128"),
      URLQueryItem(name: "enable_logging", value: "false")
    ]

    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue(environment.elevenLabsKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "text": text,
      "model_id": Self.modelID
    ])

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw SpeechServiceError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw SpeechServiceError.requestFailed(http.statusCode)
    }
    return data
  }

  private func play(_ data: Data) throws {
    let audioSession = AVAudioSession.sharedInstance()
    // .playback already routes to A2DP outputs such as the glasses; passing
    // .allowBluetoothA2DP here is invalid for this category and throws -50.
    try audioSession.setCategory(.playback, mode: .spokenAudio)
    try audioSession.setActive(true)
    let newPlayer = try AVAudioPlayer(data: data)
    newPlayer.prepareToPlay()
    guard newPlayer.play() else { throw SpeechServiceError.invalidResponse }
    player = newPlayer
  }
}
