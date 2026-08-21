// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gitty",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gitty", targets: ["Gitty"])
    ],
    targets: [
        .executableTarget(name: "Gitty"),
        .testTarget(name: "GittyTests", dependencies: ["Gitty"])
    ],
    swiftLanguageModes: [.v5]
)
