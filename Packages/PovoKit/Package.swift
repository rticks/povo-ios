// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PovoKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PovoKit", targets: ["PovoKit"])],
    targets: [
        .target(name: "PovoKit"),
        .testTarget(name: "PovoKitTests", dependencies: ["PovoKit"], resources: [.copy("Fixtures")])
    ]
)
