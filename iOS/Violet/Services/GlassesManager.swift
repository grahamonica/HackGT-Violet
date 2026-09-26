import Foundation
import MWDATCamera
import MWDATCore
import MWDATSpeech
import Observation
import UIKit

@Observable
@MainActor
final class GlassesManager {
  enum State: Equatable {
    case needsSetup
    case waitingForGlasses
    case connecting
    case listening
    case capturing
    case unavailable(String)

    var label: String {
      switch self {
      case .needsSetup: "Set up glasses"
      case .waitingForGlasses: "Put on your glasses"
      case .connecting: "Connecting to glasses"
      case .listening: "Listening for “Violet”"
      case .capturing: "Looking for a familiar face"
      case .unavailable: "Glasses need attention"
      }
    }
  }

  private(set) var state: State = .needsSetup
  private(set) var lastTranscript = ""
  private(set) var errorMessage: String?
  var onVioletCapture: ((Date, Data?, Int) -> Void)?

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private let frameSelector: FrameSelecting
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var speech: Speech?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var voiceInvocations: VoiceInvocationsStream?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let speechTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private let voiceTokens = ListenerTokenBag()
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceTask: Task<Void, Never>?
  @ObservationIgnored private var captureTask: Task<Void, Never>?
  @ObservationIgnored private var activeDevice: DeviceIdentifier?
  @ObservationIgnored private var wakeWordDetector = WakeWordDetector()
  @ObservationIgnored private var userRequestedSetup = false
  @ObservationIgnored private var isMonitoring = false
  @ObservationIgnored private var isCaptureTimerRunning = false

