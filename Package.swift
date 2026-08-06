// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexCreditMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexCreditMenuBar", targets: ["CodexCreditMenuBar"])
    ],
    targets: [
        .executableTarget(name: "CodexCreditMenuBar")
    ]
)
