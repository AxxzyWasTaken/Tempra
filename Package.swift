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
        .executableTarget(
            name: "TempraPrivilegedHelper",
            dependencies: ["TempraSafety"]
        ),
        .testTarget(
            name: "TempraTests",
            dependencies: ["Tempra", "TempraSafety"]
        )
    ],
    cLanguageStandard: .c2x
)
