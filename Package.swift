// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokSpeed",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TokSpeed", targets: ["TokSpeedApp"]),
        .executable(name: "tokspeed-cursor-hook", targets: ["TokSpeedCursorHook"])
    ],
    targets: [
        .target(name: "TokSpeedHookCore"),
        .executableTarget(
            name: "TokSpeedCursorHook",
            dependencies: ["TokSpeedHookCore"]
        ),
        .executableTarget(
            name: "TokSpeedApp",
            dependencies: ["TokSpeedHookCore"],
            path: "Sources",
            exclude: ["TokSpeedHookCore", "TokSpeedCursorHook"],
            sources: ["TokSpeedApp", "TokSpeedCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "TokSpeedTests",
            dependencies: ["TokSpeedApp", "TokSpeedHookCore", "TokSpeedCursorHook"]
        )
    ]
)
