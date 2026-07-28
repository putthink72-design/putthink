// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PuttPhysicsKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "PuttPhysicsKit", targets: ["PuttPhysicsKit"])
    ],
    targets: [
        .target(
            name: "PuttPhysicsKit",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "PuttPhysicsKitTests",
            dependencies: ["PuttPhysicsKit"],
            resources: [.process("Resources")]
        )
    ]
)
