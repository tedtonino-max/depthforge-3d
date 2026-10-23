// swift-tools-version: 5.10
import PackageDescription

let package = Package(name: "DepthForgeCore", products: [
    .library(name: "DepthForgeCore", targets: ["DepthForgeCore"])
], targets: [
    .target(name: "DepthForgeCore", path: "Sources/Core"),
    .testTarget(name: "DepthForgeCoreTests", dependencies: ["DepthForgeCore"], path: "Tests")
])
