// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoPeek",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NoPeek", targets: ["NoPeek"])
    ],
    targets: [
        // Pure, UI-free logic (models, intruder policy, secrets). Unit tested.
        .target(name: "NoPeekCore"),
        // The menu-bar app: window tracking, overlays, camera, settings UI.
        .executableTarget(
            name: "NoPeek",
            dependencies: ["NoPeekCore"]
        ),
        .testTarget(
            name: "NoPeekCoreTests",
            dependencies: ["NoPeekCore"]
        ),
        // Exercises the app's input → wrong-try → photo-request logic (no UI, no camera).
        .testTarget(
            name: "NoPeekTests",
            dependencies: ["NoPeek", "NoPeekCore"]
        )
    ]
)
