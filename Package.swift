// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DemoRec",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "demorec", targets: ["demorec"]),
        .executable(name: "DemoRecApp", targets: ["DemoRecApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DemoRecKit",
            path: "Sources/DemoRecKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "demorec",
            dependencies: [
                "DemoRecKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/demorec",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/demorec/Info.plist"]),
            ]
        ),
        // SwiftUI front end. scripts/build-app.sh wraps the binary in DemoRec.app.
        .executableTarget(
            name: "DemoRecApp",
            dependencies: ["DemoRecKit"],
            path: "Sources/DemoRecApp",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
