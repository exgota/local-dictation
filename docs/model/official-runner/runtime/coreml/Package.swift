// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "BarkProCoreML", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git",
                           revision: "a00964e1aa8eff99c4bce80bc9c8ff2d4dd1568d", traits: [])],
    targets: [.executableTarget(name: "bark-pro-coreml",
        dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources")])
