// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrowserPet",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BrowserPet", targets: ["BrowserPet"])],
    targets: [
        .executableTarget(name: "BrowserPet", path: "Sources/BrowserPet")
    ]
)
