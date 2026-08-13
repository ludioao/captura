// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ScreenRecorder", targets: ["ScreenRecorder"])],
    targets: [
        .executableTarget(
            name: "ScreenRecorder",
            path: "ScreenRecorder",
            exclude: ["ScreenRecorder.entitlements"]
        ),
        .testTarget(
            name: "ScreenRecorderTests",
            dependencies: ["ScreenRecorder"],
            path: "ScreenRecorderTests"
        )
    ]
)
