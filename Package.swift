// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mountpoint",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Mountpoint", path: "Sources/Mountpoint"),
        .testTarget(name: "MountpointTests", dependencies: ["Mountpoint"], path: "Tests/MountpointTests"),
    ]
)
