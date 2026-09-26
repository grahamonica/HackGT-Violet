import Foundation

/// Finds faces in a frame and prepares each one: box, local quality score, and
/// the crop to send for identification. Implemented with Vision + Core ML on
/// device; any implementation works (tests use fakes).
public protocol FaceAnalyzing: Sendable {
  func analyze(_ frame: ReferentFrame) async throws -> [DetectedFace]
}

/// Answers "who is this face?" for one crop, e.g. via Rekognition
/// `SearchUsersByImage`. Return an empty array when there is no match.
public protocol FaceIdentifying: Sendable {
  func identify(crop: Data) async throws -> [IdentityMatch]
}

/// Resolves who the user was referring to from a burst of frames.
///
///     let pipeline = ReferentPipeline(analyzer: ..., identifier: ...)
///     for frame in capturedFrames { await pipeline.consider(frame) }  // as they arrive
///     let result = await pipeline.resolve()                          // then resets
///
/// Frames are analyzed one at a time in arrival order while capture continues;
/// only the detected faces (not the frames) are kept.
public actor ReferentPipeline {
  public let resolver: ReferentResolver
  private let analyzer: any FaceAnalyzing
  private let identifier: any FaceIdentifying

  private var observations: [FaceObservation] = []
  private var firstTimestamp: TimeInterval?
  private var lastTimestamp: TimeInterval?
  private var diagnostics = ReferentDiagnostics()
  private var analysis: Task<Void, Never>?
  private var generation = 0

  public init(config: ReferentConfig = ReferentConfig(), analyzer: any FaceAnalyzing, identifier: any FaceIdentifying) {
    self.resolver = ReferentResolver(config: config)
    self.analyzer = analyzer
    self.identifier = identifier
  }

  /// Queues a frame for analysis and returns immediately.
  public func consider(_ frame: ReferentFrame) {
    let index = diagnostics.framesConsidered
    diagnostics.framesConsidered += 1
    firstTimestamp = min(firstTimestamp ?? frame.timestamp, frame.timestamp)
    lastTimestamp = max(lastTimestamp ?? frame.timestamp, frame.timestamp)

    let previous = analysis
    let analyzer = analyzer
    let generation = generation
    analysis = Task {
      await previous?.value
      let faces: [DetectedFace]?
      do { faces = try await analyzer.analyze(frame) } catch { faces = nil }
      self.record(faces, frameIndex: index, timestamp: frame.timestamp, generation: generation)
    }
  }

  /// Waits for pending analysis, identifies the chosen crops concurrently,
  /// and returns the outcome. The pipeline is reset as soon as analysis has
  /// finished, so frames considered while identification is in flight start
  /// the next capture instead of being lost.
  public func resolve() async -> ReferentResult {
    while let pending = analysis {
      await pending.value
      if analysis == pending { break }  // no frame arrived while waiting
    }
    let plan = resolver.plan(
      observations: observations, start: firstTimestamp ?? 0, end: lastTimestamp ?? 0)
    var diagnostics = self.diagnostics
    reset()

    diagnostics.tracks = plan.trackReferentScores.count
    diagnostics.facesPassingQuality = plan.facesPassingQuality
    diagnostics.identificationCalls = plan.candidates.count

    let identifier = identifier
    var results: [Int: Result<[IdentityMatch], any Error>] = [:]
    await withTaskGroup(of: (Int, Result<[IdentityMatch], any Error>).self) { group in
      for index in plan.candidates {
        let crop = plan.observations[index].face.crop
        group.addTask {
          do { return (index, .success(try await identifier.identify(crop: crop))) }
          catch { return (index, .failure(error)) }
        }
      }
      for await (index, result) in group { results[index] = result }
    }
    diagnostics.identificationFailures = results.values.filter {
      if case .failure = $0 { true } else { false }
    }.count

    let (outcome, identities) = resolver.resolve(plan: plan, results: results)
    diagnostics.identities = identities
    return ReferentResult(outcome: outcome, diagnostics: diagnostics)
  }

  /// Discards everything considered so far (pending analysis results are dropped).
  public func reset() {
    generation += 1
    analysis = nil
    observations = []
    firstTimestamp = nil
    lastTimestamp = nil
    diagnostics = ReferentDiagnostics()
  }

  private func record(_ faces: [DetectedFace]?, frameIndex: Int, timestamp: TimeInterval, generation: Int) {
    guard generation == self.generation else { return }
    guard let faces else {
      diagnostics.framesFailedAnalysis += 1
      return
    }
    diagnostics.facesDetected += faces.count
    observations += faces.map { FaceObservation(frameIndex: frameIndex, timestamp: timestamp, face: $0) }
  }
}
