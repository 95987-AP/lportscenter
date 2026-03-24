// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OpenPortsMenuBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "OpenPortsMenuBar", targets: ["OpenPortsMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "OpenPortsMenuBar"
        ),
    ]
)
