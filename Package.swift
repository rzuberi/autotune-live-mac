// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AutoTuneLiveMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AutoTuneLiveMac",
            targets: ["AutoTuneLiveMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AutoTuneLiveMac",
            path: "Sources"
        )
    ]
)
