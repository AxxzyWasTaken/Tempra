// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Tempra",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Tempra", targets: ["Tempra"]),
        .executable(name: "TempraWatchdog", targets: ["TempraWatchdog"])
    ],
    targets: [
        .target(name: "TempraSafety"),
        .target(
            name: "TempraSensors",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "Tempra",
            dependencies: ["TempraSafety", "TempraSensors"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "TempraWatchdog",
            dependencies: ["TempraSafety"]
        ),
        .testTarget(
            name: "TempraTests",
            dependencies: ["Tempra", "TempraSafety"]
        )
    ],
    cLanguageStandard: .c2x
)
