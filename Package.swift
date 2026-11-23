// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "WindowManagement",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "WindowManagement", targets: ["WindowManagement"]),
    .library(name: "WindowManagementMacOS", targets: ["WindowManagementMacOS"]),
  ],
  targets: [
    .binaryTarget(name: "CWindowManagement", path: "Artifacts/CWindowManagement.xcframework"),
    .target(name: "WindowManagement", dependencies: ["CWindowManagement"]),
    .target(name: "WindowManagementMacOS", dependencies: ["WindowManagement"]),
    .testTarget(name: "WindowManagementTests", dependencies: ["WindowManagement"]),
    .testTarget(
      name: "WindowManagementMacOSTests",
      dependencies: ["WindowManagementMacOS", "WindowManagement"]),
  ]
)
