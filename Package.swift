// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Sentry",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SentryApp",
            dependencies: ["SentryUI"],
            path: "Sources/SentryApp"
        ),
        .target(
            name: "SentryEngine",
            path: "Sources/SentryEngine",
            resources: [
                .copy("Resources/GeoLite2-Country.mmdb"),
                .copy("Resources/tracker-domains.txt"),
            ]
        ),
        .target(
            name: "SentryUI",
            dependencies: ["SentryEngine"],
            path: "Sources/SentryUI"
        ),
        .testTarget(
            name: "SentryEngineTests",
            dependencies: ["SentryEngine"],
            resources: [
                .copy("Fixtures/lsof-sample-output.txt"),
            ]
        ),
    ]
)
