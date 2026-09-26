import Foundation
import XCTest
@testable import ReferentCore

final class FaceAlignmentTests: XCTestCase {
  func testSimilarityTransformRecoversAKnownTransform() {
    // Rotate by 10 degrees, scale by 0.8, shift; the fit must recover it exactly.
    let angle = 10.0 * Double.pi / 180, s = 0.8
    let src = FaceAlignment.template
    let dst = src.map { p in
      Point2D(x: s * (cos(angle) * p.x - sin(angle) * p.y) + 5, y: s * (sin(angle) * p.x + cos(angle) * p.y) - 3)
    }
    let m = FaceAlignment.similarityTransform(from: src, to: dst)
    XCTAssertEqual(m[0], s * cos(angle), accuracy: 1e-9)
    XCTAssertEqual(m[3], s * sin(angle), accuracy: 1e-9)
    XCTAssertEqual(m[2], 5, accuracy: 1e-9)
    XCTAssertEqual(m[5], -3, accuracy: 1e-9)
  }

  func testIdentityWarpKeepsPixels() {
    var image = RGBImage(width: 4, height: 3)
    for i in image.pixels.indices { image.pixels[i] = UInt8(i * 7 % 256) }
    let out = FaceAlignment.warpAffine(image, matrix: [1, 0, 0, 0, 1, 0], width: 4, height: 3)
    XCTAssertEqual(out, image)
  }

  func testAreaResizeAveragesBlocks() {
    // 4x2 -> 2x1: each output pixel is the mean of a 2x2 block.
    var image = RGBImage(width: 4, height: 2)
    let values: [UInt8] = [0, 10, 100, 200, 20, 30, 120, 220]
    for (i, v) in values.enumerated() { image.pixels[i * 3] = v }
    let out = FaceAlignment.resizeArea(image, width: 2, height: 1)
    XCTAssertEqual(out.pixels[0], 15)   // (0 + 10 + 20 + 30) / 4
    XCTAssertEqual(out.pixels[3], 160)  // (100 + 200 + 120 + 220) / 4
  }

  /// Compares against Python's `align.py` on the export reference set
  /// (`python -m ml.facequality.training.export`). Set VIOLET_REFERENCE_DIR to
  /// `.../exports/FaceQuality_reference` to run it.
  func testMatchesPythonReferenceAlignment() throws {
    guard let dir = ProcessInfo.processInfo.environment["VIOLET_REFERENCE_DIR"] else {
      throw XCTSkip("VIOLET_REFERENCE_DIR not set")
    }
    let root = URL(fileURLWithPath: dir)
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
    XCTAssertFalse(reference.cases.isEmpty)
    var worstMean = 0.0, worstMax = 0
    for c in reference.cases {
      let crop = try readPPM(root.appendingPathComponent(c.crop_ppm))
      let expected = try readPPM(root.appendingPathComponent(c.aligned_ppm))
      let landmarks = c.landmarks.map { Point2D(x: $0[0], y: $0[1]) }
      let aligned = FaceAlignment.align(crop, landmarks: landmarks, size: reference.size)
      XCTAssertEqual(FaceAlignment.interocularDistance(landmarks), c.interocular_px, accuracy: 1e-3)

      let diffs = zip(aligned.pixels, expected.pixels).map { abs(Int($0) - Int($1)) }
      let mean = Double(diffs.reduce(0, +)) / Double(diffs.count)
      worstMean = max(worstMean, mean)
      worstMax = max(worstMax, diffs.max() ?? 0)
      // OpenCV interpolates in fixed point (1/32 px positions), so allow
      // rounding-level differences, but nothing structural.
      XCTAssertLessThan(mean, 1.0, "\(c.image_id): mean |diff| \(mean)")
    }
    print("alignment parity over \(reference.cases.count) faces: worst mean |diff| \(worstMean), worst max |diff| \(worstMax)")
  }
}

private struct Reference: Decodable {
  let size: Int
  let cases: [Case]

  struct Case: Decodable {
    let image_id: String
    let crop_ppm: String
    let aligned_ppm: String
    let landmarks: [[Double]]
    let interocular_px: Double
  }
}

/// Minimal binary PPM (P6, maxval 255) reader.
private func readPPM(_ url: URL) throws -> RGBImage {
  let data = try Data(contentsOf: url)
  var fields: [String] = []
  var index = data.startIndex
  while fields.count < 4 {
    while index < data.endIndex, data[index] == UInt8(ascii: " ") || data[index] == UInt8(ascii: "\n") { index += 1 }
    var token = ""
    while index < data.endIndex, data[index] != UInt8(ascii: " "), data[index] != UInt8(ascii: "\n") {
      token.append(Character(UnicodeScalar(data[index])))
      index += 1
    }
    fields.append(token)
  }
  index += 1  // single whitespace after maxval
  guard fields[0] == "P6", fields[3] == "255", let w = Int(fields[1]), let h = Int(fields[2]) else {
    throw CocoaError(.fileReadCorruptFile)
  }
  return RGBImage(width: w, height: h, pixels: [UInt8](data[index..<(index + w * h * 3)]))
}
