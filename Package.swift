// swift-tools-version: 6.0
// Face ID for Mac (by PK) — the safety core, testable without a camera or a screen.
// The same files are compiled into the app through Xcode's synchronized `glance/` folder.
import PackageDescription

let package = Package(
    name: "FaceIDCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FaceIDCore", path: "glance/Core"),
        .testTarget(name: "FaceIDCoreTests", dependencies: ["FaceIDCore"], path: "pk/CoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
