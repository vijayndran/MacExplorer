// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacExplorer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.1")
    ],
    targets: [
        // Pure, presentation-free logic that can be unit-tested headlessly.
        .target(
            name: "MacExplorerCore",
            path: "Sources/MacExplorerCore"
        ),
        .executableTarget(
            name: "MacExplorer",
            dependencies: ["CoreXLSX", "MacExplorerCore"],
            path: "MacExplorer",
            resources: [
                .copy("Resources/highlight.min.js"),
                .copy("Resources/atom-one-dark.min.css"),
                .copy("Resources/atom-one-light.min.css")
            ]
        ),
        .testTarget(
            name: "MacExplorerCoreTests",
            dependencies: ["MacExplorerCore"],
            path: "Tests/MacExplorerCoreTests"
        )
    ]
)
