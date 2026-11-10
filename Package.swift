// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SOPSVault",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SOPSVault", targets: ["SOPSVault"])],
    targets: [
        .target(name: "VaultCore"),
        .executableTarget(name: "SOPSVault", dependencies: ["VaultCore"]),
        .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"])
    ]
)
