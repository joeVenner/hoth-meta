// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoTHCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HoTHCore", targets: ["HoTHCore"])
    ],
    targets: [
        .target(name: "HoTHCore"),
        .testTarget(
            name: "HoTHCoreTests",
            dependencies: ["HoTHCore"],
            resources: [.copy("Resources")]
        )
    ]
)
