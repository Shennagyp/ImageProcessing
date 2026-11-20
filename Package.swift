// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageProcessing",
    products: [
        .library(
            name: "GeneralExecutionProtocol",
            targets: ["GeneralExecutionProtocol"]
        ),
        .library(
            name: "ImageProcessingProtocol",
            targets: ["ImageProcessingProtocol"]
        ),
        .library(
            name: "ImageProcessingRuntime",
            targets: ["ImageProcessingRuntime"]
        )
    ],
    targets: [
        .target(name: "GeneralExecutionProtocol"),
        .target(
            name: "ImageProcessingProtocol",
            dependencies: ["GeneralExecutionProtocol"]
        ),
        .target(
            name: "ImageProcessingRuntime",
            dependencies: ["GeneralExecutionProtocol", "ImageProcessingProtocol"]
        ),
        .testTarget(
            name: "GeneralExecutionProtocolTests",
            dependencies: ["GeneralExecutionProtocol"]
        ),
        .testTarget(
            name: "ImageProcessingProtocolTests",
            dependencies: ["ImageProcessingProtocol", "GeneralExecutionProtocol"]
        ),
        .testTarget(
            name: "ImageProcessingRuntimeTests",
            dependencies: ["ImageProcessingRuntime", "ImageProcessingProtocol", "GeneralExecutionProtocol"]
        )
    ],
    swiftLanguageModes: [.v6]
)
