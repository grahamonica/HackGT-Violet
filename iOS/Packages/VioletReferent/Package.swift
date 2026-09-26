// swift-tools-version: 6.0
import PackageDescription

// ReferentCore is pure Swift (Foundation only) so its decision logic builds and
// tests anywhere, including Linux. Apple-specific parts (Vision, Core ML,
// Rekognition) live in a separate target.
let package = Package(
  name: "VioletReferent",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "ReferentCore", targets: ["ReferentCore"])
  ],
  targets: [
    .target(name: "ReferentCore"),
    .testTarget(name: "ReferentCoreTests", dependencies: ["ReferentCore"]),
  ]
)
