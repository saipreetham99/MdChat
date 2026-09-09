// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MdChat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MdChat",
            path: "Sources/MdChat",
            resources: [.copy("Resources")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
