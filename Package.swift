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
    targets: [
        .executableTarget(name: "CodexCreditMenuBar"),
        .testTarget(
            name: "CodexCreditMenuBarTests",
            dependencies: ["CodexCreditMenuBar"]
        )
    ]
)
