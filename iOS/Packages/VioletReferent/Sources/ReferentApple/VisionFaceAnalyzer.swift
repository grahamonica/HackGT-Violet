#if canImport(Vision)
import CoreGraphics
import Foundation
import ReferentCore
import Vision

/// A face found by Vision, in the frame's pixel coordinates (origin top-left).
public struct VisionFace: Sendable {
  /// Face bounding box in pixels.
  public let box: CGRect
  /// Left eye, right eye, nose tip, left mouth corner, right mouth corner
  /// (image left/right), matching the quality model's training landmarks.
  public let landmarks: [Point2D]
}

/// `FaceAnalyzing` with Apple Vision + the local quality model:
/// detect faces and landmarks, cut the crop sent to Rekognition (face box +
/// `cropMargin` on each side, as in training), align it, and score it.
public struct VisionFaceAnalyzer: FaceAnalyzing {
  public let model: FaceQualityModel
  /// Fraction of the face box added on each side of the Rekognition crop.
  public var cropMargin = 0.2
  public var jpegQuality = 0.95

  public init(model: FaceQualityModel) {
    self.model = model
  }

  public func analyze(_ frame: ReferentFrame) async throws -> [DetectedFace] {
    guard let image = ImageConversion.cgImage(from: frame.jpegData) else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "frame is not a decodable image"])
    }
    let width = Double(image.width), height = Double(image.height)
    return try Self.faces(in: image).compactMap { face in
      let crop = Self.cropRect(face.box, margin: cropMargin, width: width, height: height)
      guard let cropImage = image.cropping(to: crop),
            let cropJPEG = ImageConversion.jpegData(cropImage, quality: jpegQuality),
            let cropPixels = ImageConversion.rgbImage(cropImage)
      else { return nil }
      // Landmarks relative to the crop: the model is trained on crop pixels.
      let local = face.landmarks.map { Point2D(x: $0.x - crop.minX, y: $0.y - crop.minY) }
      let aligned = FaceAlignment.align(cropPixels, landmarks: local, size: model.inputSize)
      let quality = try model.predict(alignedFace: aligned, interocularPx: FaceAlignment.interocularDistance(local))
      let box = NormalizedRect(
        x: face.box.minX / width, y: face.box.minY / height, width: face.box.width / width, height: face.box.height / height)
      return DetectedFace(box: box, quality: quality, crop: cropJPEG)
    }
  }

  /// Faces with landmarks in `image` (pixel coordinates, origin top-left).
  public static func faces(in image: CGImage) throws -> [VisionFace] {
    let request = VNDetectFaceLandmarksRequest()
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    let size = CGSize(width: image.width, height: image.height)
    return (request.results ?? []).compactMap { observation in
      guard let landmarks = observation.landmarks, let points = fivePoints(landmarks, imageSize: size) else { return nil }
      let b = observation.boundingBox  // normalized, origin bottom-left
      let box = CGRect(
        x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height)
      return VisionFace(box: box, landmarks: points)
    }
  }

  /// Vision's landmark regions -> the 5 training points, in top-left pixel coordinates:
  /// eye centers (pupils, else eye-contour centroids), nose tip (lowest point of
  /// the nose crest, else of the nose contour), mouth corners (horizontal
  /// extremes of the outer lips). Left/right are assigned by x, so Vision's
  /// left/right naming convention doesn't matter.
  static func fivePoints(_ landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [Point2D]? {
    func points(_ region: VNFaceLandmarkRegion2D?) -> [Point2D] {
      (region?.pointsInImage(imageSize: imageSize) ?? []).map { Point2D(x: Double($0.x), y: Double(imageSize.height - $0.y)) }
    }
    func centroid(_ p: [Point2D]) -> Point2D? {
      p.isEmpty ? nil : Point2D(x: p.map(\.x).reduce(0, +) / Double(p.count), y: p.map(\.y).reduce(0, +) / Double(p.count))
    }
    guard let eyeA = centroid(points(landmarks.leftPupil)) ?? centroid(points(landmarks.leftEye)),
          let eyeB = centroid(points(landmarks.rightPupil)) ?? centroid(points(landmarks.rightEye)),
          let nose = (points(landmarks.noseCrest).max { $0.y < $1.y }) ?? (points(landmarks.nose).max { $0.y < $1.y })
    else { return nil }
    let lips = points(landmarks.outerLips)
    guard let mouthLeft = lips.min(by: { $0.x < $1.x }), let mouthRight = lips.max(by: { $0.x < $1.x }) else { return nil }
    let (eyeLeft, eyeRight) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)
    return [eyeLeft, eyeRight, nose, mouthLeft, mouthRight]
  }

  static func cropRect(_ box: CGRect, margin: Double, width: Double, height: Double) -> CGRect {
    let dx = box.width * margin, dy = box.height * margin
    let x0 = max(0, (box.minX - dx).rounded(.down)), y0 = max(0, (box.minY - dy).rounded(.down))
    let x1 = min(width, (box.maxX + dx).rounded(.up)), y1 = min(height, (box.maxY + dy).rounded(.up))
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }
}
#endif
