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
        )
    ],
    targets: [
        .target(name: "GeneralExecutionProtocol"),
        .target(
            name: "ImageProcessingProtocol",
            dependencies: ["GeneralExecutionProtocol"]
        ),
        .testTarget(
            name: "GeneralExecutionProtocolTests",
            dependencies: ["GeneralExecutionProtocol"]
        ),
        .testTarget(
            name: "ImageProcessingProtocolTests",
            dependencies: ["ImageProcessingProtocol", "GeneralExecutionProtocol"]
        )
    ],
    swiftLanguageModes: [.v6]
)
