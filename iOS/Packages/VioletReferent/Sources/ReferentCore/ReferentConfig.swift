import Foundation

/// Every tunable of the pipeline. Defaults marked "from data" were chosen on
/// the face-quality dataset (see ml/facequality/training/RESULTS.md) and should
/// be re-checked on real glasses footage.
public struct ReferentConfig: Sendable {
  // MARK: Local quality gate

  /// Crops scoring below this are never sent to Rekognition. From data: 0.15
  /// rejects ~2% of crops Rekognition gets right and ~59% of those it gets wrong.
  public var minQuality = 0.15
  /// Upper bound on identification calls per capture.
  public var maxIdentificationCalls = 6
  /// Crops sent per face track (the best-quality ones), budget permitting.
  public var cropsPerTrack = 1
  /// A track already identified gets another call only if a new crop's quality
  /// beats its best sent crop by this much.
  public var requalityMargin = 0.15

  // MARK: Rate and time limits

  /// Identification calls started per second, across captures, for the
  /// pipeline's lifetime (sliding one-second window). Rekognition's default
  /// quota for `SearchUsersByImage` is 50/s per account in us-east-1 (5 in most
  /// other regions); calls over the limit wait for a slot.
  public var maxIdentificationsPerSecond = 45
  /// Identification calls in flight at once. Equal to `maxIdentificationCalls`
  /// by default, so a capture's calls all go out immediately.
  public var maxConcurrentIdentifications = 6
  /// A single call that takes longer counts as failed (protects against hung requests).
  public var identificationTimeout: Duration = .seconds(3)
  /// How often `resolve(earliest:deadline:)` re-checks for new faces and a confident answer.
  public var pollInterval: Duration = .milliseconds(100)

  // MARK: Tracking (linking the same face across frames)

  /// Minimum box overlap to continue a track in a later frame.
  public var trackMinIoU = 0.3
  /// A track ends if its face is not seen for longer than this (seconds).
  public var trackMaxGap: TimeInterval = 0.5

  // MARK: Referent scoring

  /// Temporal weight of the last frame; the first frame always has weight 1.
  public var temporalFloor = 0.3
  /// Width of the centrality falloff, in units of the half-diagonal (0.35 means a
  /// face centered 35% of the way to a corner keeps ~37% centrality).
  public var centralitySigma = 0.35
  /// How much face size can matter (0 = ignore size, 1 = size fully multiplies).
  public var sizeWeight = 0.4
  /// Face heights (fraction of the frame) mapped to size score 0 and 1, log-scaled.
  public var minFaceHeight = 0.05
  public var maxFaceHeight = 0.4

  // MARK: Recognition and final selection

  /// Rekognition matches below this similarity are ignored. From data: 80 keeps
  /// ~97.5% of correct top-1 matches and accepts ~0.7% of wrong ones.
  public var minSimilarity = 80.0
  /// Score bonus per additional agreeing crop for the same identity...
  public var agreementBonus = 0.05
  /// ...capped at this total.
  public var maxAgreementBonus = 0.15
  /// If the runner-up scores within this fraction of the best, the outcome is
  /// `ambiguous` instead of `identified`.
  public var ambiguityMargin = 0.15

  public init() {}
}
