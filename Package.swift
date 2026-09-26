// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenTank",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TokenTank", path: "Sources/TokenTank")
    ]
)
