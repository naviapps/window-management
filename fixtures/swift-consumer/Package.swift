// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "WindowManagementConsumer",
  platforms: [.macOS(.v26)],
  dependencies: [.package(name: "window-management", path: "../sdk")],
  targets: [
    .executableTarget(
      name: "WindowManagementConsumer",
      dependencies: [
        .product(name: "WindowManagement", package: "window-management"),
        .product(name: "WindowManagementMacOS", package: "window-management"),
      ])
  ]
)
