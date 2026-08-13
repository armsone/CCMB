// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexCreditMenuBar",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "CodexCreditMenuBar", targets: ["CodexCreditMenuBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "CodexCreditMenuBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "CodexCreditMenuBarTests",
            dependencies: ["CodexCreditMenuBar"]
        )
    ]
)
