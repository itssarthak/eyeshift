// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Eyeshift",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Eyeshift", path: "Sources/Eyeshift")]
)
