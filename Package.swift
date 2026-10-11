// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WiFiMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WiFiMeter",
            path: "Sources/WiFiMeter",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
