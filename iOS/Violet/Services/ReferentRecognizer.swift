import Foundation
import ImageIO
import ReferentApple
import ReferentCore
import ReferentRekognition
import UIKit

/// Face recognition through the VioletReferent package: on-device face detection
/// and quality scoring, then Rekognition search over the enrolled people.
///
/// It is `GlassesManager`'s frame selector: `reset()` marks the wake word and starts
/// resolving, every frame is passed to the pipeline, and `latestResult()` returns
/// the answer for the most recent capture (one to five seconds after `reset()`; the
/// glasses camera takes about a second to deliver its first frame).
/// `onResult` fires as soon as that answer is ready, so the capture can end early.
final class ReferentRecognizer: FrameSelecting, @unchecked Sendable {
  private let lock = NSLock()
  private var resultHandler: (@Sendable () -> Void)?
  private var generation = 0
  private let pipelineTask: Task<ReferentPipeline?, Never>
  /// Tail of the begin/consider chain, so the pipeline sees calls in arrival order.
  private var queue: Task<Void, Never>?
  private var resultTask: Task<ReferentResult?, Never>?
  private var count = 0

  init(config: RekognitionConfig) {
    let identifier = RekognitionIdentifier(config: config)
    pipelineTask = Task {
      do {
        let model = try await FaceQualityModel.bundled()
        return ReferentPipeline(analyzer: VisionFaceAnalyzer(model: model), identifier: identifier)
      } catch {
        violetTrace("face quality model failed to load: \(error)")
        return nil
      }
    }
  }

  var frameCount: Int { lock.withLock { count } }

  var onResult: (@Sendable () -> Void)? {
    get { lock.withLock { resultHandler } }
    set { lock.withLock { resultHandler = newValue } }
  }

  func reset() {
    lock.withLock {
      count = 0
      generation += 1
      let generation = generation
      let previous = queue
      let pipelineTask = pipelineTask
      let begun = Task { () -> ReferentPipeline? in
        await previous?.value
        guard let pipeline = await pipelineTask.value else { return nil }
        await pipeline.begin()
        return pipeline
      }
      queue = Task { _ = await begun.value }
      resultTask = Task { [weak self] in
        guard let pipeline = await begun.value else { return nil }
        let result = await pipeline.resolve(earliest: .seconds(1), deadline: .seconds(5))
        self?.notifyResult(generation: generation)
        return result
      }
    }
  }

  func consider(jpegData: Data) {
    // The pipeline needs a monotonic arrival time; frames carry no timestamp.
    let timestamp = ProcessInfo.processInfo.systemUptime
    lock.withLock {
      count += 1
      let previous = queue
      let pipelineTask = pipelineTask
      queue = Task {
        await previous?.value
        guard let pipeline = await pipelineTask.value else { return }
        let upright = Self.upright(jpegData)
        await pipeline.consider(ReferentFrame(jpegData: upright, timestamp: timestamp))
      }
    }
  }

  /// The pipeline picks its own crops; there is no single frame to hand back.
  func selection() -> Data? { nil }

  private func notifyResult(generation: Int) {
    let handler = lock.withLock { generation == self.generation ? resultHandler : nil }
    handler?()
  }

  func latestResult() async -> ReferentResult? {
    let task = lock.withLock { resultTask }
    return await task?.value
  }

  /// Vision ignores EXIF orientation, so re-encode frames that rely on it.
  private static func upright(_ jpeg: Data) -> Data {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation != 1,
      let image = UIImage(data: jpeg)
    else { return jpeg }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let redrawn = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(at: .zero)
    }
    return redrawn.jpegData(compressionQuality: 0.9) ?? jpeg
  }
}

/// Keeps the Rekognition collection in step with the people on this phone.
///
/// Each person is enrolled under their app ID (the Rekognition UserId). Every pass
/// asks Rekognition who is actually enrolled, so the collection heals itself: people
/// missing from it are enrolled, and users who are no longer people here (including
/// local IDs replaced by a server ID after upload) are removed. The `updatedAt` each
/// person was enrolled at is remembered so changed photos are re-sent.
actor FaceEnrollment {
  private let enroller: RekognitionEnroller
  private let defaults: UserDefaults
  private let enrolledKey: String
  private let noFaceKey: String
  private var collectionReady = false
  private var isRunning = false
  private var pending: [FamiliarPerson]?

  init(config: RekognitionConfig, defaults: UserDefaults = .standard) {
    self.enroller = RekognitionEnroller(config: config)
    self.defaults = defaults
    self.enrolledKey = "rekognition.enrolled.\(config.collectionID)"
    self.noFaceKey = "rekognition.noFace.\(config.collectionID)"
  }

  /// Returns the names of people whose photos had no usable face.
  func sync(_ people: [FamiliarPerson]) async -> [String] {
    guard !isRunning else {
      pending = people
      return []
    }
    isRunning = true
    defer { isRunning = false }

    var withoutFace: [String] = []
    var next: [FamiliarPerson]? = people
    while let current = next {
      withoutFace += await syncOnce(current)
      next = pending
      pending = nil
    }
    return withoutFace
  }

  private func syncOnce(_ people: [FamiliarPerson]) async -> [String] {
    let remote: Set<String>
    do {
      if !collectionReady {
        try await enroller.ensureCollection()
        collectionReady = true
      }
      remote = try await enroller.enrolledPersonIDs()
    } catch {
      violetTrace("rekognition collection unavailable: \(error)")
      return []
    }

    var enrolled = defaults.dictionary(forKey: enrolledKey) as? [String: Double] ?? [:]
    // People whose current photos had no face; not retried until their photos change.
    var noFace = defaults.dictionary(forKey: noFaceKey) as? [String: Double] ?? [:]
    var withoutFace: [String] = []

    for person in people {
      let version = person.updatedAt.timeIntervalSince1970
      guard noFace[person.id] != version else { continue }
      guard !remote.contains(person.id) || enrolled[person.id] != version else { continue }
      do {
        let result = try await enroller.enroll(
          personID: person.id,
          photos: [person.frontPhoto, person.leftPhoto, person.rightPhoto]
        )
        enrolled[person.id] = version
        noFace[person.id] = nil
        violetTrace("enrolled \(person.name) (\(person.id)): \(result.faceIDs.count) faces")
      } catch RekognitionError.noFaceInPhotos {
        noFace[person.id] = version
        withoutFace.append(person.name)
        violetTrace("no face in any photo of \(person.name) (\(person.id))")
      } catch {
        violetTrace("enrollment failed for \(person.name): \(error)")
      }
      defaults.set(enrolled, forKey: enrolledKey)
      defaults.set(noFace, forKey: noFaceKey)
    }

    let current = Set(people.map(\.id))
    for id in remote.subtracting(current) {
      do {
        try await enroller.remove(personID: id)
        enrolled[id] = nil
        violetTrace("removed \(id) from the collection")
      } catch {
        violetTrace("could not remove \(id) from the collection: \(error)")
      }
    }
    for id in noFace.keys where !current.contains(id) { noFace[id] = nil }
    defaults.set(enrolled, forKey: enrolledKey)
    defaults.set(noFace, forKey: noFaceKey)
    return withoutFace
  }
}
