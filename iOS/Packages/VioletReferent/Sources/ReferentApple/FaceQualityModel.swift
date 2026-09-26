#if canImport(CoreML)
import CoreML
import CoreVideo
import Foundation
import ReferentCore

/// The local quality model (exported by `ml/facequality/training/export.py`).
///
/// Input: an aligned 112x112 RGB face (see `FaceAlignment`) and the eye
/// distance in pixels of the crop sent to Rekognition. Output: predicted
/// Rekognition utility in [0, 1].
///
/// Not safe for concurrent predictions from multiple threads; `ReferentPipeline`
/// analyzes frames one at a time.
public final class FaceQualityModel: @unchecked Sendable {
  private let model: MLModel
  public let inputSize: Int

  /// Loads the model bundled with this package, compiling it on first use.
  public static func bundled(configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> FaceQualityModel {
    if let compiled = Bundle.module.url(forResource: "FaceQuality", withExtension: "mlmodelc") {
      return try FaceQualityModel(compiledModelURL: compiled, configuration: configuration)
    }
    guard let package = Bundle.module.url(forResource: "FaceQuality", withExtension: "mlpackage") else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "FaceQuality.mlpackage is missing from the package resources"])
    }
    return try await FaceQualityModel(packageURL: package, configuration: configuration)
  }

  /// Compiles and loads an `.mlpackage` (e.g. straight from `training/exports/`).
  public convenience init(packageURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) async throws {
    let compiled = try await MLModel.compileModel(at: packageURL)
    try self.init(compiledModelURL: compiled, configuration: configuration)
  }

  public init(compiledModelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) throws {
    model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
    let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint
    inputSize = constraint?.pixelsWide ?? 112
  }

  /// Quality in [0, 1] for an aligned face of `inputSize` x `inputSize`.
  public func predict(alignedFace: RGBImage, interocularPx: Double) throws -> Double {
    precondition(alignedFace.width == inputSize && alignedFace.height == inputSize, "face must be aligned to \(inputSize)x\(inputSize)")
    let interocular = try MLMultiArray(shape: [1], dataType: .float32)
    interocular[0] = NSNumber(value: Float(interocularPx))
    let input = try MLDictionaryFeatureProvider(dictionary: [
      "face": MLFeatureValue(pixelBuffer: try Self.pixelBuffer(alignedFace)),
      "interocular_px": MLFeatureValue(multiArray: interocular),
    ])
    let output = try model.prediction(from: input)
    guard let quality = output.featureValue(for: "quality")?.multiArrayValue?[0].doubleValue else {
      throw CocoaError(.coderValueNotFound, userInfo: [NSLocalizedDescriptionKey: "model returned no quality"])
    }
    return quality
  }

  /// RGB bytes -> 32BGRA pixel buffer (Core ML converts it to the model's RGB input).
  static func pixelBuffer(_ image: RGBImage) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed (\(status))"])
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<image.height {
      for x in 0..<image.width {
        let s = (y * image.width + x) * 3, d = y * stride + x * 4
        base[d] = image.pixels[s + 2]      // B
        base[d + 1] = image.pixels[s + 1]  // G
        base[d + 2] = image.pixels[s]      // R
        base[d + 3] = 255                  // A
      }
    }
    return buffer
  }
}
#endif
