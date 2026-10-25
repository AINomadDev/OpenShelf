// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenShelf",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenShelf", targets: ["OpenShelf"])],
    targets: [
        .executableTarget(name: "OpenShelf"),
        .testTarget(name: "OpenShelfTests", dependencies: ["OpenShelf"])
    ]
)
