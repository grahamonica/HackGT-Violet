import Foundation
import Observation
import ReferentCore

@Observable
@MainActor
final class AppModel {
  private(set) var people: [FamiliarPerson] = []
  private(set) var isLoading = true
  private(set) var isRecognizing = false
  private(set) var isSyncing = false
  private(set) var lastAnnouncement: String?
  private(set) var notice: String?

  var canAddPerson: Bool {
    people.count < AppLimits.maximumPeople
  }

  let glasses: GlassesManager

  @ObservationIgnored private let environment: AppEnvironment
  @ObservationIgnored private let store: LocalStore
  @ObservationIgnored private let remoteAPI: RemoteAPI
  @ObservationIgnored private let recognizer: PersonRecognizing
  @ObservationIgnored private let speaker: ElevenLabsSpeaker
  /// Rekognition path; nil when AWS isn't configured, which keeps the OpenAI recognizer.
  @ObservationIgnored private let referent: ReferentRecognizer?
  @ObservationIgnored private let enrollment: FaceEnrollment?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var hasStarted = false
  /// Per-request timings, printed to the console after each answer. Nil (and free)
  /// unless the app is launched with `-VioletLatency YES`.
  @ObservationIgnored private let latency: LatencyRecorder?
  /// Plays a short "one moment" line if the answer is slow; cancelled once it's ready.
  @ObservationIgnored private var fillerTask: Task<Void, Never>?
  @ObservationIgnored private var nextFiller = 0
  /// The slow path's model; nil on iOS versions without on-device models.
  @ObservationIgnored private let followUps: (any FollowUpAnswering)?
  @ObservationIgnored private var replyVoiceStarted = false

  init(environment: AppEnvironment = .load()) {
    self.environment = environment
    self.store = LocalStore()
    self.remoteAPI = RemoteAPI(environment: environment)
    self.recognizer = OpenAIRecognitionService(environment: environment)
    self.speaker = ElevenLabsSpeaker(environment: environment)
    let latency = UserDefaults.standard.bool(forKey: "VioletLatency") ? LatencyRecorder() : nil
    self.latency = latency
    let referent = environment.rekognition.map { ReferentRecognizer(config: $0, latency: latency) }
    self.referent = referent
    self.enrollment = environment.rekognition.map { FaceEnrollment(config: $0) }
    self.glasses = GlassesManager(frameSelector: referent ?? FirstFrameSelector(), latency: latency)
    self.followUps = Self.makeFollowUpService()
  }

