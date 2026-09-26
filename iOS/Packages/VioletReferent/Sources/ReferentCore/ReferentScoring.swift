import Foundation

/// How likely a face was the person being referred to, from when and where it
/// appeared. Independent of identity and of Rekognition.
public enum ReferentScoring {
  /// Linear decay from 1 at the first frame to `floor` at the last, over the
  /// capture's normalized time, so buffers of any length weigh alike.
  public static func temporalWeight(timestamp: TimeInterval, start: TimeInterval, end: TimeInterval, floor: Double) -> Double {
    let span = end - start
    let p = span > 0 ? min(max((timestamp - start) / span, 0), 1) : 0
    return floor + (1 - floor) * (1 - p)
  }

  /// 1 at the frame center, Gaussian falloff toward the corners. Distance is in
  /// units of the half-diagonal, so a corner is at distance 1.
  public static func centrality(_ box: NormalizedRect, sigma: Double) -> Double {
    let dx = box.centerX - 0.5
    let dy = box.centerY - 0.5
    let distance = (dx * dx + dy * dy).squareRoot() / 0.5.squareRoot()
    return exp(-(distance / sigma) * (distance / sigma))
  }

  /// 0 for faces at or below `minHeight` of the frame, 1 at or above `maxHeight`,
  /// log-scaled in between.
  public static func sizeScore(_ box: NormalizedRect, minHeight: Double, maxHeight: Double) -> Double {
    guard box.height > 0, maxHeight > minHeight else { return 0 }
    let s = log(box.height / minHeight) / log(maxHeight / minHeight)
    return min(max(s, 0), 1)
  }

  /// Centrality, scaled down by up to `sizeWeight` for small faces.
  public static func geometry(_ box: NormalizedRect, config: ReferentConfig) -> Double {
    let size = sizeScore(box, minHeight: config.minFaceHeight, maxHeight: config.maxFaceHeight)
    return centrality(box, sigma: config.centralitySigma) * (1 - config.sizeWeight + config.sizeWeight * size)
  }

  public static func referentScore(
    box: NormalizedRect, timestamp: TimeInterval, start: TimeInterval, end: TimeInterval, config: ReferentConfig
  ) -> Double {
    temporalWeight(timestamp: timestamp, start: start, end: end, floor: config.temporalFloor)
      * geometry(box, config: config)
  }
}
