import AVFoundation
import Foundation

/// Where Violet's chime and spoken answers play: normally the glasses (the Bluetooth
/// route), or the iPhone speaker when the "Play audio on phone" demo setting is on.
///
/// The wake word never goes through this audio session: on-glasses speech reaches the
/// app through the Wearables SDK, not iOS audio input. What must not happen is opening
/// the glasses' hands-free (HFP) microphone, which the SDK shares with the system
/// Bluetooth stack. iOS only lets an app force the built-in speaker in play-and-record
/// mode, so phone mode uses it with every Bluetooth option off: the input is the
/// iPhone's own (unused) microphone and the glasses' microphone is left alone.
@MainActor
enum AudioOutput {
  static let playOnPhoneKey = "playAudioOnPhone"

  static var playOnPhone: Bool { UserDefaults.standard.bool(forKey: playOnPhoneKey) }

  /// Configures the session for the next sound, falling back to the glasses if the
  /// phone speaker can't be used. Returns true when the sound will play on the phone.
  @discardableResult
  static func prepare() -> Bool {
    if playOnPhone {
      do {
        try routeToPhoneSpeaker()
        violetTrace("audio → phone speaker · \(routeDescription)")
        return true
      } catch {
        violetTrace("phone speaker unavailable (\(error)); playing on the glasses")
      }
    }
    do {
      try routeToGlasses()
      violetTrace("audio → glasses · \(routeDescription)")
    } catch {
      violetTrace("audio session setup failed: \(error)")
    }
    return false
  }

  /// Called when a sound on the phone speaker fails to start.
  static func fallBackToGlasses() throws {
    violetTrace("phone playback failed; playing on the glasses")
    try routeToGlasses()
  }

  /// Applies the setting right away (e.g. when it is toggled) and logs the result.
  static func apply() {
    violetTrace("setting changed: play audio on phone = \(playOnPhone)")
    prepare()
  }

  static var routeDescription: String {
    let route = AVAudioSession.sharedInstance().currentRoute
    let outputs = route.outputs.map { "\($0.portType.rawValue) (\($0.portName))" }
    let inputs = route.inputs.map { "\($0.portType.rawValue) (\($0.portName))" }
    return "out: \(outputs.joined(separator: ", ")) · in: \(inputs.isEmpty ? "none" : inputs.joined(separator: ", "))"
  }

  private static func routeToPhoneSpeaker() throws {
    let session = AVAudioSession.sharedInstance()
    // No .allowBluetooth / .allowBluetoothA2DP: nothing of this session may touch the glasses.
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    try session.setActive(true)
    try session.overrideOutputAudioPort(.speaker)

    let route = session.currentRoute
    guard route.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
      throw AudioOutputError.notOnSpeaker(routeDescription)
    }
    let bluetoothInputs: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]
    guard !route.inputs.contains(where: { bluetoothInputs.contains($0.portType) }) else {
      throw AudioOutputError.glassesMicrophoneInUse(routeDescription)
    }
  }

  private static func routeToGlasses() throws {
    let session = AVAudioSession.sharedInstance()
    // .playback already routes to A2DP outputs such as the glasses; passing
    // .allowBluetoothA2DP here is invalid for this category and throws -50.
    try session.setCategory(.playback, mode: .spokenAudio)
    try session.setActive(true)
  }
}

enum AudioOutputError: Error, CustomStringConvertible {
  case notOnSpeaker(String)
  case glassesMicrophoneInUse(String)

  var description: String {
    switch self {
    case .notOnSpeaker(let route): "output did not switch to the speaker (\(route))"
    case .glassesMicrophoneInUse(let route): "the glasses microphone became the input (\(route))"
    }
  }
}
