import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import MWDATSpeech
import Observation
import UIKit

// TEMP DEBUG: capture-path tracing; remove once the dropout is diagnosed.
func violetTrace(_ message: String) {
  #if DEBUG
  print("[VioletTrace] \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)")
  #endif
}

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
  private(set) var isSetupComplete = false
  var onVioletCapture: ((Date, Data?, Int) -> Void)?
  /// True while the app is still working on the previous answer (after the camera
  /// has stopped); capture-button presses are ignored until it is done.
  var isRecognitionRunning: (() -> Bool)?

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private let frameSelector: FrameSelecting
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var speech: Speech?
  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var inputsTask: Task<Void, Never>?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var voiceInvocations: VoiceInvocationsStream?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let speechTokens = ListenerTokenBag()
  @ObservationIgnored private let inputTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private let voiceTokens = ListenerTokenBag()
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceTask: Task<Void, Never>?
  @ObservationIgnored private var captureTask: Task<Void, Never>?
  @ObservationIgnored private var activeDevice: DeviceIdentifier?
  @ObservationIgnored private var wakeWordDetector = WakeWordDetector()
  @ObservationIgnored private let wakeChime = WakeChime()
  @ObservationIgnored private var userRequestedSetup = false
  @ObservationIgnored private var isMonitoring = false
  @ObservationIgnored private var isCaptureTimerRunning = false
  @ObservationIgnored private var isCapturing = false
  @ObservationIgnored private var isCameraStopping = false
  @ObservationIgnored private var pendingTrigger: Date?
  @ObservationIgnored private var captureTriggeredAt: Date?
  @ObservationIgnored private var teardownTask: Task<Void, Never>?

  init(
    wearables: WearablesInterface = Wearables.shared,
    frameSelector: FrameSelecting = FirstFrameSelector()
  ) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.frameSelector = frameSelector
    if case .registered = wearables.registrationState {
      isSetupComplete = true
    }
  }

  isolated deinit {
    registrationTask?.cancel()
    deviceTask?.cancel()
    captureTask?.cancel()
    teardownTask?.cancel()
    inputsTask?.cancel()
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
    violetTrace("registration: \(registration)")
    switch registration {
    case .registered:
      isSetupComplete = true
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
    violetTrace("active device: \(identifier.map { "\($0)" } ?? "none")")
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
        violetTrace("glasses permissions not granted; waiting for setup")
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
    violetTrace("session state: \(sessionState)")
    switch sessionState {
    case .started:
      attachSpeechIfNeeded()
      attachCaptureButtonIfNeeded()
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
    violetTrace("speech started=\(started) stopped=\(stopped)")
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
    violetTrace("transcript: \(transcript)")
    guard wakeWordDetector.consume(transcript) else { return }
    triggerViolet()
  }

  /// The one entry point for a request: "Violet", "Hey Meta, start Violet", and the
  /// glasses capture button all come through here.
  private func triggerViolet() {
    acknowledgeWakeWord()
    beginVioletCapture(at: .now)
  }

  /// Listens for the glasses capture button for as long as the device session runs.
  /// Only the capture button is subscribed: single-finger temple taps are reserved by
  /// the glasses for pausing and stopping the session.
  private func attachCaptureButtonIfNeeded() {
    guard inputs == nil, let session, session.state == .started else { return }
    do {
      let configuration = InputsConfiguration(sources: [.captureButton], consumeBack: false)
      guard let attached = try session.addInputs(configuration: configuration) else {
        violetTrace("capture button input unavailable on these glasses")
        return
      }
      inputs = attached
      attached.statePublisher.listen { state in
        violetTrace("capture button input: \(state)")
      }.store(in: inputTokens)
      attached.errorPublisher.listen { error in
        // Optional path: the wake word keeps working, so don't surface this in the UI.
        violetTrace("capture button input error: \(error)")
      }.store(in: inputTokens)
      inputsTask = Task { [weak self] in
        for await event in attached.events {
          guard case .capture(let press, _, _) = event else { continue }
          self?.handleCaptureButton(press)
        }
      }
    } catch {
      violetTrace("capture button input failed: \(error)")
    }
  }

  private func handleCaptureButton(_ press: CapturePressType) {
    violetTrace("capture button: \(press)")
    guard press == .shortPress else { return }
    let busy = isCapturing || isCameraStopping || pendingTrigger != nil
      || (isRecognitionRunning?() ?? false)
    guard !busy else {
      violetTrace("capture button ignored: a recognition is already running")
      return
    }
    triggerViolet()
  }

  /// Dings once per request; saying "Violet" again during a capture is not a new one.
  private func acknowledgeWakeWord() {
    guard !isCapturing, pendingTrigger == nil else { return }
    wakeChime.play()
  }

  private func beginVioletCapture(at triggeredAt: Date) {
    violetTrace("begin capture; camera=\(camera != nil) session=\(String(describing: session?.state))")
    // A capture already in progress answers this trigger too.
    guard !isCapturing else { return }
    // The glasses reject a new stream until the previous one has fully stopped,
    // so hold the trigger and start it once teardown finishes.
    guard !isCameraStopping else {
      pendingTrigger = triggeredAt
      return
    }
    guard let session, session.state == .started else {
      onVioletCapture?(triggeredAt, nil, 0)
      return
    }
    frameSelector.reset()
    isCaptureTimerRunning = false
    isCapturing = true
    captureTriggeredAt = triggeredAt
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
    violetTrace("stream state: \(streamState)")
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
      // The stream can stop on its own before the five seconds are up.
      if isCapturing { completeCapture(triggeredAt: triggeredAt, error: nil) }
      finishCameraTeardown()
    default:
      break
    }
  }

  /// Ends the current capture before the five seconds are up, e.g. once the
  /// frame selector already has its answer.
  func finishCaptureEarly() {
    guard isCapturing, let captureTriggeredAt else { return }
    violetTrace("finishing capture early")
    completeCapture(triggeredAt: captureTriggeredAt, error: nil)
  }

  private func completeCapture(triggeredAt: Date, error: String?) {
    // Stream errors and the five-second timer can both land; deliver once.
    guard isCapturing else { return }
    isCapturing = false
    violetTrace("complete capture; frames=\(frameSelector.frameCount) error=\(error ?? "none")")
    captureTask?.cancel()
    captureTask = nil
    let selection = frameSelector.selection()
    let count = frameSelector.frameCount
    beginCameraTeardown()
    state = speech?.state == .started ? .listening : .connecting
    if let error { errorMessage = error }
    onVioletCapture?(triggeredAt, selection, count)
  }

  /// Stopping the camera is asynchronous. Keep the stream listeners until it reports
  /// `.stopped`, falling back to a timeout in case that state never arrives.
  private func beginCameraTeardown() {
    guard let camera, !isCameraStopping else {
      if self.camera == nil { finishCameraTeardown() }
      return
    }
    isCameraStopping = true
    camera.stop()
    teardownTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, let self, self.isCameraStopping else { return }
      violetTrace("camera teardown timed out; forcing cleanup")
      self.finishCameraTeardown()
    }
  }

  private func finishCameraTeardown() {
    teardownTask?.cancel()
    teardownTask = nil
    streamTokens.clear()
    camera = nil
    isCameraStopping = false
    isCaptureTimerRunning = false
    if speech?.state == .started { state = .listening }
    if let pending = pendingTrigger {
      pendingTrigger = nil
      beginVioletCapture(at: pending)
    }
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
            await MainActor.run { self?.triggerViolet() }
          }
        }.store(in: voiceTokens)
        stream.errorPublisher.listen { [weak self] error in
          Task { @MainActor in
            violetTrace("voice invocation error: \(error.localizedDescription)")
            self?.errorMessage = error.localizedDescription
          }
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
    teardownTask?.cancel()
    teardownTask = nil
    isCapturing = false
    isCameraStopping = false
    pendingTrigger = nil
    streamTokens.clear()
    speechTokens.clear()
    inputsTask?.cancel()
    inputsTask = nil
    inputTokens.clear()
    sessionTokens.clear()
    camera = nil
    speech = nil
    inputs = nil
    session = nil
    isCaptureTimerRunning = false
  }

  private func show(_ message: String) {
    violetTrace("show error: \(message)")
    errorMessage = message
    state = .unavailable(message)
  }
}
