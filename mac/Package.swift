// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InFocusDrive",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "InFocusDrive",
            path: "Sources/InFocusDrive",
            linkerSettings: [.linkedFramework("NetFS")]
        ),
    ]
)
