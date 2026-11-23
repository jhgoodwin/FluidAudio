// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parakeet-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "FluidAudio", path: "../..")],
    targets: [
        .executableTarget(
            name: "parakeet-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
