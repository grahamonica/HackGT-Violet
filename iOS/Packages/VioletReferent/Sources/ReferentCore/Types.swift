import Foundation

/// One captured frame. `timestamp` is in seconds on any monotonic clock; the
/// earliest frame supplied is treated as the "Hey Violet" reference frame.
public struct ReferentFrame: Sendable {
  public let jpegData: Data
  public let timestamp: TimeInterval

  public init(jpegData: Data, timestamp: TimeInterval) {
    self.jpegData = jpegData
    self.timestamp = timestamp
  }
}

/// A rectangle in normalized image coordinates: origin at the top-left, x to
/// the right, y down, all values as fractions of the image width/height.
public struct NormalizedRect: Sendable, Hashable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var centerX: Double { x + width / 2 }
  public var centerY: Double { y + height / 2 }
  public var area: Double { max(0, width) * max(0, height) }

  /// Intersection over union with another rectangle (0 when disjoint).
  public func iou(_ other: NormalizedRect) -> Double {
    let ix = max(0, min(x + width, other.x + other.width) - max(x, other.x))
    let iy = max(0, min(y + height, other.y + other.height) - max(y, other.y))
    let intersection = ix * iy
    let union = area + other.area - intersection
    return union > 0 ? intersection / union : 0
  }
}

/// A face found in one frame by a `FaceAnalyzing` implementation.
public struct DetectedFace: Sendable {
  /// Face bounding box in the source frame.
  public let box: NormalizedRect
  /// Local quality-model score in [0, 1]: predicted usefulness for Rekognition.
  public let quality: Double
  /// Exactly the image that would be sent to Rekognition for this face.
  public let crop: Data

  public init(box: NormalizedRect, quality: Double, crop: Data) {
    self.box = box
    self.quality = quality
    self.crop = crop
  }
}

/// One candidate identity returned by a `FaceIdentifying` implementation.
public struct IdentityMatch: Sendable, Hashable {
  /// Rekognition `UserId` (or the equivalent id of another identifier).
  public let userID: String
  /// Similarity on Rekognition's 0-100 scale.
  public let similarity: Double

  public init(userID: String, similarity: Double) {
    self.userID = userID
    self.similarity = similarity
  }
}

/// One accepted recognition that supports an identity.
public struct Evidence: Sendable {
  public let frameIndex: Int
  public let timestamp: TimeInterval
  public let box: NormalizedRect
  public let quality: Double
  public let similarity: Double
  public let trackID: Int
  /// How likely this face track was the person being referred to (see `ReferentScoring`).
  public let referentScore: Double
}

/// A recognized identity with its combined score and supporting evidence.
public struct Identification: Sendable {
  public let userID: String
  /// Referent score of the best supporting track plus a small agreement bonus.
  public let score: Double
  public let bestSimilarity: Double
  public let evidence: [Evidence]
}

/// The result of resolving who the user was referring to.
public enum ReferentOutcome: Sendable {
  /// One identity clearly stands out.
  case identified(Identification)
  /// Several identities scored within `ambiguityMargin` of each other (best first).
  case ambiguous([Identification])
  /// Crops were sent, but none produced an acceptable match.
  case notRecognized
  /// Faces were found, but none passed the local quality gate; no Rekognition calls were made.
  case poorQuality
  /// No face was detected in any frame.
  case noFace
  /// No identification succeeded: every request failed (e.g. no network) or
  /// timed out (`ReferentError`). Distinct from `notRecognized`.
  case failed(any Error)
}

public enum ReferentError: Error, Sendable {
  /// No identification result arrived before the deadline or per-call timeout.
  case identificationTimedOut
  /// Faces passed the quality gate but no request was made (e.g. a call budget of 0).
  case noIdentificationAttempted
  /// `begin()` or `reset()` was called while this resolution was running.
  case cancelled
}

/// Counts for logging and threshold tuning.
public struct ReferentDiagnostics: Sendable {
  public var framesConsidered = 0
  public var framesFailedAnalysis = 0
  public var facesDetected = 0
  public var tracks = 0
  public var facesPassingQuality = 0
  public var identificationCalls = 0
  public var identificationFailures = 0
  /// Seconds from `begin()` (or the `resolve()` call) to the answer.
  public var secondsToAnswer = 0.0
  /// True if a confident answer ended the capture before its deadline.
  public var answeredEarly = false
  /// Every accepted identity, best first (the outcome may be a subset).
  public var identities: [Identification] = []

  public init() {}
}

public struct ReferentResult: Sendable {
  public let outcome: ReferentOutcome
  public let diagnostics: ReferentDiagnostics
}
