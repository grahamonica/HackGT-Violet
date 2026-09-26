import Foundation

/// An 8-bit RGB image, row-major, 3 bytes per pixel.
public struct RGBImage: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public var pixels: [UInt8]

  public init(width: Int, height: Int, pixels: [UInt8]) {
    precondition(pixels.count == width * height * 3, "RGBImage needs width*height*3 bytes")
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  public init(width: Int, height: Int) {
    self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 3))
  }
}

public struct Point2D: Sendable, Hashable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// The quality model's input preparation: warp a face so its 5 landmarks land
/// on the ArcFace 112x112 template. Mirrors `ml/facequality/training/align.py`
/// (and its OpenCV calls) so on-device inputs match training; checked against
/// the Python reference set in the tests.
///
/// Landmark order: left eye, right eye, nose tip, left mouth corner, right
/// mouth corner, where left/right are image left/right. Coordinates are pixels
/// of the image being aligned (the crop sent to Rekognition).
public enum FaceAlignment {
  /// InsightFace's canonical 112x112 ArcFace template.
  public static let template: [Point2D] = [
    Point2D(x: 38.2946, y: 51.6963),
    Point2D(x: 73.5318, y: 51.5014),
    Point2D(x: 56.0252, y: 71.7366),
    Point2D(x: 41.5493, y: 92.3655),
    Point2D(x: 70.7299, y: 92.2041),
  ]

  public static func template(size: Int) -> [Point2D] {
    let s = Double(size) / 112.0
    return template.map { Point2D(x: $0.x * s, y: $0.y * s) }
  }

  /// Eye-to-eye distance in pixels (the model's face-resolution input).
  public static func interocularDistance(_ landmarks: [Point2D]) -> Double {
    let dx = landmarks[1].x - landmarks[0].x
    let dy = landmarks[1].y - landmarks[0].y
    return (dx * dx + dy * dy).squareRoot()
  }

  /// Least-squares similarity (rotation, uniform scale, translation, no
  /// reflection) mapping `src` onto `dst`, as a row-major 2x3 matrix.
  public static func similarityTransform(from src: [Point2D], to dst: [Point2D]) -> [Double] {
    let n = Double(src.count)
    let msx = src.map(\.x).reduce(0, +) / n, msy = src.map(\.y).reduce(0, +) / n
    let mdx = dst.map(\.x).reduce(0, +) / n, mdy = dst.map(\.y).reduce(0, +) / n
    var dot = 0.0, cross = 0.0, norm = 0.0
    for (s, d) in zip(src, dst) {
      let sx = s.x - msx, sy = s.y - msy, dx = d.x - mdx, dy = d.y - mdy
      dot += sx * dx + sy * dy
      cross += sx * dy - sy * dx
      norm += sx * sx + sy * sy
    }
    let a = dot / norm, b = cross / norm
    return [a, -b, mdx - (a * msx - b * msy), b, a, mdy - (b * msx + a * msy)]
  }

  /// The aligned `size`x`size` face. Faces needing more than 2x shrinking are
  /// first area-downsampled so the warp itself never shrinks by more than 2x.
  public static func align(_ image: RGBImage, landmarks: [Point2D], size: Int = 112) -> RGBImage {
    precondition(landmarks.count == 5, "alignment needs 5 landmarks")
    let dst = template(size: size)
    var source = image
    var points = landmarks
    var m = similarityTransform(from: points, to: dst)
    let scale = abs(m[0] * m[4] - m[1] * m[3]).squareRoot()
    if scale < 0.5 {
      let r = 2 * scale  // after resizing by r the warp scale is exactly 0.5
      let w = max(1, Int((Double(image.width) * r).rounded(.toNearestOrEven)))
      let h = max(1, Int((Double(image.height) * r).rounded(.toNearestOrEven)))
      source = resizeArea(image, width: w, height: h)
      let fx = Double(w) / Double(image.width), fy = Double(h) / Double(image.height)
      points = landmarks.map { Point2D(x: $0.x * fx, y: $0.y * fy) }
      m = similarityTransform(from: points, to: dst)
    }
    return warpAffine(source, matrix: m, width: size, height: size)
  }

