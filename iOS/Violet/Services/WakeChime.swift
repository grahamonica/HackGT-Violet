import AVFoundation
import Foundation

/// The short chime played when Violet hears its name, so the wearer knows the
/// glasses are looking. It plays on the same route as the spoken answers.
@MainActor
final class WakeChime {
  private let player: AVAudioPlayer?

  init(bundle: Bundle = .main) {
    let url = bundle.url(forResource: "WakeChime", withExtension: "mp3")
    player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
    player?.prepareToPlay()
    if player == nil { violetTrace("WakeChime.mp3 is missing from the app bundle") }
  }

  func play() {
    guard let player else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    } catch {
      violetTrace("chime audio session failed: \(error)")
    }
    player.currentTime = 0
    player.play()
  }
}
