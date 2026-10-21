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
        .package(url: "https://github.com/PsychQuant/pdf-visual-diff-swift.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .target(
            name: "PDFToLaTeXCore",
            dependencies: [
                .product(name: "PDFVisualDiff", package: "pdf-visual-diff-swift"),
            ]
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
