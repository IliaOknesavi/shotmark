// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shotmark",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "Shotmark", path: "Sources/Shotmark")],
    swiftLanguageModes: [.v5]
)
