#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import ReferentCore
import UniformTypeIdentifiers

/// Image conversions shared by the analyzer and the tests.
public enum ImageConversion {
  /// Decodes JPEG/PNG data. Orientation metadata is ignored (frames are assumed upright).
  public static func cgImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// JPEG-encodes an image (what gets sent to Rekognition).
  public static func jpegData(_ image: CGImage, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  /// The image's pixels as 8-bit RGB (alpha dropped).
  public static func rgbImage(_ image: CGImage) -> RGBImage? {
    let width = image.width, height = image.height
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }
    let rgba = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
      pixels[i * 3] = rgba[i * 4]
      pixels[i * 3 + 1] = rgba[i * 4 + 1]
      pixels[i * 3 + 2] = rgba[i * 4 + 2]
    }
    return RGBImage(width: width, height: height, pixels: pixels)
  }
}
#endif
