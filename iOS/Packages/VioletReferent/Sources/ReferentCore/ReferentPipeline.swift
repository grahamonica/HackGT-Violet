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
///     await pipeline.begin()                                    // "Hey Violet"
///     for frame in incoming { await pipeline.consider(frame) }  // as frames arrive
///     let result = await pipeline.resolve(earliest: .seconds(2), deadline: .seconds(5))
///
/// Frames are analyzed one at a time in arrival order; only detected faces are
/// kept. Identification starts during capture, as new people appear. A capture
/// runs from `begin()` until `resolve` answers; frames outside a capture are
/// ignored, so the camera may keep streaming after an early answer. One
/// resolution at a time; `begin()`/`reset()` cancel a running one.
public actor ReferentPipeline {
  public let resolver: ReferentResolver
  private let analyzer: any FaceAnalyzing
  private let identifier: any FaceIdentifying
  private let rateLimiter: RateLimiter
  private let clock = ContinuousClock()

  // Capture state (cleared by reset()).
  private var capturing = false
  private var captureStart: ContinuousClock.Instant?
  private var observations: [FaceObservation] = []
  private var firstTimestamp: TimeInterval?
  private var lastTimestamp: TimeInterval?
  private var diagnostics = ReferentDiagnostics()
  private var analysis: Task<Void, Never>?
  private var sent: [Int: SendState] = [:]
  private var results: [Int: Result<[IdentityMatch], any Error>] = [:]
  private var inFlight: [Int: Task<Void, Never>] = [:]
  private var generation = 0

  public init(config: ReferentConfig = ReferentConfig(), analyzer: any FaceAnalyzing, identifier: any FaceIdentifying) {
    self.resolver = ReferentResolver(config: config)
    self.analyzer = analyzer
    self.identifier = identifier
    self.rateLimiter = RateLimiter(limit: config.maxIdentificationsPerSecond)
  }

  /// Starts a new capture, discarding anything from a previous one.
  public func begin() {
    reset()
    capturing = true
    captureStart = clock.now
  }

  /// Queues a frame for analysis and returns immediately. Ignored outside a capture.
  public func consider(_ frame: ReferentFrame) {
    guard capturing else { return }
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

  /// Answers as soon as possible after `earliest`, and no later than `deadline`
  /// (both measured from `begin()`, network included).
  ///
  /// From `earliest` on, it identifies new people as they appear and returns
  /// early once the outcome is `.identified` with no request pending. Otherwise
  /// it keeps capturing until `deadline`, then cancels anything in flight and
  /// answers from the results received.
  public func resolve(earliest: Duration = .seconds(2), deadline: Duration = .seconds(5)) async -> ReferentResult {
    guard let start = captureStart else { return await resolve() }
    try? await clock.sleep(until: start + earliest)
    return await run(deadline: start + deadline, started: start)
  }

  /// Ends the capture now and answers from the frames received so far,
  /// waiting for the resulting identification calls (each bounded by
  /// `identificationTimeout`).
  public func resolve() async -> ReferentResult {
    let started = captureStart ?? clock.now
    capturing = false
    while let pending = analysis {
      await pending.value
      if analysis == pending { break }  // no frame arrived while waiting
    }
    return await run(deadline: nil, started: started)
  }

  /// Ends any capture, cancels pending work, and discards everything.
  public func reset() {
    generation += 1
    capturing = false
    captureStart = nil
    analysis = nil
    for task in inFlight.values { task.cancel() }
    inFlight = [:]
    sent = [:]
    results = [:]
    observations = []
    firstTimestamp = nil
    lastTimestamp = nil
    diagnostics = ReferentDiagnostics()
  }

  // MARK: - Private

  /// Plans, dispatches and evaluates on each poll until an answer is due.
  /// `deadline == nil` means the capture is closed: finish once nothing is left to do.
  private func run(deadline: ContinuousClock.Instant?, started: ContinuousClock.Instant) async -> ReferentResult {
    let generation = generation
    let config = resolver.config
    while true {
      guard generation == self.generation else {
        return ReferentResult(outcome: .failed(ReferentError.cancelled), diagnostics: ReferentDiagnostics())
      }
      let pastDeadline = deadline.map { clock.now >= $0 } ?? false
      if pastDeadline { capturing = false }

      let plan = resolver.plan(
        observations: observations, start: firstTimestamp ?? 0, end: lastTimestamp ?? 0, sent: sent)
      var waiting = plan.candidates[...]
      if !pastDeadline {
        while inFlight.count < max(1, config.maxConcurrentIdentifications), let index = waiting.popFirst() {
          dispatch(index, plan: plan, generation: generation)
        }
      }
      let (outcome, identities) = resolver.resolve(plan: plan, results: results, pending: inFlight.count)
      let open = Array(inFlight.keys) + Array(waiting)

      var done = pastDeadline || (deadline == nil && open.isEmpty)
      var early = false
      if case .identified(let best) = outcome, deadline != nil, !pastDeadline {
        // Answer early once no open request could still overtake or tie the
        // winner; faces far less likely to be the referent don't hold it up.
        let bar = best.score * (1 - config.ambiguityMargin)
        let winnerTracks = Set(best.evidence.map(\.trackID))
        let couldChange = open.contains { index in
          let track = plan.trackIDs[index]
          return !winnerTracks.contains(track)
            && plan.trackReferentScores[track] + config.maxAgreementBonus >= bar
        }
        if !couldChange {
          done = true
          early = true
        }
      }
      if done { return finish(outcome, identities, plan: plan, early: early, started: started) }

      var nap = config.pollInterval
      if let deadline { nap = min(nap, max(.zero, deadline - clock.now)) }
      try? await clock.sleep(for: nap)
    }
  }

  private func dispatch(_ index: Int, plan: ReferentResolver.Plan, generation: Int) {
    sent[index] = .pending
    let crop = plan.observations[index].face.crop
    let identifier = identifier
    let rateLimiter = rateLimiter
    let timeout = resolver.config.identificationTimeout
    inFlight[index] = Task {
      guard await rateLimiter.acquire() else { return }  // cancelled while waiting for a slot
      let result = await Self.identify(crop, with: identifier, timeout: timeout)
      self.complete(index, result, generation: generation)
    }
  }

  private func complete(_ index: Int, _ result: Result<[IdentityMatch], any Error>, generation: Int) {
    guard generation == self.generation, inFlight.removeValue(forKey: index) != nil else { return }
    results[index] = result
    if case .success = result { sent[index] = .succeeded } else { sent[index] = .failed }
  }

  private func finish(
    _ outcome: ReferentOutcome, _ identities: [Identification], plan: ReferentResolver.Plan,
    early: Bool, started: ContinuousClock.Instant
  ) -> ReferentResult {
    var diagnostics = self.diagnostics
    diagnostics.tracks = plan.trackReferentScores.count
    diagnostics.facesPassingQuality = plan.facesPassingQuality
    diagnostics.identificationCalls = sent.count
    diagnostics.identificationFailures = results.values.filter {
      if case .failure = $0 { true } else { false }
    }.count + inFlight.count
    diagnostics.identities = identities
    diagnostics.answeredEarly = early
    let elapsed = (clock.now - started).components
    diagnostics.secondsToAnswer = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    reset()
    return ReferentResult(outcome: outcome, diagnostics: diagnostics)
  }

  /// Runs one identification, giving up after `timeout` even if the identifier
  /// ignores cancellation.
  private static func identify(
    _ crop: Data, with identifier: any FaceIdentifying, timeout: Duration
  ) async -> Result<[IdentityMatch], any Error> {
    let once = OnceContinuation<Result<[IdentityMatch], any Error>>()
    return await withCheckedContinuation { continuation in
      once.set(continuation)
      let work = Task {
        do { once.resume(.success(try await identifier.identify(crop: crop))) }
        catch { once.resume(.failure(error)) }
      }
      Task {
        try? await Task.sleep(for: timeout)
        work.cancel()
        once.resume(.failure(ReferentError.identificationTimedOut))
      }
    }
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

/// Resumes a continuation exactly once, whichever caller comes first.
private final class OnceContinuation<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?

  func set(_ continuation: CheckedContinuation<Value, Never>) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  func resume(_ value: Value) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: value)
  }
}
