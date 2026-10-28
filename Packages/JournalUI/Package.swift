// swift-tools-version: 6.2
import PackageDescription

// JournalUI holds SwiftUI views that the Mac app (Phase 7) will reuse: rows, chips,
// the media viewer and editor pieces. iPhone-only screens live in the app target.
let package = Package(
    name: "JournalUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "JournalUI", targets: ["JournalUI"]),
    ],
    dependencies: [
        .package(path: "../JournalCore"),
    ],
    targets: [
        .target(
            name: "JournalUI",
            dependencies: ["JournalCore"],
            resources: [.process("Resources")]
        ),
    ]
)
