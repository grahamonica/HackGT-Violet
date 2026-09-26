import Foundation
import Observation
import ReferentApple
import ReferentCore
import ReferentRekognition

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
  @ObservationIgnored private let enroller: RekognitionEnroller?
  @ObservationIgnored private let speaker: ElevenLabsSpeaker
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var recognitionCount = 0
  @ObservationIgnored private var isCollectionReady = false
  @ObservationIgnored private var isEnrolling = false

  init(environment: AppEnvironment = .load()) {
    self.environment = environment
    self.store = LocalStore()
    self.remoteAPI = RemoteAPI(environment: environment)
    // Search and enrollment share one config so they always use the same collection.
    self.enroller = environment.rekognition.map { RekognitionEnroller(config: $0) }
    self.speaker = ElevenLabsSpeaker(environment: environment)
    self.glasses = GlassesManager()
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    let cache = await store.load()
    people = cache.people
    isLoading = false

    glasses.onVioletCapture = { [weak self] timestamp, result in
      Task { @MainActor in
        await self?.processCapture(timestamp: timestamp, result: result)
      }
    }
    glasses.startMonitoring()
    await loadPipeline()
    startSyncLoop()
  }

  func setActive(_ active: Bool) {
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
      await enrollChangedPeople()
    } catch {
      notice = "\(person.name) is saved on this phone and will sync when the connection returns."
    }
    return true
  }

  func readBio(for person: FamiliarPerson) async {
    let text = "\(person.name). \(person.bio)"
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
    defer { isSyncing = false }

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

    await enrollChangedPeople()
  }

  private func loadPipeline() async {
    guard let rekognition = environment.rekognition else {
      notice = "Face recognition is not configured."
      return
    }
    do {
      let model = try await FaceQualityModel.bundled()
      glasses.pipeline = ReferentPipeline(
        analyzer: VisionFaceAnalyzer(model: model),
        identifier: RekognitionIdentifier(config: rekognition)
      )
    } catch {
      violetTrace("face quality model failed to load: \(error)")
      notice = "Face recognition could not start."
    }
  }

  /// Rekognition only recognizes enrolled people, and its UserId is the person's ID. Anyone new
  /// or changed since their last enrollment is enrolled again; people waiting to upload are
  /// skipped because their ID changes once the database assigns one.
  private func enrollChangedPeople() async {
    guard let enroller, !isEnrolling else { return }
    isEnrolling = true
    defer { isEnrolling = false }

    do {
      if !isCollectionReady {
        try await enroller.ensureCollection()
        isCollectionReady = true
      }
    } catch {
      violetTrace("ensureCollection failed: \(error)")
      return
    }

    let defaultsKey = "rekognitionEnrolledAt.\(enroller.config.collectionID)"
    var enrolledAt = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    for person in people where !person.needsUpload {
      let version = person.updatedAt.timeIntervalSince1970
      guard enrolledAt[person.id] != version else { continue }
      do {
        let enrollment = try await enroller.enroll(
          personID: person.id,
          photos: [person.frontPhoto, person.leftPhoto, person.rightPhoto]
        )
        if !enrollment.photosWithoutFace.isEmpty {
          notice = "Violet could not find a face in \(enrollment.photosWithoutFace.count) of \(person.name)’s photos."
        }
        enrolledAt[person.id] = version
      } catch RekognitionError.noFaceInPhotos {
        notice = "Violet could not find a face in any of \(person.name)’s photos."
        enrolledAt[person.id] = version
      } catch {
        // Retried on the next one-minute sync.
        violetTrace("enrollment failed for \(person.name): \(error)")
      }
    }
    UserDefaults.standard.set(enrolledAt, forKey: defaultsKey)
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

  private func processCapture(timestamp: Date, result: ReferentResult?) async {
    recognitionCount += 1
    isRecognizing = true
    defer {
      recognitionCount -= 1
      isRecognizing = recognitionCount > 0
    }

    let matchedPerson: FamiliarPerson?
    if let result {
      violetTrace("referent diagnostics: \(result.diagnostics)")
      switch result.outcome {
      case .identified(let match):
        matchedPerson = people.first(where: { $0.id == match.userID })
      case .failed(let error):
        violetTrace("recognition failed: \(error)")
        matchedPerson = nil
        notice = "I could not complete the comparison, so I did not guess."
      case .ambiguous, .notRecognized, .poorQuality, .noFace:
        matchedPerson = nil
      }
    } else {
      matchedPerson = nil
      notice = "The glasses did not return a usable image."
    }

    let identifiedName = matchedPerson?.name ?? "Unknown"
    let log = RecognitionLog(timestamp: timestamp, identifiedPerson: identifiedName)
    do {
      _ = try await store.append(log)
      if environment.mongoIsConfigured {
        try await remoteAPI.upload(log)
        _ = try await store.markLogUploaded(id: log.id)
      }
    } catch {
      // The local append is attempted first; pending remote logs are retried by sync.
    }

    let speech: String
    if let matchedPerson {
      speech = "This is \(matchedPerson.name), your \(matchedPerson.relation)."
    } else {
      speech = "This is not one of your family members."
    }
    lastAnnouncement = speech
    violetTrace("speaking: \(speech)")
    do {
      try await speaker.speak(speech)
    } catch {
      violetTrace("speech failed: \(error)")
      notice = error.localizedDescription
    }
  }
}
