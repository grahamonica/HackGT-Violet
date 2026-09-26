import Foundation

/// A face detection placed in time, as used by the resolver.
public struct FaceObservation: Sendable {
  public let frameIndex: Int
  public let timestamp: TimeInterval
  public let face: DetectedFace

  public init(frameIndex: Int, timestamp: TimeInterval, face: DetectedFace) {
    self.frameIndex = frameIndex
    self.timestamp = timestamp
    self.face = face
  }
}

/// Links detections of the same face across frames by box overlap, so repeated
/// sightings of one person count as one track instead of many candidates.
public enum FaceTracking {
  /// Returns one track id per observation (same order as the input).
  /// Within a frame, pairs are matched greedily by highest overlap; a track
  /// only continues if its face was seen within `maxGap` seconds.
  public static func assignTracks(_ observations: [FaceObservation], minIoU: Double, maxGap: TimeInterval) -> [Int] {
    var trackIDs = [Int](repeating: -1, count: observations.count)
    var lastSeen: [(box: NormalizedRect, time: TimeInterval)] = []  // indexed by track id

    let byFrame = Dictionary(grouping: observations.indices, by: { observations[$0].frameIndex })
    let frames = byFrame.keys.sorted { lhs, rhs in
      let tl = observations[byFrame[lhs]![0]].timestamp
      let tr = observations[byFrame[rhs]![0]].timestamp
      return tl == tr ? lhs < rhs : tl < tr
    }

    for frame in frames {
      let indices = byFrame[frame]!
      let now = observations[indices[0]].timestamp
      let live = lastSeen.indices.filter { now - lastSeen[$0].time <= maxGap }

      var pairs: [(iou: Double, obs: Int, track: Int)] = []
      for i in indices {
        for t in live {
          let overlap = observations[i].face.box.iou(lastSeen[t].box)
          if overlap >= minIoU { pairs.append((overlap, i, t)) }
        }
      }
      pairs.sort { $0.iou > $1.iou }

      var usedTracks = Set<Int>()
      for pair in pairs where trackIDs[pair.obs] == -1 && !usedTracks.contains(pair.track) {
        trackIDs[pair.obs] = pair.track
        usedTracks.insert(pair.track)
      }
      for i in indices {
        if trackIDs[i] == -1 {
          trackIDs[i] = lastSeen.count
          lastSeen.append((observations[i].face.box, now))
        } else {
          lastSeen[trackIDs[i]] = (observations[i].face.box, now)
        }
      }
    }
    return trackIDs
  }
}
