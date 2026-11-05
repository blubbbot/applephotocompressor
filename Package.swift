// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoCompressor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhotoCompressor", targets: ["PhotoCompressor"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CompressionCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PhotoCompressor", dependencies: ["CompressionCore"]),
        .testTarget(name: "CompressionCoreTests", dependencies: ["CompressionCore", "CSQLite"]),
        .testTarget(name: "PhotoCompressorTests", dependencies: ["PhotoCompressor"])
    ]
)
