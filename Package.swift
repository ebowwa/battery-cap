// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryCap",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BatteryCap",
            path: "Sources/BatteryCap"
            // The LaunchDaemon plist is generated at runtime by
            // PersistenceInstaller, so we don't need to bundle a template.
        )
    ]
)
