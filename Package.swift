// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TakoLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TakoLauncher", targets: ["TakoLauncher"])
    ],
    targets: [
        .executableTarget(name: "TakoLauncher")
    ]
)