  init(
    wearables: WearablesInterface = Wearables.shared,
    frameSelector: FrameSelecting = FirstFrameSelector()
  ) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.frameSelector = frameSelector
  }

  isolated deinit {
    registrationTask?.cancel()
    deviceTask?.cancel()
    captureTask?.cancel()
    session?.stop()
    voiceInvocations?.stop()
  }

  func startMonitoring() {
    guard !isMonitoring else { return }
    isMonitoring = true

    registrationTask = Task { [weak self] in
      guard let self else { return }
      await self.handleRegistrationState(self.wearables.registrationState)
      for await registration in self.wearables.registrationStateStream() {
        await self.handleRegistrationState(registration)
      }
    }

    deviceTask = Task { [weak self] in
      guard let self else { return }
      for await identifier in self.deviceSelector.activeDeviceStream() {
        await self.handleActiveDevice(identifier)
      }
    }
  }

  func enable() async {
    userRequestedSetup = true
    errorMessage = nil
    if case .registered = wearables.registrationState {
      await requestPermissionsAndStart()
      return
    }
    do {
      try await wearables.startRegistration()
    } catch {
      show(error.localizedDescription)
    }
  }

  func handleCallbackURL(_ url: URL) async {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else { return }
    do {
      _ = try await wearables.handleUrl(url)
    } catch {
      show(error.localizedDescription)
    }
  }

  func retry() async {
    errorMessage = nil
    await startSessionIfPermissionsGranted()
  }

  private func handleRegistrationState(_ registration: RegistrationState) async {
    switch registration {
    case .registered:
      if userRequestedSetup {
        await requestPermissionsAndStart()
      } else {
        await startSessionIfPermissionsGranted()
      }
    case .registering:
      state = .connecting
    default:
      state = .needsSetup
    }
  }

  private func handleActiveDevice(_ identifier: DeviceIdentifier?) async {
    activeDevice = identifier
    guard let identifier else {
      if session == nil, case .registered = wearables.registrationState {
        state = .waitingForGlasses
      }
      return
    }
    startVoiceInvocations(on: identifier)
    await startSessionIfPermissionsGranted()
  }

  private func requestPermissionsAndStart() async {
    do {
      if try await wearables.checkPermissionStatus(.microphone) != .granted {
        guard try await wearables.requestPermission(.microphone) == .granted else {
          show("Microphone access is needed to hear “Violet.”")
          return
        }
      }
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        guard try await wearables.requestPermission(.camera) == .granted else {
          show("Camera access is needed for the five-second glasses view.")
          return
        }
      }
      await startSessionIfPermissionsGranted()
    } catch {
      show(error.localizedDescription)
    }
  }

  private func startSessionIfPermissionsGranted() async {
    guard session == nil, activeDevice != nil else { return }
    guard case .registered = wearables.registrationState else { return }
    do {
      guard try await wearables.checkPermissionStatus(.microphone) == .granted,
        try await wearables.checkPermissionStatus(.camera) == .granted
      else {
        state = .needsSetup
        return
      }
      let newSession = try wearables.createSession(deviceSelector: deviceSelector)
      session = newSession
      observeSession(newSession)
      state = .connecting
      try newSession.start()
    } catch {
      session = nil
      show(error.localizedDescription)
    }
  }

  private func observeSession(_ deviceSession: DeviceSession) {
    deviceSession.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleSessionState(state) }
    }.store(in: sessionTokens)
    deviceSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.show(error.localizedDescription) }
    }.store(in: sessionTokens)
  }

  private func handleSessionState(_ sessionState: DeviceSessionState) {
    switch sessionState {
    case .started:
      attachSpeechIfNeeded()
    case .paused:
      state = .connecting
    case .stopped:
      cleanupSession()
      state = activeDevice == nil ? .waitingForGlasses : .connecting
    default:
      break
    }
  }

  private func attachSpeechIfNeeded() {
    guard speech == nil, let session, session.state == .started else { return }
    do {
      guard let attached = try session.addSpeech() else {
        show("These glasses do not currently provide on-device speech recognition.")
        return
      }
      speech = attached
      attached.transcriptionPublisher.listen { [weak self] result in
        Task { @MainActor in self?.receiveTranscript(result.text) }
      }.store(in: speechTokens)
      attached.statePublisher.listen { [weak self] state in
        let started = state == .started
        let stopped = state == .stopped
        Task { @MainActor in self?.handleSpeechState(started: started, stopped: stopped) }
      }.store(in: speechTokens)
      attached.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.show(error.localizedDescription) }
      }.store(in: speechTokens)
      attached.start()
    } catch {
      show(error.localizedDescription)
    }
  }

  private func handleSpeechState(started: Bool, stopped: Bool) {
    if started {
      if camera == nil { state = .listening }
    } else if stopped {
      guard let speech, session?.state == .started else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(600))
        if speech.state == .stopped { speech.start() }
      }
    }
  }

  private func receiveTranscript(_ transcript: String) {
    lastTranscript = transcript
    guard wakeWordDetector.consume(transcript) else { return }
    beginVioletCapture(at: .now)
  }

  private func beginVioletCapture(at triggeredAt: Date) {
    guard camera == nil, let session, session.state == .started else { return }
    frameSelector.reset()
    isCaptureTimerRunning = false
    let configuration = StreamConfiguration(
      videoCodec: .raw,
      resolution: .medium,
      frameRate: 15
    )

    do {
      guard let newCamera = try session.addCamera(config: configuration) else {
        completeCapture(triggeredAt: triggeredAt, error: "The glasses camera was unavailable.")
        return
      }
      camera = newCamera
      state = .capturing
      observeStream(newCamera.stream, triggeredAt: triggeredAt)
      newCamera.stream.start()
    } catch {
      completeCapture(triggeredAt: triggeredAt, error: error.localizedDescription)
    }
  }

  private func observeStream(_ stream: MWDATCamera.Stream, triggeredAt: Date) {
    let selector = frameSelector
    stream.statePublisher.listen { [weak self] streamState in
      Task { @MainActor in self?.handleStreamState(streamState, triggeredAt: triggeredAt) }
    }.store(in: streamTokens)
    stream.videoFramePublisher.listen { frame in
      guard let image = frame.makeUIImage(), let jpeg = image.jpegData(compressionQuality: 0.86) else {
        return
      }
      selector.consider(jpegData: jpeg)
    }.store(in: streamTokens)
    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.completeCapture(triggeredAt: triggeredAt, error: error.localizedDescription)
      }
    }.store(in: streamTokens)
  }

  private func handleStreamState(_ streamState: StreamState, triggeredAt: Date) {
    switch streamState {
    case .streaming:
      guard !isCaptureTimerRunning else { return }
      isCaptureTimerRunning = true
      captureTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        self?.completeCapture(triggeredAt: triggeredAt, error: nil)
      }
    case .stopped:
      streamTokens.clear()
      camera = nil
      isCaptureTimerRunning = false
      if speech?.state == .started { state = .listening }
    default:
      break
    }
  }

  private func completeCapture(triggeredAt: Date, error: String?) {
    captureTask?.cancel()
    captureTask = nil
    let selection = frameSelector.selection()
    let count = frameSelector.frameCount
    camera?.stop()
    camera = nil
    streamTokens.clear()
    isCaptureTimerRunning = false
    state = speech?.state == .started ? .listening : .connecting
    if let error { errorMessage = error }
    onVioletCapture?(triggeredAt, selection, count)
  }

  private func startVoiceInvocations(on identifier: DeviceIdentifier) {
    do {
      if voiceInvocations == nil {
        let stream = try VoiceInvocationsStream(wearables: wearables)
        voiceInvocations = stream
        stream.invocationsPublisher.listen { [weak self] invocation in
          guard let launch = invocation as? LaunchApp else { return }
          Task {
            _ = await launch.responseHandle.sendSuccess(actionOutput: nil)
            await MainActor.run { self?.beginVioletCapture(at: .now) }
          }
        }.store(in: voiceTokens)
        stream.errorPublisher.listen { [weak self] error in
          Task { @MainActor in self?.errorMessage = error.localizedDescription }
        }.store(in: voiceTokens)
      }
      try voiceInvocations?.start(deviceIdentifier: identifier)
    } catch {
      // Voice Invocation requires separate Developer Center approval. Active-session
      // speech remains available even when this optional cold-launch channel is absent.
    }
  }

  private func cleanupSession() {
    captureTask?.cancel()
    captureTask = nil
    streamTokens.clear()
    speechTokens.clear()
    sessionTokens.clear()
    camera = nil
    speech = nil
    session = nil
    isCaptureTimerRunning = false
  }

  private func show(_ message: String) {
    errorMessage = message
    state = .unavailable(message)
  }
}
