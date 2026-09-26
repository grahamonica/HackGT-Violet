import AVFoundation
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

@MainActor
final class ElevenLabsSpeaker: NSObject {
  private let environment: AppEnvironment
  private let session: URLSession
  private var player: AVAudioPlayer?

  init(environment: AppEnvironment, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
  }

  func speak(_ text: String) async throws {
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
      "model_id": "eleven_multilingual_v2"
    ])

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw SpeechServiceError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw SpeechServiceError.requestFailed(http.statusCode)
    }

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP])
    try audioSession.setActive(true)
    let newPlayer = try AVAudioPlayer(data: data)
    newPlayer.prepareToPlay()
    guard newPlayer.play() else { throw SpeechServiceError.invalidResponse }
    player = newPlayer
  }
}
