// swift-tools-version: 6.0
import PackageDescription

// ReferentCore: pure Swift (Foundation only) decision logic and alignment;
//   builds and tests anywhere, including Linux.
// ReferentRekognition: Rekognition client with hand-rolled SigV4 signing;
//   CryptoKit on Apple platforms, swift-crypto (same API) on Linux only.
// ReferentApple: Vision landmarks + the Core ML quality model; Apple only.

var dependencies: [Package.Dependency] = []
var rekognitionDependencies: [Target.Dependency] = ["ReferentCore"]
var products: [Product] = [
  .library(name: "ReferentCore", targets: ["ReferentCore"]),
  .library(name: "ReferentRekognition", targets: ["ReferentRekognition"]),
]
var targets: [Target] = [
  .target(name: "ReferentCore"),
  .target(name: "ReferentRekognition", dependencies: rekognitionDependencies),
  .testTarget(name: "ReferentCoreTests", dependencies: ["ReferentCore"]),
  .testTarget(name: "ReferentRekognitionTests", dependencies: ["ReferentRekognition"]),
]

#if os(Linux)
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
targets[1] = .target(
  name: "ReferentRekognition",
  dependencies: rekognitionDependencies + [.product(name: "Crypto", package: "swift-crypto")])
#else
products.append(.library(name: "ReferentApple", targets: ["ReferentApple"]))
targets += [
  // The model is copied as-is and compiled on first use (MLModel.compileModel),
  // which works with both Xcode and `swift test`.
  .target(name: "ReferentApple", dependencies: ["ReferentCore"], resources: [.copy("Resources/FaceQuality.mlpackage")]),
  .testTarget(name: "ReferentAppleTests", dependencies: ["ReferentApple"]),
]
#endif

let package = Package(
  name: "VioletReferent",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: products,
  dependencies: dependencies,
  targets: targets
)
