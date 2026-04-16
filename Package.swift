// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "pdf-to-latex-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDFToLaTeXCore", targets: ["PDFToLaTeXCore"]),
        .executable(name: "pdf-to-latex", targets: ["PDFToLaTeXCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "PDFToLaTeXCore",
            dependencies: []
        ),
        .executableTarget(
            name: "PDFToLaTeXCLI",
            dependencies: [
                "PDFToLaTeXCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "PDFToLaTeXCoreTests",
            dependencies: ["PDFToLaTeXCore"]
        ),
    ]
)
