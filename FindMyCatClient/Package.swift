// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "FindMyCatClient",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "FindMyCatClient",
            targets: ["FindMyCatClient"]),
    ],
    dependencies: [
        // Add any external dependencies here
    ],
    targets: [
        .executableTarget(
            name: "FindMyCatClient",
            dependencies: [],
            path: ".",
            sources: [
                "FindMyCatClientApp.swift",
                "ViewModels/MainViewModel.swift",
                "Views/ContentView.swift"
            ]
        ),
    ]
)