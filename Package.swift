// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MXMasterInput",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "MXMasterInput",
            dependencies: ["SystemEvents", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MXMasterInput",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .target(
            name: "SystemEvents",
            path: "Sources/SystemEvents",
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .testTarget(
            name: "MXMasterInputTests",
            dependencies: ["MXMasterInput"],
            path: "Tests/MXMasterInputTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SystemEventsTests",
            dependencies: ["SystemEvents"],
            path: "Tests/SystemEventsTests"
        ),
    ]
)
