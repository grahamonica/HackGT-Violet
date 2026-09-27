import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import MWDATSpeech
import Observation
import ReferentCore
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
  /// Called when a trigger is accepted, before the camera starts.
  var onRequestStarted: (@MainActor () -> Void)?

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private let frameSelector: FrameSelecting
  @ObservationIgnored private let latency: LatencyRecorder?
  /// True from an accepted trigger until the app calls `requestFinished()` after the
  /// answer has been spoken. Every trigger in between is ignored.
  @ObservationIgnored private var isRequestActive = false
  /// What the wearer says after "Violet", collected from the wake word until the app
  /// takes it with `finishQuestion`. Nil for button and "Hey Meta" requests.
  @ObservationIgnored private var question: QuestionCollector?
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
  @ObservationIgnored private var watchdogTask: Task<Void, Never>?
  /// When speech last delivered a transcript. While listening it sends one every ~0.3 s,
  /// even in silence, so a long gap means it has stalled.
  @ObservationIgnored private var lastTranscriptAt: Date?
  /// When speech last produced actual words (or was restarted). On real glasses it can
  /// keep sending empty transcripts while no longer hearing anything; a restart fixes it.
  @ObservationIgnored private var lastHeardAt: Date?
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
    frameSelector: FrameSelecting = FirstFrameSelector(),
    latency: LatencyRecorder? = nil
  ) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.frameSelector = frameSelector
    self.latency = latency
    if case .registered = wearables.registrationState {
      isSetupComplete = true
    }
  }

  isolated deinit {
    registrationTask?.cancel()
    deviceTask?.cancel()
    watchdogTask?.cancel()
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

    watchdogTask = Task { [weak self] in
      var tick = 0
      while !Task.isCancelled {
        // Frequent, because the wake word is lost for as long as speech is stalled.
        try? await Task.sleep(for: .seconds(2))
        tick += 1
        await self?.keepListening(logHeartbeat: tick % 8 == 0)
      }
    }
  }

  /// Recovers the wake word when nothing else will. A stopped session (glasses taken
  /// off or folded, another experience took over) is only replaced when the device or
  /// registration changes, and speech that stops while the session is paused is never
  /// restarted by its own stop handler. Paused sessions are left alone: the glasses
  /// resume those themselves.
  private func keepListening(logHeartbeat: Bool) async {
    if logHeartbeat {
      let quiet = lastTranscriptAt.map { Int(Date.now.timeIntervalSince($0)) }
      violetTrace(
        "heartbeat: session=\(session.map { "\($0.state)" } ?? "none") "
          + "speech=\(speech.map { "\($0.state)" } ?? "none") quietFor=\(quiet.map { "\($0)s" } ?? "-")"
      )
    }
    if session == nil {
      guard activeDevice != nil, case .registered = wearables.registrationState else { return }
      violetTrace("watchdog: no session while glasses are available; starting one")
      await startSessionIfPermissionsGranted()
    } else if session?.state == .started {
      resumeListeningIfNeeded(reason: "watchdog")
    }
  }

  private func resumeListeningIfNeeded(reason: String) {
    guard let speech else {
      attachSpeechIfNeeded()
      return
    }
    let stalled = lastTranscriptAt.map { Date.now.timeIntervalSince($0) > 4 } ?? false
    let deaf = lastHeardAt.map { Date.now.timeIntervalSince($0) > 20 } ?? false
    // Not while a question is being collected: a restart would lose its words.
    if speech.state == .started, camera == nil, question == nil, stalled || deaf {
      // Reports "started" but has stopped delivering anything, or only empty results
      // for a while; either way a fresh start makes it hear again.
      violetTrace("\(reason): speech \(stalled ? "stalled" : "hearing nothing"); restarting it")
      lastTranscriptAt = .now
      lastHeardAt = .now
      speech.stop()
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(600))
        if speech.state == .stopped { speech.start() }
      }
      return
    }
    guard speech.state == .stopped else {
      // Still listening after a pause; show that instead of "Connecting".
      if speech.state == .started, camera == nil, state == .connecting { state = .listening }
      return
    }
    violetTrace("\(reason): speech was stopped; restarting it")
    speech.start()
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
      resumeListeningIfNeeded(reason: "session started")
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
      lastTranscriptAt = .now
      lastHeardAt = .now
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
    lastTranscriptAt = .now
    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastHeardAt = .now }
    violetTrace("transcript: \(transcript)")
    question?.add(transcript)
    guard wakeWordDetector.consume(transcript) else { return }
    triggerViolet(source: "wake word", transcript: transcript)
  }

  /// The one entry point for a request: "Violet", "Hey Meta, start Violet", and the
  /// glasses capture button all come through here. One request at a time: a trigger
  /// while Violet is capturing, recognizing or speaking is ignored. Only a spoken
  /// "Violet" can carry a follow-up question, so only then are the next words collected.
  private func triggerViolet(source: String, transcript: String? = nil) {
    guard !isRequestActive else {
      violetTrace("\(source) ignored: Violet is still answering")
      return
    }
    isRequestActive = true
    question = transcript.map { QuestionCollector(startingWith: $0) }
    latency?.begin()
    latency?.note("trigger", source)
    wakeChime.play()
    onRequestStarted?()
    beginVioletCapture(at: .now)
  }

  /// Called by the app once the answer has finished playing; triggers work again.
  func requestFinished() {
    isRequestActive = false
    question = nil
  }

  /// Stops collecting and returns the words said after "Violet" (nil if this request
  /// didn't start with the wake word). If the wearer is still talking, waits for a short
  /// pause, up to `maxWait`, so the end of the question isn't cut off. Call it before
  /// Violet speaks, or the glasses would transcribe Violet's own voice.
  func finishQuestion(maxWait: Duration = .seconds(1)) async -> String? {
    guard question != nil else { return nil }
    let clock = ContinuousClock()
    let deadline = clock.now + maxWait
    while clock.now < deadline, let last = question?.lastWordsAt, Date.now.timeIntervalSince(last) < 0.8 {
      try? await Task.sleep(for: .milliseconds(100))
    }
    defer { question = nil }
    return question?.question
  }

  /// Stops collecting without using the words (no one was identified).
  func discardQuestion() {
    question = nil
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
    triggerViolet(source: "capture button")
  }

  private func beginVioletCapture(at triggeredAt: Date) {
    violetTrace("begin capture; camera=\(camera != nil) session=\(String(describing: session?.state))")
    guard !isCapturing else { return }
    // The glasses reject a new stream until the previous one has fully stopped
    // (possible when the last answer was short), so hold the trigger and start it
    // once teardown finishes.
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

    latency?.mark("camera requested")
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
    let latency = latency
    stream.statePublisher.listen { [weak self] streamState in
      Task { @MainActor in self?.handleStreamState(streamState, triggeredAt: triggeredAt) }
    }.store(in: streamTokens)
    stream.videoFramePublisher.listen { frame in
      latency?.mark("first camera frame")
      let convert = { frame.makeUIImage()?.jpegData(compressionQuality: 0.86) }
      let converted = if let latency { latency.measure("frame to JPEG (on arrival)", convert) } else { convert() }
      guard let jpeg = converted else { return }
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
      latency?.mark("camera streaming")
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
    latency?.mark("capture ended")
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
    if isCameraStopping { latency?.mark("camera stopped") }
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
            await MainActor.run { self?.triggerViolet(source: "Hey Meta") }
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
    // A capture cut off here never reaches the app, which would otherwise be the one
    // to end the request; end it so the next trigger works.
    if isCapturing || pendingTrigger != nil {
      isRequestActive = false
      question = nil
    }
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
