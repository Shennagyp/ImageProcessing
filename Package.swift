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
        ),
        .library(
            name: "ImageProcessingCPUProvider",
            targets: ["ImageProcessingCPUProvider"]
        ),
        .library(
            name: "ImageProcessingReferenceOperations",
            targets: ["ImageProcessingReferenceOperations"]
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
        .target(
            name: "ImageProcessingCPUProvider",
            dependencies: ["GeneralExecutionProtocol"]
        ),
        .target(
            name: "ImageProcessingReferenceOperations",
            dependencies: [
                "GeneralExecutionProtocol",
                "ImageProcessingProtocol",
                "ImageProcessingCPUProvider"
            ]
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
        ),
        .testTarget(
            name: "ImageProcessingCPUReferenceTests",
            dependencies: [
                "GeneralExecutionProtocol",
                "ImageProcessingProtocol",
                "ImageProcessingRuntime",
                "ImageProcessingCPUProvider",
                "ImageProcessingReferenceOperations"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
