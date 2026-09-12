// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContainerStatus",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "ContainerStatus",
            path: "Sources/ContainerStatus"
        )
    ]
)
