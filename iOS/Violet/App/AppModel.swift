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
  @ObservationIgnored private var recognitionCount = 0

  init(environment: AppEnvironment = .load()) {
    self.environment = environment
    self.store = LocalStore()
    self.remoteAPI = RemoteAPI(environment: environment)
    self.recognizer = OpenAIRecognitionService(environment: environment)
    self.speaker = ElevenLabsSpeaker(environment: environment)
    let referent = environment.rekognition.map(ReferentRecognizer.init(config:))
    self.referent = referent
    self.enrollment = environment.rekognition.map { FaceEnrollment(config: $0) }
    self.glasses = referent.map { GlassesManager(frameSelector: $0) } ?? GlassesManager()
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
    glasses.isRecognitionRunning = { [weak self] in self?.isRecognizing ?? false }
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
      cache = try await store.mergeRemote(changes, syncedAt: startedAt)
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
    "You can add up to \(AppLimits.maximumPeople) people. Delete someone from MongoDB to add another."
  }

  private func processCapture(timestamp: Date, image: Data?, frameCount: Int) async {
    recognitionCount += 1
    isRecognizing = true
    defer {
      recognitionCount -= 1
      isRecognizing = recognitionCount > 0
    }

    let matchedPerson: FamiliarPerson?
    var unmatchedSpeech = Announcement.notFamily
    if let referent {
      if frameCount > 0, let result = await referent.latestResult() {
        (matchedPerson, unmatchedSpeech) = interpret(result, fallback: unmatchedSpeech)
      } else {
        matchedPerson = nil
        notice = "The glasses did not return a usable image."
      }
    } else if let image {
      do {
        let decision = try await recognizer.recognize(candidate: image, among: people)
        matchedPerson = decision.personID.flatMap { id in people.first(where: { $0.id == id }) }
      } catch {
        violetTrace("recognition failed: \(error)")
        matchedPerson = nil
        notice = "I could not complete the comparison, so I did not guess."
      }
    } else {
      matchedPerson = nil
      notice = "The glasses did not return a usable image."
    }

    let identifiedName = matchedPerson?.name ?? "Unknown"
    let log = RecognitionLog(timestamp: timestamp, identifiedPerson: identifiedName)
    // Saved alongside the speech so a slow or unreachable server never delays the answer.
    Task { @MainActor [weak self] in await self?.record(log) }

    let speech: String
    if let matchedPerson {
      speech = Announcement.identified(matchedPerson)
    } else {
      speech = unmatchedSpeech
    }
    lastAnnouncement = speech
    let elapsed = Date().timeIntervalSince(timestamp).formatted(.number.precision(.fractionLength(2)))
    violetTrace("speaking \(elapsed)s after trigger: \(speech)")
    do {
      try await speaker.speak(speech)
      violetTrace("voice audio started \(Date().timeIntervalSince(timestamp).formatted(.number.precision(.fractionLength(2))))s after trigger")
    } catch {
      violetTrace("speech failed: \(error)")
      notice = error.localizedDescription
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
  static let noFace = "I couldn't see anyone's face."
  static let unsure = "I couldn't tell who this is, so I won't guess."
  static let fixed = [notFamily, noFace, unsure]

  static func identified(_ person: FamiliarPerson) -> String {
    "This is \(person.name), your \(person.relation)."
  }

  static func bio(_ person: FamiliarPerson) -> String {
    "\(person.name). \(person.bio)"
  }
}
