// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StatsWarning",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StatsWarning", targets: ["StatsWarning"]),
        .executable(name: "StatsWarningSettings", targets: ["StatsWarningSettings"])
    ],
    targets: [
        .target(name: "TemperatureCore"),
        .target(name: "SMCBridge", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "TemperatureHardware", dependencies: ["SMCBridge", "TemperatureCore"]),
        .target(name: "TemperatureIPC", dependencies: ["TemperatureCore"]),
        .executableTarget(name: "StatsWarning", dependencies: ["TemperatureCore", "TemperatureHardware", "TemperatureIPC"]),
        .executableTarget(name: "StatsWarningSettings", dependencies: ["TemperatureCore", "TemperatureIPC"]),
        .testTarget(name: "TemperatureCoreTests", dependencies: ["TemperatureCore", "TemperatureIPC"])
    ]
)
