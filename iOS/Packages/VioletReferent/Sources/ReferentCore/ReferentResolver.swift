import Foundation

/// The pipeline's decision logic, free of I/O:
/// 1. `plan`: track faces, score how likely each track is the referent, and
///    choose which crops are worth an identification call.
/// 2. `resolve`: turn identification results into a `ReferentOutcome`.
public struct ReferentResolver: Sendable {
  public let config: ReferentConfig

  public init(config: ReferentConfig = ReferentConfig()) {
    self.config = config
  }

  public struct Plan: Sendable {
    public let observations: [FaceObservation]
    /// Track id per observation.
    public let trackIDs: [Int]
    /// Best referent score over each track's sightings, indexed by track id.
    public let trackReferentScores: [Double]
    /// Observation indices to identify, highest priority first.
    public let candidates: [Int]
    public let facesPassingQuality: Int
  }

  /// `start`/`end` are the first and last frame timestamps of the capture
  /// (including frames without faces).
  public func plan(observations: [FaceObservation], start: TimeInterval, end: TimeInterval) -> Plan {
    let trackIDs = FaceTracking.assignTracks(observations, minIoU: config.trackMinIoU, maxGap: config.trackMaxGap)
    let trackCount = (trackIDs.max() ?? -1) + 1

    // A track's referent score uses all its sightings, whether or not the crop
    // is good enough to send: the person was there and central either way.
    var trackScores = [Double](repeating: 0, count: trackCount)
    var passing = [[Int]](repeating: [], count: trackCount)
    for (i, obs) in observations.enumerated() {
      let score = ReferentScoring.referentScore(
        box: obs.face.box, timestamp: obs.timestamp, start: start, end: end, config: config)
      trackScores[trackIDs[i]] = max(trackScores[trackIDs[i]], score)
      if obs.face.quality >= config.minQuality { passing[trackIDs[i]].append(i) }
    }
    for t in passing.indices {
      passing[t].sort { observations[$0].face.quality > observations[$1].face.quality }
    }

    // Every track gets its best crop before any track gets a second one; tracks
    // most likely to be the referent go first, so a cap never drops them.
    let trackOrder = (0..<trackCount).filter { !passing[$0].isEmpty }.sorted { trackScores[$0] > trackScores[$1] }
    var candidates: [Int] = []
    rounds: for round in 0..<max(config.cropsPerTrack, 0) {
      for t in trackOrder where round < passing[t].count {
        guard candidates.count < config.maxIdentificationCalls else { break rounds }
        candidates.append(passing[t][round])
      }
    }

    return Plan(
      observations: observations,
      trackIDs: trackIDs,
      trackReferentScores: trackScores,
      candidates: candidates,
      facesPassingQuality: passing.reduce(0) { $0 + $1.count })
  }

  /// `results` holds one entry per identified candidate (observation index).
  /// Returns the outcome and every accepted identity, best first.
  public func resolve(plan: Plan, results: [Int: Result<[IdentityMatch], any Error>]) -> (ReferentOutcome, [Identification]) {
    if plan.observations.isEmpty { return (.noFace, []) }
    if plan.candidates.isEmpty { return (.poorQuality, []) }

    var evidenceByUser: [String: [Evidence]] = [:]
    var firstError: (any Error)?
    var anySuccess = false
    for index in plan.candidates {
      switch results[index] {
      case .success(let matches):
        anySuccess = true
        guard let best = matches.max(by: { $0.similarity < $1.similarity }),
              best.similarity >= config.minSimilarity else { continue }
        let obs = plan.observations[index]
        let track = plan.trackIDs[index]
        evidenceByUser[best.userID, default: []].append(Evidence(
          frameIndex: obs.frameIndex, timestamp: obs.timestamp, box: obs.face.box, quality: obs.face.quality,
          similarity: best.similarity, trackID: track, referentScore: plan.trackReferentScores[track]))
      case .failure(let error):
        firstError = firstError ?? error
      case nil:
        continue
      }
    }
    if !anySuccess, let error = firstError { return (.failed(error), []) }

    let identities = evidenceByUser
      .map { identification(userID: $0.key, evidence: $0.value) }
      .sorted { $0.score == $1.score ? $0.bestSimilarity > $1.bestSimilarity : $0.score > $1.score }

    guard let best = identities.first else { return (.notRecognized, []) }
    let contenders = identities.filter { $0.score >= best.score * (1 - config.ambiguityMargin) }
    return (contenders.count > 1 ? .ambiguous(contenders) : .identified(best), identities)
  }

  /// Best supporting track's referent score, plus a capped bonus per extra agreeing crop.
  private func identification(userID: String, evidence: [Evidence]) -> Identification {
    let base: Double = evidence.map(\.referentScore).max() ?? 0
    let extra = Double(evidence.count - 1)
    let bonus: Double = min(config.agreementBonus * extra, config.maxAgreementBonus)
    let bestSimilarity: Double = evidence.map(\.similarity).max() ?? 0
    return Identification(
      userID: userID, score: base + bonus, bestSimilarity: bestSimilarity,
      evidence: evidence.sorted { $0.referentScore > $1.referentScore })
  }
}