  /// OpenCV `INTER_AREA` downsampling: each output pixel is the area-weighted
  /// mean of the input pixels it covers.
  static func resizeArea(_ image: RGBImage, width: Int, height: Int) -> RGBImage {
    let xTab = areaTable(source: image.width, destination: width)
    let yTab = areaTable(source: image.height, destination: height)
    // Horizontal pass into a float buffer, then vertical.
    var rows = [Double](repeating: 0, count: image.height * width * 3)
    for y in 0..<image.height {
      for (dx, entries) in xTab.enumerated() {
        for (sx, w) in entries {
          let s = (y * image.width + sx) * 3, d = (y * width + dx) * 3
          rows[d] += w * Double(image.pixels[s])
          rows[d + 1] += w * Double(image.pixels[s + 1])
          rows[d + 2] += w * Double(image.pixels[s + 2])
        }
      }
    }
    var out = RGBImage(width: width, height: height)
    for (dy, entries) in yTab.enumerated() {
      for dx in 0..<width {
        var r = 0.0, g = 0.0, b = 0.0
        for (sy, w) in entries {
          let s = (sy * width + dx) * 3
          r += w * rows[s]
          g += w * rows[s + 1]
          b += w * rows[s + 2]
        }
        let d = (dy * width + dx) * 3
        out.pixels[d] = clampByte(r)
        out.pixels[d + 1] = clampByte(g)
        out.pixels[d + 2] = clampByte(b)
      }
    }
    return out
  }

  /// OpenCV's `computeResizeAreaTab`: (source index, weight) per output index.
  private static func areaTable(source: Int, destination: Int) -> [[(Int, Double)]] {
    let scale = Double(source) / Double(destination)
    return (0..<destination).map { d in
      let f1 = Double(d) * scale, f2 = f1 + scale
      let cell = min(scale, Double(source) - f1)
      var s2 = Int(f2.rounded(.down))
      var s1 = Int(f1.rounded(.up))
      s2 = min(s2, source - 1)
      s1 = min(s1, s2)
      var entries: [(Int, Double)] = []
      if Double(s1) - f1 > 1e-3 { entries.append((s1 - 1, (Double(s1) - f1) / cell)) }
      for s in s1..<max(s1, s2) { entries.append((s, 1 / cell)) }
      if f2 - Double(s2) > 1e-3 { entries.append((s2, min(min(f2 - Double(s2), 1), cell) / cell)) }
      return entries
    }
  }

  /// Bilinear warp by the forward 2x3 `matrix` (source -> destination), black
  /// outside the source, like `cv2.warpAffine` with `BORDER_CONSTANT` 0.
  static func warpAffine(_ image: RGBImage, matrix m: [Double], width: Int, height: Int) -> RGBImage {
    let det = m[0] * m[4] - m[1] * m[3]
    let i00 = m[4] / det, i01 = -m[1] / det, i10 = -m[3] / det, i11 = m[0] / det
    let i02 = -(i00 * m[2] + i01 * m[5]), i12 = -(i10 * m[2] + i11 * m[5])
    var out = RGBImage(width: width, height: height)
    for y in 0..<height {
      for x in 0..<width {
        let sx = i00 * Double(x) + i01 * Double(y) + i02
        let sy = i10 * Double(x) + i11 * Double(y) + i12
        let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
        let fx = sx - Double(x0), fy = sy - Double(y0)
        let d = (y * width + x) * 3
        for c in 0..<3 {
          let v00 = sample(image, x0, y0, c), v10 = sample(image, x0 + 1, y0, c)
          let v01 = sample(image, x0, y0 + 1, c), v11 = sample(image, x0 + 1, y0 + 1, c)
          let v = (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
          out.pixels[d + c] = clampByte(v)
        }
      }
    }
    return out
  }

  @inline(__always)
  private static func sample(_ image: RGBImage, _ x: Int, _ y: Int, _ c: Int) -> Double {
    guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
    return Double(image.pixels[(y * image.width + x) * 3 + c])
  }

  @inline(__always)
  private static func clampByte(_ v: Double) -> UInt8 {
    UInt8(min(max(v.rounded(.toNearestOrEven), 0), 255))
  }
}