  private static func makeFollowUpService() -> (any FollowUpAnswering)? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) { return AppleFollowUpService() }
    #endif
    return nil
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    let cache = await store.load()
    people = cache.people
    isLoading = false
    preparePeople()

    referent?.onResult = { [weak self] in
      Task { @MainActor in self?.glasses.finishCaptureEarly() }
    }
    glasses.onRequestStarted = { [weak self] in
      self?.scheduleFiller()
      // Load the model while the camera runs, in case a question follows.
      self?.followUps?.prepare()
    }
    glasses.onVioletCapture = { [weak self] timestamp, image, frameCount in
      Task { @MainActor in
        await self?.processCapture(timestamp: timestamp, image: image, frameCount: frameCount)
      }
    }
    glasses.startMonitoring()
    startSyncLoop()
  }

  func setActive(_ active: Bool) {
    violetTrace("app \(active ? "active" : "inactive or background")")
    if active {
      startSyncLoop()
    } else {
      syncTask?.cancel()
      syncTask = nil
      Task { await remoteAPI.disconnect() }
    }
  }

  func enableGlasses() async {
    await glasses.enable()
  }

  func handleCallbackURL(_ url: URL) async {
    await glasses.handleCallbackURL(url)
  }

  func prepareToAddPerson() async -> Bool {
    if environment.mongoIsConfigured {
      do {
        let startedAt = Date.now
        let remotePeople = try await remoteAPI.fetchRelationshipChanges(since: nil)
        let cache = try await store.replaceRemoteSnapshot(remotePeople, syncedAt: startedAt)
        people = cache.people
      } catch {
        guard canAddPerson else {
          notice = "Violet could not refresh the people list. Check the connection and try again."
          return false
        }
      }
    }

    guard canAddPerson else {
      notice = peopleLimitNotice
      return false
    }
    return true
  }

  @discardableResult
  func addPerson(_ draft: RelationshipDraft) async -> Bool {
    guard canAddPerson else {
      notice = peopleLimitNotice
      return false
    }

    let person = draft.makePerson()
    do {
      let cache = try await store.upsert(person)
      people = cache.people
      notice = "\(person.name) was added."
      preparePeople()
    } catch LocalStoreError.peopleLimitReached {
      notice = peopleLimitNotice
      return false
    } catch {
      notice = "\(person.name) could not be saved on this phone."
      return false
    }

    guard environment.mongoIsConfigured else { return true }
    do {
      let saved = try await remoteAPI.upload(person)
      let cache = try await store.markPersonUploaded(
        id: person.id,
        serverID: saved.id,
        updatedAt: saved.updatedAt
      )
      people = cache.people
    } catch {
      notice = "\(person.name) is saved on this phone and will sync when the connection returns."
    }
    return true
  }

  func readBio(for person: FamiliarPerson) async {
    let text = Announcement.bio(person)
    lastAnnouncement = text
    do {
      try await speaker.speak(text)
    } catch {
      notice = error.localizedDescription
    }
  }

  func syncNow() async {
    guard environment.mongoIsConfigured, !isSyncing else { return }
    isSyncing = true
    defer {
      isSyncing = false
      preparePeople()
    }

    var cache = await store.load()
    for person in cache.people where person.needsUpload {
      do {
        let saved = try await remoteAPI.upload(person)
        cache = try await store.markPersonUploaded(
          id: person.id,
          serverID: saved.id,
          updatedAt: saved.updatedAt
        )
      } catch {
        // Keep this record pending and continue with other queued work.
      }
    }

    for log in cache.logs where log.needsUpload {
      do {
        try await remoteAPI.upload(log)
        cache = try await store.markLogUploaded(id: log.id)
      } catch {
        // Logs remain local until a later one-minute pass succeeds.
      }
    }

    do {
      // Stamp the cursor before querying so edits made during the query are fetched next time.
      let startedAt = Date.now
      let changes = try await remoteAPI.fetchRelationshipChanges(since: cache.lastRelationshipSync)
      // Read IDs after the changes so a person added mid-sync is never dropped.
      let liveIDs = try await remoteAPI.fetchRelationshipIDs()
      cache = try await store.mergeRemote(changes, liveIDs: liveIDs, syncedAt: startedAt)
      people = cache.people
    } catch {
      // Cached data remains the source of truth while offline.
      people = cache.people
    }
  }

  private func startSyncLoop() {
    guard syncTask == nil else { return }
    syncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.syncNow()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  private var peopleLimitNotice: String {
    "You can add up to \(AppLimits.maximumPeople) people. Delete someone in the provider portal to add another."
  }

  /// Handles one request from capture to the end of the spoken answer. The glasses
  /// ignore new triggers until this returns.
  private func processCapture(timestamp: Date, image: Data?, frameCount: Int) async {
    isRecognizing = true
    defer {
      isRecognizing = false
      glasses.requestFinished()
      if let latency { print(latency.report()) }
    }

    let matchedPerson: FamiliarPerson?
    var unmatchedSpeech = Announcement.notFamily
    if let referent {
      if frameCount == 0 {
        matchedPerson = nil
        unmatchedSpeech = Announcement.noFace
        latency?.note("outcome", "no camera frames")
        notice = "The glasses did not return a usable image."
      } else if let result = await referent.latestResult() {
        latency?.mark("result reached the app")
        (matchedPerson, unmatchedSpeech) = interpret(result, fallback: unmatchedSpeech)
      } else {
        // Only happens when the face quality model failed to load at launch.
        violetTrace("no recognition result: the face quality model is not loaded")
        matchedPerson = nil
        unmatchedSpeech = Announcement.noFace
        latency?.note("outcome", "face model not loaded")
        notice = "Violet is having trouble recognizing faces right now. Try closing and reopening the app."
      }
    } else if let image {
      do {
        let decision = try await recognizer.recognize(candidate: image, among: people)
        matchedPerson = decision.personID.flatMap { id in people.first(where: { $0.id == id }) }
        latency?.note("outcome", matchedPerson == nil ? "not recognized (OpenAI)" : "identified (OpenAI)")
      } catch {
        violetTrace("recognition failed: \(error)")
        matchedPerson = nil
        unmatchedSpeech = Announcement.unsure
        latency?.note("outcome", "OpenAI failed")
        notice = "I could not complete the comparison, so I did not guess."
      }
    } else {
      matchedPerson = nil
      unmatchedSpeech = Announcement.noFace
      latency?.note("outcome", "no camera frames")
      notice = "The glasses did not return a usable image."
    }
    isRecognizing = false

    let identifiedName = matchedPerson?.name ?? "Unknown"
    let log = RecognitionLog(timestamp: timestamp, identifiedPerson: identifiedName)
    // Saved alongside the speech so a slow or unreachable server never delays the answer.
    Task { @MainActor [weak self] in await self?.record(log) }

    // Slow path: only after a confident match, and only for words said after "Violet".
    // The model runs while the identity line plays.
    var followUp: Task<FollowUpResult, Never>?
    if let matchedPerson, let followUps, followUps.isAvailable,
      let question = await glasses.finishQuestion(), FollowUpText.mightBeQuestion(question)
    {
      latency?.mark("question heard")
      let request = FollowUpRequest(utterance: question, person: matchedPerson, today: .now)
      followUp = Task { await self.askFollowUp(request, using: followUps) }
    } else {
      glasses.discardQuestion()
    }

    let speech: String
    if let matchedPerson {
      speech = Announcement.identified(matchedPerson)
    } else {
      speech = unmatchedSpeech
    }
    lastAnnouncement = speech
    let elapsed = Date().timeIntervalSince(timestamp).formatted(.number.precision(.fractionLength(2)))
    violetTrace("speaking \(elapsed)s after trigger: \(speech)")
    // A filler that hasn't started yet is dropped; one already playing finishes and
    // the answer follows it.
    fillerTask?.cancel()
    fillerTask = nil
    latency?.note("voice", speaker.isPrepared(speech) ? "cached" : "generated now")
    latency?.mark("answer chosen")
    do {
      try await speaker.speak(speech) { [latency = self.latency] in
        latency?.mark("voice started")
        violetTrace("voice audio started \(Date().timeIntervalSince(timestamp).formatted(.number.precision(.fractionLength(2))))s after trigger")
      }
      latency?.mark("voice finished")
    } catch {
      violetTrace("speech failed: \(error)")
      notice = error.localizedDescription
    }
    if let followUp { await deliverFollowUp(followUp) }
  }

  /// Runs the follow-up model, giving up after `FollowUpTiming.modelTimeout` even if
  /// the model doesn't stop when cancelled.
  private func askFollowUp(_ request: FollowUpRequest, using model: any FollowUpAnswering) async
    -> FollowUpResult
  {
    let first = FirstResult<FollowUpResult>()
    let started = ContinuousClock.now
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<FollowUpResult, Never>) in
      first.continuation = continuation
      let work = Task { @MainActor in
        do {
          first.resume(.answer(try await model.answer(request)))
        } catch {
          first.resume(.failed(error))
        }
      }
      Task { @MainActor in
        try? await Task.sleep(for: FollowUpTiming.modelTimeout)
        work.cancel()
        first.resume(.timedOut)
      }
    }
    latency?.add("follow-up model (on device)", ContinuousClock.now - started)
    latency?.mark("follow-up model returned")
    return result
  }

  /// Speaks the follow-up once the identity line is done. A filler plays only when the
  /// model has decided there is a reply and its voice is slow to generate, so a
  /// non-question never gets a "one moment".
  private func deliverFollowUp(_ pending: Task<FollowUpResult, Never>) async {
    let reply: String
    switch await pending.value {
    case .answer(.reply(let text)):
      reply = text
      latency?.note("follow-up", "answered")
    case .answer(.notAFollowUp):
      latency?.note("follow-up", "not a follow-up")
      return
    case .timedOut:
      violetTrace("follow-up model timed out")
      latency?.note("follow-up", "model timed out")
      return
    case .failed(let error):
      violetTrace("follow-up model failed: \(error)")
      latency?.note("follow-up", "model failed")
      return
    }
    latency?.mark("follow-up reply ready")
    violetTrace("follow-up reply: \(reply)")
    lastAnnouncement = reply

    replyVoiceStarted = false
    let filler = Task { @MainActor [weak self] in
      try? await Task.sleep(for: FollowUpTiming.fillerDelay)
      guard !Task.isCancelled, let self, !self.replyVoiceStarted else { return }
      await self.sayNextFiller()
    }
    defer { filler.cancel() }
    do {
      try await speaker.speak(reply, timeout: FollowUpTiming.voiceTimeout) { [weak self] in
        self?.replyVoiceStarted = true
        self?.latency?.mark("follow-up voice started")
      }
      latency?.mark("follow-up voice finished")
    } catch {
      // Skipped quietly: the identity line was already said.
      violetTrace("follow-up speech failed: \(error)")
    }
  }

  private func record(_ log: RecognitionLog) async {
    do {
      _ = try await store.append(log)
      if environment.mongoIsConfigured {
        try await remoteAPI.upload(log)
        _ = try await store.markLogUploaded(id: log.id)
      }
    } catch {
      // The local append is attempted first; pending remote logs are retried by sync.
    }
  }

  /// Maps a Rekognition result to a person, or to what to say when there isn't one.
  private func interpret(
    _ result: ReferentResult,
    fallback: String
  ) -> (FamiliarPerson?, String) {
    let d = result.diagnostics
    violetTrace(
      "referent: frames=\(d.framesConsidered) faces=\(d.facesDetected) passing=\(d.facesPassingQuality) "
        + "calls=\(d.identificationCalls) failures=\(d.identificationFailures) "
        + "seconds=\(d.secondsToAnswer.formatted(.number.precision(.fractionLength(2))))"
    )
    latency?.note("outcome", Self.describe(result.outcome))
    switch result.outcome {
    case .identified(let match):
      violetTrace("referent identified \(match.userID) similarity=\(match.bestSimilarity)")
      if let person = people.first(where: { $0.id == match.userID }) {
        return (person, fallback)
      }
      return (nil, fallback)
    case .notRecognized:
      return (nil, fallback)
    case .noFace:
      return (nil, Announcement.noFace)
    case .ambiguous(let options):
      // The same person entered twice (e.g. from the portal and the phone) matches both
      // entries equally; that's still one answer.
      let candidates = options.compactMap { option in people.first(where: { $0.id == option.userID }) }
      if candidates.count == options.count, let best = candidates.first,
        candidates.allSatisfy({ $0.name.caseInsensitiveCompare(best.name) == .orderedSame })
      {
        violetTrace("referent ambiguous between entries for \(best.name); using the best match")
        return (best, fallback)
      }
      return (nil, Announcement.unsure)
    case .poorQuality:
      return (nil, Announcement.unsure)
    case .failed(let error):
      violetTrace("referent failed: \(error)")
      notice = "I could not complete the comparison, so I did not guess."
      return (nil, Announcement.unsure)
    }
  }

  /// After `Announcement.fillerDelay` without an answer, says the next filler line.
  /// Only lines already generated are used, so one never starts late (after the answer).
  private func scheduleFiller() {
    fillerTask?.cancel()
    fillerTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Announcement.fillerDelay)
      guard !Task.isCancelled, let self else { return }
      await self.sayNextFiller()
    }
  }

  /// Says the next filler line in turn, if its audio is ready.
  private func sayNextFiller() async {
    let line = Announcement.fillers[nextFiller % Announcement.fillers.count]
    nextFiller += 1
    guard speaker.isPrepared(line) else { return }
    try? await speaker.speak(line) { [latency = self.latency] in
      latency?.mark("filler started")
    }
  }

  private static func describe(_ outcome: ReferentOutcome) -> String {
    switch outcome {
    case .identified: "identified"
    case .ambiguous: "ambiguous"
    case .notRecognized: "not recognized"
    case .poorQuality: "faces too unclear"
    case .noFace: "no face"
    case .failed: "Rekognition failed"
    }
  }

  private func preparePeople() {
    // Prepare every sentence Violet can say now, so answers and bios play without waiting on
    // ElevenLabs. Runs after each sync, so a bio or relation edited on the portal is
    // regenerated within a minute and the old audio is dropped.
    let sentences = people.flatMap { [Announcement.identified($0), Announcement.bio($0)] }
      + Announcement.fixed
    Task { @MainActor [weak self] in await self?.speaker.prepare(sentences) }

    guard let enrollment else { return }
    let snapshot = people
    Task { @MainActor [weak self] in
      let withoutFace = await enrollment.sync(snapshot)
      guard !withoutFace.isEmpty else { return }
      self?.notice = "No clear face was found in the photos for \(withoutFace.joined(separator: ", ")). Add new photos so Violet can recognize them."
    }
  }
}

/// Everything Violet says after a capture, in one place so it can be pre-generated.
enum Announcement {
  static let notFamily = "This is not one of your family members."
  static let noFace = "I couldn't see anyone's face. Try looking right at the person and ask me again."
  static let unsure = "I couldn't tell who this is, so I won't guess."
  /// Said in turn when an answer takes longer than `fillerDelay`.
  static let fillers = ["One moment.", "Just a second.", "Let me take a look."]
  static let fillerDelay: Duration = .seconds(3)
  static let fixed = [notFamily, noFace, unsure] + fillers

  static func identified(_ person: FamiliarPerson) -> String {
    "This is \(person.name), your \(person.relation)."
  }

  static func bio(_ person: FamiliarPerson) -> String {
    "\(person.name). \(person.bio)"
  }
}

/// How a follow-up model call ended.
private enum FollowUpResult: Sendable {
  case answer(FollowUpAnswer)
  case timedOut
  case failed(any Error)
}

/// Resumes a continuation with whichever result arrives first.
@MainActor
private final class FirstResult<Value> {
  var continuation: CheckedContinuation<Value, Never>?

  func resume(_ value: Value) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}
