// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Tempra",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Tempra", targets: ["Tempra"])
    ],
    targets: [
        .target(
            name: "TempraSensors",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "Tempra",
            dependencies: ["TempraSensors"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "TempraTests",
            dependencies: ["Tempra"]
        )
    ],
    cLanguageStandard: .c2x
)
