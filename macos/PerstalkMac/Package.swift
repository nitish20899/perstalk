// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PerstalkMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PerstalkMac", targets: ["PerstalkMac"])
    ],
    targets: [
        .executableTarget(name: "PerstalkMac")
    ]
)
