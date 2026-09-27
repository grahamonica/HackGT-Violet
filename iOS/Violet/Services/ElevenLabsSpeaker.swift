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
/// sentences prepared ahead with `prepare` play without a network round trip.
@MainActor
final class ElevenLabsSpeaker: NSObject {
  private static let modelID = "eleven_multilingual_v2"

  private let environment: AppEnvironment
  private let session: URLSession
  private let cacheDirectory: URL
  private var player: AVAudioPlayer?
  private var inFlight: [String: Task<Data, Error>] = [:]
  /// Resumed when the current sentence ends.
  private var playbackFinished: CheckedContinuation<Void, Never>?
  /// Sentences play one after another: true while one holds the turn, and later
  /// ones wait here in order.
  private var isPlaying = false
  private var waitingForTurn: [CheckedContinuation<Void, Never>] = []

  init(environment: AppEnvironment, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
    self.cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("violet-speech", isDirectory: true)
  }

  /// Speaks `text` and returns once it has finished playing. If another sentence is
  /// playing, this one waits and plays right after it (its audio loads meanwhile).
  /// `onStart` runs when the audio begins. `timeout` limits generating audio that isn't cached.
  func speak(_ text: String, timeout: TimeInterval = 45, onStart: (@MainActor () -> Void)? = nil) async throws {
    let data = try await audio(for: text, timeout: timeout)
    await takeTurn()
    defer { releaseTurn() }
    let player = try play(data)
    onStart?()
    await waitUntilFinished(player)
  }

  private func takeTurn() async {
    if isPlaying {
      await withCheckedContinuation { waitingForTurn.append($0) }
    }
    isPlaying = true
  }

  /// Hands the turn straight to the next waiting sentence, if any.
  private func releaseTurn() {
    if waitingForTurn.isEmpty {
      isPlaying = false
    } else {
      waitingForTurn.removeFirst().resume()
    }
  }

  /// Starts generating `text` now, so a later `speak` of the same text finds it ready or
  /// joins the request already in flight instead of starting over.
  func preload(_ text: String, timeout: TimeInterval = 45) {
    Task { [weak self] in
      do {
        _ = try await self?.audio(for: text, timeout: timeout)
      } catch {
        violetTrace("speech preload failed: \(error)")
      }
    }
  }

  /// True when `text` is already on disk and plays without a network request.
  func isPrepared(_ text: String) -> Bool {
    FileManager.default.fileExists(atPath: cacheURL(for: text).path)
  }

  /// Makes the cache hold exactly these sentences: audio for text that is no longer
  /// used (e.g. an old bio) is deleted, and anything missing is generated.
  func prepare(_ texts: [String]) async {
    let wanted = Set(texts)
    removeCachedAudio(except: Set(wanted.map { cacheURL(for: $0).lastPathComponent }))
    for text in wanted {
      do {
        _ = try await audio(for: text)
      } catch {
        violetTrace("speech prepare failed for \"\(text)\": \(error)")
      }
    }
  }

  private func removeCachedAudio(except keep: Set<String>) {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: cacheDirectory,
      includingPropertiesForKeys: nil
    )) ?? []
    for file in files where !keep.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
      violetTrace("removed unused voice audio \(file.lastPathComponent.prefix(12))")
    }
  }

  private func audio(for text: String, timeout: TimeInterval = 45) async throws -> Data {
    let file = cacheURL(for: text)
    if let cached = try? Data(contentsOf: file) { return cached }
    if let pending = inFlight[text] { return try await pending.value }

    violetTrace("generating voice: \(text.prefix(60))")
    let task = Task { try await self.synthesize(text, timeout: timeout) }
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

  private func synthesize(_ text: String, timeout: TimeInterval) async throws -> Data {
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
    request.timeoutInterval = timeout
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

  private func play(_ data: Data) throws -> AVAudioPlayer {
    let onPhone = AudioOutput.prepare()
    let newPlayer = try AVAudioPlayer(data: data)
    newPlayer.delegate = self
    newPlayer.prepareToPlay()
    if !newPlayer.play() {
      guard onPhone else { throw SpeechServiceError.invalidResponse }
      try AudioOutput.fallBackToGlasses()
      guard newPlayer.play() else { throw SpeechServiceError.invalidResponse }
    }
    player = newPlayer
    return newPlayer
  }

  /// Waits for the delegate to report the end, or for the clip's length plus a margin
  /// in case it never does (e.g. an audio interruption).
  private func waitUntilFinished(_ player: AVAudioPlayer) async {
    let id = ObjectIdentifier(player)
    let limit = player.duration + 2
    await withCheckedContinuation { continuation in
      playbackFinished = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(limit))
        self?.endPlayback(of: id)
      }
    }
  }

  /// Releases the waiter, if player `id` is still the current one.
  private func endPlayback(of id: ObjectIdentifier) {
    guard player.map(ObjectIdentifier.init) == id else { return }
    playbackFinished?.resume()
    playbackFinished = nil
  }
}

extension ElevenLabsSpeaker: AVAudioPlayerDelegate {
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let id = ObjectIdentifier(player)
    Task { @MainActor in self.endPlayback(of: id) }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    let id = ObjectIdentifier(player)
    Task { @MainActor in self.endPlayback(of: id) }
  }
}
