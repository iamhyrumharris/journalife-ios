// swift-tools-version: 6.2
import PackageDescription

// JournalCore holds everything that has no UI: models, stores, media storage,
// archive export/import and search. It must build for iOS, macOS and watchOS,
// so it never imports UIKit or AppKit.
let package = Package(
    name: "JournalCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "JournalCore", targets: ["JournalCore"]),
    ],
    targets: [
        .target(name: "JournalCore"),
        .testTarget(name: "JournalCoreTests", dependencies: ["JournalCore"]),
    ]
)
