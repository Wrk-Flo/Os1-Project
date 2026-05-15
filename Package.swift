// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OS1",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "OS1",
            targets: ["OS1"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "OS1",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/OS1",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OS1Tests",
            dependencies: ["OS1"],
            path: "Tests/OS1Tests"
        )
    ]
)
