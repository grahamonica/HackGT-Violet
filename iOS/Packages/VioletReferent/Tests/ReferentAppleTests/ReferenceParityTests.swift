#if canImport(Vision) && canImport(CoreML)
import Foundation
import XCTest
import ReferentCore
@testable import ReferentApple

/// Checks the on-device pipeline against the Python reference set written by
/// `python -m ml.facequality.training.export`. Run on a Mac:
///
///     VIOLET_REFERENCE_DIR=<repo>/ml/facequality/training/exports/FaceQuality_reference swift test
///
/// Each test prints its measurement; thresholds only catch clear breakage.
final class ReferenceParityTests: XCTestCase {
  struct Case: Decodable {
    let image_id: String
    let crop: String
    let aligned: String
    let landmarks: [[Double]]
    let interocular_px: Double
    let quality: Double
  }

  struct Reference: Decodable { let cases: [Case] }

  var root: URL!
  var cases: [Case] = []
  var model: FaceQualityModel!

  override func setUp() async throws {
    guard let dir = ProcessInfo.processInfo.environment["VIOLET_REFERENCE_DIR"] else {
      throw XCTSkip("VIOLET_REFERENCE_DIR not set")
    }
    root = URL(fileURLWithPath: dir)
    cases = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: root.appendingPathComponent("cases.json"))).cases
    model = try await FaceQualityModel.bundled()
  }

  func image(_ relative: String) throws -> CGImage {
    let data = try Data(contentsOf: root.appendingPathComponent(relative))
    return try XCTUnwrap(ImageConversion.cgImage(from: data), relative)
  }

  /// Core ML (float16) vs PyTorch on the same Python-aligned faces.
  func testCoreMLMatchesPyTorch() throws {
    var diffs: [Double] = []
    for c in cases {
      let face = try XCTUnwrap(ImageConversion.rgbImage(try image(c.aligned)))
      diffs.append(abs(try model.predict(alignedFace: face, interocularPx: c.interocular_px) - c.quality))
    }
    print("Core ML vs PyTorch: mean |diff| \(diffs.reduce(0, +) / Double(diffs.count)), max \(diffs.max()!)")
    XCTAssertLessThan(diffs.max()!, 0.03)
  }

  /// Vision's derived 5 points vs CelebA's annotations, in units of eye distance.
  func testVisionLandmarksAgreeWithCelebA() throws {
    var errors: [Double] = [], missed = 0
    for c in cases {
      let truth = c.landmarks.map { Point2D(x: $0[0], y: $0[1]) }
      guard let face = try nearest(VisionFaceAnalyzer.faces(in: image(c.crop)), to: truth) else { missed += 1; continue }
      let iod = FaceAlignment.interocularDistance(truth)
      let perPoint = zip(face.landmarks, truth).map { hypot($0.x - $1.x, $0.y - $1.y) / iod }
      errors.append(perPoint.reduce(0, +) / 5)
      print("  \(c.image_id): per-point error / eye distance = \(perPoint.map { String(format: "%.3f", $0) })")
    }
    print("Vision vs CelebA landmarks: mean error \(errors.reduce(0, +) / Double(max(errors.count, 1))) eye distances, faces missed \(missed)/\(cases.count)")
    XCTAssertLessThan(errors.reduce(0, +) / Double(max(errors.count, 1)), 0.25)
  }

  /// Full on-device path (Apple JPEG decode + Vision landmarks + Swift alignment
  /// + Core ML) vs the Python score. Differences here combine all sources.
  func testEndToEndQualityIsClose() throws {
    var diffs: [Double] = []
    for c in cases {
      let crop = try image(c.crop)
      let truth = c.landmarks.map { Point2D(x: $0[0], y: $0[1]) }
      guard let face = try nearest(VisionFaceAnalyzer.faces(in: crop), to: truth),
            let pixels = ImageConversion.rgbImage(crop) else { continue }
      let aligned = FaceAlignment.align(pixels, landmarks: face.landmarks, size: model.inputSize)
      let quality = try model.predict(alignedFace: aligned, interocularPx: FaceAlignment.interocularDistance(face.landmarks))
      diffs.append(abs(quality - c.quality))
    }
    print("end-to-end vs Python: mean |diff| \(diffs.reduce(0, +) / Double(max(diffs.count, 1))), max \(diffs.max() ?? 0) over \(diffs.count) faces")
    XCTAssertLessThan(diffs.reduce(0, +) / Double(max(diffs.count, 1)), 0.15)
  }

  func testAnalyzerProducesSendableCrops() async throws {
    let analyzer = VisionFaceAnalyzer(model: model)
    let data = try Data(contentsOf: root.appendingPathComponent(cases[0].crop))
    let faces = try await analyzer.analyze(ReferentFrame(jpegData: data, timestamp: 0))
    let face = try XCTUnwrap(faces.first, "no face found")
    XCTAssertNotNil(ImageConversion.cgImage(from: face.crop), "crop must be a valid JPEG")
    XCTAssert((0...1).contains(face.quality))
  }

  private func nearest(_ faces: [VisionFace], to truth: [Point2D]) -> VisionFace? {
    let cx = truth.map(\.x).reduce(0, +) / 5, cy = truth.map(\.y).reduce(0, +) / 5
    return faces.min { a, b in
      hypot(a.box.midX - cx, a.box.midY - cy) < hypot(b.box.midX - cx, b.box.midY - cy)
    }
  }
}
#endif
