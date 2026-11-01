// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoolNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CoolNotch",
            path: "Sources/CoolNotch"
        )
    ]
)
