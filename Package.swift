// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Tempra",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Tempra", targets: ["Tempra"]),
        .executable(name: "TempraWatchdog", targets: ["TempraWatchdog"]),
        .executable(
            name: "TempraPrivilegedHelper",
            targets: ["TempraPrivilegedHelper"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        )
    ],
    targets: [
        .target(
            name: "TempraSafety",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "TempraSensors",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "Tempra",
            dependencies: [
                "TempraSafety",
                "TempraSensors",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .executableTarget(
            name: "TempraWatchdog",
            dependencies: ["TempraSafety"]
        ),
        .executableTarget(
            name: "TempraPrivilegedHelper",
            dependencies: ["TempraSafety"]
        ),
        .testTarget(
            name: "TempraTests",
            dependencies: [
                "Tempra",
                "TempraSafety",
                "TempraWatchdog",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../.."
                ])
            ]
        )
    ],
    cLanguageStandard: .c2x
)
