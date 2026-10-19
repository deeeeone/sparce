// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sparce",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sparce",
            path: "Sources/Sparce"
        )
    ]
)
